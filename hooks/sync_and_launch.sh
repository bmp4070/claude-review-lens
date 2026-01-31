#!/usr/bin/env bash
#
# Claude Code Stop Hook: Sync VS Code Extension & Launch IDE
# Installs Claude Review Lens from local VSIX or VS Code Marketplace
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

EXTENSION_ID="your-publisher-name.claude-review-lens"
REVIEW_FILE=".claude-review.json"

# Installation source: "local" or "marketplace"
INSTALL_SOURCE="${INSTALL_SOURCE:-local}"

# Local VSIX path (used when INSTALL_SOURCE=local)
LOCAL_VSIX_PATH="${LOCAL_VSIX_PATH:-$HOME/github-oss/claude-review-code/claude-review-lens-0.1.0.vsix}"

# =============================================================================
# Utility Functions
# =============================================================================

log_info() {
    echo "[claude-hook] $*" >&2
}

log_error() {
    echo "[claude-hook] ERROR: $*" >&2
}

# Find VS Code executable
find_vscode() {
    local code_paths=(
        "code"
        "/usr/local/bin/code"
        "/opt/homebrew/bin/code"
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    )

    for path in "${code_paths[@]}"; do
        if command -v "$path" &>/dev/null; then
            echo "$path"
            return 0
        fi
    done

    return 1
}

# Check if extension is installed
is_extension_installed() {
    local code_cmd="$1"
    "$code_cmd" --list-extensions 2>/dev/null | grep -qi "^${EXTENSION_ID}$"
}

# Get installed extension version
get_installed_version() {
    local code_cmd="$1"
    "$code_cmd" --list-extensions --show-versions 2>/dev/null \
        | grep -i "^${EXTENSION_ID}@" \
        | cut -d'@' -f2 \
        || echo ""
}

# Get version from local VSIX filename
get_local_vsix_version() {
    local vsix_path="$1"
    # Extract version from filename like claude-review-lens-0.1.0.vsix
    basename "$vsix_path" | sed -E 's/.*-([0-9]+\.[0-9]+\.[0-9]+)\.vsix$/\1/'
}

# Compare versions: returns 0 if $1 > $2
version_gt() {
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

# Install from local VSIX
install_from_local() {
    local code_cmd="$1"
    local vsix_path="$2"

    if [[ ! -f "$vsix_path" ]]; then
        log_error "VSIX not found: $vsix_path"
        return 1
    fi

    local local_version
    local_version=$(get_local_vsix_version "$vsix_path")
    local installed_version
    installed_version=$(get_installed_version "$code_cmd")

    # Install if not present or outdated
    if [[ -z "$installed_version" ]]; then
        log_info "Installing Claude Review Lens v${local_version}..."
        "$code_cmd" --install-extension "$vsix_path" --force &>/dev/null
        log_info "Installed successfully"
    elif version_gt "$local_version" "$installed_version"; then
        log_info "Updating: v${installed_version} -> v${local_version}"
        "$code_cmd" --install-extension "$vsix_path" --force &>/dev/null
        log_info "Updated successfully"
    fi
    # Silent if already up-to-date
}

# Install from VS Code Marketplace
install_from_marketplace() {
    local code_cmd="$1"

    if ! is_extension_installed "$code_cmd"; then
        log_info "Installing Claude Review Lens from Marketplace..."
        "$code_cmd" --install-extension "$EXTENSION_ID" &>/dev/null
        log_info "Installed successfully"
    fi
    # Marketplace handles auto-updates, so we just ensure it's installed
}

# Extract first review target from .claude-review.json
get_first_review_target() {
    local project_dir="$1"
    local review_file="${project_dir}/${REVIEW_FILE}"

    if [[ ! -f "$review_file" ]]; then
        return 1
    fi

    # Extract first file and line from review JSON
    local file line
    file=$(jq -r '.[0].file // empty' "$review_file" 2>/dev/null)
    line=$(jq -r '.[0].line // 1' "$review_file" 2>/dev/null)

    if [[ -n "$file" ]]; then
        echo "${project_dir}/${file}:${line}"
    fi
}

# =============================================================================
# Main Logic
# =============================================================================

main() {
    local project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
    local review_file="${project_dir}/${REVIEW_FILE}"
    local code_cmd

    # Only proceed if a review file exists (indicates a review was done)
    if [[ ! -f "$review_file" ]]; then
        # No review performed, exit silently
        return 0
    fi

    # Find VS Code
    if ! code_cmd=$(find_vscode); then
        log_error "VS Code not found in PATH"
        return 1
    fi

    log_info "Review file detected, launching VS Code..."

    # Install/update extension based on source
    case "$INSTALL_SOURCE" in
        local)
            install_from_local "$code_cmd" "$LOCAL_VSIX_PATH" || true
            ;;
        marketplace)
            install_from_marketplace "$code_cmd" || true
            ;;
        *)
            log_error "Unknown INSTALL_SOURCE: $INSTALL_SOURCE"
            ;;
    esac

    # Launch VS Code with project
    local goto_target
    goto_target=$(get_first_review_target "$project_dir" || echo "")

    if [[ -n "$goto_target" ]]; then
        # Open project and jump to first review comment
        "$code_cmd" "$project_dir" --goto "$goto_target" &>/dev/null &
    else
        # Just open the project
        "$code_cmd" "$project_dir" &>/dev/null &
    fi

    disown 2>/dev/null || true
}

main "$@"
