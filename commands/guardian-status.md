---
allowed-tools: Bash(cloud-guardian status:*), Bash(cloud-guardian whitelist list:*)
description: Show cloud-guardian protection status for the current cluster
---

## Context

- Guardian status: !`cloud-guardian status`
- Whitelist: !`cloud-guardian whitelist list`

## Your task

Display a clear status report based on the above output. Include:

1. **Current context** and its protection level (Fully Protected or Semi-Protected)
2. **What is blocked** at each tier
3. **How to proceed** if a command gets blocked:
   - Claude will show the blocked command and hash
   - User must explicitly say YES to confirm
   - Claude then runs `cloud-guardian-approve <hash>`
   - Claude retries the original command

Keep it concise. Do not run any other tools.
