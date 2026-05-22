#!/usr/bin/env bash
HOOK="/Users/zhangzhiming/git/cloud-guardian/hooks/check-destructive.sh"
TOKEN_DIR=$(mktemp -d)
export CLOUD_GUARDIAN_TOKEN_DIR="$TOKEN_DIR"
PASS=0; FAIL=0

chk() {
  local expect="$1" label="$2" cmd="$3"
  local blocked
  echo "{\"tool_input\":{\"command\":\"$cmd\"}}" | bash "$HOOK" 2>/dev/null \
    | grep -q '"continue": false' && blocked=yes || blocked=no
  if [[ "$expect" == "$blocked" ]]; then
    echo "  PASS  $label"; PASS=$((PASS+1))
  else
    echo "  FAIL  $label (expected=$expect got=$blocked)"; FAIL=$((FAIL+1))
  fi
}

echo "── 只读命令 → 应放行（即使是生产集群）────────────────────────────────"
chk no  "kubectl logs"                  'kubectl logs -n logging loki-backend-0 --tail=50'
chk no  "kubectl get pods"             'kubectl get pods -n mainnet'
chk no  "kubectl describe pod"         'kubectl describe pod loki-backend-0 -n logging'
chk no  "kubectl top nodes"            'kubectl top nodes'
chk no  "kubectl rollout status"       'kubectl rollout status daemonset/kube-proxy -n kube-system'
chk no  "kubectl config current-context" 'kubectl config current-context'
chk no  "kubectl get nodes -o wide"    'kubectl get nodes -o wide'

echo ""
echo "── 写操作 → 应继续被拦截 ───────────────────────────────────────────────"
chk yes "kubectl delete pod"           'kubectl delete pod loki-backend-0 -n logging'
chk yes "kubectl apply -f"             'kubectl apply -f manifest.yaml'
chk yes "kubectl scale"                'kubectl scale sts loki-backend --replicas=0 -n logging'
chk yes "kubectl exec"                 'kubectl exec -it loki-backend-0 -n logging -- bash'
chk yes "kubectl rollout restart"      'kubectl rollout restart deployment/grafana-log -n logging'

echo ""
echo "── 链式命令（读+写）→ 应拦截 ───────────────────────────────────────────"
chk yes "kubectl get && kubectl delete" 'kubectl get pods && kubectl delete pod foo'

echo ""
echo "────────────────────────────────────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
rm -rf "$TOKEN_DIR"
[[ $FAIL -eq 0 ]]
