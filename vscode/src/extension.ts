/* Bux Language Server Protocol client for VS Code
 * Discovers and launches the bux-lsp binary, connects via stdio.
 */

import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind,
    RevealOutputChannelOn,
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;
let outputChannel: vscode.OutputChannel | undefined;
let statusBar: vscode.StatusBarItem | undefined;

const SETTING_SECTION = 'bux';

export async function activate(context: vscode.ExtensionContext): Promise<void> {
    outputChannel = vscode.window.createOutputChannel('Bux');
    context.subscriptions.push(outputChannel);

    statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
    statusBar.command = 'bux.restartLsp';
    statusBar.tooltip = 'Bux Language Server — click to restart';
    context.subscriptions.push(statusBar);

    context.subscriptions.push(
        vscode.commands.registerCommand('bux.restartLsp', async () => {
            await restartClient(true);
        }),
        vscode.commands.registerCommand('bux.stopLsp', async () => {
            await stopClient();
            setStatus('off', 'Bux LSP stopped');
            outputChannel?.appendLine('[bux] LSP stopped by user');
        }),
        vscode.commands.registerCommand('bux.showOutput', () => {
            outputChannel?.show(true);
        }),
        vscode.workspace.onDidChangeConfiguration(async (e) => {
            if (
                e.affectsConfiguration('bux.lsp.enabled') ||
                e.affectsConfiguration('bux.lsp.path')
            ) {
                outputChannel?.appendLine('[bux] Configuration changed — restarting LSP');
                await restartClient(false);
            }
        })
    );

    await startClient();
}

export function deactivate(): Thenable<void> | undefined {
    return stopClient();
}

async function restartClient(userInitiated: boolean): Promise<void> {
    await stopClient();
    await startClient();
    if (userInitiated) {
        vscode.window.setStatusBarMessage('Bux LSP restarted', 3000);
    }
}

async function stopClient(): Promise<void> {
    if (!client) {
        return;
    }
    const c = client;
    client = undefined;
    try {
        await c.stop();
    } catch (err) {
        outputChannel?.appendLine(`[bux] Error stopping client: ${err}`);
    }
}

async function startClient(): Promise<void> {
    const config = vscode.workspace.getConfiguration(SETTING_SECTION);
    const enabled = config.get<boolean>('lsp.enabled', true);

    if (!enabled) {
        setStatus('off', 'Bux LSP disabled');
        outputChannel?.appendLine('[bux] LSP disabled in settings (bux.lsp.enabled)');
        return;
    }

    const configuredPath = config.get<string>('lsp.path', 'bux-lsp') || 'bux-lsp';
    const resolved = resolveLspPath(configuredPath);

    if (!resolved) {
        setStatus('error', 'bux-lsp not found');
        const msg =
            'Bux LSP binary not found. Build with `make lsp` (produces tools/bux-lsp) ' +
            'or set bux.lsp.path to the full path of the binary.';
        outputChannel?.appendLine(`[bux] ${msg}`);
        outputChannel?.appendLine(`[bux] Configured path: ${configuredPath}`);
        const choice = await vscode.window.showWarningMessage(
            'Bux: language server (bux-lsp) not found',
            'Open Output',
            'Open Settings'
        );
        if (choice === 'Open Output') {
            outputChannel?.show(true);
        } else if (choice === 'Open Settings') {
            await vscode.commands.executeCommand('workbench.action.openSettings', 'bux.lsp');
        }
        return;
    }

    outputChannel?.appendLine(`[bux] Using LSP binary: ${resolved}`);
    setStatus('starting', 'Starting Bux LSP…');

    const serverOptions: ServerOptions = {
        command: resolved,
        transport: TransportKind.stdio,
        options: { env: process.env },
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [
            { scheme: 'file', language: 'bux' },
            { scheme: 'untitled', language: 'bux' },
        ],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.{bux,toml}'),
        },
        outputChannel,
        revealOutputChannelOn: RevealOutputChannelOn.Error,
        traceOutputChannel: outputChannel,
    };

    client = new LanguageClient('bux-lsp', 'Bux Language Server', serverOptions, clientOptions);

    try {
        await client.start();
        setStatus('ready', `Bux LSP ready (${path.basename(resolved)})`);
        outputChannel?.appendLine('[bux] Language server started');
    } catch (err) {
        setStatus('error', 'Bux LSP failed to start');
        outputChannel?.appendLine(`[bux] Failed to start language server: ${err}`);
        vscode.window.showErrorMessage(
            `Bux LSP failed to start: ${err instanceof Error ? err.message : String(err)}`
        );
        client = undefined;
    }
}

/**
 * Resolve bux-lsp:
 * 1. Configured absolute / relative path
 * 2. Workspace tools/bux-lsp (and nearby monorepo parents)
 * 3. Command on PATH
 */
function resolveLspPath(configured: string): string | undefined {
    const candidates: string[] = [];

    if (path.isAbsolute(configured)) {
        candidates.push(configured);
    } else if (configured.includes('/') || configured.includes('\\')) {
        candidates.push(path.resolve(configured));
        for (const folder of vscode.workspace.workspaceFolders ?? []) {
            candidates.push(path.join(folder.uri.fsPath, configured));
        }
    }

    for (const folder of vscode.workspace.workspaceFolders ?? []) {
        const root = folder.uri.fsPath;
        candidates.push(
            path.join(root, 'tools', 'bux-lsp'),
            path.join(root, 'tools', 'bux-lsp.exe'),
            path.join(root, 'bin', 'bux-lsp'),
            path.join(root, 'bux-lsp'),
            path.resolve(root, '..', 'tools', 'bux-lsp'),
            path.resolve(root, '..', '..', 'tools', 'bux-lsp')
        );
    }

    for (const c of candidates) {
        if (isExecutable(c)) {
            return c;
        }
    }

    // Bare name: search PATH
    const bare = configured.includes('/') || configured.includes('\\') ? 'bux-lsp' : configured;
    return findInPath(bare);
}

function findInPath(cmd: string): string | undefined {
    const pathEnv = process.env.PATH ?? process.env.Path ?? '';
    const sep = process.platform === 'win32' ? ';' : ':';
    const exts =
        process.platform === 'win32'
            ? (process.env.PATHEXT ?? '.EXE;.CMD;.BAT').split(';')
            : [''];

    for (const dir of pathEnv.split(sep)) {
        if (!dir) continue;
        for (const ext of exts) {
            const candidate = path.join(dir, cmd + ext);
            if (isExecutable(candidate)) {
                return candidate;
            }
        }
    }
    return undefined;
}

function isExecutable(filePath: string): boolean {
    try {
        const st = fs.statSync(filePath);
        if (!st.isFile()) {
            return false;
        }
        if (process.platform === 'win32') {
            return true;
        }
        fs.accessSync(filePath, fs.constants.X_OK);
        return true;
    } catch {
        return false;
    }
}

function setStatus(state: 'ready' | 'starting' | 'error' | 'off', text: string): void {
    if (!statusBar) return;
    switch (state) {
        case 'ready':
            statusBar.text = '$(check) Bux';
            statusBar.backgroundColor = undefined;
            break;
        case 'starting':
            statusBar.text = '$(sync~spin) Bux';
            statusBar.backgroundColor = undefined;
            break;
        case 'error':
            statusBar.text = '$(error) Bux';
            statusBar.backgroundColor = new vscode.ThemeColor('statusBarItem.errorBackground');
            break;
        case 'off':
            statusBar.text = '$(circle-slash) Bux';
            statusBar.backgroundColor = undefined;
            break;
    }
    statusBar.tooltip = text;
    statusBar.show();
}
