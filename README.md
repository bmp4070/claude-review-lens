# Claude Review Lens

**CodeRabbit-style AI code reviews in your IDE, powered by Claude CLI.**

Transform Claude's code review output into native VS Code/Cursor comment threads — anchored to specific lines, with markdown rendering, severity badges, and a resolve workflow.

![Demo](docs/demo.gif)

## Features

- **Native Comment Threads** — Reviews appear as collapsible threads in the editor
- **Comments Panel Integration** — Navigate all findings from the sidebar
- **Markdown Support** — Code blocks, bold, lists, all rendered beautifully
- **Severity Badges** — Visual indicators for errors, warnings, and info
- **Resolve Workflow** — Dismiss comments as you address them
- **Auto-Launch** — IDE opens automatically when Claude generates a review

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/claude-review-lens/main/install.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/YOUR_ORG/claude-review-lens.git
cd claude-review-lens
./install.sh
```

## What Gets Installed

| Component | Location | Purpose |
|-----------|----------|---------|
| VS Code Extension | Cursor/VS Code | Renders comment threads |
| Stop Hook | `~/.claude/hooks/` | Launches IDE after review |
| `/review` Skill | `~/.claude/settings.json` | Slash command for reviews |
| CLAUDE.md | `~/.claude/CLAUDE.md` | Instructs Claude on output format |

## Usage

```bash
# Start Claude in any project
cd your-project
claude

# Run a review
> /review                    # Review all changes
> /review src/api/           # Review specific path
> review the authentication module

# Exit Claude
> exit
```

**On exit:** Your IDE opens with review comments displayed as native threads.

## Manual Extension Install

If the installer can't detect your editor:

```bash
# Cursor
cursor --install-extension claude-review-lens-0.2.0.vsix

# VS Code
code --install-extension claude-review-lens-0.2.0.vsix
```

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
git clone https://github.com/YOUR_ORG/claude-review-lens.git
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
