# cloud-guardian

A Claude Code plugin that prevents destructive operations on AWS, EKS, Kubernetes, and the local filesystem.

**No cluster is trusted by default. All dangerous operations require explicit user confirmation.**

## How it works

1. Claude attempts a destructive command
2. The `PreToolUse` hook intercepts it and **blocks**, printing a hash
3. Claude shows the user exactly what was blocked and asks: **"Confirm? Type YES."**
4. User says YES → Claude runs `cloud-guardian-approve <hash>`
5. Claude retries → hook finds the token → **allows once** → token consumed

No bypass. No auto-approval. The token is one-time and expires in 5 minutes.

---

## Protection tiers

### Tier 1 — Always requires confirmation (all clusters, including whitelisted)

**Kubernetes**

| Pattern | Risk |
|---|---|
| `kubectl delete pvc / persistentvolumeclaim` | Permanent data loss |
| `kubectl delete namespace / ns` | Deletes all resources in namespace |
| `kubectl delete ... --all / -A` | Bulk deletion |
| `eksctl delete cluster` | Destroys entire EKS cluster |

**AWS — any service**

Any `aws <service> delete-* / terminate-* / remove-*` is blocked regardless of cluster whitelist. This covers all services including IAM, EC2, RDS, EKS, DynamoDB, ElastiCache, S3, SNS, SQS, Route53, KMS, Secrets Manager, ECR, ECS, ELB, CloudFormation, Lambda, and any future services.

Special cases: `aws s3 rm`, `aws s3 rb`, `aws s3 sync --delete`

**Infrastructure**

| Pattern | Risk |
|---|---|
| `terraform destroy` | Full environment teardown |

**Local filesystem**

| Pattern | Risk |
|---|---|
| `rm -r/-R/--recursive` on absolute paths, `~`, `$HOME` | Recursive deletion of important directories |
| `find ... -delete` | Bulk file deletion |
| `find ... -exec rm` | Bulk file deletion via find |
| `shred` | Unrecoverable secure wipe |

Relative path removals (`rm -rf ./build`) are intentionally allowed.

---

### Tier 2 — Requires confirmation on non-whitelisted clusters

On clusters not in the whitelist, Claude cannot autonomously execute:

| Pattern | Why |
|---|---|
| All `kubectl` and `helm` commands | Unknown cluster = treat as production |
| `eksctl delete nodegroup / addon` | Node group removal |

> AWS operations are always Tier 1 regardless of whitelist — the k8s cluster whitelist does not exempt AWS CLI operations.

---

## Whitelist

Add a dev/test cluster to relax Tier 2 restrictions. **Tier 1 always requires confirmation even on whitelisted clusters.**

Adding to the whitelist requires interactive confirmation to prevent accidents.

```bash
# Add cluster (prompts for confirmation)
cloud-guardian whitelist add my-dev-cluster

# List
cloud-guardian whitelist list

# Remove
cloud-guardian whitelist remove my-dev-cluster

# Show current context and protection level
cloud-guardian status
```

Config: `~/.config/cloud-guardian/config.json`

```json
{
  "whitelistedClusters": ["my-dev-cluster"]
}
```

---

## Skills

- `/guardian-status` — Show current cluster context and active protection level
- `/guardian-approve` — Walk through the confirmation flow for a blocked operation

---

## Installation

### Option 1: From source (recommended)

```bash
git clone https://github.com/BlueShells/cloud-guardian
cd cloud-guardian
bash setup/install.sh
```

The install script:
- Copies `cloud-guardian` and `cloud-guardian-approve` to `~/.local/bin/`
- Creates `~/.config/cloud-guardian/` with a default empty config
- Prints the exact snippet to add to `~/.claude/settings.json`

Then add the printed hook snippet to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash /path/to/cloud-guardian/hooks/check-destructive.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

### Option 2: As a Claude Code plugin

Add to `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "cloud-guardian": {
      "source": {
        "source": "github",
        "repo": "BlueShells/cloud-guardian"
      }
    }
  },
  "enabledPlugins": {
    "cloud-guardian@cloud-guardian": true
  }
}
```

Restart Claude Code to download the plugin, then find the installed path:

```bash
ls ~/.claude/plugins/cache/cloud-guardian/cloud-guardian/
```

Add the hook pointing to that path:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/plugins/cache/cloud-guardian/cloud-guardian/<version>/hooks/check-destructive.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

### Option 3: Team-wide protection (protect all members via project repo)

Commit cloud-guardian into any infrastructure repo so every team member is automatically protected when they open Claude Code on that project — no manual installation required.

**Step 1**: Copy the hook script into the repo:

```bash
mkdir -p .claude/hooks
curl -o .claude/hooks/cloud-guardian.sh \
  https://raw.githubusercontent.com/BlueShells/cloud-guardian/main/hooks/check-destructive.sh
chmod +x .claude/hooks/cloud-guardian.sh
```

**Step 2**: Create `.claude/settings.json` in the project root:

```json
{
  "permissions": {
    "disableBypassPermissionsMode": "disable"
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/cloud-guardian.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

**Step 3**: Commit and push both files.

Anyone who clones the repo and opens Claude Code is immediately protected. `disableBypassPermissionsMode` prevents bypassing with `--dangerously-skip-permissions`.

**Note**: `cloud-guardian-approve` must still be installed on each machine for the approval flow to work. Add this to your team onboarding:

```bash
curl -o ~/.local/bin/cloud-guardian-approve \
  https://raw.githubusercontent.com/BlueShells/cloud-guardian/main/bin/cloud-guardian-approve
chmod +x ~/.local/bin/cloud-guardian-approve
```

---

## Security hardening

### Protection against `--dangerously-skip-permissions`

cloud-guardian defends at two independent levels:

**Level 1 — Hook `permissionDecision: "deny"`** (built-in)

The hook uses the PreToolUse-specific `permissionDecision: "deny"` field, which is enforced by the hook system independently of the global permission mode. Destructive commands are blocked even when `--dangerously-skip-permissions` is active.

**Level 2 — Disable bypass mode entirely** (recommended for teams)

Add to `.claude/settings.json` (project-level, committed to the repo):

```json
{
  "permissions": {
    "disableBypassPermissionsMode": "disable"
  }
}
```

Anyone who tries `claude --dangerously-skip-permissions` is rejected at startup.

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CLOUD_GUARDIAN_CONFIG` | `~/.config/cloud-guardian/config.json` | Whitelist config path |
| `CLOUD_GUARDIAN_TOKEN_DIR` | `~/.config/cloud-guardian/tokens` | Approval token directory |
