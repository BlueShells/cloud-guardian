#!/usr/bin/env bash
# cloud-guardian install script
# Installs binaries to ~/.local/bin and configures the Claude Code hook.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${CLOUD_GUARDIAN_BIN:-$HOME/.local/bin}"
CONFIG_DIR="${CLOUD_GUARDIAN_CONFIG_DIR:-$HOME/.config/cloud-guardian}"
CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
HOOK_SCRIPT="$PLUGIN_DIR/hooks/check-destructive.sh"

echo "cloud-guardian installer"
echo "Plugin dir : $PLUGIN_DIR"
echo "Bin dir    : $BIN_DIR"
echo "Config dir : $CONFIG_DIR"
echo ""

# ── Install binaries ──────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR"
cp "$PLUGIN_DIR/bin/cloud-guardian" "$BIN_DIR/cloud-guardian"
cp "$PLUGIN_DIR/bin/cloud-guardian-approve" "$BIN_DIR/cloud-guardian-approve"
chmod +x "$BIN_DIR/cloud-guardian" "$BIN_DIR/cloud-guardian-approve"
echo "✅ Installed binaries to $BIN_DIR"

# Warn if BIN_DIR is not in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qxF "$BIN_DIR"; then
  echo "⚠️  $BIN_DIR is not in your PATH."
  echo "   Add this to your shell profile:"
  echo "   export PATH=\"$BIN_DIR:\$PATH\""
fi

# ── Initialize config ─────────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR/tokens"
if [[ ! -f "$CONFIG_DIR/config.json" ]]; then
  echo '{"whitelistedClusters":[]}' > "$CONFIG_DIR/config.json"
  echo "✅ Created config: $CONFIG_DIR/config.json"
else
  echo "✅ Config exists: $CONFIG_DIR/config.json"
fi

# ── Claude Code hook setup ────────────────────────────────────────────────────
echo ""
echo "To enable the Claude Code hook, add this to $CLAUDE_SETTINGS:"
echo ""
cat << HOOK_JSON
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOOK_SCRIPT",
            "timeout": 5
          }
        ]
      }
    ]
  }
HOOK_JSON

echo ""
echo "Installation complete."
echo "Run 'cloud-guardian status' to verify."
