# Claude Review Lens Integration

## Code Review Output Format

When performing a code review (e.g., when the user asks to "review this code", "review the PR", "review my changes"), output your findings to `.claude-review.json` in the workspace root.

### Schema

```json
[
  {
    "file": "relative/path/to/file.ts",
    "line": 42,
    "endLine": 45,
    "message": "Markdown-formatted review comment",
    "author": "Claude",
    "mode": "comment | suggestion",
    "severity": "critical | medium | nit",
    "suggestedCode": "const x = 1;",
    "confidence": 95,
    "agent": "code-reviewer",
    "category": "error-handling",
    "ratings": { "encapsulation": 8, "clarity": 7 }
  }
]
```

### Field Descriptions

| Field | Required | Description |
|-------|----------|-------------|
| `file` | Yes | Relative path from workspace root |
| `line` | Yes | 1-based line number |
| `endLine` | No | End line for multi-line replacements (1-based, inclusive) |
| `message` | Yes | Markdown-formatted comment. Use `###` headers, `**bold**`, `` `code` ``, and fenced code blocks |
| `author` | No | Default: "Claude" |
| `mode` | No | `"comment"` for observations, `"suggestion"` for actionable changes |
| `severity` | No | `"critical"`, `"medium"`, or `"nit"` |
| `suggestedCode` | No | **For Apply Suggestion feature**: Clean code to apply when user clicks "Apply" |
| `confidence` | No | Confidence score 0-100 (displayed in comment) |
| `agent` | No | Agent that generated this (e.g., `"code-reviewer"`, `"silent-failure-hunter"`) |
| `category` | No | Issue category (e.g., `"error-handling"`, `"type-design"`) |
| `ratings` | No | Quantitative ratings object (e.g., `{"encapsulation": 8}`) displayed as star ratings |

### Message Formatting Guidelines

Structure review comments for maximum clarity:

```markdown
### Brief Title

**Problem:** What's wrong or could be improved.

**Suggestion:**
\`\`\`typescript
// Suggested code fix
\`\`\`

Why this matters or additional context.
```

### Example Review Output

When reviewing code, write the file like this:

```json
[
  {
    "file": "src/api/handler.ts",
    "line": 23,
    "endLine": 25,
    "message": "### Missing Error Handling\n\n**Problem:** This async function doesn't catch errors.\n\n**Suggestion:**\n```typescript\ntry {\n  const result = await fetchData();\n  return result;\n} catch (error) {\n  logger.error('Failed to fetch:', error);\n  throw new ApiError(500, 'Internal error');\n}\n```",
    "author": "Claude",
    "mode": "suggestion",
    "severity": "error",
    "suggestedCode": "try {\n  const result = await fetchData();\n  return result;\n} catch (error) {\n  logger.error('Failed to fetch:', error);\n  throw new ApiError(500, 'Internal error');\n}"
  }
]
```

### Review Workflow

1. When asked to review code/PR/changes, analyze the code thoroughly
2. Write findings to `.claude-review.json` using the Write tool
3. Summarize findings in your response
4. The Claude Review Lens extension will display comments in the IDE

### Severity Guidelines

- **critical**: Must fix - Security vulnerabilities, bugs, data loss, breaking changes
- **medium**: Should fix - Performance issues, code smells, potential bugs, missing error handling
- **nit**: Nice to have - Style suggestions, best practices, minor improvements, readability

## Features

### Apply Suggestion (One-Click Code Fix)

When `mode: "suggestion"` and `suggestedCode` is provided:
- An "Apply Suggestion" button appears in the comment
- Click to replace code at `line` (through `endLine` if specified) with `suggestedCode`
- The thread is automatically resolved after applying

### Claude CLI Interaction (Reply to Comments)

If Claude CLI is installed, users can reply to review comments:
- Reply box appears on each comment thread
- User questions are sent to Claude with the original review context
- Claude's response appears as a new comment in the thread

**Requirements:** Claude CLI must be installed and available in PATH.

### PR-Review-Toolkit Agent Support

The extension recognizes agents from the pr-review-toolkit:

| Agent | Icon | Description |
|-------|------|-------------|
| `code-reviewer` | $(checklist) | Code quality and style violations |
| `silent-failure-hunter` | $(bug) | Error handling issues |
| `code-simplifier` | $(wand) | Code simplification suggestions |
| `comment-analyzer` | $(comment-discussion) | Comment quality analysis |
| `pr-test-analyzer` | $(beaker) | Test coverage gaps |
| `type-design-analyzer` | $(symbol-interface) | Type design quality |

When `agent` is specified, the appropriate icon and label are displayed.

### Ratings Display

When `ratings` object is provided (e.g., from type-design-analyzer):
```json
"ratings": {
  "encapsulation": 8,
  "clarity": 7,
  "maintainability": 9
}
```

Each rating is displayed as a star rating (1-10 scale).
