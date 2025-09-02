#!/usr/bin/env bash
set -euo pipefail

log() { echo "[dotfiles] $*"; }

# ========================================
# 0) Prereqs and PATH
# ========================================
# Ensure npm global bin is on PATH for this session (common in Codespaces/Dev Containers).
if command -v npm >/dev/null 2>&1; then
  NPM_BIN_GLOBAL="$(npm bin -g 2>/dev/null || true)"
  if [ -n "${NPM_BIN_GLOBAL:-}" ] && ! echo ":$PATH:" | grep -q ":${NPM_BIN_GLOBAL}:"; then
    export PATH="${NPM_BIN_GLOBAL}:$PATH"
    hash -r || true
  fi
fi

# ========================================
# 1) Install Claude CLI (global)
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
# 2) Write Codex MCP Config (~/.codex/config.toml)
# ========================================
mkdir -p "${HOME}/.codex"
CONFIG_PATH="${HOME}/.codex/config.toml"

if [ ! -f "${CONFIG_PATH}" ]; then
  log "Creating ${CONFIG_PATH}"
  cat > "${CONFIG_PATH}" <<'EOF'
# Codex MCP Server Configuration
# IMPORTANT: the top-level key is 'mcp_servers'
EOF
else
  log "Found existing ${CONFIG_PATH}"
fi

# Append Context7 (only if key present)
if [ -n "${CONTEXT7_API_KEY:-}" ]; then
  if ! grep -q '^\[mcp_servers\.context7\]' "${CONFIG_PATH}"; then
    cat >> "${CONFIG_PATH}" <<EOF

[mcp_servers.context7]
command = "npx"
args = ["-y", "@upstash/context7-mcp", "--api-key", "${CONTEXT7_API_KEY}"]
env = {}
EOF
    log "Added [mcp_servers.context7]"
  else
    log "Section [mcp_servers.context7] already present"
  fi
else
  log "CONTEXT7_API_KEY not set; skipping Context7 in Codex config"
fi

# Append Tavily (only if key present)
if [ -n "${TAVILY_API_KEY:-}" ]; then
  if ! grep -q '^\[mcp_servers\.tavily\]' "${CONFIG_PATH}"; then
    cat >> "${CONFIG_PATH}" <<EOF

[mcp_servers.tavily]
command = "npx"
args = ["-y", "mcp-remote", "https://mcp.tavily.com/mcp/?tavilyApiKey=${TAVILY_API_KEY}"]
env = {}
EOF
    log "Added [mcp_servers.tavily]"
  else
    log "Section [mcp_servers.tavily] already present"
  fi
else
  log "TAVILY_API_KEY not set; skipping Tavily in Codex config"
fi

# ========================================
# 3) Register MCP Servers in Claude (idempotent)
# ========================================
if command -v claude >/dev/null 2>&1; then
  add_mcp_if_missing() {
    local name="$1"; shift
    if claude mcp list 2>/dev/null | grep -qE "^[[:space:]]*${name}[[:space:]]*$"; then
      log "MCP already present: ${name}"
    else
      log "Adding MCP: ${name}"
      claude mcp add --transport stdio "${name}" -- "$@"
    fi
  }

  if [ -n "${CONTEXT7_API_KEY:-}" ]; then
    add_mcp_if_missing context7 npx @upstash/context7-mcp --api-key "${CONTEXT7_API_KEY}"
  else
    log "CONTEXT7_API_KEY not set; skipping Claude Context7 registration"
  fi

  if [ -n "${TAVILY_API_KEY:-}" ]; then
    add_mcp_if_missing tavily npx -y mcp-remote "https://mcp.tavily.com/mcp/?tavilyApiKey=${TAVILY_API_KEY}"
  else
    log "TAVILY_API_KEY not set; skipping Claude Tavily registration"
  fi
else
  log "Claude CLI not found; skipping Claude MCP registration"
fi

# ========================================
# 4) Optional: Preinstall MCP servers globally (offline/readiness)
# ========================================
# This is optional; by default, we rely on npx to fetch on first run.
# Uncomment to preinstall:
# if command -v npm >/dev/null 2>&1; then
#   npm install -g @upstash/context7-mcp mcp-remote
# fi

log "LLM/MCP bootstrap complete."

# Note: MongoDB MCP is intentionally omitted here and is configured per-project
# in the repository's devcontainer setup.

