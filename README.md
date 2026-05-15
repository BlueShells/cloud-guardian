# cloud-guardian

A Claude Code plugin that prevents destructive and dangerous operations on AWS, GCP, Azure, Kubernetes, Vault, and the local filesystem.

**No cluster is trusted by default. All dangerous operations require explicit user confirmation — even edits that look safe but can cause outages.**

## How it works

1. Claude attempts a potentially dangerous command
2. The `PreToolUse` hook intercepts it, **blocks**, and prints a hash + risk explanation
3. Claude presents the risk to the user: _"This will change X. Impact: Y. Confirm? Type YES."_
4. User says YES → Claude runs `cloud-guardian-approve <hash>`
5. Claude retries → hook finds the token → **allows once** → token consumed

No bypass. No auto-approval. The token is one-time and expires in 5 minutes.

---

## Why edits are as dangerous as deletes

Most safety tools only block deletes. cloud-guardian also blocks **modifications that can cause production outages**:

- Editing an `Ingress` → external traffic routing breaks immediately
- Editing a `NetworkPolicy` → service-to-service communication drops
- Changing a Route53 DNS record → global outage for minutes or hours
- Modifying an ALB listener → all users behind the LB are affected
- `kubectl scale --replicas=0` → immediate downtime, no rollback needed
- `terraform apply` → can destroy or misconfigure any managed resource

The hook forces Claude to **explain the impact before the user decides**, not apologize after.

---

## Protection tiers

### Tier 1 — Always requires confirmation (all clusters, including whitelisted)

#### Kubernetes

| Pattern | Risk |
|---|---|
| `kubectl delete pvc / persistentvolumeclaim` | Permanent data loss |
| `kubectl delete namespace / ns` | Deletes ALL resources in namespace |
| `kubectl delete ... --all / -A` | Bulk deletion across resources |
| `kubectl edit/patch ingress` | Breaks external traffic routing |
| `kubectl edit/patch networkpolicy` | Blocks service-to-service communication |
| `kubectl edit/patch secret` | Breaks services that mount this secret |
| `kubectl edit/patch clusterrole / clusterrolebinding` | Revokes RBAC permissions from controllers |
| `kubectl scale --replicas=0` | Immediate service downtime |
| `eksctl delete cluster` | Destroys entire EKS cluster |

#### AWS — deletions (any service)

`aws <service> delete-* / terminate-* / remove-*` is blocked for all services: IAM, EC2, RDS, EKS, DynamoDB, ElastiCache, S3, SNS, SQS, Route53, KMS, Secrets Manager, ECR, ECS, ELB, CloudFormation, Lambda, and any future services.

Special cases: `aws s3 rm`, `aws s3 rb`, `aws s3 sync --delete`

#### AWS — dangerous modifications

| Pattern | Risk |
|---|---|
| `aws ec2 authorize/revoke-security-group` | Firewall change can expose or block services |
| `aws route53 change-resource-record-sets` | DNS propagates globally — hours to recover |
| `aws elbv2 modify-listener / modify-rule` | All users behind the LB are affected |
| `aws rds modify-db-instance` | May trigger database restart |
| `aws rds reboot-db-instance` | Drops all active DB connections |
| `aws cloudfront update-distribution` | CDN config breaks asset delivery globally |

#### GCP

| Pattern | Risk |
|---|---|
| `gcloud ... delete` | GCP resource deletion |
| `gcloud compute firewall-rules update` | Firewall change can expose or block services |
| `gcloud dns record-sets update` | DNS change causes widespread outage |
| `gcloud sql instances delete` | Cloud SQL instance deletion is permanent |
| `gcloud container clusters delete` | GKE cluster deletion destroys all workloads |
| `gcloud projects delete` | Irreversible after 30-day grace period |

#### Azure

| Pattern | Risk |
|---|---|
| `az ... delete` | Azure resource deletion |
| `az network nsg rule delete/create` | NSG change can expose VMs or block traffic |
| `az network dns record-set` | DNS change causes global resolution failures |
| `az aks delete` | AKS cluster deletion |
| `az group delete` | Removes ALL resources in the group permanently |

#### HashiCorp Vault

| Pattern | Risk |
|---|---|
| `vault kv delete` | Credentials removed — dependent services break |
| `vault auth disable` | Revokes all tokens from this auth method |
| `vault secrets disable` | Removes all secrets at this path |
| `vault operator seal` | ALL secrets become inaccessible until unseal |

#### Infrastructure as Code

| Pattern | Risk |
|---|---|
| `terraform destroy` | Destroys all managed infrastructure |
| `terraform apply` | Can modify or destroy any managed resource |

#### Local filesystem

| Pattern | Risk |
|---|---|
| `rm -r/-R/--recursive` on `/`, `~`, `$HOME` | Recursive deletion of system or home directories |
| `find ... -delete` | Bulk file deletion with no undo |
| `find ... -exec rm` | Bulk file deletion via find |
| `shred` | Unrecoverable secure wipe |

Relative path removals (`rm -rf ./build`) are intentionally allowed.

---

### Tier 2 — Requires confirmation on non-whitelisted clusters

| Pattern | Why |
|---|---|
| All `kubectl` and `helm` commands | Unknown cluster = treat as production |
| `eksctl delete nodegroup / addon` | Removes compute capacity or cluster functionality |

> Cloud provider operations (AWS/GCP/Azure/Vault) are **always Tier 1** regardless of k8s cluster whitelist.

---

## Whitelist

Add a dev/test cluster to relax Tier 2 restrictions. **Tier 1 always requires confirmation even on whitelisted clusters.**

Adding to the whitelist requires interactive confirmation.

```bash
cloud-guardian whitelist add my-dev-cluster   # prompts for YES
cloud-guardian whitelist list
cloud-guardian whitelist remove my-dev-cluster
cloud-guardian status                         # show current protection level
```

Config: `~/.config/cloud-guardian/config.json`

```json
{
  "whitelistedClusters": ["my-dev-cluster"]
}
```

---

## Skills

| Skill | Description |
|---|---|
| `/guardian-status` | Show current cluster context and active protection level |
| `/guardian-approve` | Walk through the confirmation flow for a blocked operation |
| `/guardian-review` | **AI-powered risk review** — reads files being applied, diffs current vs proposed state, scores risk, presents structured summary before user decides |

### AI risk review flow

When Claude is about to run `kubectl apply -f infra.yaml` or `helm upgrade`:

1. Hook blocks the operation
2. Claude invokes `/guardian-review`
3. The skill reads the file, checks current resource state, runs `kubectl diff` or `terraform plan`
4. Presents a structured summary:

```
📋 RISK REVIEW: kubectl apply -f ingress.yaml
Resources  : Ingress/api-gateway (namespace: production)
Change     : host rule /* → /api/* (path narrowed)
Impact     : All traffic to non-/api/* paths will 404
Reversible : Yes — revert the YAML and re-apply
Risk Level : HIGH

⚠️ This change will drop traffic to non-API paths immediately.
Do you want to proceed? Type YES to confirm.
```

5. User says YES → Claude creates approval token → retries

---

## Audit log

Every blocked, approved, and executed operation is written to `~/.local/share/cloud-guardian/audit.log`.

```bash
cloud-guardian audit            # last 50 entries
cloud-guardian audit tail       # live stream
cloud-guardian audit blocked    # show only blocked operations
cloud-guardian audit stats      # summary counts by context
cloud-guardian audit clear      # clear log (prompts for confirmation)
```

Sample log:

```
2026-05-15 18:30:01  BLOCKED   mainnet-mantle-eks           kubectl delete pvc data-vol-0 -n prod
                                                              [CRITICAL] PVC data is permanently lost
2026-05-15 18:31:10  APPROVED  mainnet-mantle-eks            hash=e759efff8f7440a1
2026-05-15 18:31:15  EXECUTED  mainnet-mantle-eks            kubectl delete pvc data-vol-0 -n prod
```

---

## Pre-operation backup

`hooks/backup-before-modify.sh` automatically saves the current state of any Kubernetes resource **before** `kubectl apply`, `edit`, or `patch` executes.

Backups are written to `~/.local/share/cloud-guardian/backups/` with timestamp and context in the filename:

```
20260515_183000_mainnet-mantle-eks_Ingress-api-gateway.yaml
```

Add as an additional PreToolUse hook:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash /path/to/hooks/check-destructive.sh", "timeout": 5 },
          { "type": "command", "command": "bash /path/to/hooks/backup-before-modify.sh", "timeout": 10 }
        ]
      }
    ]
  }
}
```

---

## AI evaluation hook (optional)

Add a `type: "prompt"` hook to have Claude evaluate ambiguous operations that pattern matching might miss:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash /path/to/hooks/check-destructive.sh", "timeout": 5 },
          {
            "type": "prompt",
            "prompt": "Infrastructure safety check. A bash command is about to run.\n\nIf READ-ONLY (get, describe, list, logs, diff, dry-run): respond {\"decision\": \"allow\"}\n\nIf WRITE/MODIFY on infrastructure: evaluate whether it could cause service downtime, data loss, or security exposure. For HIGH/CRITICAL risk respond {\"decision\": \"block\", \"reason\": \"[one clear sentence]\"}. For LOW/MEDIUM risk respond {\"decision\": \"allow\"}.\n\nThe pattern-matching hook already handles known-dangerous commands. This catches edge cases.\n\nJSON only."
          }
        ]
      }
    ]
  }
}
```

---

## Installation

### Option 1: From source (recommended)

```bash
git clone https://github.com/BlueShells/cloud-guardian
cd cloud-guardian
bash setup/install.sh
```

The install script copies to `~/.local/bin/`:
- `cloud-guardian` — management CLI
- `cloud-guardian-approve` — approval token generator
- `cloud-guardian-audit` — audit log viewer

Then add the hook to `~/.claude/settings.json` (path printed by install script):

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
      "source": { "source": "github", "repo": "BlueShells/cloud-guardian" }
    }
  },
  "enabledPlugins": {
    "cloud-guardian@cloud-guardian": true
  }
}
```

Restart Claude Code, find the installed version:

```bash
ls ~/.claude/plugins/cache/cloud-guardian/cloud-guardian/
```

Then add the hook with the actual version path.

### Option 3: Team-wide (protect all members via project repo)

Commit cloud-guardian into any infrastructure repo. Every team member is protected automatically when they open Claude Code — no manual install required.

**Step 1** — add the hook script:

```bash
mkdir -p .claude/hooks
curl -o .claude/hooks/cloud-guardian.sh \
  https://raw.githubusercontent.com/BlueShells/cloud-guardian/main/hooks/check-destructive.sh
chmod +x .claude/hooks/cloud-guardian.sh
```

**Step 2** — create `.claude/settings.json`:

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

**Step 3** — commit and push.

`disableBypassPermissionsMode` prevents anyone from using `--dangerously-skip-permissions`.

**Onboarding** — each team member needs `cloud-guardian-approve`:

```bash
curl -o ~/.local/bin/cloud-guardian-approve \
  https://raw.githubusercontent.com/BlueShells/cloud-guardian/main/bin/cloud-guardian-approve
chmod +x ~/.local/bin/cloud-guardian-approve
```

---

## Security hardening

### Protection against `--dangerously-skip-permissions`

Two independent layers:

**Layer 1** — `permissionDecision: "deny"` in the hook output. Enforced by the Claude Code hook system independently of the global permission mode. Active even when bypass mode is enabled.

**Layer 2** — `disableBypassPermissionsMode: "disable"` in `.claude/settings.json`. Rejects `--dangerously-skip-permissions` at startup entirely.

Use both for defense in depth.

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CLOUD_GUARDIAN_CONFIG` | `~/.config/cloud-guardian/config.json` | Whitelist config |
| `CLOUD_GUARDIAN_TOKEN_DIR` | `~/.config/cloud-guardian/tokens` | Approval token directory |
| `CLOUD_GUARDIAN_AUDIT_LOG` | `~/.local/share/cloud-guardian/audit.log` | Audit log path |
| `CLOUD_GUARDIAN_BACKUP_DIR` | `~/.local/share/cloud-guardian/backups` | Pre-operation backup directory |
| `CLOUD_GUARDIAN_MAX_BACKUPS` | `100` | Maximum number of backup files to retain |
