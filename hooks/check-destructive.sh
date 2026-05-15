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

# ── False-positive guard ───────────────────────────────────────────────────────
# git/gh commands (commit, push, pr create, etc.) cannot execute cloud operations
# directly. Their arguments (commit messages, PR bodies, heredocs) may legitimately
# contain dangerous command text for documentation purposes.
# Skip all pattern checks if:
#   - the command starts with git or gh, AND
#   - there are no compound operators (&& || ; |) that could chain a real command
# Compound commands like "git status && kubectl delete pvc" are still caught.
if echo "$COMMAND" | grep -qE '^\s*(git|gh)\s' && \
   ! echo "$COMMAND" | grep -qE '&&|\|\|[^|]|[^|]\|[^|]|;'; then
  exit 0
fi

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
  # AWS — ANY service deletion/termination/removal.
  # Covers all services (IAM, EC2, RDS, EKS, DynamoDB, ElastiCache, SNS, SQS,
  # Route53, KMS, Secrets Manager, ECR, ECS, CloudFormation, Lambda, etc.)
  # deliberately NOT limited to specific services to avoid enumeration gaps.
  # k8s cluster whitelist does NOT exempt AWS operations.
  'aws[[:space:]]+[[:alnum:]-]+[[:space:]]+(delete|terminate|remove)-'
  # AWS S3 special-case commands (don't use delete-*/terminate-* form)
  'aws[[:space:]]s3[[:space:]]rm\b'
  'aws[[:space:]]s3[[:space:]]rb\b'
  'aws[[:space:]]s3[[:space:]]sync.*--delete'
  # Terraform — full environment teardown
  'terraform[[:space:]]destroy\b'
  # ── Local filesystem: high-risk deletion ───────────────────────────────────
  # rm with recursive flag (-r / -R / --recursive) targeting absolute paths,
  # home directory (~), or $HOME. Relative-path removals (rm -rf ./build) are
  # intentionally NOT blocked — only absolute/home targets are high-risk.
  'rm[[:space:]].*(--recursive|-[a-zA-Z]*[rR][a-zA-Z]*).*[[:space:]](/|~|\$\{?HOME)'
  # find with bulk-delete action — require command position to avoid matching
  # text descriptions inside commit messages, comments, or heredocs
  '(^|[[:space:]]*[;&|(`][[:space:]]*)find[[:space:]].*-delete\b'
  '(^|[[:space:]]*[;&|(`][[:space:]]*)find[[:space:]].*-exec[[:space:]].*\brm\b'
  # secure overwrite — same command-position requirement
  '(^|[[:space:]]*[;&|(`][[:space:]]*)shred[[:space:]]'
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
    # All kubectl and helm on non-whitelisted clusters
    '(^|[[:space:];&|`])(kubectl|helm)[[:space:]]'
    # eksctl sub-cluster operations (cluster deletion is Tier 1)
    'eksctl[[:space:]]delete[[:space:]]nodegroup\b'
    'eksctl[[:space:]]delete[[:space:]]addon\b'
    # Note: all AWS delete/terminate/remove commands are already caught by Tier 1
    # and do NOT depend on whitelist status.
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
