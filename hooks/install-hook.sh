#!/usr/bin/env bash
#
# One-Click Installer for Claude Review Lens Stop Hook
# Usage: ./install-hook.sh
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
HOOK_SCRIPT="sync_and_launch.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# =============================================================================
# Colors
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step() { echo -e "${BLUE}>>>${NC} $*"; }

# =============================================================================
# Pre-flight Checks
# =============================================================================

check_dependencies() {
    local missing=()
    command -v jq &>/dev/null || missing+=("jq")
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing: ${missing[*]}. Install with: brew install ${missing[*]}"
    fi
}

# =============================================================================
# Installation
# =============================================================================

create_directories() {
    step "Creating directories..."
    mkdir -p "$HOOKS_DIR"
    info "Created $HOOKS_DIR"
}

install_hook_script() {
    step "Installing hook script..."
    cp "${SCRIPT_DIR}/${HOOK_SCRIPT}" "${HOOKS_DIR}/${HOOK_SCRIPT}"
    chmod +x "${HOOKS_DIR}/${HOOK_SCRIPT}"
    info "Installed ${HOOKS_DIR}/${HOOK_SCRIPT}"
}

backup_settings() {
    if [[ -f "$SETTINGS_FILE" ]]; then
        local backup="${SETTINGS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$SETTINGS_FILE" "$backup"
        info "Backed up settings to $backup"
    fi
}

inject_hook_config() {
    step "Configuring Claude hooks..."

    # Detect VSIX path
    local vsix_path
    vsix_path=$(find "$PROJECT_DIR" -maxdepth 1 -name "*.vsix" -type f | head -1)
    if [[ -z "$vsix_path" ]]; then
        vsix_path="${PROJECT_DIR}/claude-review-lens-0.1.0.vsix"
        warn "No VSIX found, using default path: $vsix_path"
    fi

    local hook_config
    hook_config=$(cat << EOF
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "${HOOKS_DIR}/${HOOK_SCRIPT}",
            "timeout": 30000,
            "environment": {
              "INSTALL_SOURCE": "local",
              "LOCAL_VSIX_PATH": "${vsix_path}"
            }
          }
        ]
      }
    ]
  }
}
EOF
)

    if [[ ! -f "$SETTINGS_FILE" ]]; then
        echo "$hook_config" | jq '.' > "$SETTINGS_FILE"
        info "Created new settings with hook"
    else
        local existing
        existing=$(cat "$SETTINGS_FILE")

        # Check if our hook already exists
        if echo "$existing" | jq -e '.hooks.Stop[]?.hooks[]? | select(.command | contains("sync_and_launch.sh"))' &>/dev/null; then
            info "Hook already configured, skipping"
            return 0
        fi

        # Check if Stop hooks exist
        if echo "$existing" | jq -e '.hooks.Stop' &>/dev/null; then
            local new_hook
            new_hook=$(echo "$hook_config" | jq '.hooks.Stop[0]')
            echo "$existing" | jq --argjson hook "$new_hook" '.hooks.Stop += [$hook]' > "$SETTINGS_FILE"
            info "Added hook to existing Stop array"
        else
            echo "$existing" | jq --argjson hooks "$(echo "$hook_config" | jq '.hooks')" \
                '.hooks = (.hooks // {}) + $hooks' > "$SETTINGS_FILE"
            info "Added hooks section to settings"
        fi
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "Claude Review Lens - Hook Installer"
    echo "===================================="
    echo ""

    check_dependencies
    create_directories
    backup_settings
    install_hook_script
    inject_hook_config

    echo ""
    echo -e "${GREEN}Installation complete!${NC}"
    echo ""
    echo "  Hook:     ${HOOKS_DIR}/${HOOK_SCRIPT}"
    echo "  Settings: ${SETTINGS_FILE}"
    echo ""
    echo "When you exit Claude CLI, VS Code will auto-launch."
    echo ""
    echo "To switch to Marketplace later, update INSTALL_SOURCE:"
    echo "  INSTALL_SOURCE=marketplace"
    echo ""
}

main "$@"
