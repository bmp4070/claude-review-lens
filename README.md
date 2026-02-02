# Claude Review Lens

<img width="1112" height="926" alt="Screenshot 2026-02-02 at 12 57 40 PM" src="https://github.com/user-attachments/assets/49e1bc09-fca4-444e-ad81-cc261ccb63cf" />


**CodeRabbit-style AI code reviews in your IDE, powered by Claude CLI.**

Transform Claude's code review output into native VS Code/Cursor comment threads — anchored to specific lines, with markdown rendering, severity badges, and a resolve workflow.

## Features

- **Native Comment Threads** — Reviews appear as collapsible threads in the editor
- **Comments Panel Integration** — Navigate all findings from the sidebar
- **Markdown Support** — Code blocks, bold, lists, all rendered beautifully
- **Severity Badges** — Visual indicators for errors, warnings, and info
- **Resolve Workflow** — Dismiss comments as you address them
- **Auto-Launch** — IDE opens automatically when Claude generates a review

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/bmp4070/claude-review-lens/main/install.sh | bash
```

This installs:
- VS Code extension from [Marketplace](https://marketplace.visualstudio.com/items?itemName=code-authx.claude-review-lens)
- Claude stop hook for auto-launch
- `/pr-review` skill for PR reviews

## What Gets Installed

| Component | Location | Purpose |
|-----------|----------|---------|
| VS Code Extension | Cursor/VS Code | Renders comment threads |
| Stop Hook | `~/.claude/hooks/sync_and_launch.sh` | Checkouts branch & launches IDE |
| `/pr-review` Skill | `~/.claude/skills/pr-review/SKILL.md` | Slash command for PR reviews |
| CLAUDE.md | `~/.claude/CLAUDE.md` | Instructs Claude on output format |

## Usage

```bash
# Start Claude in any project
cd your-project
claude

# Review a PR
> /pr-review 123                    # Review PR #123
> /pr-review https://github.com/org/repo/pull/123

# Exit Claude
> exit
```

**On exit:** The hook checks out the PR branch and opens your IDE with review comments.

**⚠️ IMPORTANT:** Restart Claude CLI after installation for `/pr-review` to appear.

## Manual Extension Install

```bash
# From Marketplace (recommended)
cursor --install-extension code-authx.claude-review-lens
# or
code --install-extension code-authx.claude-review-lens
```

Or install from [VS Code Marketplace](https://marketplace.visualstudio.com/items?itemName=code-authx.claude-review-lens).

## Review JSON Schema

Claude writes reviews to `.claude-review.json`:

```json
[
  {
    "file": "src/api/handler.ts",
    "line": 23,
    "message": "### Missing Error Handling\n\n**Problem:** No try/catch around async call.\n\n```typescript\ntry {\n  await fetchData();\n} catch (e) {\n  handleError(e);\n}\n```",
    "author": "Claude",
    "mode": "suggestion",
    "severity": "error"
  }
]
```

### Fields

| Field | Required | Values |
|-------|----------|--------|
| `file` | Yes | Relative path from workspace root |
| `line` | Yes | 1-based line number |
| `message` | Yes | Markdown-formatted comment |
| `author` | No | Default: "Claude" |
| `mode` | No | `"comment"` or `"suggestion"` |
| `severity` | No | `"info"`, `"warning"`, `"error"` |

## Commands

| Command | Description |
|---------|-------------|
| `Claude Review: Refresh` | Reload comments from JSON |
| `Claude Review: Resolve All` | Dismiss all comment threads |
| `Claude Review: Open Panel` | Focus the Comments sidebar |

## Configuration

### Change Editor

Edit `~/.claude/hooks/sync_and_launch.sh` to prioritize your editor:

```bash
find_editor() {
    local paths=("cursor" "code" "codium" ...)
```

### Disable Auto-Launch

Remove the Stop hook from `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": []
  }
}
```

## Uninstall

```bash
# Remove hook
rm ~/.claude/hooks/sync_and_launch.sh

# Remove skill (edit settings.json)
# Remove extension
cursor --uninstall-extension your-publisher-name.claude-review-lens
```

## Development

```bash
# Clone
git clone https://github.com/bmp4070/claude-review-lens.git
cd claude-review-lens

# Install dependencies
npm install

# Compile
npm run compile

# Package
npm run package

# Test in VS Code
# Press F5 to launch Extension Development Host
```

## License

MIT
