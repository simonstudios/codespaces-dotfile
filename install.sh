#!/usr/bin/env bash
set -euo pipefail

log() { echo "[dotfiles] $*"; }

# ========================================
# 0) Ensure npm global bin is in PATH
# ========================================
if command -v npm >/dev/null 2>&1; then
  NPM_BIN_GLOBAL="$(npm bin -g 2>/dev/null || true)"
  if [ -n "${NPM_BIN_GLOBAL:-}" ] && ! echo ":$PATH:" | grep -q ":${NPM_BIN_GLOBAL}:"; then
    export PATH="${NPM_BIN_GLOBAL}:$PATH"
    hash -r || true
  fi
fi

# ========================================
# 1) Install Claude CLI globally
# ========================================
if command -v npm >/dev/null 2>&1; then
  if ! command -v claude >/dev/null 2>&1; then
    log "Installing Claude Code CLI..."
    npm install -g @anthropic-ai/claude-code
    hash -r || true
  else
    log "Claude Code CLI already installed"
  fi
else
  log "npm not found; skipping Claude CLI install"
fi

# ========================================
# 2) Configure Codex MCP (Context7 + Tavily only)
# ========================================
# MongoDB is project-specific and handled by the repo's postStartCommand
mkdir -p "${HOME}/.codex"
CONFIG_PATH="${HOME}/.codex/config.toml"

if [ ! -f "${CONFIG_PATH}" ]; then
  log "Creating ${CONFIG_PATH} with global MCP servers..."
  cat > "${CONFIG_PATH}" <<'EOF'
# Codex MCP Server Configuration
# IMPORTANT: the top-level key is 'mcp_servers'
EOF
else
  log "Found existing ${CONFIG_PATH}"
fi

# Add Context7 (only if API key is set)
if [ -n "${CONTEXT7_API_KEY:-}" ]; then
  if ! grep -q '^\[mcp_servers\.context7\]' "${CONFIG_PATH}"; then
    cat >> "${CONFIG_PATH}" <<EOF

[mcp_servers.context7]
command = "npx"
args = ["-y", "@upstash/context7-mcp", "--api-key", "${CONTEXT7_API_KEY}"]
env = {}
EOF
    log "Added Context7 to Codex config"
  else
    log "Context7 already in Codex config"
  fi
else
  log "CONTEXT7_API_KEY not set; skipping Context7"
fi

# Add Tavily (only if API key is set)
if [ -n "${TAVILY_API_KEY:-}" ]; then
  if ! grep -q '^\[mcp_servers\.tavily\]' "${CONFIG_PATH}"; then
    cat >> "${CONFIG_PATH}" <<EOF

[mcp_servers.tavily]
command = "npx"
args = ["-y", "mcp-remote", "https://mcp.tavily.com/mcp/?tavilyApiKey=${TAVILY_API_KEY}"]
env = {}
EOF
    log "Added Tavily to Codex config"
  else
    log "Tavily already in Codex config"
  fi
else
  log "TAVILY_API_KEY not set; skipping Tavily"
fi

# ========================================
# 3) Register MCP servers in Claude CLI
# ========================================
if command -v claude >/dev/null 2>&1; then
  add_mcp_if_missing() {
    local name="$1"; shift
    if claude mcp list 2>/dev/null | grep -qE "^[[:space:]]*${name}[[:space:]]*$"; then
      log "MCP already registered: ${name}"
    else
      log "Registering MCP: ${name}"
      claude mcp add --transport stdio "${name}" -- "$@"
    fi
  }

  # Register Context7 if key is present
  if [ -n "${CONTEXT7_API_KEY:-}" ]; then
    add_mcp_if_missing context7 npx @upstash/context7-mcp --api-key "${CONTEXT7_API_KEY}"
  else
    log "CONTEXT7_API_KEY not set; skipping Context7 registration"
  fi

  # Register Tavily if key is present
  if [ -n "${TAVILY_API_KEY:-}" ]; then
    add_mcp_if_missing tavily npx -y mcp-remote "https://mcp.tavily.com/mcp/?tavilyApiKey=${TAVILY_API_KEY}"
  else
    log "TAVILY_API_KEY not set; skipping Tavily registration"
  fi
else
  log "Claude CLI not found; skipping MCP registrations"
fi

# ========================================
# 4) Configure VS Code MCP settings
# ========================================
# This creates a global VS Code MCP config for Context7 and GitHub
VSCODE_DIR="${HOME}/.vscode"
MCP_CONFIG="${VSCODE_DIR}/mcp.json"

if [ ! -d "${VSCODE_DIR}" ]; then
  mkdir -p "${VSCODE_DIR}"
  log "Created ${VSCODE_DIR} directory"
fi

if [ ! -f "${MCP_CONFIG}" ]; then
  log "Creating VS Code MCP config..."
  cat > "${MCP_CONFIG}" <<'EOF'
{
	"servers": {
		"context7": {
			"type": "http",
			"url": "https://mcp.context7.com/mcp"
		},
		"github": {
			"type": "http",
			"url": "https://api.githubcopilot.com/mcp/"
		}
	}
}
EOF
  log "VS Code MCP config created at ${MCP_CONFIG}"
else
  log "VS Code MCP config already exists at ${MCP_CONFIG}"
fi

log "Global LLM/MCP setup complete"