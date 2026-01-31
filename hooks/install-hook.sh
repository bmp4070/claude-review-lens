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

# =============================================================================
# Colors
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# =============================================================================
# Pre-flight Checks
# =============================================================================

check_dependencies() {
    local missing=()

    command -v jq &>/dev/null || missing+=("jq")
    command -v curl &>/dev/null || missing+=("curl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}\nInstall with: brew install ${missing[*]}"
    fi
}

# =============================================================================
# Installation Functions
# =============================================================================

create_directories() {
    info "Creating directories..."
    mkdir -p "$HOOKS_DIR"
}

install_hook_script() {
    local source_script="${SCRIPT_DIR}/${HOOK_SCRIPT}"
    local dest_script="${HOOKS_DIR}/${HOOK_SCRIPT}"

    if [[ ! -f "$source_script" ]]; then
        # Generate inline if source doesn't exist
        info "Generating hook script..."
        cat > "$dest_script" << 'HOOK_SCRIPT_EOF'
#!/usr/bin/env bash
#
# Claude Code Stop Hook: Sync VS Code Extension & Launch IDE
#

set -euo pipefail

EXTENSION_ID="your-org.claude-review-lens"
ARTIFACTORY_BASE_URL="${ARTIFACTORY_URL:-https://artifactory.example.com}"
ARTIFACTORY_REPO="${ARTIFACTORY_REPO:-vscode-extensions-local}"
ARTIFACTORY_PATH="${ARTIFACTORY_PATH:-claude-review-lens}"
REVIEW_FILE=".claude-review.json"
TEMP_DIR="${TMPDIR:-/tmp}/claude-review-lens-hook"

log_info() { echo "[claude-hook] $*" >&2; }
log_error() { echo "[claude-hook] ERROR: $*" >&2; }
cleanup() { [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

find_vscode() {
    local paths=("code" "/usr/local/bin/code" "/opt/homebrew/bin/code"
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
    for p in "${paths[@]}"; do
        command -v "$p" &>/dev/null && echo "$p" && return 0
    done
    return 1
}

get_installed_version() {
    "$1" --list-extensions --show-versions 2>/dev/null \
        | grep -i "^${EXTENSION_ID}@" | cut -d'@' -f2 || echo ""
}

get_latest_version() {
    [[ -z "${ARTIFACTORY_API_KEY:-}" ]] && return 1
    local url="${ARTIFACTORY_BASE_URL}/api/storage/${ARTIFACTORY_REPO}/${ARTIFACTORY_PATH}?properties=version&list"
    curl -sf -H "X-JFrog-Art-Api: ${ARTIFACTORY_API_KEY}" "$url" 2>/dev/null \
        | jq -r '.properties.version[0] // empty' 2>/dev/null
}

version_gt() {
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

install_extension() {
    local code_cmd="$1" version="$2"
    local url="${ARTIFACTORY_BASE_URL}/${ARTIFACTORY_REPO}/${ARTIFACTORY_PATH}/claude-review-lens-${version}.vsix"
    mkdir -p "$TEMP_DIR"
    local vsix="${TEMP_DIR}/claude-review-lens-${version}.vsix"
    log_info "Downloading v${version}..."
    curl -sf -H "X-JFrog-Art-Api: ${ARTIFACTORY_API_KEY}" -o "$vsix" "$url" || return 1
    log_info "Installing..."
    "$code_cmd" --install-extension "$vsix" --force &>/dev/null || return 1
    log_info "Updated to v${version}"
}

get_first_review_target() {
    local file="${1}/${REVIEW_FILE}"
    [[ -f "$file" ]] || return 1
    local f l
    f=$(jq -r '.[0].file // empty' "$file" 2>/dev/null)
    l=$(jq -r '.[0].line // 1' "$file" 2>/dev/null)
    [[ -n "$f" ]] && echo "${1}/${f}:${l}"
}

main() {
    local project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
    local code_cmd installed latest

    code_cmd=$(find_vscode) || { log_error "VS Code not found"; return 1; }
    installed=$(get_installed_version "$code_cmd")

    if [[ -n "${ARTIFACTORY_API_KEY:-}" ]]; then
        latest=$(get_latest_version 2>/dev/null || echo "")
        if [[ -n "$latest" ]]; then
            if [[ -z "$installed" ]]; then
                log_info "Installing v${latest}..."
                install_extension "$code_cmd" "$latest" || true
            elif version_gt "$latest" "$installed"; then
                log_info "Updating: v${installed} -> v${latest}"
                install_extension "$code_cmd" "$latest" || true
            fi
        fi
    fi

    local goto=$(get_first_review_target "$project_dir" || echo "")
    if [[ -n "$goto" ]]; then
        "$code_cmd" "$project_dir" --goto "$goto" &>/dev/null &
    else
        "$code_cmd" "$project_dir" &>/dev/null &
    fi
    disown 2>/dev/null || true
}

main "$@"
HOOK_SCRIPT_EOF
    else
        info "Installing hook script from source..."
        cp "$source_script" "$dest_script"
    fi

    chmod +x "$dest_script"
    info "Hook script installed: $dest_script"
}

backup_settings() {
    if [[ -f "$SETTINGS_FILE" ]]; then
        local backup="${SETTINGS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$SETTINGS_FILE" "$backup"
        info "Backed up existing settings to: $backup"
    fi
}

inject_hook_config() {
    info "Configuring Claude settings..."

    local hook_config
    hook_config=$(cat << 'EOF'
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/sync_and_launch.sh",
            "timeout": 30000
          }
        ]
      }
    ]
  }
}
EOF
)

    if [[ ! -f "$SETTINGS_FILE" ]]; then
        # Create new settings file
        echo "$hook_config" | jq '.' > "$SETTINGS_FILE"
        info "Created new settings file with hook configuration"
    else
        # Merge with existing settings
        local existing
        existing=$(cat "$SETTINGS_FILE")

        # Check if hooks.Stop already exists
        if echo "$existing" | jq -e '.hooks.Stop' &>/dev/null; then
            warn "hooks.Stop already configured. Checking for duplicates..."

            # Check if our hook is already there
            if echo "$existing" | jq -e '.hooks.Stop[] | select(.hooks[].command == "~/.claude/hooks/sync_and_launch.sh")' &>/dev/null; then
                info "Hook already configured. Skipping..."
                return 0
            fi

            # Append to existing Stop hooks
            local new_hook
            new_hook=$(echo "$hook_config" | jq '.hooks.Stop[0]')
            echo "$existing" | jq --argjson hook "$new_hook" '.hooks.Stop += [$hook]' > "$SETTINGS_FILE"
            info "Added hook to existing Stop configuration"
        else
            # Merge hooks object
            echo "$existing" | jq --argjson hooks "$(echo "$hook_config" | jq '.hooks')" \
                '.hooks = (.hooks // {}) + $hooks' > "$SETTINGS_FILE"
            info "Added hooks configuration to settings"
        fi
    fi
}

setup_env_reminder() {
    echo ""
    warn "Don't forget to set your Artifactory API key!"
    echo ""
    echo "  Add to your shell profile (~/.zshrc or ~/.bashrc):"
    echo ""
    echo "    export ARTIFACTORY_API_KEY='your-api-key-here'"
    echo ""
    echo "  Or configure it in your Claude settings.json environment block."
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    info "Installing Claude Review Lens Stop Hook"
    echo "========================================"
    echo ""

    check_dependencies
    create_directories
    backup_settings
    install_hook_script
    inject_hook_config
    setup_env_reminder

    echo ""
    info "Installation complete!"
    echo ""
    echo "  Hook script: $HOOKS_DIR/$HOOK_SCRIPT"
    echo "  Settings:    $SETTINGS_FILE"
    echo ""
    echo "  The hook will run automatically when you exit Claude CLI."
    echo ""
}

main "$@"
