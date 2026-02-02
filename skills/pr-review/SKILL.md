---
name: pr-review
description: Review a GitHub PR and output findings to .claude-review.json for IDE visualization
---

# PR Review Skill

Review a GitHub Pull Request and generate structured review comments that will be displayed in VS Code/Cursor.

## Instructions

1. **Get the PR details** using `gh pr view <number> --json headRefName,title,body,files`

2. **Checkout the PR branch** to analyze the actual code:
   ```bash
   gh pr checkout <number>
   ```

3. **Get the changed files** and analyze each one:
   ```bash
   gh pr diff <number>
   ```

4. **Write findings** to `.claude-review.json` in the workspace root using this schema:

```json
{
  "branch": "<branch-name-from-PR>",
  "pr": <pr-number>,
  "comments": [
    {
      "file": "relative/path/to/file.ts",
      "line": 42,
      "message": "### Title\n\n**Problem:** Description of the issue.\n\n**Suggestion:**\n```typescript\n// suggested fix\n```",
      "author": "Claude",
      "mode": "suggestion",
      "severity": "error"
    }
  ]
}
```

## Severity Guidelines

- **error**: Security issues, bugs, crashes, data loss, breaking changes
- **warning**: Performance issues, code smells, potential bugs, deprecations
- **info**: Style suggestions, best practices, minor improvements

## Message Formatting

Structure each comment with:
- `### Brief Title` - What the issue is
- `**Problem:**` - Why it's a problem
- `**Suggestion:**` - Code fix with fenced code block
- Additional context if needed

## Example Usage

User: `/pr-review 123`
User: `/pr-review https://github.com/org/repo/pull/123`

## Output

After writing `.claude-review.json`, summarize:
- Total comments by severity (X errors, Y warnings, Z info)
- Key issues found
- Overall assessment

The Claude Review Lens extension will display these as native comment threads in the IDE when you exit.
