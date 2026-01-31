#!/usr/bin/env bash
#
# Claude Code Stop Hook: Sync VS Code Extension & Launch IDE
# Automatically updates Claude Review Lens and opens the project
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

EXTENSION_ID="your-org.claude-review-lens"
ARTIFACTORY_BASE_URL="${ARTIFACTORY_URL:-https://artifactory.example.com}"
ARTIFACTORY_REPO="${ARTIFACTORY_REPO:-vscode-extensions-local}"
ARTIFACTORY_PATH="${ARTIFACTORY_PATH:-claude-review-lens}"
REVIEW_FILE=".claude-review.json"

# Temp directory for downloads
TEMP_DIR="${TMPDIR:-/tmp}/claude-review-lens-hook"

# =============================================================================
# Utility Functions
# =============================================================================

log_info() {
    echo "[claude-hook] $*" >&2
}

log_error() {
    echo "[claude-hook] ERROR: $*" >&2
}

cleanup() {
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

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

# Get installed extension version (returns empty if not installed)
get_installed_version() {
    local code_cmd="$1"
    "$code_cmd" --list-extensions --show-versions 2>/dev/null \
        | grep -i "^${EXTENSION_ID}@" \
        | cut -d'@' -f2 \
        || echo ""
}

# Query Artifactory for latest version
get_latest_version() {
    if [[ -z "${ARTIFACTORY_API_KEY:-}" ]]; then
        log_error "ARTIFACTORY_API_KEY not set"
        return 1
    fi

    local api_url="${ARTIFACTORY_BASE_URL}/api/storage/${ARTIFACTORY_REPO}/${ARTIFACTORY_PATH}?properties=version&list"
    local response

    response=$(curl -sf \
        -H "X-JFrog-Art-Api: ${ARTIFACTORY_API_KEY}" \
        "$api_url" 2>/dev/null) || return 1

    # Extract version from properties response
    # Expected format: {"properties":{"version":["0.2.0"]}}
    echo "$response" | jq -r '.properties.version[0] // empty' 2>/dev/null
}

# Get latest VSIX download URL
get_vsix_url() {
    local version="$1"
    echo "${ARTIFACTORY_BASE_URL}/${ARTIFACTORY_REPO}/${ARTIFACTORY_PATH}/claude-review-lens-${version}.vsix"
}

# Compare versions: returns 0 if $1 > $2
version_gt() {
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

# Download and install extension
install_extension() {
    local code_cmd="$1"
    local version="$2"
    local vsix_url
    local vsix_path

    vsix_url=$(get_vsix_url "$version")
    mkdir -p "$TEMP_DIR"
    vsix_path="${TEMP_DIR}/claude-review-lens-${version}.vsix"

    log_info "Downloading v${version} from Artifactory..."

    if ! curl -sf \
        -H "X-JFrog-Art-Api: ${ARTIFACTORY_API_KEY}" \
        -o "$vsix_path" \
        "$vsix_url"; then
        log_error "Failed to download VSIX"
        return 1
    fi

    log_info "Installing extension..."

    if ! "$code_cmd" --install-extension "$vsix_path" --force &>/dev/null; then
        log_error "Failed to install extension"
        return 1
    fi

    log_info "Successfully updated to v${version}"
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
    local code_cmd
    local installed_version
    local latest_version

    # Find VS Code
    if ! code_cmd=$(find_vscode); then
        log_error "VS Code not found in PATH"
        return 1
    fi

    # Check versions (silent unless update needed)
    installed_version=$(get_installed_version "$code_cmd")

    # Only query Artifactory if API key is set
    if [[ -n "${ARTIFACTORY_API_KEY:-}" ]]; then
        latest_version=$(get_latest_version 2>/dev/null || echo "")

        if [[ -n "$latest_version" ]]; then
            if [[ -z "$installed_version" ]]; then
                log_info "Extension not installed, installing v${latest_version}..."
                install_extension "$code_cmd" "$latest_version" || true
            elif version_gt "$latest_version" "$installed_version"; then
                log_info "Update available: v${installed_version} -> v${latest_version}"
                install_extension "$code_cmd" "$latest_version" || true
            fi
        fi
    fi

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
