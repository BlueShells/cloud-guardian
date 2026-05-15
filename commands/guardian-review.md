---
allowed-tools: Bash(kubectl get:*), Bash(kubectl diff:*), Bash(cat:*), Bash(helm diff:*), Bash(terraform plan:*)
description: AI-powered risk review of a pending cloud operation before execution
---

## Context

- Current kubectl context: !`kubectl config current-context 2>/dev/null || echo "unknown"`
- Is whitelisted: !`cat ~/.config/cloud-guardian/config.json 2>/dev/null | jq -r --arg ctx "$(kubectl config current-context 2>/dev/null)" 'if (.whitelistedClusters // []) | index($ctx) != null then "YES (Tier 2 relaxed)" else "NO (fully protected)" end' 2>/dev/null || echo "unknown"`

## Your task

A cloud operation is pending review. You have the command and its context from the previous block message.

Perform a structured risk assessment:

### Step 1 — Understand the change

For `kubectl apply -f <file>`:
- Read the file with `cat <file>`
- List each resource being created/modified

For `kubectl edit/patch <resource>`:
- Read the current state: `kubectl get <resource> <name> -n <namespace> -o yaml`
- If editing, try: `kubectl diff -f <file>` to see what changes

For `helm upgrade`:
- Try: `helm diff upgrade <release> <chart>` if helm-diff plugin is available
- Otherwise: describe what the upgrade changes

For `terraform apply`:
- Run: `terraform plan` to show what will change

### Step 2 — Risk assessment

Answer each question:
1. **What resources are affected?** (name, namespace, type)
2. **What exactly changes?** (before → after for key fields)
3. **Who/what is impacted?** (users, services, downstream dependencies)
4. **Is it reversible?** (can we rollback and how?)
5. **Risk level:** LOW / MEDIUM / HIGH / CRITICAL

Risk criteria:
- **CRITICAL**: Can cause immediate production outage or data loss (ingress, DNS, firewall, PVC)
- **HIGH**: Can cause partial degradation or requires manual recovery (replica changes, secret rotation)
- **MEDIUM**: Recoverable with rollback, affects non-critical path (configmap, annotation updates)
- **LOW**: Read-only or additive changes with no traffic impact

### Step 3 — Decision

Present a clear summary to the user:
```
📋 RISK REVIEW: <operation>
Resources  : <list>
Change     : <before → after>
Impact     : <affected services/users>
Reversible : <yes/no — how>
Risk Level : <LOW|MEDIUM|HIGH|CRITICAL>

⚠️  <one-sentence risk statement>
```

Then ask: **"Do you want to proceed? Type YES to confirm."**

- If YES: run `cloud-guardian-approve <hash>` (from the block message), then retry
- If NO: cancel and inform the user the operation has been aborted
- If CRITICAL risk: recommend a safer alternative before asking for confirmation

**Never approve automatically. The point of this review is to make the risk explicit before the user decides.**
