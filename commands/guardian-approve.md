---
allowed-tools: Bash(cloud-guardian-approve:*)
description: Approve a blocked destructive cloud operation after explicit user confirmation
---

## Your task

A destructive cloud operation was blocked by cloud-guardian and is pending user confirmation.

You have the operation details and hash in your context from the block message.

Steps:
1. Present the user with:
   - The exact command that was blocked
   - The target cluster/context
   - The risk (Tier 1 = irreversible data loss, Tier 2 = destructive on this cluster)

2. Ask explicitly: **"Do you confirm this operation? Type YES to proceed."**

3. Wait for the user's response:
   - **If user says YES**: run `cloud-guardian-approve <hash>` (use the hash from the block message), then immediately retry the original blocked command
   - **If user says anything else**: cancel and inform the user the operation has been aborted

**Never approve automatically. Never infer confirmation from context. Wait for explicit YES.**
