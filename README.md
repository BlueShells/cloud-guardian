# cloud-guardian

A Claude Code plugin that prevents destructive operations on AWS, EKS, and Kubernetes clusters.

**No cluster is trusted by default. All dangerous operations require explicit user confirmation.**

## How it works

1. Claude attempts a destructive command
2. The `PreToolUse` hook intercepts it and **blocks** with a hash
3. Claude shows the user exactly what was blocked and asks: **"Confirm? Type YES."**
4. User says YES → Claude runs `cloud-guardian-approve <hash>`
5. Claude retries → hook finds the token → **allows once** → token consumed

No bypass. No auto-approval. The token is one-time and expires in 5 minutes.

## Protection tiers

### Tier 1 — Always requires confirmation (all clusters, including whitelisted)

| Command pattern | Risk |
|---|---|
| `kubectl delete pvc / namespace / --all` | Permanent data loss |
| `eksctl delete cluster` | Destroys entire EKS cluster |
| `aws rds delete-db-instance / delete-db-cluster` | Database deletion |
| `aws eks delete-cluster` | EKS cluster removal via CLI |
| `aws s3 rb` / `s3api delete-bucket` | S3 bucket deletion |
| `terraform destroy` | Full environment teardown |

### Tier 2 — Requires confirmation on non-whitelisted clusters

| Command pattern | Why blocked |
|---|---|
| All `kubectl` and `helm` commands | Unknown cluster = treat as production |
| `aws ec2 terminate-instances` | Instance termination |
| `aws s3 rm` / `s3 sync --delete` | Object deletion |
| `aws iam delete-*` | IAM resource deletion |
| `aws cloudformation delete-stack` | Stack teardown |
| `aws lambda delete-function` | Function deletion |
| `aws ec2 delete-*` | EC2 resource deletion |
| `eksctl delete nodegroup / addon` | Node group removal |

## Whitelist

Whitelisted clusters are trusted for Tier 2 operations but **Tier 1 always requires confirmation**.

```bash
# Add a dev/test cluster to whitelist (requires interactive confirmation)
cloud-guardian whitelist add my-dev-cluster

# List whitelisted clusters
cloud-guardian whitelist list

# Remove
cloud-guardian whitelist remove my-dev-cluster
```

Config stored at: `~/.config/cloud-guardian/config.json`

```json
{
  "whitelistedClusters": ["my-dev-cluster"]
}
```

## Skills

- `/guardian-status` — Show current context and active protection level
- `/guardian-approve` — Walk through confirmation flow for a blocked operation

## Installation

### From GitHub (as Claude Code plugin)

Add to `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "cloud-guardian": {
      "source": {
        "source": "github",
        "repo": "YOUR_USERNAME/cloud-guardian"
      }
    }
  },
  "enabledPlugins": {
    "cloud-guardian@cloud-guardian": true
  }
}
```

After plugin cache is downloaded, add the hook (path varies by version):

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "bash ~/.claude/plugins/cache/cloud-guardian/cloud-guardian/<version>/hooks/check-destructive.sh",
        "timeout": 5
      }]
    }]
  }
}
```

### From source (local)

```bash
git clone https://github.com/YOUR_USERNAME/cloud-guardian
cd cloud-guardian
bash setup/install.sh
```

The install script copies binaries to `~/.local/bin/` and prints the exact hook config to add to `~/.claude/settings.json`.

## Security hardening

### Protection against `--dangerously-skip-permissions`

By default, `--dangerously-skip-permissions` bypasses Claude Code's interactive permission prompts. cloud-guardian defends against this at two levels:

**Level 1 — Hook `permissionDecision: "deny"`** (built-in to this plugin)

The `block()` function in the hook uses the PreToolUse-specific `permissionDecision: "deny"` field, which is enforced by the hook system independently of the global permission mode. This means destructive commands are blocked even when permissions are bypassed.

**Level 2 — Disable bypass mode entirely** (recommended for production teams)

Add this to `.claude/settings.json` (project-level, committed to the repo) to completely prevent `--dangerously-skip-permissions` from being activated:

```json
{
  "permissions": {
    "disableBypassPermissionsMode": "disable"
  }
}
```

With this setting, anyone who tries to run `claude --dangerously-skip-permissions` will be rejected at startup. Combine with Level 1 for defense in depth.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CLOUD_GUARDIAN_CONFIG` | `~/.config/cloud-guardian/config.json` | Config file path |
| `CLOUD_GUARDIAN_TOKEN_DIR` | `~/.config/cloud-guardian/tokens` | Approval token directory |
