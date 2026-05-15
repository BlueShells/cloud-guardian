#!/usr/bin/env bash
HOOK="/Users/zhangzhiming/git/cloud-guardian/hooks/check-destructive.sh"
PASS=0; FAIL=0

chk() {
  local expect="$1" label="$2" cmd="$3"
  local out blocked
  out=$(echo "{\"tool_input\":{\"command\":\"$cmd\"}}" | bash "$HOOK" 2>/dev/null || true)
  echo "$out" | grep -q '"continue": false' && blocked=yes || blocked=no
  if [[ "$expect" == "$blocked" ]]; then
    echo "  PASS  $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $label (expected=$expect got=$blocked)"
    FAIL=$((FAIL+1))
  fi
}

echo "── git/gh 命令内的描述文字 → 应放行 ───────────────────────────────────"
chk no  "git commit -m 含 kubectl delete pvc"   'git commit -m "kubectl delete pvc data-vol"'
chk no  "git commit heredoc 含 kubectl"         'git -C /path commit -m "reset: kubectl delete pvc"'
chk no  "gh pr create body 含 kubectl delete"   'gh pr create --body "run kubectl delete pvc to reset"'
chk no  "gh pr create body 含 terraform destroy" 'gh pr create --body "terraform destroy to teardown"'
chk no  "git push 单独"                         'git push origin main'

echo ""
echo "── 真实危险命令 → 应拦截 ──────────────────────────────────────────────"
chk yes "kubectl delete pvc 直接执行"           'kubectl delete pvc data-vol-0 -n infra'
chk yes "git status && kubectl delete pvc"      'git status && kubectl delete pvc data-vol'
chk yes "git push; kubectl delete pvc"          'git push; kubectl delete pvc data-vol'
chk yes "terraform destroy 直接"               'terraform destroy -auto-approve'
chk yes "git status && terraform destroy"       'git status && terraform destroy'

echo ""
echo "────────────────────────────────────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
