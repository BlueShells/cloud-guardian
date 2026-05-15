---
allowed-tools: Bash(kubectl config current-context:*), Bash(kubectl config get-contexts:*)
description: Show cloud-guardian protection status and current cluster context
---

## Context

- Current kubectl context: !`kubectl config current-context 2>/dev/null || echo "kubectl not configured"`
- Available contexts: !`kubectl config get-contexts --no-headers 2>/dev/null | awk '{print $1, $2, $3}' | head -20 || echo "N/A"`

## Your task

Based on the current context above, display a cloud-guardian status report:

**1. Context Status**
- Show the active context name
- Label it as: `QA4 (Semi-Protected)` if it's `qa4-mantle-eks` or `mantle-eks`, otherwise `PRODUCTION (Fully Protected)`

**2. Active Protections**

If PRODUCTION context:
- ALL kubectl commands: BLOCKED
- ALL helm commands: BLOCKED
- AWS EC2 terminate-instances: BLOCKED
- AWS S3 rm / rb: BLOCKED
- AWS IAM delete-*: BLOCKED
- AWS CloudFormation delete-stack: BLOCKED
- eksctl delete nodegroup/addon: BLOCKED
- (+ everything in Always Blocked below)

Always Blocked (even on QA4):
- kubectl delete pvc / namespace / --all: BLOCKED
- eksctl delete cluster: BLOCKED
- aws rds delete-db-instance / delete-db-cluster: BLOCKED
- aws eks delete-cluster: BLOCKED
- terraform destroy: BLOCKED

**3. What is Allowed on QA4**
- kubectl get/describe/logs/exec/apply/rollout
- helm list/status/get/upgrade/install
- AWS read-only operations

Show as a concise status card. Do not call any other tools.
