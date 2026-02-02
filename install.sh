#!/usr/bin/env bash
#
# Claude Review Lens - One-Line Installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/claude-review-lens/main/install.sh | bash
#
# Or clone and run:
#   git clone https://github.com/YOUR_ORG/claude-review-lens.git
#   cd claude-review-lens && ./install.sh
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

REPO_URL="https://github.com/YOUR_ORG/claude-review-lens"
VSIX_URL="https://github.com/YOUR_ORG/claude-review-lens/releases/latest/download/claude-review-lens.vsix"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

# =============================================================================
# Colors
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*"; exit 1; }
step() { echo -e "${BLUE}→${NC} $*"; }

# =============================================================================
# Pre-flight
# =============================================================================

check_deps() {
    command -v jq &>/dev/null || error "jq required. Install: brew install jq"
    command -v curl &>/dev/null || error "curl required"
}

detect_editor() {
    if command -v cursor &>/dev/null; then
        echo "cursor"
    elif command -v code &>/dev/null; then
        echo "code"
    else
        echo ""
    fi
}

# =============================================================================
# Installation Steps
# =============================================================================

install_extension() {
    local editor="$1"
    step "Installing VS Code extension..."

    # Check if running from cloned repo
    local vsix_path=""
    if [[ -f "./claude-review-lens-0.2.0.vsix" ]]; then
        vsix_path="./claude-review-lens-0.2.0.vsix"
    elif [[ -f "./claude-review-lens.vsix" ]]; then
        vsix_path="./claude-review-lens.vsix"
    else
        # Download from releases
        vsix_path="/tmp/claude-review-lens.vsix"
        curl -fsSL "$VSIX_URL" -o "$vsix_path" 2>/dev/null || {
            warn "Could not download VSIX. Install manually from $REPO_URL"
            return 0
        }
    fi

    "$editor" --install-extension "$vsix_path" --force &>/dev/null && \
        info "Extension installed in $editor" || \
        warn "Extension install failed. Install manually."
}

install_hook() {
    step "Installing Claude hook..."

    mkdir -p "$HOOKS_DIR"

    cat > "$HOOKS_DIR/sync_and_launch.sh" << 'HOOK_EOF'
#!/usr/bin/env bash
set -euo pipefail

REVIEW_FILE=".claude-review.json"

find_editor() {
    local paths=("cursor" "code" "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
    for p in "${paths[@]}"; do
        command -v "$p" &>/dev/null && echo "$p" && return 0
    done
    return 1
}

get_first_target() {
    local file="${1}/${REVIEW_FILE}"
    [[ -f "$file" ]] || return 1
    local f l
    f=$(jq -r '.[0].file // empty' "$file" 2>/dev/null)
    l=$(jq -r '.[0].line // 1' "$file" 2>/dev/null)
    [[ -n "$f" ]] && echo "${1}/${f}:${l}"
}

main() {
    local project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
    [[ -f "${project_dir}/${REVIEW_FILE}" ]] || exit 0

    local editor
    editor=$(find_editor) || { echo "[hook] Editor not found" >&2; exit 1; }

    echo "[claude-hook] Review detected, launching $editor..." >&2

    local goto=$(get_first_target "$project_dir" || echo "")
    if [[ -n "$goto" ]]; then
        "$editor" "$project_dir" --goto "$goto" &>/dev/null &
    else
        "$editor" "$project_dir" &>/dev/null &
    fi
    disown 2>/dev/null || true
}

main "$@"
HOOK_EOF

    chmod +x "$HOOKS_DIR/sync_and_launch.sh"
    info "Hook installed: $HOOKS_DIR/sync_and_launch.sh"
}

install_settings() {
    step "Configuring Claude settings..."

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

    mkdir -p "$CLAUDE_DIR"

    if [[ ! -f "$SETTINGS_FILE" ]]; then
        echo "$hook_config" | jq '.' > "$SETTINGS_FILE"
        info "Created settings with hook"
    elif jq -e '.hooks.Stop[]?.hooks[]? | select(.command | contains("sync_and_launch"))' "$SETTINGS_FILE" &>/dev/null; then
        info "Hook already configured"
    elif jq -e '.hooks.Stop' "$SETTINGS_FILE" &>/dev/null; then
        local new_hook
        new_hook=$(echo "$hook_config" | jq '.hooks.Stop[0]')
        jq --argjson hook "$new_hook" '.hooks.Stop += [$hook]' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"
        mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
        info "Added hook to existing config"
    else
        jq --argjson hooks "$(echo "$hook_config" | jq '.hooks')" \
            '.hooks = (.hooks // {}) + $hooks' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"
        mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
        info "Added hooks section"
    fi
}

install_skill() {
    step "Installing /review skill..."

    # Add skill to settings
    local skill_config
    skill_config=$(cat << 'EOF'
{
  "skills": {
    "review": {
      "description": "Review code and output findings to .claude-review.json",
      "prompt": "Review the code thoroughly and write your findings to `.claude-review.json` in the workspace root.\n\nUse this JSON schema:\n```json\n[\n  {\n    \"file\": \"relative/path.ts\",\n    \"line\": 42,\n    \"message\": \"### Title\\n\\n**Problem:** ...\\n\\n**Suggestion:**\\n```code```\",\n    \"author\": \"Claude\",\n    \"mode\": \"suggestion\",\n    \"severity\": \"warning\"\n  }\n]\n```\n\nSeverity levels:\n- error: Security issues, bugs, crashes\n- warning: Performance, code smells\n- info: Style, best practices\n\nAnalyze: ${input:-all staged/modified files}"
    }
  }
}
EOF
)

    if [[ -f "$SETTINGS_FILE" ]]; then
        if ! jq -e '.skills.review' "$SETTINGS_FILE" &>/dev/null; then
            jq --argjson skills "$(echo "$skill_config" | jq '.skills')" \
                '.skills = (.skills // {}) + $skills' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"
            mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
            info "Added /review skill"
        else
            info "Skill already configured"
        fi
    fi
}

install_claude_md() {
    step "Installing CLAUDE.md instructions..."

    local claude_md="$CLAUDE_DIR/CLAUDE.md"
    local marker="# Claude Review Lens Integration"

    if [[ -f "$claude_md" ]] && grep -q "$marker" "$claude_md"; then
        info "CLAUDE.md already configured"
        return 0
    fi

    cat >> "$claude_md" << 'CLAUDE_EOF'

# Claude Review Lens Integration

When performing code reviews, output findings to `.claude-review.json`:

```json
[
  {
    "file": "path/to/file.ts",
    "line": 42,
    "message": "### Title\n\n**Problem:** Description\n\n**Suggestion:**\n```typescript\n// fix\n```",
    "author": "Claude",
    "mode": "suggestion",
    "severity": "warning"
  }
]
```

Severity: error (bugs/security), warning (code smells), info (suggestions)
CLAUDE_EOF

    info "Added review instructions to CLAUDE.md"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   Claude Review Lens Installer         ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""

    check_deps

    local editor
    editor=$(detect_editor)
    if [[ -z "$editor" ]]; then
        warn "No editor found (cursor/code). Extension not installed."
    else
        install_extension "$editor"
    fi

    install_hook
    install_settings
    install_skill
    install_claude_md

    echo ""
    echo -e "${GREEN}Installation complete!${NC}"
    echo ""
    echo "  Usage:"
    echo "    cd your-project"
    echo "    claude"
    echo "    > /review           # Review all changes"
    echo "    > /review src/      # Review specific path"
    echo "    > exit"
    echo ""
    echo "  On exit, your editor opens with review comments."
    echo ""
}

main "$@"
