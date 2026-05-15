#!/usr/bin/env bash
# cloud-guardian: PreToolUse hook — prevents destructive cloud operations.
#
# Protection model:
#   Tier 1 (always blocked, ALL clusters):
#     kubectl delete pvc/namespace/--all, eksctl delete cluster,
#     aws rds delete-db-*, aws eks delete-cluster, terraform destroy, etc.
#
#   Tier 2 (blocked on non-whitelisted clusters):
#     All kubectl/helm, aws ec2 terminate, aws s3 rm, eksctl delete nodegroup, etc.
#
# Both tiers require explicit user confirmation via the approval token mechanism:
#   1. Hook blocks and prints a hash
#   2. User confirms in conversation
#   3. Claude runs: cloud-guardian-approve <hash>
#   4. Claude retries the original command — hook finds token and allows once

set -uo pipefail

# ── Config paths (override via env) ──────────────────────────────────────────
TOKEN_DIR="${CLOUD_GUARDIAN_TOKEN_DIR:-$HOME/.config/cloud-guardian/tokens}"
CONFIG_FILE="${CLOUD_GUARDIAN_CONFIG:-$HOME/.config/cloud-guardian/config.json}"

# ── Read command ──────────────────────────────────────────────────────────────
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[[ -z "$COMMAND" ]] && exit 0

# ── Helpers ───────────────────────────────────────────────────────────────────

# Compute command hash (16-char, stable across retries for identical commands)
CMD_HASH=$(printf '%s' "$COMMAND" | sha256sum 2>/dev/null | cut -c1-16 \
           || printf '%s' "$COMMAND" | shasum -a 256 | cut -c1-16)

# Emit a blocking JSON response with approval instructions.
# Uses permissionDecision:"deny" (PreToolUse-specific) so the block takes effect
# even when Claude Code is running with --dangerously-skip-permissions.
block() {
  local tier="$1"
  local note="${2:-}"
  jq -n \
    --arg tier   "$tier" \
    --arg ctx    "$KUBECTL_CONTEXT" \
    --arg cmd    "$(printf '%s' "$COMMAND" | head -c 200)" \
    --arg hash   "$CMD_HASH" \
    --arg note   "$note" \
    '{
      "continue": false,
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": ("[cloud-guardian] \($tier) | ctx=\($ctx) | run `cloud-guardian-approve \($hash)` after user confirms")
      },
      "stopReason": (
        "🚨 [cloud-guardian] \($tier)\n" +
        "  Context : \($ctx)\n" +
        "  Command : \($cmd)\n" +
        "  Hash    : \($hash)\n" +
        (if $note != "" then "  Note    : \($note)\n" else "" end) +
        "\nTo proceed:\n" +
        "  1. Tell the user exactly what operation will run and ask for confirmation.\n" +
        "  2. ONLY if user explicitly says YES: run `cloud-guardian-approve \($hash)`\n" +
        "  3. Immediately retry the original command."
      )
    }'
  exit 0
}

# Check for a valid one-time approval token
check_token() {
  local token_file="$TOKEN_DIR/$CMD_HASH"
  if [[ -f "$token_file" ]]; then
    local expiry now
    expiry=$(cat "$token_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [[ "$now" -lt "$expiry" ]]; then
      rm -f "$token_file"   # One-time: consume immediately
      exit 0                # Allow this command
    fi
    rm -f "$token_file"     # Expired — fall through to block
  fi
}

# Check if current kubectl context is whitelisted
KUBECTL_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")

is_whitelisted() {
  [[ -f "$CONFIG_FILE" ]] || return 1
  jq -e --arg ctx "$KUBECTL_CONTEXT" \
    '(.whitelistedClusters // []) | index($ctx) != null' \
    "$CONFIG_FILE" > /dev/null 2>&1
}

# ── Tier 1: Always requires confirmation, regardless of whitelist ─────────────

TIER1_PATTERNS=(
  # kubectl — persistent data loss
  'kubectl[[:space:]].*delete[[:space:]].*\bpvc\b'
  'kubectl[[:space:]].*delete[[:space:]].*\bpersistentvolumeclaim\b'
  'kubectl[[:space:]].*delete[[:space:]].*\bnamespace\b'
  'kubectl[[:space:]].*delete[[:space:]].*\bns\b'
  'kubectl[[:space:]].*delete.*--all\b'
  'kubectl[[:space:]].*delete.*\B-A\b'
  # eksctl — cluster teardown
  'eksctl[[:space:]]delete[[:space:]]cluster\b'
  # AWS RDS — database deletion
  'aws[[:space:]]rds[[:space:]]delete-db-instance\b'
  'aws[[:space:]]rds[[:space:]]delete-db-cluster\b'
  'aws[[:space:]]rds[[:space:]]delete-global-cluster\b'
  # AWS EKS — cluster deletion via CLI
  'aws[[:space:]]eks[[:space:]]delete-cluster\b'
  # AWS S3 — bucket removal
  'aws[[:space:]]s3[[:space:]]rb\b'
  'aws[[:space:]]s3api[[:space:]]delete-bucket\b'
  # Terraform — full environment teardown
  'terraform[[:space:]]destroy\b'
)

for pattern in "${TIER1_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qiE "$pattern"; then
    check_token
    block "CRITICAL — IRREVERSIBLE OPERATION" \
      "Whitelist does NOT exempt this command. Tier 1 always requires confirmation."
  fi
done

# ── Tier 2: Requires confirmation on non-whitelisted clusters ─────────────────

if ! is_whitelisted; then
  TIER2_PATTERNS=(
    # All kubectl and helm (on unrecognised clusters)
    '(^|[[:space:];&|`])(kubectl|helm)[[:space:]]'
    # AWS EC2
    'aws[[:space:]]ec2[[:space:]]terminate-instances\b'
    # AWS S3 content deletion
    'aws[[:space:]]s3[[:space:]]rm\b'
    'aws[[:space:]]s3[[:space:]]sync.*--delete\b'
    # AWS IAM
    'aws[[:space:]]iam[[:space:]]delete-'
    # AWS CloudFormation
    'aws[[:space:]]cloudformation[[:space:]]delete-stack\b'
    # AWS Lambda
    'aws[[:space:]]lambda[[:space:]]delete-function\b'
    # AWS EC2 resource deletion
    'aws[[:space:]]ec2[[:space:]]delete-'
    # eksctl nodegroup/addon
    'eksctl[[:space:]]delete[[:space:]]nodegroup\b'
    'eksctl[[:space:]]delete[[:space:]]addon\b'
  )

  for pattern in "${TIER2_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -qiE "$pattern"; then
      check_token
      block "PRODUCTION CLUSTER — CONFIRMATION REQUIRED" \
        "Cluster '$KUBECTL_CONTEXT' is not whitelisted. Use: cloud-guardian whitelist add $KUBECTL_CONTEXT"
    fi
  done
fi

exit 0
