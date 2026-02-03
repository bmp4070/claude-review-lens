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
      "endLine": 45,
      "message": "### Title\n\n**Problem:** Description of the issue.\n\n**Suggestion:**\n```typescript\n// suggested fix\n```",
      "author": "Claude",
      "mode": "suggestion",
      "severity": "critical",
      "suggestedCode": "// The clean code to apply\nconst result = await fetchData();"
    }
  ]
}
```

## Field Guidelines

### Required Fields
- `file`: Relative path from workspace root
- `line`: 1-based line number where the issue starts
- `message`: Markdown-formatted explanation

### Optional Fields
- `endLine`: End line for multi-line replacements (inclusive, 1-based)
- `mode`: `"comment"` for observations, `"suggestion"` for actionable fixes
- `severity`: `"critical"`, `"medium"`, or `"nit"`
- `suggestedCode`: **Important for Apply Suggestion feature** - clean code that will replace lines `line` through `endLine`

## Severity Guidelines

- **critical**: Must fix - Security vulnerabilities, bugs, data loss, breaking changes
- **medium**: Should fix - Performance issues, code smells, potential bugs, missing error handling
- **nit**: Nice to have - Style suggestions, best practices, minor improvements, readability

## Message Formatting

Structure each comment with:
- `### Brief Title` - What the issue is
- `**Problem:**` - Why it's a problem
- `**Suggestion:**` - Code fix with fenced code block
- Additional context if needed

## Apply Suggestion Feature

When providing a suggestion that can be applied with one click:

1. Set `mode: "suggestion"`
2. Set `line` to the first line to replace
3. Set `endLine` to the last line to replace (or omit for single-line)
4. Set `suggestedCode` to the exact code that should replace those lines

Example:
```json
{
  "file": "src/utils.ts",
  "line": 10,
  "endLine": 12,
  "message": "### Add null check\n\n**Problem:** Function may throw on null input.\n\n**Suggestion:**\n```typescript\nif (!data) return null;\nreturn data.value;\n```",
  "mode": "suggestion",
  "severity": "medium",
  "suggestedCode": "if (!data) return null;\nreturn data.value;"
}
```

The user can click "Apply Suggestion" in the IDE to replace lines 10-12 with the `suggestedCode`.

## Example Usage

User: `/pr-review 123`
User: `/pr-review https://github.com/org/repo/pull/123`

## Output

After writing `.claude-review.json`, summarize:
- Total comments by severity (X critical, Y medium, Z nits)
- Key issues found
- Overall assessment

The Claude Review Lens extension will display these as native comment threads in the IDE when you exit.

## Interactive Features

If the user has Claude CLI installed:
- They can reply to comments directly in the IDE
- Replies are sent to Claude with the original comment context
- Claude's response appears as a new comment in the thread
