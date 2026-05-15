#!/usr/bin/env bash
# cloud-guardian: Prevent destructive cloud operations on AWS, EKS, and Kubernetes
# Reads stdin JSON from Claude Code PreToolUse hook and blocks dangerous commands.

# Read command from stdin JSON
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

# Skip if no command found
[[ -z "$COMMAND" ]] && exit 0

# Helper: emit a blocking response
block() {
  jq -n --arg msg "$1" '{"continue": false, "stopReason": $msg}'
  exit 0
}

# Get current kubectl context (used for cluster classification)
KUBECTL_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")

# QA4 contexts: semi-protected, only extreme ops are blocked
is_qa4() {
  [[ "$KUBECTL_CONTEXT" == "qa4-mantle-eks" || "$KUBECTL_CONTEXT" == "mantle-eks" ]]
}

# ── TIER 1: Always blocked regardless of context ──────────────────────────────
# Irreversible operations that can never be auto-approved

ALWAYS_BLOCKED=(
  # kubectl: persistent data destruction
  'kubectl[[:space:]].*delete[[:space:]].*\bpvc\b'
  'kubectl[[:space:]].*delete[[:space:]].*\bpersistentvolumeclaim\b'
  'kubectl[[:space:]].*delete[[:space:]].*\bnamespace\b'
  'kubectl[[:space:]].*delete[[:space:]].*\bns\b'
  'kubectl[[:space:]].*delete.*--all\b'
  'kubectl[[:space:]].*delete.*-A\b'
  # eksctl: EKS cluster deletion
  'eksctl[[:space:]]delete[[:space:]]cluster\b'
  # AWS RDS: database deletion
  'aws[[:space:]]rds[[:space:]]delete-db-instance\b'
  'aws[[:space:]]rds[[:space:]]delete-db-cluster\b'
  'aws[[:space:]]rds[[:space:]]delete-global-cluster\b'
  # AWS EKS: cluster deletion via CLI
  'aws[[:space:]]eks[[:space:]]delete-cluster\b'
  # AWS S3: bucket removal
  'aws[[:space:]]s3[[:space:]]rb\b'
  'aws[[:space:]]s3api[[:space:]]delete-bucket\b'
  # Terraform: full environment destruction
  'terraform[[:space:]]destroy\b'
)

for pattern in "${ALWAYS_BLOCKED[@]}"; do
  if echo "$COMMAND" | grep -qiE "$pattern"; then
    block "🚨 [cloud-guardian] CRITICAL BLOCKED | ctx=$KUBECTL_CONTEXT | cmd=$(echo "$COMMAND" | head -c 120) ... | This operation is IRREVERSIBLE. Stop immediately and ask the user for explicit written confirmation before proceeding."
  fi
done

# ── TIER 2: Blocked on non-QA4 (production) clusters ─────────────────────────
# On production, Claude should never operate autonomously

if ! is_qa4; then
  # Block ALL kubectl and helm on production
  if echo "$COMMAND" | grep -qE '(^|[[:space:];&|`])(kubectl|helm)[[:space:]]'; then
    block "🚨 [cloud-guardian] PRODUCTION BLOCKED | ctx=$KUBECTL_CONTEXT | cmd=$(echo "$COMMAND" | head -c 120) ... | All kubectl/helm on non-QA4 clusters requires explicit user confirmation. Allowed: qa4-mantle-eks, mantle-eks."
  fi

  # Block destructive AWS CLI operations
  AWS_DESTRUCTIVE=(
    'aws[[:space:]]ec2[[:space:]]terminate-instances\b'
    'aws[[:space:]]s3[[:space:]]rm\b'
    'aws[[:space:]]s3[[:space:]]sync.*--delete\b'
    'aws[[:space:]]iam[[:space:]]delete-'
    'aws[[:space:]]cloudformation[[:space:]]delete-stack\b'
    'aws[[:space:]]lambda[[:space:]]delete-function\b'
    'aws[[:space:]]ec2[[:space:]]delete-\w'
    'eksctl[[:space:]]delete[[:space:]]nodegroup\b'
    'eksctl[[:space:]]delete[[:space:]]addon\b'
  )

  for pattern in "${AWS_DESTRUCTIVE[@]}"; do
    if echo "$COMMAND" | grep -qiE "$pattern"; then
      block "🚨 [cloud-guardian] AWS DESTRUCTIVE BLOCKED | cmd=$(echo "$COMMAND" | head -c 120) ... | This AWS operation is destructive and requires explicit user confirmation before execution."
    fi
  done
fi

exit 0
