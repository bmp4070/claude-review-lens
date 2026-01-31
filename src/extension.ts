import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';

// =============================================================================
// Types
// =============================================================================

interface ReviewComment {
  file: string;
  line: number;
  message: string;
  author?: string;
  mode?: 'comment' | 'suggestion';
  severity?: 'info' | 'warning' | 'error';
}

interface ClaudeComment extends vscode.Comment {
  id: string;
  parent?: ClaudeCommentThread;
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

    this.disposables.push(resolveCmd, resolveAllCmd, refreshCmd, openPanelCmd);
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

  private loadReviewComments(): void {
    try {
      if (!fs.existsSync(this.reviewFilePath)) {
        this.clearAllThreads();
        return;
      }

      const content = fs.readFileSync(this.reviewFilePath, 'utf-8');
      const comments: ReviewComment[] = JSON.parse(content);

      if (!Array.isArray(comments)) {
        vscode.window.showWarningMessage('Claude Review: Invalid format - expected array');
        return;
      }

      // Clear existing threads before rebuilding
      this.clearAllThreads();

      // Group comments by file and line for threading
      const grouped = this.groupComments(comments);

      // Create threads
      for (const groupedComments of grouped.values()) {
        this.createThread(groupedComments);
      }

      // Show notification
      const count = comments.length;
      if (count > 0) {
        vscode.window
          .showInformationMessage(
            `Claude Review: ${count} comment${count > 1 ? 's' : ''} loaded`,
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

  private createThread(comments: ReviewComment[]): void {
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
    const body = this.buildCommentBody(review);

    const comment: ClaudeComment = {
      id,
      body,
      author: this.getAuthor(review),
      mode: vscode.CommentMode.Preview,
      parent: thread,
      contextValue: review.mode === 'suggestion' ? 'suggestion' : 'comment',
    };

    return comment;
  }

  private buildCommentBody(review: ReviewComment): vscode.MarkdownString {
    const md = new vscode.MarkdownString();
    md.isTrusted = true;
    md.supportHtml = true;
    md.supportThemeIcons = true;

    // Add severity badge if present
    if (review.severity) {
      const badges: Record<string, string> = {
        info: '$(info) **Info**',
        warning: '$(warning) **Warning**',
        error: '$(error) **Error**',
      };
      md.appendMarkdown(badges[review.severity] + '\n\n');
    }

    // Add suggestion label if applicable
    if (review.mode === 'suggestion') {
      md.appendMarkdown('$(lightbulb) **Suggestion**\n\n');
    }

    // Add the main message (already supports markdown)
    md.appendMarkdown(review.message);

    return md;
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

  // Note: Reactions require iconPath which complicates things
  // Severity is shown via badges in the comment body instead

  private resolveThread(thread: ClaudeCommentThread): void {
    thread.dispose();
    this.threads.delete(thread.id);
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
