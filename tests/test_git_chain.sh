#!/usr/bin/env bash
HOOK="/Users/zhangzhiming/git/cloud-guardian/hooks/check-destructive.sh"
PASS=0; FAIL=0

chk() {
  local expect="$1" label="$2" cmd="$3"
  local out blocked
  out=$(echo "{\"tool_input\":{\"command\":\"$cmd\"}}" | bash "$HOOK" 2>/dev/null || true)
  echo "$out" | grep -q '"continue": false' && blocked=yes || blocked=no
  if [[ "$expect" == "$blocked" ]]; then
    echo "  PASS  $label"; PASS=$((PASS+1))
  else
    echo "  FAIL  $label (expected=$expect got=$blocked)"; FAIL=$((FAIL+1))
  fi
}

echo "── git chained with && → 全是 git，应放行 ──────────────────────────────"
chk no  "git add && git commit (kubectl in message)" \
  'git add file.py && git commit -m "fix: remove kubectl calls"'
chk no  "git add && git commit && git push" \
  'git add -A && git commit -m "feat: batch service migration" && git push'

echo ""
echo "── 真实危险：git 后跟非 git 命令 ──────────────────────────────────────"
chk yes "git status && kubectl delete pod" \
  'git status && kubectl delete pod foo -n prod'
chk yes "git pull; terraform destroy" \
  'git pull; terraform destroy -auto-approve'

echo ""
echo "── 原有测试保持正常 ────────────────────────────────────────────────────"
chk no  "纯 git commit (kubectl in message)" \
  'git commit -m "fix: stop using kubectl delete pvc in script"'
chk yes "直接 kubectl delete pvc" \
  'kubectl delete pvc data-vol-0 -n prod'

echo ""
echo "──────────────────────────────────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
