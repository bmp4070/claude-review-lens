#!/usr/bin/env bash
#
# Claude Review Lens - One-Line Installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/bmp4070/claude-review-lens/main/install.sh | bash
#
# Or clone and run:
#   git clone https://github.com/bmp4070/claude-review-lens.git
#   cd claude-review-lens && ./install.sh
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

REPO_URL="https://github.com/bmp4070/claude-review-lens"
VSIX_URL="https://github.com/bmp4070/claude-review-lens/releases/latest/download/claude-review-lens.vsix"
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

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Look for local VSIX first (if cloned repo)
    local vsix_path=""
    vsix_path=$(find "$script_dir" -maxdepth 1 -name "claude-review-lens-*.vsix" -type f 2>/dev/null | head -1)

    # If no local VSIX, download from GitHub releases
    if [[ -z "$vsix_path" ]]; then
        step "Downloading extension from GitHub releases..."
        vsix_path="/tmp/claude-review-lens.vsix"
        if ! curl -fsSL "$VSIX_URL" -o "$vsix_path" 2>/dev/null; then
            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║  Extension download failed!                                 ║${NC}"
            echo -e "${RED}╠════════════════════════════════════════════════════════════╣${NC}"
            echo -e "${RED}║  Please install manually:                                   ║${NC}"
            echo -e "${RED}║  1. Download VSIX from:                                     ║${NC}"
            echo -e "${RED}║     ${REPO_URL}/releases ${NC}"
            echo -e "${RED}║  2. Run:                                                    ║${NC}"
            echo -e "${RED}║     $editor --install-extension <path-to-vsix>     ${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            return 1
        fi
        info "Downloaded extension"
    fi

    # Install the extension
    if "$editor" --install-extension "$vsix_path" --force &>/dev/null; then
        info "Extension installed in $editor"
    else
        echo ""
        echo -e "${RED}Extension install failed.${NC}"
        echo "Try manually: $editor --install-extension $vsix_path"
        return 1
    fi
}

install_hook() {
    step "Installing Claude hook..."

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
    # Support both array and object formats
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

    # Checkout PR branch if specified
    local branch=$(get_branch "$project_dir" || echo "")
    [[ -n "$branch" ]] && checkout_branch "$project_dir" "$branch"

    # Launch editor
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
    step "Installing /pr-review skill..."

    local skill_dir="$SKILLS_DIR/pr-review"
    mkdir -p "$skill_dir"

    cat > "$skill_dir/SKILL.md" << 'SKILL_EOF'
---
name: pr-review
description: Review a GitHub PR and output findings to .claude-review.json for IDE visualization
---

# PR Review Skill

Review a GitHub Pull Request and generate structured review comments.

## Instructions

1. **Get PR details**: `gh pr view <number> --json headRefName,title,body,files`
2. **Checkout PR branch**: `gh pr checkout <number>`
3. **Analyze changes**: `gh pr diff <number>`
4. **Write findings** to `.claude-review.json`:

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

After writing the file, summarize findings. The IDE will display comments when you exit.
SKILL_EOF

    info "Skill installed: $skill_dir/SKILL.md"
}

install_claude_md() {
    step "Installing CLAUDE.md instructions..."

    local claude_md="$CLAUDE_DIR/CLAUDE.md"
    local marker="# Claude Review Lens"

    if [[ -f "$claude_md" ]] && grep -q "$marker" "$claude_md"; then
        info "CLAUDE.md already configured"
        return 0
    fi

    cat >> "$claude_md" << 'CLAUDE_EOF'

# Claude Review Lens

When reviewing PRs, output to `.claude-review.json`:

```json
{
  "branch": "feature-branch",
  "pr": 123,
  "comments": [
    {"file": "path.ts", "line": 42, "message": "...", "severity": "error"}
  ]
}
```

Use `/pr-review <number>` to review a PR.
CLAUDE_EOF

    info "Added instructions to CLAUDE.md"
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
    echo "    > /pr-review 123      # Review PR #123"
    echo "    > exit"
    echo ""
    echo "  On exit, your editor opens with review comments."
    echo ""
    echo -e "  ${YELLOW}⚠ IMPORTANT: Restart Claude CLI for /pr-review to appear${NC}"
    echo ""
}

main "$@"
