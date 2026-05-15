# cloud-guardian

A Claude Code plugin that prevents destructive operations on AWS, EKS, and Kubernetes clusters.

## What it does

Intercepts Bash commands via `PreToolUse` hook and blocks:

### Tier 1 — Always blocked (even on QA4)

These operations are irreversible and require explicit user confirmation:

| Command Pattern | Reason |
|---|---|
| `kubectl delete pvc / namespace / --all` | Permanent data loss |
| `eksctl delete cluster` | Destroys entire EKS cluster |
| `aws rds delete-db-instance / delete-db-cluster` | Database deletion |
| `aws eks delete-cluster` | EKS cluster deletion via CLI |
| `aws s3 rb / s3api delete-bucket` | Bucket deletion |
| `terraform destroy` | Full environment teardown |

### Tier 2 — Blocked on non-QA4 clusters

On production clusters, Claude cannot autonomously execute:
- All `kubectl` commands
- All `helm` commands
- `aws ec2 terminate-instances`
- `aws s3 rm` / `aws s3 sync --delete`
- `aws iam delete-*`
- `aws cloudformation delete-stack`
- `aws lambda delete-function`
- `eksctl delete nodegroup / addon`

### QA4 clusters (semi-protected)

Contexts `qa4-mantle-eks` and `mantle-eks` allow normal operations but still enforce Tier 1 blocks.

## Skills

- `/guardian-status` — Show current context and active protection level

## Installation

### Option 1: Install as plugin (after publishing to GitHub)

Add to `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "cloud-guardian": {
      "source": {
        "source": "github",
        "repo": "YOUR_GITHUB_USERNAME/cloud-guardian"
      }
    }
  },
  "enabledPlugins": {
    "cloud-guardian@cloud-guardian": true
  }
}
```

Then add the hook (pointing to the installed plugin cache):

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "bash ~/.claude/plugins/cache/cloud-guardian/cloud-guardian/hooks/check-destructive.sh",
        "timeout": 5
      }]
    }]
  }
}
```

### Option 2: Direct hook (local development)

Copy `hooks/check-destructive.sh` to `~/.claude/hooks/cloud-guardian.sh` and add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "bash ~/.claude/hooks/cloud-guardian.sh",
        "timeout": 5
      }]
    }]
  }
}
```

## Configuration

To customize QA4 contexts, edit `hooks/check-destructive.sh`:

```bash
is_qa4() {
  [[ "$KUBECTL_CONTEXT" == "qa4-mantle-eks" || "$KUBECTL_CONTEXT" == "mantle-eks" ]]
}
```
