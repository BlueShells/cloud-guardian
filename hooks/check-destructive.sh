#!/usr/bin/env bash
# cloud-guardian: PreToolUse hook — intelligent cloud operations safety guard.
#
# Protection model:
#   Tier 1 (always requires confirmation, ALL clusters including whitelisted):
#     - Irreversible deletions: kubectl delete pvc/namespace/--all, eksctl delete cluster
#     - Dangerous modifications: ingress/networkpolicy/secret/RBAC edits, scale to 0
#     - AWS: any delete/terminate/remove-*, plus firewall/DNS/LB/DB modifications
#     - GCP / Azure / Vault: deletion and dangerous modification patterns
#     - Terraform: destroy and apply
#     - Local filesystem: recursive deletion, bulk find-delete, shred
#
#   Tier 2 (requires confirmation on non-whitelisted clusters):
#     - All kubectl and helm commands
#     - eksctl delete nodegroup/addon
#
# Confirmation flow:
#   1. Hook blocks and prints a hash + risk explanation
#   2. Claude presents risk to user, asks for explicit YES
#   3. User says YES → Claude runs: cloud-guardian-approve <hash>
#   4. Claude retries → hook finds token → allows once → token consumed

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
TOKEN_DIR="${CLOUD_GUARDIAN_TOKEN_DIR:-$HOME/.config/cloud-guardian/tokens}"
CONFIG_FILE="${CLOUD_GUARDIAN_CONFIG:-$HOME/.config/cloud-guardian/config.json}"
AUDIT_LOG="${CLOUD_GUARDIAN_AUDIT_LOG:-$HOME/.local/share/cloud-guardian/audit.log}"

# ── Read command ──────────────────────────────────────────────────────────────
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[[ -z "$COMMAND" ]] && exit 0

# ── False-positive guard ──────────────────────────────────────────────────────
# git/gh commands cannot execute cloud operations directly. Their arguments
# (commit messages, PR bodies, heredocs) may reference dangerous commands
# for documentation purposes.
#
# Cases handled:
#   1. Pure git/gh command (no compound operator) → skip entirely
#   2. git/gh command chained with && or ; (e.g. git add && git commit)
#      → only the non-git parts need checking, but if ALL parts start with
#        git/gh, the whole command is safe to skip.
_all_parts_are_git() {
  # Split on &&, ||, ; and check each segment starts with git or gh
  local cmd="$1"
  # Replace operators with newlines, strip leading spaces, check each part
  echo "$cmd" | tr ';&|' '\n' | while IFS= read -r part; do
    part="${part#"${part%%[! ]*}"}"  # ltrim
    [[ -z "$part" ]] && continue
    echo "$part" | grep -qE '^(git|gh)\s' || { echo "non-git"; return; }
  done
}

if echo "$COMMAND" | grep -qE '^\s*(git|gh)\s'; then
  if ! echo "$COMMAND" | grep -qE '&&|\|\|[^|]|[^|]\|[^|]|;'; then
    # Simple git/gh command, no chaining → skip
    exit 0
  fi
  # Chained command — skip only if every segment is git/gh
  # (e.g. "git add X && git commit -m '...kubectl...'" is safe)
  if ! _all_parts_are_git "$COMMAND" | grep -q "non-git"; then
    exit 0
  fi
  # At least one non-git segment exists → fall through to pattern checks
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
CMD_HASH=$(printf '%s' "$COMMAND" | sha256sum 2>/dev/null | cut -c1-16 \
           || printf '%s' "$COMMAND" | shasum -a 256 | cut -c1-16)

KUBECTL_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")

_audit() {
  local event="$1" tier="${2:-}" risk="${3:-}"
  mkdir -p "$(dirname "$AUDIT_LOG")"
  printf '%s  %-8s  %-28s  %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$event" "$KUBECTL_CONTEXT" \
    "$(printf '%s' "$COMMAND" | head -c 120)" >> "$AUDIT_LOG" 2>/dev/null || true
  if [[ -n "$tier" && -n "$risk" ]]; then
    printf '                                                  [%s] %s\n' \
      "$tier" "$risk" >> "$AUDIT_LOG" 2>/dev/null || true
  fi
}

block() {
  local tier="$1" risk="$2"
  _audit "BLOCKED" "$tier" "$risk"
  jq -n \
    --arg tier "$tier" --arg ctx "$KUBECTL_CONTEXT" \
    --arg cmd  "$(printf '%s' "$COMMAND" | head -c 200)" \
    --arg risk "$risk" --arg hash "$CMD_HASH" \
    '{
      "continue": false,
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": ("[cloud-guardian] \($tier) | \($risk) | run `cloud-guardian-approve \($hash)` after user confirms")
      },
      "stopReason": (
        "🚨 [cloud-guardian] \($tier)\n" +
        "  Context : \($ctx)\n" +
        "  Command : \($cmd)\n" +
        "  Risk    : \($risk)\n" +
        "  Hash    : \($hash)\n\n" +
        "To proceed:\n" +
        "  1. Explain to the user exactly what will change and the risk\n" +
        "  2. Only if user explicitly says YES: run `cloud-guardian-approve \($hash)`\n" +
        "  3. Immediately retry the original command"
      )
    }'
  exit 0
}

check_token() {
  local token_file="$TOKEN_DIR/$CMD_HASH"
  if [[ -f "$token_file" ]]; then
    local expiry now
    expiry=$(cat "$token_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [[ "$now" -lt "$expiry" ]]; then
      rm -f "$token_file"
      _audit "EXECUTED"
      exit 0
    fi
    rm -f "$token_file"
  fi
}

is_whitelisted() {
  [[ -f "$CONFIG_FILE" ]] || return 1
  jq -e --arg ctx "$KUBECTL_CONTEXT" \
    '(.whitelistedClusters // []) | index($ctx) != null' \
    "$CONFIG_FILE" > /dev/null 2>&1
}

# ── Tier 1: Always requires confirmation, regardless of whitelist ─────────────
# Format: 'regex_pattern###Human-readable risk description'
# Separator ### avoids conflicts with | used in regex alternation.
# AWS/GCP/Azure/Vault operations are always Tier 1 regardless of k8s whitelist.

TIER1=(
  # kubectl: irreversible deletions
  'kubectl[[:space:]].*delete[[:space:]].*\bpvc\b###PVC data is permanently lost — cannot be recovered without an external backup'
  'kubectl[[:space:]].*delete[[:space:]].*\bpersistentvolumeclaim\b###PVC data is permanently lost — cannot be recovered without an external backup'
  'kubectl[[:space:]].*delete[[:space:]].*\bnamespace\b###Deletes ALL resources inside the namespace including PVCs, secrets, and services'
  'kubectl[[:space:]].*delete[[:space:]].*\bns\b###Deletes ALL resources inside the namespace including PVCs, secrets, and services'
  'kubectl[[:space:]].*delete.*--all\b###Bulk-deletes all resources of this type in the namespace'
  'kubectl[[:space:]].*delete.*\B-A\b###Bulk-deletes all resources of this type across ALL namespaces'

  # kubectl: dangerous modifications to critical resources
  'kubectl[[:space:]].*(edit|patch)[[:space:]].*(ingress\b|ing\b)###Ingress change can immediately break external traffic routing for all users'
  'kubectl[[:space:]].*(edit|patch)[[:space:]].*\bnetworkpolic###NetworkPolicy change can block service-to-service communication and cause cascading failures'
  'kubectl[[:space:]].*(edit|patch)[[:space:]].*\bsecret\b###Modifying a secret can break all services that mount or reference it'
  'kubectl[[:space:]].*(edit|patch)[[:space:]].*(clusterrole\b|clusterrolebinding\b)###RBAC change can revoke permissions from service accounts and break controllers'
  'kubectl[[:space:]].*scale.*--replicas[[:space:]]*=[[:space:]]*0###Scaling to 0 replicas causes IMMEDIATE service downtime with no traffic fallback'

  # eksctl: cluster teardown
  'eksctl[[:space:]]delete[[:space:]]cluster\b###Destroys the entire EKS cluster, all node groups, and all running workloads'

  # AWS: any service deletion/termination/removal (broad pattern — covers all services)
  'aws[[:space:]]+[[:alnum:]-]+[[:space:]]+(delete|terminate|remove)-###AWS resource deletion is typically irreversible'

  # AWS: dangerous modifications
  'aws[[:space:]]ec2[[:space:]](authorize|revoke)-security-group###Firewall rule change can expose services to the internet or block legitimate traffic'
  'aws[[:space:]]ec2[[:space:]]modify-instance-attribute###Instance attribute change may require stop/start and causes downtime'
  'aws[[:space:]]route53[[:space:]]change-resource-record-sets###DNS change propagates globally — wrong records can cause widespread outage for minutes or hours'
  'aws[[:space:]]elbv2[[:space:]]modify-(listener|rule|load-balancer-attributes)###Load balancer change affects routing for ALL users behind this LB'
  'aws[[:space:]]rds[[:space:]]modify-db-instance###Database config change may trigger a reboot and cause downtime for all connected services'
  'aws[[:space:]]rds[[:space:]]reboot-db-instance###Database restart immediately drops all active connections and causes service errors'
  'aws[[:space:]]cloudfront[[:space:]]update-distribution###CDN config change deploys globally and can break asset delivery or routing for all users'

  # AWS S3: special-case destructive commands (don't match the broad delete- pattern)
  'aws[[:space:]]s3[[:space:]]rm\b###S3 object deletion is irreversible without versioning enabled'
  'aws[[:space:]]s3[[:space:]]rb\b###S3 bucket deletion is permanent and removes all contained objects'
  'aws[[:space:]]s3[[:space:]]sync.*--delete###sync --delete removes objects that do not exist in the source — data loss if paths are wrong'

  # Terraform
  'terraform[[:space:]]destroy\b###Destroys ALL infrastructure managed by this Terraform state'
  'terraform[[:space:]]apply\b###Applies infrastructure changes — verify the plan shows only intended modifications'

  # GCP (gcloud)
  'gcloud[[:space:]].*delete[[:space:]]###GCP resource deletion — verify target project and resource before confirming'
  'gcloud[[:space:]]compute[[:space:]]firewall-rules[[:space:]]update###Firewall rule change can expose services or block legitimate traffic'
  'gcloud[[:space:]]dns[[:space:]]record-sets[[:space:]]update###DNS change propagates globally and can cause widespread outage'
  'gcloud[[:space:]]sql[[:space:]]instances[[:space:]]delete###Cloud SQL instance deletion is permanent and destroys all data'
  'gcloud[[:space:]]container[[:space:]]clusters[[:space:]]delete###GKE cluster deletion destroys all workloads and node pools'
  'gcloud[[:space:]]projects[[:space:]]delete###Project deletion is IRREVERSIBLE after 30-day grace period and removes ALL resources'

  # Azure (az)
  'az[[:space:]].*delete\b###Azure resource deletion — verify subscription and resource group before confirming'
  'az[[:space:]]network[[:space:]]nsg[[:space:]]rule[[:space:]](delete|create)###NSG rule change can expose VMs or block traffic to services'
  'az[[:space:]]network[[:space:]]dns[[:space:]]record-set###DNS record change can cause resolution failures globally'
  'az[[:space:]]aks[[:space:]]delete###AKS cluster deletion destroys all workloads'
  'az[[:space:]]group[[:space:]]delete###Resource group deletion removes ALL contained resources permanently'

  # HashiCorp Vault
  'vault[[:space:]]kv[[:space:]]delete###Vault secret deletion removes credentials — services depending on them will break'
  'vault[[:space:]]auth[[:space:]]disable###Disabling auth method revokes all tokens issued by it — widespread auth failure'
  'vault[[:space:]]secrets[[:space:]]disable###Disabling secrets engine removes all stored secrets in that path'
  'vault[[:space:]]operator[[:space:]]seal###Sealing Vault makes ALL secrets inaccessible until manual unseal'

  # Local filesystem: high-risk deletion
  # Requires command position prefix to avoid matching text inside commit messages/heredocs
  'rm[[:space:]].*(--recursive|-[a-zA-Z]*[rR][a-zA-Z]*).*[[:space:]](/|~|\$\{?HOME)###Recursive deletion of system or home directories is irreversible'
  '(^|[[:space:]]*[;&|(`][[:space:]]*)find[[:space:]].*-delete\b###find -delete removes every matched file with no confirmation or undo'
  '(^|[[:space:]]*[;&|(`][[:space:]]*)find[[:space:]].*-exec[[:space:]].*\brm\b###find -exec rm removes every matched file with no confirmation or undo'
  '(^|[[:space:]]*[;&|(`][[:space:]]*)shred[[:space:]]###shred overwrites file data — recovery is impossible by design'
)

for entry in "${TIER1[@]}"; do
  pattern="${entry%%###*}"
  risk="${entry#*###}"
  if echo "$COMMAND" | grep -qiE "$pattern"; then
    check_token
    block "CRITICAL — REQUIRES CONFIRMATION" "$risk"
  fi
done

# ── Tier 2: Requires confirmation on non-whitelisted clusters ─────────────────

if ! is_whitelisted; then
  TIER2=(
    '(^|[[:space:];&|`])(kubectl|helm)[[:space:]]###All kubectl/helm operations on non-whitelisted clusters require confirmation'
    'eksctl[[:space:]]delete[[:space:]]nodegroup\b###Node group deletion removes compute capacity and evicts all running pods'
    'eksctl[[:space:]]delete[[:space:]]addon\b###EKS addon removal can affect cluster DNS, networking, or storage'
  )

  for entry in "${TIER2[@]}"; do
    pattern="${entry%%###*}"
    risk="${entry#*###}"
    if echo "$COMMAND" | grep -qiE "$pattern"; then
      check_token
      block "PRODUCTION CLUSTER — CONFIRMATION REQUIRED" \
        "$risk (cluster '$KUBECTL_CONTEXT' is not whitelisted — add with: cloud-guardian whitelist add $KUBECTL_CONTEXT)"
    fi
  done
fi

exit 0
