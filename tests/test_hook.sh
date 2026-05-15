#!/usr/bin/env bash
HOOK="/Users/zhangzhiming/git/cloud-guardian/hooks/check-destructive.sh"
PASS=0; FAIL=0

# Helper: pipe JSON to hook, check if blocked
is_blocked() {
  echo "$1" | bash "$HOOK" 2>/dev/null | grep -q '"continue": false'
}

expect_block() {
  local label="$1" json="$2"
  shift 2
  if env "$@" bash "$HOOK" <<< "$json" 2>/dev/null | grep -q '"continue": false'; then
    echo "  PASS  $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $label (expected: blocked)"
    FAIL=$((FAIL+1))
  fi
}

expect_allow() {
  local label="$1" json="$2"
  shift 2
  local out
  out=$(env "$@" bash "$HOOK" <<< "$json" 2>/dev/null || true)
  if echo "$out" | grep -q '"continue": false'; then
    echo "  FAIL  $label (expected: allowed, got: blocked)"
    FAIL=$((FAIL+1))
  else
    echo "  PASS  $label"
    PASS=$((PASS+1))
  fi
}

# ── Setup ─────────────────────────────────────────────────────────────────────
# Use isolated token dir for all tests — never touch the real default dir
TOKEN_DIR=$(mktemp -d)
export CLOUD_GUARDIAN_TOKEN_DIR="$TOKEN_DIR"

TMPKUBE=$(mktemp)
cat > "$TMPKUBE" << 'EOF'
apiVersion: v1
kind: Config
current-context: mainnet-prod
contexts:
- context: {cluster: c, user: u}
  name: mainnet-prod
clusters:
- cluster: {server: "https://fake"}
  name: c
users:
- name: u
  user: {}
EOF
CFG_WHITELIST=$(mktemp)
echo '{"whitelistedClusters":["qa4-mantle-eks"]}' > "$CFG_WHITELIST"

# ── Tier 1: always blocked ────────────────────────────────────────────────────
echo ""
echo "── Tier 1 (always blocked, even on whitelisted clusters) ───────────────"

expect_block  "terraform destroy" \
  '{"tool_input":{"command":"terraform destroy -auto-approve"}}'

expect_block  "kubectl delete pvc" \
  '{"tool_input":{"command":"kubectl delete pvc data-vol-0"}}'

expect_block  "kubectl delete namespace" \
  '{"tool_input":{"command":"kubectl delete namespace production"}}'

expect_block  "kubectl delete --all" \
  '{"tool_input":{"command":"kubectl delete pods --all -n prod"}}'

expect_block  "eksctl delete cluster" \
  '{"tool_input":{"command":"eksctl delete cluster --name mainnet"}}'

expect_block  "aws rds delete-db-instance" \
  '{"tool_input":{"command":"aws rds delete-db-instance --db-instance-identifier mydb"}}'

expect_block  "aws s3 rb (bucket removal)" \
  '{"tool_input":{"command":"aws s3 rb s3://prod-bucket --force"}}'

# Tier 1 must still block even on whitelisted cluster
expect_block  "kubectl delete pvc — whitelisted cluster" \
  '{"tool_input":{"command":"kubectl delete pvc data-vol-0"}}' \
  "CLOUD_GUARDIAN_CONFIG=$CFG_WHITELIST"

# ── Tier 2: non-whitelisted cluster ──────────────────────────────────────────
echo ""
echo "── Tier 2 (non-whitelisted cluster) ────────────────────────────────────"

expect_block  "kubectl get pods — non-whitelisted" \
  '{"tool_input":{"command":"kubectl get pods -n prod"}}' \
  "KUBECONFIG=$TMPKUBE"

expect_block  "helm list — non-whitelisted" \
  '{"tool_input":{"command":"helm list -n prod"}}' \
  "KUBECONFIG=$TMPKUBE"

expect_block  "aws ec2 terminate-instances — non-whitelisted" \
  '{"tool_input":{"command":"aws ec2 terminate-instances --instance-ids i-123"}}' \
  "KUBECONFIG=$TMPKUBE"

expect_block  "aws s3 rm — non-whitelisted" \
  '{"tool_input":{"command":"aws s3 rm s3://bucket/prefix/ --recursive"}}' \
  "KUBECONFIG=$TMPKUBE"

# ── Whitelisted cluster: Tier 2 should be allowed ────────────────────────────
echo ""
echo "── Tier 2 allowed on whitelisted cluster ───────────────────────────────"

expect_allow  "kubectl get pods — whitelisted" \
  '{"tool_input":{"command":"kubectl get pods -n test"}}' \
  "CLOUD_GUARDIAN_CONFIG=$CFG_WHITELIST"

expect_allow  "helm list — whitelisted" \
  '{"tool_input":{"command":"helm list -n test"}}' \
  "CLOUD_GUARDIAN_CONFIG=$CFG_WHITELIST"

# ── Token flow ────────────────────────────────────────────────────────────────
echo ""
echo "── Approval token flow ─────────────────────────────────────────────────"

CMD='terraform destroy -auto-approve'
HASH=$(printf '%s' "$CMD" | sha256sum | cut -c1-16)

# Step 1: must be blocked without token
expect_block  "Tier 1 blocked before approval" \
  '{"tool_input":{"command":"terraform destroy -auto-approve"}}' \
  "CLOUD_GUARDIAN_TOKEN_DIR=$TOKEN_DIR"

# Step 2: approve (token written to TOKEN_DIR)
CLOUD_GUARDIAN_TOKEN_DIR="$TOKEN_DIR" \
  /Users/zhangzhiming/git/cloud-guardian/bin/cloud-guardian-approve "$HASH" > /dev/null

# Step 3: retry — must be allowed
expect_allow  "Allowed immediately after approval token" \
  '{"tool_input":{"command":"terraform destroy -auto-approve"}}' \
  "CLOUD_GUARDIAN_TOKEN_DIR=$TOKEN_DIR"

# Step 4: token consumed — must block again
expect_block  "Blocked again after token consumed (one-time)" \
  '{"tool_input":{"command":"terraform destroy -auto-approve"}}' \
  "CLOUD_GUARDIAN_TOKEN_DIR=$TOKEN_DIR"

# Token dir must be empty
if [[ -z "$(ls "$TOKEN_DIR")" ]]; then
  echo "  PASS  Token file deleted after use"
  PASS=$((PASS+1))
else
  echo "  FAIL  Token file not deleted"
  FAIL=$((FAIL+1))
fi

# ── Safe commands ─────────────────────────────────────────────────────────────
echo ""
echo "── Safe commands (always allowed) ──────────────────────────────────────"

expect_allow  "echo hello" \
  '{"tool_input":{"command":"echo hello"}}'

expect_allow  "git status" \
  '{"tool_input":{"command":"git status"}}'

expect_allow  "aws s3 ls (read-only)" \
  '{"tool_input":{"command":"aws s3 ls s3://bucket"}}'

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"

rm -f "$TMPKUBE" "$CFG_WHITELIST"
rm -rf "$TOKEN_DIR"   # test-only dir; real tokens at $HOME/.config/cloud-guardian/tokens

[[ "$FAIL" -eq 0 ]]
