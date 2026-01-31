# Claude Review Lens Integration

## Code Review Output Format

When performing a code review (e.g., when the user asks to "review this code", "review the PR", "review my changes"), output your findings to `.claude-review.json` in the workspace root.

### Schema

```json
[
  {
    "file": "relative/path/to/file.ts",
    "line": 42,
    "message": "Markdown-formatted review comment",
    "author": "Claude",
    "mode": "comment | suggestion",
    "severity": "info | warning | error"
  }
]
```

### Field Descriptions

| Field | Required | Description |
|-------|----------|-------------|
| `file` | Yes | Relative path from workspace root |
| `line` | Yes | 1-based line number |
| `message` | Yes | Markdown-formatted comment. Use `###` headers, `**bold**`, `` `code` ``, and fenced code blocks |
| `author` | No | Default: "Claude" |
| `mode` | No | `"comment"` for observations, `"suggestion"` for actionable changes |
| `severity` | No | `"info"`, `"warning"`, or `"error"` |

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
    "message": "### Missing Error Handling\n\n**Problem:** This async function doesn't catch errors.\n\n**Suggestion:**\n```typescript\ntry {\n  const result = await fetchData();\n  return result;\n} catch (error) {\n  logger.error('Failed to fetch:', error);\n  throw new ApiError(500, 'Internal error');\n}\n```",
    "author": "Claude",
    "mode": "suggestion",
    "severity": "error"
  }
]
```

### Review Workflow

1. When asked to review code/PR/changes, analyze the code thoroughly
2. Write findings to `.claude-review.json` using the Write tool
3. Summarize findings in your response
4. The Claude Review Lens extension will display comments in the IDE

### Severity Guidelines

- **error**: Security issues, bugs, crashes, data loss risks
- **warning**: Performance issues, code smells, potential bugs
- **info**: Style suggestions, best practices, minor improvements
