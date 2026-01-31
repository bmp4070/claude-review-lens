import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';

// ============================================================================
// Types
// ============================================================================

interface ReviewComment {
  file: string;
  line: number;
  message: string;
  type: 'info' | 'warning' | 'error';
}

// ============================================================================
// Decoration Types Factory
// ============================================================================

function createDecorationTypes() {
  const gutterIconPath = (type: string) => {
    // Using unicode-based SVG for gutter icons
    const colors: Record<string, string> = {
      info: '#6b9fef',
      warning: '#d9a540',
      error: '#e55353'
    };
    const color = colors[type] || colors.info;

    // Create a simple circle SVG as data URI
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
      <circle cx="8" cy="8" r="6" fill="${color}" opacity="0.9"/>
      <circle cx="8" cy="8" r="3" fill="white" opacity="0.8"/>
    </svg>`;

    return vscode.Uri.parse(`data:image/svg+xml,${encodeURIComponent(svg)}`);
  };

  const ghostTextStyles: Record<string, vscode.ThemableDecorationAttachmentRenderOptions> = {
    info: {
      color: new vscode.ThemeColor('editorCodeLens.foreground'),
      fontStyle: 'italic',
      margin: '0 0 0 2em'
    },
    warning: {
      color: '#d9a540',
      fontStyle: 'italic',
      margin: '0 0 0 2em'
    },
    error: {
      color: '#e55353',
      fontStyle: 'italic',
      margin: '0 0 0 2em'
    }
  };

  return {
    info: vscode.window.createTextEditorDecorationType({
      gutterIconPath: gutterIconPath('info'),
      gutterIconSize: 'contain',
      after: ghostTextStyles.info
    }),
    warning: vscode.window.createTextEditorDecorationType({
      gutterIconPath: gutterIconPath('warning'),
      gutterIconSize: 'contain',
      after: ghostTextStyles.warning
    }),
    error: vscode.window.createTextEditorDecorationType({
      gutterIconPath: gutterIconPath('error'),
      gutterIconSize: 'contain',
      after: ghostTextStyles.error
    })
  };
}

// ============================================================================
// Review Manager
// ============================================================================

class ReviewManager {
  private decorationTypes: ReturnType<typeof createDecorationTypes>;
  private comments: ReviewComment[] = [];
  private disposables: vscode.Disposable[] = [];
  private watcher: vscode.FileSystemWatcher | undefined;

  constructor(private readonly workspaceRoot: string) {
    this.decorationTypes = createDecorationTypes();
    this.setupFileWatcher();
    this.setupEditorListeners();
    this.loadComments();
  }

  private get reviewFilePath(): string {
    return path.join(this.workspaceRoot, '.claude-review.json');
  }

  private setupFileWatcher(): void {
    const pattern = new vscode.RelativePattern(this.workspaceRoot, '.claude-review.json');
    this.watcher = vscode.workspace.createFileSystemWatcher(pattern);

    this.watcher.onDidCreate(() => this.loadComments(), this, this.disposables);
    this.watcher.onDidChange(() => this.loadComments(), this, this.disposables);
    this.watcher.onDidDelete(() => this.clearAllDecorations(), this, this.disposables);

    this.disposables.push(this.watcher);
  }

  private setupEditorListeners(): void {
    vscode.window.onDidChangeActiveTextEditor(
      () => this.applyDecorationsToActiveEditor(),
      this,
      this.disposables
    );

    // Also handle when document content changes (in case lines shift)
    vscode.workspace.onDidChangeTextDocument(
      (e) => {
        const activeEditor = vscode.window.activeTextEditor;
        if (activeEditor && e.document === activeEditor.document) {
          this.applyDecorationsToActiveEditor();
        }
      },
      this,
      this.disposables
    );
  }

  private loadComments(): void {
    try {
      if (!fs.existsSync(this.reviewFilePath)) {
        this.comments = [];
        this.clearAllDecorations();
        return;
      }

      const content = fs.readFileSync(this.reviewFilePath, 'utf-8');
      const parsed = JSON.parse(content);

      if (!Array.isArray(parsed)) {
        vscode.window.showWarningMessage('Claude Review Lens: Invalid format - expected array');
        return;
      }

      this.comments = parsed.filter(this.isValidComment);
      this.applyDecorationsToActiveEditor();

    } catch (error) {
      if (error instanceof SyntaxError) {
        vscode.window.showWarningMessage('Claude Review Lens: Invalid JSON in .claude-review.json');
      } else {
        console.error('Claude Review Lens: Error loading comments', error);
      }
    }
  }

  private isValidComment(item: unknown): item is ReviewComment {
    if (typeof item !== 'object' || item === null) {
      return false;
    }
    const obj = item as Record<string, unknown>;
    return (
      typeof obj.file === 'string' &&
      typeof obj.line === 'number' &&
      typeof obj.message === 'string' &&
      ['info', 'warning', 'error'].includes(obj.type as string)
    );
  }

  private applyDecorationsToActiveEditor(): void {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
      return;
    }

    // Clear existing decorations first
    this.clearDecorations(editor);

    const filePath = editor.document.uri.fsPath;
    const relativePath = path.relative(this.workspaceRoot, filePath);

    // Group comments by type for this file
    const commentsByType: Record<string, ReviewComment[]> = {
      info: [],
      warning: [],
      error: []
    };

    for (const comment of this.comments) {
      // Match both absolute and relative paths
      if (comment.file === relativePath || comment.file === filePath) {
        commentsByType[comment.type]?.push(comment);
      }
    }

    // Apply decorations for each type
    for (const [type, typeComments] of Object.entries(commentsByType)) {
      const decorations = this.createDecorations(editor, typeComments);
      const decorationType = this.decorationTypes[type as keyof typeof this.decorationTypes];
      editor.setDecorations(decorationType, decorations);
    }
  }

  private createDecorations(
    editor: vscode.TextEditor,
    comments: ReviewComment[]
  ): vscode.DecorationOptions[] {
    const lineCount = editor.document.lineCount;

    return comments
      .filter((c) => c.line >= 1 && c.line <= lineCount)
      .map((comment) => {
        const lineIndex = comment.line - 1; // Convert to 0-based
        const line = editor.document.lineAt(lineIndex);
        const range = new vscode.Range(lineIndex, line.text.length, lineIndex, line.text.length);

        // Truncate message for ghost text
        const truncatedMessage = comment.message.length > 50
          ? comment.message.substring(0, 47) + '...'
          : comment.message;

        return {
          range,
          hoverMessage: this.createHoverMessage(comment),
          renderOptions: {
            after: {
              contentText: `  // ${truncatedMessage}`
            }
          }
        };
      });
  }

  private createHoverMessage(comment: ReviewComment): vscode.MarkdownString {
    const icons: Record<string, string> = {
      info: '$(info)',
      warning: '$(warning)',
      error: '$(error)'
    };

    const md = new vscode.MarkdownString();
    md.supportThemeIcons = true;
    md.appendMarkdown(`**${icons[comment.type]} Claude Review**\n\n`);
    md.appendMarkdown(comment.message);
    return md;
  }

  private clearDecorations(editor: vscode.TextEditor): void {
    editor.setDecorations(this.decorationTypes.info, []);
    editor.setDecorations(this.decorationTypes.warning, []);
    editor.setDecorations(this.decorationTypes.error, []);
  }

  private clearAllDecorations(): void {
    this.comments = [];
    for (const editor of vscode.window.visibleTextEditors) {
      this.clearDecorations(editor);
    }
  }

  public refresh(): void {
    this.loadComments();
  }

  public dispose(): void {
    // Clear all decorations
    this.clearAllDecorations();

    // Dispose decoration types
    this.decorationTypes.info.dispose();
    this.decorationTypes.warning.dispose();
    this.decorationTypes.error.dispose();

    // Dispose all subscriptions
    for (const disposable of this.disposables) {
      disposable.dispose();
    }
    this.disposables = [];
  }
}

// ============================================================================
// Extension Activation
// ============================================================================

let reviewManager: ReviewManager | undefined;

export function activate(context: vscode.ExtensionContext): void {
  const workspaceFolders = vscode.workspace.workspaceFolders;
  if (!workspaceFolders || workspaceFolders.length === 0) {
    return;
  }

  const workspaceRoot = workspaceFolders[0].uri.fsPath;
  reviewManager = new ReviewManager(workspaceRoot);

  // Register refresh command
  const refreshCommand = vscode.commands.registerCommand(
    'claude-review-lens.refresh',
    () => reviewManager?.refresh()
  );

  context.subscriptions.push(refreshCommand);
  context.subscriptions.push({ dispose: () => reviewManager?.dispose() });

  console.log('Claude Review Lens activated');
}

export function deactivate(): void {
  reviewManager?.dispose();
  reviewManager = undefined;
}
