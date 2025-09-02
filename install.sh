#!/usr/bin/env bash
set -euo pipefail

# ========================================
# Register MongoDB MCP (project-specific)
# ========================================
# This runs via postAttachCommand, AFTER dotfiles have completed

# Ensure npm global bin is in PATH (where Claude CLI is installed)
if command -v npm >/dev/null 2>&1; then
  NPM_BIN_GLOBAL="$(npm bin -g 2>/dev/null || true)"
  if [ -n "${NPM_BIN_GLOBAL:-}" ] && ! echo ":$PATH:" | grep -q ":${NPM_BIN_GLOBAL}:"; then
    export PATH="${NPM_BIN_GLOBAL}:$PATH"
    hash -r || true
  fi
fi

echo "Registering project-specific MongoDB MCP..."

# Register MongoDB in Claude CLI (dotfiles should have installed claude)
if command -v claude >/dev/null 2>&1; then
  if claude mcp list 2>/dev/null | grep -qE "^[[:space:]]*mongodb[[:space:]]*$"; then
    echo "MongoDB MCP already registered in Claude"
  else
    echo "Registering MongoDB MCP in Claude..."
    claude mcp add --transport stdio mongodb -- npx mongodb-mcp-server
    echo "MongoDB MCP registered successfully"
  fi
else
  echo "Warning: Claude CLI not found. Ensure dotfiles are configured with Claude CLI."
fi

# Ensure Codex config has MongoDB (idempotent)
CONFIG_PATH="${HOME}/.codex/config.toml"
if [ -f "${CONFIG_PATH}" ]; then
  if ! grep -q '^\[mcp_servers\.mongodb\]' "${CONFIG_PATH}"; then
    echo "Adding MongoDB to existing Codex config..."
    cat >> "${CONFIG_PATH}" <<'EOF'

[mcp_servers.mongodb]
command = "npx"
args = ["-y", "mongodb-mcp-server"]
env = {}
EOF
    echo "MongoDB added to Codex config"
  else
    echo "MongoDB already in Codex config"
  fi
else
  # Create minimal config with MongoDB if dotfiles didn't create one
  echo "Creating Codex config with MongoDB..."
  mkdir -p "${HOME}/.codex"
  cat > "${CONFIG_PATH}" <<'EOF'
# Codex MCP Server Configuration
# IMPORTANT: the top-level key is 'mcp_servers'

[mcp_servers.mongodb]
command = "npx"
args = ["-y", "mongodb-mcp-server"]
env = {}
EOF
  echo "Codex config created with MongoDB"
fi

echo "MongoDB MCP registration complete"