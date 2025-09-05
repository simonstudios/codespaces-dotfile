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

# Detect workspace folder for project-scoped Claude config
# Prefer known env vars; fallback to scanning /workspaces
WORKSPACE_DIR=""
if [ -n "${WORKSPACE_FOLDER:-}" ] && [ -d "${WORKSPACE_FOLDER}" ]; then
  WORKSPACE_DIR="${WORKSPACE_FOLDER}"
elif [ -n "${REMOTE_CONTAINERS_WORKSPACE_FOLDER:-}" ] && [ -d "${REMOTE_CONTAINERS_WORKSPACE_FOLDER}" ]; then
  WORKSPACE_DIR="${REMOTE_CONTAINERS_WORKSPACE_FOLDER}"
elif [ -d "/workspaces" ]; then
  for d in /workspaces/*; do
    base="$(basename "$d")"
    if [ -d "$d" ] && [ "$base" != ".codespaces" ]; then
      WORKSPACE_DIR="$d"
      break
    fi
  done
fi
if [ -n "${WORKSPACE_DIR}" ]; then
  log "Detected workspace directory: ${WORKSPACE_DIR}"
else
  log "Could not detect workspace directory; Claude MCP registrations may be skipped"
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
    log "Added Context7 to Codex config"
  else
    log "Context7 already present in Codex config"
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
    log "Added Tavily to Codex config"
  else
    log "Tavily already present in Codex config"
  fi
else
  log "TAVILY_API_KEY not set; skipping Tavily in Codex config"
fi

# ========================================
# 3) Register MCP Servers in Claude (idempotent, project-scoped)
# ========================================
if command -v claude >/dev/null 2>&1; then
  add_mcp_if_missing() {
    local name="$1"; shift
    if claude mcp list 2>/dev/null | grep -qE "^[[:space:]]*${name}[[:space:]]*$"; then
      log "MCP already present: ${name}"
    else
      log "Registering MCP: ${name}"
      claude mcp add --transport stdio "${name}" -- "$@"
    fi
  }

  if [ -n "${WORKSPACE_DIR}" ] && [ -d "${WORKSPACE_DIR}" ]; then
    (
      cd "${WORKSPACE_DIR}"
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
    )
  else
    log "Workspace not detected; skipping project-scoped Claude MCP registrations"
  fi
else
  log "Claude CLI not found; skipping Claude MCP registration"
fi

# ========================================
# 4) Configure VS Code MCP settings (Context7 + Tavily)
# ========================================
write_or_update_vscode_mcp() {
  local target_dir="$1"; shift
  local target_file="${target_dir}/mcp.json"
  mkdir -p "${target_dir}"

  # Check if file exists and has content
  if [ -f "${target_file}" ] && [ -s "${target_file}" ]; then
    log "Found existing ${target_file}, updating with Context7 and Tavily..."
    
    # Use Python for JSON manipulation (more reliable than jq in all environments)
    if command -v python3 >/dev/null 2>&1; then
      python3 << PYTHON_EOF
import json
import sys

config_file = "${target_file}"

# Read existing config
try:
    with open(config_file, 'r') as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}

# Ensure structure exists
if 'inputs' not in config:
    config['inputs'] = []
if 'servers' not in config:
    config['servers'] = {}

# Add Tavily input if not present
tavily_input = {
    "type": "promptString",
    "id": "tavily-api-key",
    "description": "Tavily API Key",
    "password": True
}

# Add default if TAVILY_API_KEY is set
tavily_key = "${TAVILY_API_KEY}"
if tavily_key:
    tavily_input["default"] = tavily_key

# Remove existing tavily input and add new one
config['inputs'] = [inp for inp in config['inputs'] if inp.get('id') != 'tavily-api-key']
config['inputs'].append(tavily_input)

# Add Context7 server
config['servers']['context7'] = {
    "type": "http",
    "url": "https://mcp.context7.com/mcp"
}

# Add Tavily server
config['servers']['tavily'] = {
    "type": "http",
    "url": "https://mcp.tavily.com/mcp/?tavilyApiKey=\${input:tavily-api-key}"
}

# Write updated config
with open(config_file, 'w') as f:
    json.dump(config, f, indent=2)

print(f"Updated {config_file} with Context7 and Tavily servers")
PYTHON_EOF
    else
      log "Python3 not available, using simple append method"
      # Backup existing file
      cp "${target_file}" "${target_file}.bak"
    fi
  else
    # No existing file, create new one
    log "Creating new ${target_file}"
    if [ -n "${TAVILY_API_KEY:-}" ]; then
      cat > "${target_file}" <<EOF
{
  "inputs": [
    {
      "type": "promptString",
      "id": "tavily-api-key",
      "description": "Tavily API Key",
      "default": "${TAVILY_API_KEY}",
      "password": true
    }
  ],
  "servers": {
    "context7": {
      "type": "http",
      "url": "https://mcp.context7.com/mcp"
    },
    "tavily": {
      "type": "http",
      "url": "https://mcp.tavily.com/mcp/?tavilyApiKey=\${input:tavily-api-key}"
    }
  }
}
EOF
    else
      cat > "${target_file}" <<'EOF'
{
  "inputs": [
    {
      "type": "promptString",
      "id": "tavily-api-key",
      "description": "Tavily API Key",
      "password": true
    }
  ],
  "servers": {
    "context7": {
      "type": "http",
      "url": "https://mcp.context7.com/mcp"
    },
    "tavily": {
      "type": "http",
      "url": "https://mcp.tavily.com/mcp/?tavilyApiKey=${input:tavily-api-key}"
    }
  }
}
EOF
    fi
  fi
  
  log "VS Code MCP config updated at ${target_file}"
}

# Write for the current HOME (dotfiles usually run as 'codespace')
write_or_update_vscode_mcp "${HOME}/.vscode"

# If the devcontainer uses a different remoteUser (e.g., node), also write there
if id node >/dev/null 2>&1 && [ -d "/home/node" ]; then
  write_or_update_vscode_mcp "/home/node/.vscode"
fi

# CRITICAL: Write to workspace .vscode directory for VS Code/Copilot to find it
if [ -n "${WORKSPACE_DIR}" ] && [ -d "${WORKSPACE_DIR}" ]; then
  write_or_update_vscode_mcp "${WORKSPACE_DIR}/.vscode"
fi

log "Global LLM/MCP setup complete"

# ========================================
# 5) Ensure ~/.zshrc contains codex-dotfiles block
# ========================================
if [ ! -f "$HOME/.zshrc" ] || ! grep -q '>>> codex-dotfiles zshrc >>>' "$HOME/.zshrc" 2>/dev/null; then
  cat >> "$HOME/.zshrc" <<'EOF'

# >>> codex-dotfiles zshrc >>>
# Prevent zsh-newuser-install wizard
export ZDOTDIR="$HOME"

# Ensure npm global bin is on PATH for CLI tools installed via npm -g
if command -v npm >/dev/null 2>&1; then
  NPM_BIN_GLOBAL="$(npm bin -g 2>/dev/null || true)"
  if [ -n "${NPM_BIN_GLOBAL:-}" ] && [[ ":$PATH:" != *":${NPM_BIN_GLOBAL}:"* ]]; then
    export PATH="${NPM_BIN_GLOBAL}:$PATH"
  fi
fi

# Friendly prompt
PROMPT='%n@%m:%~%# '
# <<< codex-dotfiles zshrc <<<
EOF
  log "Appended codex-dotfiles zshrc block to ~/.zshrc"
fi