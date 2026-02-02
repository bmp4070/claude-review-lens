#!/usr/bin/env bash
#
# Claude Review Lens - One-Line Installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/bmp4070/claude-review-lens/main/install.sh | bash
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

EXTENSION_ID="code-authx.claude-review-lens"
MARKETPLACE_URL="https://marketplace.visualstudio.com/items?itemName=${EXTENSION_ID}"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SKILLS_DIR="$CLAUDE_DIR/skills"
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
    step "Installing extension from VS Code Marketplace..."

    if "$editor" --install-extension "$EXTENSION_ID" --force &>/dev/null; then
        info "Extension installed: $EXTENSION_ID"
    else
        echo ""
        warn "Auto-install failed. Install manually:"
        echo "    $editor --install-extension $EXTENSION_ID"
        echo "    Or visit: $MARKETPLACE_URL"
        echo ""
    fi
}

install_hook() {
    step "Installing Claude stop hook..."

    mkdir -p "$HOOKS_DIR"

    cat > "$HOOKS_DIR/sync_and_launch.sh" << 'HOOK_EOF'
#!/usr/bin/env bash
set -euo pipefail

REVIEW_FILE=".claude-review.json"

log_info() { echo "[claude-hook] $*" >&2; }

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
    f=$(jq -r 'if type == "array" then .[0].file else .comments[0].file end // empty' "$file" 2>/dev/null)
    l=$(jq -r 'if type == "array" then .[0].line else .comments[0].line end // 1' "$file" 2>/dev/null)
    [[ -n "$f" ]] && echo "${1}/${f}:${l}"
}

get_branch() {
    local file="${1}/${REVIEW_FILE}"
    [[ -f "$file" ]] || return 1
    jq -r '.branch // empty' "$file" 2>/dev/null
}

checkout_branch() {
    local project_dir="$1" branch="$2"
    [[ -z "$branch" ]] && return 0
    git -C "$project_dir" rev-parse --git-dir &>/dev/null || return 0

    local current=$(git -C "$project_dir" branch --show-current 2>/dev/null || echo "")
    [[ "$current" == "$branch" ]] && return 0

    log_info "Checking out branch: $branch"
    git -C "$project_dir" fetch origin "$branch" 2>/dev/null || true
    git -C "$project_dir" checkout "$branch" 2>/dev/null || \
        git -C "$project_dir" checkout -b "$branch" "origin/$branch" 2>/dev/null || \
        log_info "Could not checkout $branch"
}

main() {
    local project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
    [[ -f "${project_dir}/${REVIEW_FILE}" ]] || exit 0

    local editor
    editor=$(find_editor) || { log_info "Editor not found"; exit 1; }

    log_info "Review detected, launching $editor..."

    local branch=$(get_branch "$project_dir" || echo "")
    [[ -n "$branch" ]] && checkout_branch "$project_dir" "$branch"

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
    info "Hook installed: ~/.claude/hooks/sync_and_launch.sh"
}

install_settings() {
    step "Configuring Claude hooks..."

    mkdir -p "$CLAUDE_DIR"

    local hook_entry='{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "~/.claude/hooks/sync_and_launch.sh",
        "timeout": 30000
      }]
    }'

    if [[ ! -f "$SETTINGS_FILE" ]]; then
        echo "{\"hooks\":{\"Stop\":[$hook_entry]}}" | jq '.' > "$SETTINGS_FILE"
        info "Created Claude settings with hook"
    elif jq -e '.hooks.Stop[]?.hooks[]? | select(.command | contains("sync_and_launch"))' "$SETTINGS_FILE" &>/dev/null; then
        info "Hook already configured"
    else
        jq --argjson hook "$hook_entry" '.hooks.Stop = ((.hooks.Stop // []) + [$hook])' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"
        mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
        info "Added hook to Claude settings"
    fi
}

install_skill() {
    step "Installing /pr-review skill..."

    local skill_dir="$SKILLS_DIR/pr-review"
    mkdir -p "$skill_dir"

    cat > "$skill_dir/SKILL.md" << 'SKILL_EOF'
---
name: pr-review
description: Review a GitHub PR and output findings to .claude-review.json for IDE visualization
---

Review a GitHub Pull Request and generate structured review comments.

## Steps

1. Get PR info: `gh pr view <number> --json headRefName,title,files`
2. Checkout branch: `gh pr checkout <number>`
3. Analyze changes: `gh pr diff <number>`
4. Write `.claude-review.json`:

```json
{
  "branch": "<branch-name>",
  "pr": <number>,
  "comments": [
    {
      "file": "path/to/file.ts",
      "line": 42,
      "message": "### Title\n\n**Problem:** ...\n\n**Suggestion:**\n```code```",
      "author": "Claude",
      "mode": "suggestion",
      "severity": "error"
    }
  ]
}
```

## Severity

- **error**: Security, bugs, crashes, breaking changes
- **warning**: Performance, code smells, deprecations
- **info**: Style, best practices

## Usage

```
/pr-review 123
/pr-review https://github.com/org/repo/pull/123
```

After writing the file, summarize findings by severity. IDE opens with comments on exit.
SKILL_EOF

    info "Skill installed: ~/.claude/skills/pr-review/"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      Claude Review Lens Installer          ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo ""

    check_deps

    local editor
    editor=$(detect_editor)

    if [[ -z "$editor" ]]; then
        warn "No editor found (cursor/code)"
        echo "    Install extension manually: $MARKETPLACE_URL"
    else
        install_extension "$editor"
    fi

    install_hook
    install_settings
    install_skill

    echo ""
    echo -e "${GREEN}✓ Installation complete!${NC}"
    echo ""
    echo "  Usage:"
    echo "    cd your-project"
    echo "    claude"
    echo "    > /pr-review 123"
    echo "    > exit"
    echo ""
    echo "  IDE opens automatically with review comments."
    echo ""
    echo -e "  ${YELLOW}⚠ Restart Claude CLI for /pr-review skill${NC}"
    echo ""
}

main "$@"
