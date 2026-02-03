import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';
import { spawn, execSync } from 'child_process';

// =============================================================================
// Types
// =============================================================================

interface ReviewComment {
  file: string;
  line: number;
  endLine?: number; // End line for multi-line replacements (1-based, inclusive)
  message: string;
  author?: string;
  mode?: 'comment' | 'suggestion';
  severity?: 'critical' | 'medium' | 'nit'; // Review severity: critical (must fix), medium (should fix), nit (nice to have)
  suggestedCode?: string; // Explicit code to apply for suggestions
  confidence?: number; // Confidence score 0-100 (from code-reviewer agent)
  agent?: string; // Which pr-review-toolkit agent generated this (e.g., 'code-reviewer', 'silent-failure-hunter')
  category?: string; // Issue category (e.g., 'error-handling', 'type-design', 'test-coverage')
  ratings?: Record<string, number>; // Quantitative ratings (e.g., from type-design-analyzer)
  metadata?: {
    branch?: string;
  };
}

// =============================================================================
// Claude CLI Detection
// =============================================================================

class ClaudeCliDetector {
  private static cachedPath: string | null | undefined = undefined;

  static async detect(): Promise<string | null> {
    if (this.cachedPath !== undefined) {
      return this.cachedPath;
    }

    const paths = [
      // Common global paths
      '/usr/local/bin/claude',
      '/opt/homebrew/bin/claude',
      // User local
      `${process.env.HOME}/.local/bin/claude`,
      `${process.env.HOME}/.npm-global/bin/claude`,
      // NVM paths
      `${process.env.HOME}/.nvm/versions/node/*/bin/claude`,
    ];

    // Check specific paths first
    for (const p of paths) {
      if (!p.includes('*') && this.isExecutable(p)) {
        this.cachedPath = p;
        return p;
      }
    }

    // Try 'which claude' or 'where claude'
    try {
      const cmd = process.platform === 'win32' ? 'where claude' : 'which claude';
      const result = execSync(cmd, { encoding: 'utf-8', timeout: 5000 }).trim();
      const foundPath = result.split('\n')[0];
      if (foundPath && this.isExecutable(foundPath)) {
        this.cachedPath = foundPath;
        return foundPath;
      }
    } catch {
      // Not found in PATH
    }

    this.cachedPath = null;
    return null;
  }

  private static isExecutable(filePath: string): boolean {
    try {
      fs.accessSync(filePath, fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  }

  static clearCache(): void {
    this.cachedPath = undefined;
  }
}

// ReviewFile format: { branch?: string, pr?: number, comments: ReviewComment[] }
// Also supports simple array format: ReviewComment[]

interface ClaudeComment extends vscode.Comment {
  id: string;
  parent?: ClaudeCommentThread;
  reviewData?: ReviewComment; // Store original review for apply action
}

interface ClaudeCommentThread extends vscode.CommentThread {
  id: string;
}

// =============================================================================
// Constants
// =============================================================================

const REVIEW_FILE = '.claude-review.json';
const CONTROLLER_ID = 'claude-review';
const CONTROLLER_LABEL = 'Claude Review';

// =============================================================================
// Comment Controller Manager
// =============================================================================

class ClaudeReviewController {
  private controller: vscode.CommentController;
  private threads: Map<string, ClaudeCommentThread> = new Map();
  private comments: Map<string, ClaudeComment> = new Map(); // Track comments for apply action
  private disposables: vscode.Disposable[] = [];
  private watcher: vscode.FileSystemWatcher | undefined;
  private commentId = 0;

  // Claude author persona
  private readonly claudeAuthor: vscode.CommentAuthorInformation = {
    name: 'Claude',
    iconPath: vscode.Uri.parse(
      'data:image/svg+xml,' +
        encodeURIComponent(`
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
            <defs>
              <linearGradient id="claude-grad" x1="0%" y1="0%" x2="100%" y2="100%">
                <stop offset="0%" style="stop-color:#D97757;stop-opacity:1" />
                <stop offset="100%" style="stop-color:#C45A3B;stop-opacity:1" />
              </linearGradient>
            </defs>
            <circle cx="16" cy="16" r="15" fill="url(#claude-grad)"/>
            <text x="16" y="21" font-family="system-ui" font-size="14" font-weight="bold"
                  fill="white" text-anchor="middle">C</text>
          </svg>
        `)
    ),
  };

  constructor(private readonly workspaceRoot: string) {
    // Create the comment controller
    this.controller = vscode.comments.createCommentController(
      CONTROLLER_ID,
      CONTROLLER_LABEL
    );

    // Configure comment controller options
    this.controller.commentingRangeProvider = undefined; // Read-only, no new comments

    // Register reply handler for Claude CLI interaction
    this.controller.reactionHandler = undefined; // No reactions

    // Note: VS Code calls this command when user submits a reply in the comment thread
    // The argument is a CommentReply object with {thread, text}
    this.disposables.push(
      vscode.commands.registerCommand('claude-review.reply', async (reply: vscode.CommentReply) => {
        if (!reply || !reply.text) {
          vscode.window.showWarningMessage('Claude Review: Please enter a reply');
          return;
        }
        await this.handleReply(reply);
      })
    );

    // Register commands
    this.registerCommands();

    // Setup file watcher
    this.setupFileWatcher();

    // Initial load
    this.loadReviewComments();
  }

  private registerCommands(): void {
    // Resolve single thread
    const resolveCmd = vscode.commands.registerCommand(
      'claude-review.resolve',
      (thread: ClaudeCommentThread) => {
        this.resolveThread(thread);
      }
    );

    // Resolve all threads
    const resolveAllCmd = vscode.commands.registerCommand(
      'claude-review.resolveAll',
      () => {
        this.resolveAllThreads();
      }
    );

    // Refresh from file
    const refreshCmd = vscode.commands.registerCommand(
      'claude-review.refresh',
      () => {
        this.loadReviewComments();
      }
    );

    // Open comments panel
    const openPanelCmd = vscode.commands.registerCommand(
      'claude-review.openPanel',
      () => {
        vscode.commands.executeCommand('workbench.panel.comments.focus');
      }
    );

    // Expand all collapsed threads
    const expandAllCmd = vscode.commands.registerCommand(
      'claude-review.expandAll',
      () => {
        this.expandAllThreads();
      }
    );

    // Toggle thread at current line
    const toggleCmd = vscode.commands.registerCommand(
      'claude-review.toggleAtLine',
      () => {
        this.toggleThreadAtCurrentLine();
      }
    );

    // Apply suggestion
    const applySuggestionCmd = vscode.commands.registerCommand(
      'claude-review.applySuggestion',
      (commentId: string) => {
        this.applySuggestion(commentId);
      }
    );

    // Copy suggestion to clipboard
    const copySuggestionCmd = vscode.commands.registerCommand(
      'claude-review.copySuggestion',
      (commentId: string) => {
        this.copySuggestion(commentId);
      }
    );

    this.disposables.push(resolveCmd, resolveAllCmd, refreshCmd, openPanelCmd, expandAllCmd, toggleCmd, applySuggestionCmd, copySuggestionCmd);

    // Auto-expand when cursor moves to a line with a comment
    vscode.window.onDidChangeTextEditorSelection(
      (e) => this.onSelectionChange(e),
      this,
      this.disposables
    );
  }

  private onSelectionChange(e: vscode.TextEditorSelectionChangeEvent): void {
    const editor = e.textEditor;
    const line = e.selections[0]?.active.line;
    if (line === undefined) {
      return;
    }

    // Find thread at this line
    const filePath = editor.document.uri.fsPath;
    for (const thread of this.threads.values()) {
      if (
        thread.uri.fsPath === filePath &&
        thread.range &&
        thread.range.start.line === line &&
        thread.collapsibleState === vscode.CommentThreadCollapsibleState.Collapsed
      ) {
        thread.collapsibleState = vscode.CommentThreadCollapsibleState.Expanded;
        break;
      }
    }
  }

  private expandAllThreads(): void {
    for (const thread of this.threads.values()) {
      thread.collapsibleState = vscode.CommentThreadCollapsibleState.Expanded;
    }
  }

  private toggleThreadAtCurrentLine(): void {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
      return;
    }

    const line = editor.selection.active.line;
    const filePath = editor.document.uri.fsPath;

    for (const thread of this.threads.values()) {
      if (thread.uri.fsPath === filePath && thread.range && thread.range.start.line === line) {
        thread.collapsibleState =
          thread.collapsibleState === vscode.CommentThreadCollapsibleState.Collapsed
            ? vscode.CommentThreadCollapsibleState.Expanded
            : vscode.CommentThreadCollapsibleState.Collapsed;
        break;
      }
    }
  }

  private setupFileWatcher(): void {
    const pattern = new vscode.RelativePattern(this.workspaceRoot, REVIEW_FILE);
    this.watcher = vscode.workspace.createFileSystemWatcher(pattern);

    this.watcher.onDidCreate(() => this.loadReviewComments(), this, this.disposables);
    this.watcher.onDidChange(() => this.loadReviewComments(), this, this.disposables);
    this.watcher.onDidDelete(() => this.clearAllThreads(), this, this.disposables);

    this.disposables.push(this.watcher);
  }

  private get reviewFilePath(): string {
    return path.join(this.workspaceRoot, REVIEW_FILE);
  }

  private async loadReviewComments(): Promise<void> {
    try {
      if (!fs.existsSync(this.reviewFilePath)) {
        this.clearAllThreads();
        return;
      }

      const content = fs.readFileSync(this.reviewFilePath, 'utf-8');
      const parsed = JSON.parse(content);

      // Support both array format and object format with comments field
      let comments: ReviewComment[];
      if (Array.isArray(parsed)) {
        comments = parsed;
      } else if (parsed && typeof parsed === 'object' && Array.isArray(parsed.comments)) {
        comments = parsed.comments;
      } else {
        vscode.window.showWarningMessage('Claude Review: Invalid format - expected array or {comments: [...]}');
        return;
      }

      // Clear existing threads before rebuilding
      this.clearAllThreads();

      // Group comments by file and line for threading
      const grouped = this.groupComments(comments);

      // Create threads (async to check CLI availability)
      const threadPromises = Array.from(grouped.values()).map((groupedComments) =>
        this.createThread(groupedComments)
      );
      await Promise.all(threadPromises);

      // Show notification with CLI status
      const count = comments.length;
      if (count > 0) {
        const claudePath = await ClaudeCliDetector.detect();
        const replyStatus = claudePath ? ' (replies enabled)' : '';

        vscode.window
          .showInformationMessage(
            `Claude Review: ${count} comment${count > 1 ? 's' : ''} loaded${replyStatus}`,
            'Open Comments Panel'
          )
          .then((selection) => {
            if (selection === 'Open Comments Panel') {
              vscode.commands.executeCommand('workbench.panel.comments.focus');
            }
          });
      }
    } catch (error) {
      if (error instanceof SyntaxError) {
        vscode.window.showWarningMessage('Claude Review: Invalid JSON in review file');
      } else {
        console.error('Claude Review: Error loading comments', error);
      }
    }
  }

  private groupComments(comments: ReviewComment[]): Map<string, ReviewComment[]> {
    const grouped = new Map<string, ReviewComment[]>();

    for (const comment of comments) {
      const key = `${comment.file}:${comment.line}`;
      const existing = grouped.get(key) || [];
      existing.push(comment);
      grouped.set(key, existing);
    }

    return grouped;
  }

  private async createThread(comments: ReviewComment[]): Promise<void> {
    if (comments.length === 0) {
      return;
    }

    const firstComment = comments[0];
    const filePath = path.isAbsolute(firstComment.file)
      ? firstComment.file
      : path.join(this.workspaceRoot, firstComment.file);

    const uri = vscode.Uri.file(filePath);
    const line = Math.max(0, firstComment.line - 1); // Convert to 0-based

    // Create range for the entire line
    const range = new vscode.Range(line, 0, line, 0);

    // Create the thread
    const thread = this.controller.createCommentThread(
      uri,
      range,
      []
    ) as ClaudeCommentThread;

    // Generate thread ID
    const threadId = `${firstComment.file}:${firstComment.line}`;
    thread.id = threadId;

    // Configure thread appearance
    // Note: Reply functionality disabled for now - Claude CLI integration needs refinement
    thread.canReply = false;
    thread.collapsibleState = vscode.CommentThreadCollapsibleState.Expanded;
    thread.label = this.getThreadLabel(comments);

    // Add context value for command enablement
    thread.contextValue = 'claude-review-thread';

    // Create comments for the thread
    thread.comments = comments.map((c) => this.createComment(c, thread));

    // Store reference
    this.threads.set(threadId, thread);
  }

  private createComment(review: ReviewComment, thread: ClaudeCommentThread): ClaudeComment {
    const id = `comment-${++this.commentId}`;

    // Build the comment body with markdown
    const body = this.buildCommentBody(review, id);

    const comment: ClaudeComment = {
      id,
      body,
      author: this.getAuthor(review),
      mode: vscode.CommentMode.Preview,
      parent: thread,
      contextValue: review.mode === 'suggestion' ? 'suggestion' : 'comment',
      reviewData: review, // Store for apply action
    };

    // Track comment for apply action
    this.comments.set(id, comment);

    return comment;
  }

  private buildCommentBody(review: ReviewComment, commentId: string): vscode.MarkdownString {
    const md = new vscode.MarkdownString();
    md.isTrusted = true;
    md.supportHtml = true;
    md.supportThemeIcons = true;

    // Add severity badge if present
    if (review.severity) {
      const badges: Record<string, string> = {
        critical: '$(flame) **Critical**',
        medium: '$(warning) **Medium**',
        nit: '$(info) **Nit**',
      };
      const badge = badges[review.severity] || badges.nit;

      // Add confidence score if available
      if (review.confidence !== undefined) {
        md.appendMarkdown(`${badge} _(${review.confidence}% confidence)_\n\n`);
      } else {
        md.appendMarkdown(badge + '\n\n');
      }
    }

    // Add agent type badge if from pr-review-toolkit
    if (review.agent) {
      const agentLabels: Record<string, string> = {
        'code-reviewer': '$(checklist) Code Review',
        'silent-failure-hunter': '$(bug) Error Handling',
        'code-simplifier': '$(wand) Simplification',
        'comment-analyzer': '$(comment-discussion) Comment Quality',
        'pr-test-analyzer': '$(beaker) Test Coverage',
        'type-design-analyzer': '$(symbol-interface) Type Design',
      };
      const label = agentLabels[review.agent] || `$(extensions) ${review.agent}`;
      md.appendMarkdown(`${label}\n\n`);
    }

    // Add the main message (already supports markdown)
    // If suggestedCode is present, strip out redundant "Suggestion/Suggested Fix" code blocks from message
    let message = review.message;
    if (review.suggestedCode) {
      // Remove "**Suggestion:**" or "**Suggested Fix:**" sections with their code blocks
      message = message.replace(/\*\*Suggest(?:ion|ed Fix):\*\*\s*\n*```[\s\S]*?```/gi, '');
      // Clean up any trailing whitespace or multiple newlines
      message = message.replace(/\n{3,}/g, '\n\n').trim();
    }
    md.appendMarkdown(message);

    // Add ratings if available (from type-design-analyzer)
    if (review.ratings && Object.keys(review.ratings).length > 0) {
      md.appendMarkdown('\n\n---\n**Ratings:**\n');
      for (const [key, value] of Object.entries(review.ratings)) {
        const stars = '★'.repeat(Math.round(value)) + '☆'.repeat(10 - Math.round(value));
        md.appendMarkdown(`- ${key}: ${stars} (${value}/10)\n`);
      }
    }

    // Add suggested code block with diff-like styling
    if (review.mode === 'suggestion' && review.suggestedCode) {
      const args = encodeURIComponent(JSON.stringify(commentId));

      // Detect language from file extension
      const ext = review.file.split('.').pop() || '';
      const langMap: Record<string, string> = {
        ts: 'typescript', tsx: 'typescript', js: 'javascript', jsx: 'javascript',
        py: 'python', java: 'java', go: 'go', rs: 'rust', rb: 'ruby',
        cpp: 'cpp', c: 'c', cs: 'csharp', php: 'php', swift: 'swift',
      };
      const lang = langMap[ext] || ext;

      // Add styled suggested code section
      md.appendMarkdown('\n\n---\n');
      md.appendMarkdown(`$(diff-added) **Suggested Change** _(Lines ${review.line}${review.endLine ? `-${review.endLine}` : ''})_ ‎ ‎ [$(copy)](command:claude-review.copySuggestion?${args} "Copy to clipboard")\n\n`);

      // Code block with syntax highlighting and green diff prefix
      const codeLines = review.suggestedCode.split('\n');
      const diffCode = codeLines.map(line => `+ ${line}`).join('\n');
      md.appendMarkdown(`\`\`\`diff\n${diffCode}\n\`\`\`\n\n`);

      // Action button
      md.appendMarkdown(`[$(play) **Apply Change**](command:claude-review.applySuggestion?${args})`);
    }

    return md;
  }

  private async applySuggestion(commentId: string): Promise<void> {
    const comment = this.comments.get(commentId);
    if (!comment || !comment.reviewData) {
      vscode.window.showErrorMessage('Claude Review: Could not find suggestion to apply');
      return;
    }

    const review = comment.reviewData;
    if (!review.suggestedCode) {
      vscode.window.showErrorMessage('Claude Review: No suggested code available');
      return;
    }

    // Build file path
    const filePath = path.isAbsolute(review.file)
      ? review.file
      : path.join(this.workspaceRoot, review.file);

    const uri = vscode.Uri.file(filePath);

    try {
      // Open the document
      const document = await vscode.workspace.openTextDocument(uri);

      // Calculate range to replace
      const startLine = Math.max(0, review.line - 1); // Convert to 0-based
      const endLine = review.endLine ? review.endLine - 1 : startLine; // Use endLine if provided

      const startPos = new vscode.Position(startLine, 0);
      const endPos = new vscode.Position(endLine, document.lineAt(endLine).text.length);
      const range = new vscode.Range(startPos, endPos);

      // Create workspace edit
      const edit = new vscode.WorkspaceEdit();
      edit.replace(uri, range, review.suggestedCode);

      // Apply the edit
      const success = await vscode.workspace.applyEdit(edit);

      if (success) {
        vscode.window.showInformationMessage('Claude Review: Suggestion applied');

        // Optionally resolve the thread
        if (comment.parent) {
          this.resolveThread(comment.parent);
        }
      } else {
        vscode.window.showErrorMessage('Claude Review: Failed to apply suggestion');
      }
    } catch (error) {
      vscode.window.showErrorMessage(
        `Claude Review: Error applying suggestion - ${error instanceof Error ? error.message : 'Unknown error'}`
      );
    }
  }

  private async copySuggestion(commentId: string): Promise<void> {
    const comment = this.comments.get(commentId);
    if (!comment || !comment.reviewData) {
      vscode.window.showErrorMessage('Claude Review: Could not find suggestion to copy');
      return;
    }

    const review = comment.reviewData;
    if (!review.suggestedCode) {
      vscode.window.showErrorMessage('Claude Review: No suggested code available');
      return;
    }

    await vscode.env.clipboard.writeText(review.suggestedCode);
    vscode.window.showInformationMessage('Claude Review: Suggested code copied to clipboard');
  }

  private getAuthor(review: ReviewComment): vscode.CommentAuthorInformation {
    if (review.author && review.author !== 'Claude') {
      return { name: review.author };
    }
    return this.claudeAuthor;
  }

  private getThreadLabel(comments: ReviewComment[]): string {
    const types = new Set(comments.map((c) => c.mode || 'comment'));
    if (types.has('suggestion')) {
      return 'Claude Suggestion';
    }
    return 'Claude Review';
  }

  // =============================================================================
  // Claude CLI Reply Handling
  // =============================================================================

  private async handleReply(reply: vscode.CommentReply): Promise<void> {
    const thread = reply.thread as ClaudeCommentThread;
    const userText = reply.text.trim();

    if (!userText) {
      return;
    }

    // Get the first comment to find original review data
    const firstComment = thread.comments[0] as ClaudeComment;
    const originalReview = firstComment?.reviewData;

    // Create loading comment
    const loadingComment = this.createLoadingComment();
    thread.comments = [...thread.comments, loadingComment];

    try {
      // Get file context around the relevant line
      const fileContext = await this.getFileContext(thread.uri.fsPath, originalReview?.line || 1, 10);

      // Build the prompt
      const prompt = this.buildClaudePrompt(originalReview, userText, fileContext);

      // Invoke Claude CLI
      const response = await this.invokeClaudeCli(prompt);

      // Remove loading comment
      thread.comments = thread.comments.filter((c) => c !== loadingComment);

      // Add user's message
      const userComment = this.createUserComment(userText);
      thread.comments = [...thread.comments, userComment];

      // Add Claude's response
      if (response.success && response.output) {
        const claudeResponse = this.createClaudeResponseComment(response.output);
        thread.comments = [...thread.comments, claudeResponse];
      } else {
        vscode.window.showErrorMessage(
          `Claude response failed: ${response.error || 'Unknown error'}`
        );
      }
    } catch (error) {
      // Remove loading comment on error
      thread.comments = thread.comments.filter((c) => c !== loadingComment);

      vscode.window.showErrorMessage(
        `Failed to get Claude response: ${error instanceof Error ? error.message : 'Unknown error'}`
      );
    }
  }

  private createLoadingComment(): ClaudeComment {
    const md = new vscode.MarkdownString('$(loading~spin) _Waiting for Claude..._');
    md.isTrusted = true;

    return {
      id: `loading-${Date.now()}`,
      body: md,
      author: this.claudeAuthor,
      mode: vscode.CommentMode.Preview,
    };
  }

  private createUserComment(text: string): ClaudeComment {
    const md = new vscode.MarkdownString(text);
    md.isTrusted = true;

    return {
      id: `user-${Date.now()}`,
      body: md,
      author: { name: 'You' },
      mode: vscode.CommentMode.Preview,
    };
  }

  private createClaudeResponseComment(response: string): ClaudeComment {
    const md = new vscode.MarkdownString(response);
    md.isTrusted = true;
    md.supportHtml = true;
    md.supportThemeIcons = true;

    return {
      id: `response-${Date.now()}`,
      body: md,
      author: this.claudeAuthor,
      mode: vscode.CommentMode.Preview,
    };
  }

  private async getFileContext(filePath: string, line: number, contextLines: number): Promise<string> {
    try {
      const document = await vscode.workspace.openTextDocument(filePath);
      const startLine = Math.max(0, line - contextLines - 1);
      const endLine = Math.min(document.lineCount - 1, line + contextLines - 1);

      const lines: string[] = [];
      for (let i = startLine; i <= endLine; i++) {
        const lineText = document.lineAt(i).text;
        const marker = i === line - 1 ? '>>>' : '   ';
        lines.push(`${marker} ${i + 1}: ${lineText}`);
      }
      return lines.join('\n');
    } catch {
      return '[Could not read file context]';
    }
  }

  private buildClaudePrompt(review: ReviewComment | undefined, userQuestion: string, fileContext: string): string {
    const parts: string[] = [];

    parts.push('You are responding to a follow-up question about a code review comment.');
    parts.push('');

    if (review) {
      parts.push('ORIGINAL REVIEW COMMENT:');
      parts.push(`File: ${review.file}, Line: ${review.line}`);
      if (review.severity) {
        parts.push(`Severity: ${review.severity}`);
      }
      parts.push(review.message);
      parts.push('');
    }

    parts.push('FILE CONTEXT (around the relevant line):');
    parts.push(fileContext);
    parts.push('');

    parts.push("USER'S QUESTION:");
    parts.push(userQuestion);
    parts.push('');

    parts.push("Provide a helpful, concise response addressing the user's question about this code review comment.");
    parts.push('Format your response in markdown.');

    return parts.join('\n');
  }

  private async invokeClaudeCli(prompt: string): Promise<{ success: boolean; output?: string; error?: string }> {
    const claudePath = await ClaudeCliDetector.detect();
    if (!claudePath) {
      return { success: false, error: 'Claude CLI not found' };
    }

    return new Promise((resolve) => {
      const child = spawn(claudePath, ['--print', prompt], {
        stdio: ['pipe', 'pipe', 'pipe'],
        cwd: this.workspaceRoot,
      });

      let stdout = '';
      let stderr = '';

      child.stdout?.on('data', (data) => {
        stdout += data.toString();
      });

      child.stderr?.on('data', (data) => {
        stderr += data.toString();
      });

      child.on('close', (code) => {
        if (code === 0) {
          resolve({ success: true, output: stdout.trim() });
        } else {
          resolve({ success: false, error: stderr.trim() || `Exit code: ${code}` });
        }
      });

      child.on('error', (err) => {
        resolve({ success: false, error: err.message });
      });

      // Timeout after 60 seconds
      setTimeout(() => {
        child.kill();
        resolve({ success: false, error: 'Request timed out after 60 seconds' });
      }, 60000);
    });
  }

  // Note: Reactions require iconPath which complicates things
  // Severity is shown via badges in the comment body instead

  private resolveThread(thread: ClaudeCommentThread | vscode.CommentThread): void {
    if (!thread) {
      vscode.window.showErrorMessage('Claude Review: No thread to resolve');
      return;
    }

    // Get the thread ID - either from our custom property or generate from URI/range
    const customThread = thread as ClaudeCommentThread;
    const threadId = customThread.id ||
      `${vscode.workspace.asRelativePath(thread.uri)}:${(thread.range?.start.line ?? 0) + 1}`;

    thread.dispose();
    this.threads.delete(threadId);
    this.updateReviewFile();
  }

  private resolveAllThreads(): void {
    for (const thread of this.threads.values()) {
      thread.dispose();
    }
    this.threads.clear();
    this.updateReviewFile();
  }

  private clearAllThreads(): void {
    for (const thread of this.threads.values()) {
      thread.dispose();
    }
    this.threads.clear();
    this.comments.clear(); // Clear comment tracking
  }

  private updateReviewFile(): void {
    // Optionally update the JSON file when threads are resolved
    // For now, we just clear in memory; the file remains unchanged
    // To persist resolved state, implement JSON file update here
  }

  public getFirstCommentLocation(): { file: string; line: number } | undefined {
    const firstThread = this.threads.values().next().value as ClaudeCommentThread | undefined;
    if (firstThread && firstThread.range) {
      return {
        file: firstThread.uri.fsPath,
        line: firstThread.range.start.line + 1,
      };
    }
    return undefined;
  }

  public dispose(): void {
    this.clearAllThreads();
    this.controller.dispose();
    for (const disposable of this.disposables) {
      disposable.dispose();
    }
    this.disposables = [];
  }
}

// =============================================================================
// Extension Activation
// =============================================================================

let reviewController: ClaudeReviewController | undefined;

export function activate(context: vscode.ExtensionContext): void {
  const workspaceFolders = vscode.workspace.workspaceFolders;
  if (!workspaceFolders || workspaceFolders.length === 0) {
    return;
  }

  const workspaceRoot = workspaceFolders[0].uri.fsPath;
  reviewController = new ClaudeReviewController(workspaceRoot);

  context.subscriptions.push({
    dispose: () => reviewController?.dispose(),
  });

  // Open comments panel if review file exists
  const reviewFile = path.join(workspaceRoot, REVIEW_FILE);
  if (fs.existsSync(reviewFile)) {
    // Small delay to let threads load first
    setTimeout(() => {
      vscode.commands.executeCommand('workbench.panel.comments.focus');
    }, 500);
  }

  console.log('Claude Review Lens activated');
}

export function deactivate(): void {
  reviewController?.dispose();
  reviewController = undefined;
}
