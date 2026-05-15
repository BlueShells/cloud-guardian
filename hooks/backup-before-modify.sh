#!/usr/bin/env bash
# cloud-guardian: PostToolUse hook — auto-backup critical resources before modification.
#
# Triggers on Bash tool calls that modify critical k8s resources.
# Saves the CURRENT state to ~/.local/share/cloud-guardian/backups/ BEFORE the
# change is applied, so you have a rollback snapshot.
#
# Install as a PreToolUse hook (runs before the command executes):
#   "matcher": "Bash",
#   "type": "command",
#   "command": "bash /path/to/backup-before-modify.sh"

set -uo pipefail

BACKUP_DIR="${CLOUD_GUARDIAN_BACKUP_DIR:-$HOME/.local/share/cloud-guardian/backups}"
AUDIT_LOG="${CLOUD_GUARDIAN_AUDIT_LOG:-$HOME/.local/share/cloud-guardian/audit.log}"
MAX_BACKUPS="${CLOUD_GUARDIAN_MAX_BACKUPS:-100}"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[[ -z "$COMMAND" ]] && exit 0

# Only act on kubectl modify operations
if ! echo "$COMMAND" | grep -qiE 'kubectl[[:space:]].*(apply|edit|patch|replace|set[[:space:]]image)'; then
  exit 0
fi

KUBECTL_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

backup_resource() {
  local kind="$1" name="$2" namespace="${3:-}"
  local ns_flag=""
  [[ -n "$namespace" ]] && ns_flag="-n $namespace"

  local safe_name
  safe_name=$(echo "${kind}-${name}" | tr '/:' '_')
  local backup_file="$BACKUP_DIR/${TIMESTAMP}_${KUBECTL_CONTEXT}_${safe_name}.yaml"

  mkdir -p "$BACKUP_DIR"
  # shellcheck disable=SC2086
  if kubectl get "$kind" "$name" $ns_flag -o yaml > "$backup_file" 2>/dev/null; then
    # Audit log
    mkdir -p "$(dirname "$AUDIT_LOG")"
    printf '%s  %-8s  %-28s  backed up %s/%s → %s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "BACKUP" "$KUBECTL_CONTEXT" "$kind" "$name" \
      "$(basename "$backup_file")" >> "$AUDIT_LOG" 2>/dev/null || true
    echo "[cloud-guardian] Backup saved: $backup_file" >&2
  fi
}

# ── Detect resource being modified and back it up ─────────────────────────────

# kubectl apply -f <file> → parse resources from file
if echo "$COMMAND" | grep -qiE 'kubectl[[:space:]].*apply.*-f'; then
  FILE=$(echo "$COMMAND" | grep -oE '\-f\s+\S+' | awk '{print $2}' | head -1)
  if [[ -n "$FILE" && -f "$FILE" ]]; then
    # Extract kind/name/namespace from each YAML document
    while IFS= read -r line; do
      kind=$(echo "$line" | grep -oE '^kind:[[:space:]]+\S+' | awk '{print $2}')
      [[ -n "$kind" ]] && current_kind="$kind"
    done < "$FILE"
    # Simple approach: backup by extracting kind+name pairs
    while read -r kind name namespace; do
      [[ -n "$kind" && -n "$name" ]] && backup_resource "$kind" "$name" "$namespace"
    done < <(
      python3 -c "
import sys, yaml
docs = list(yaml.safe_load_all(open('$FILE')))
for d in docs:
  if d and 'kind' in d and 'metadata' in d:
    ns = d['metadata'].get('namespace', '')
    print(d['kind'], d['metadata'].get('name',''), ns)
" 2>/dev/null || true
    )
  fi
fi

# kubectl edit/patch <kind> <name> [-n namespace]
if echo "$COMMAND" | grep -qiE 'kubectl[[:space:]].*(edit|patch)[[:space:]]'; then
  # Extract: kubectl edit <kind> <name> [-n <ns>]
  KIND=$(echo "$COMMAND" | grep -oiE '(edit|patch)[[:space:]]+\S+' | awk '{print $2}')
  NAME=$(echo "$COMMAND" | grep -oiE '(edit|patch)[[:space:]]+\S+[[:space:]]+\S+' | awk '{print $3}')
  NS=$(echo "$COMMAND" | grep -oE '\-n[[:space:]]+\S+' | awk '{print $2}')
  [[ -n "$KIND" && -n "$NAME" ]] && backup_resource "$KIND" "$NAME" "$NS"
fi

# Prune old backups beyond MAX_BACKUPS
if [[ -d "$BACKUP_DIR" ]]; then
  BACKUP_COUNT=$(find "$BACKUP_DIR" -name '*.yaml' | wc -l)
  if [[ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]]; then
    find "$BACKUP_DIR" -name '*.yaml' -printf '%T+ %p\n' 2>/dev/null | \
      sort | head -$(( BACKUP_COUNT - MAX_BACKUPS )) | awk '{print $2}' | \
      xargs rm -f 2>/dev/null || true
  fi
fi

exit 0
