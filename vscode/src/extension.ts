/* Bux Language Server Protocol client for VS Code
 * Launches bux-lsp binary and connects via stdin/stdout.
 */

import * as path from 'path';
import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind
} from 'vscode-languageclient/node';

let client: LanguageClient;

export function activate(context: vscode.ExtensionContext) {
    const config = vscode.workspace.getConfiguration('bux.lsp');
    const enabled = config.get<boolean>('enabled', true);
    if (!enabled) {
        vscode.window.showInformationMessage('Bux LSP is disabled in settings');
        return;
    }

    const lspPath = config.get<string>('path', 'bux-lsp');

    const serverOptions: ServerOptions = {
        command: lspPath,
        transport: TransportKind.stdio
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: 'file', language: 'bux' }],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.bux')
        }
    };

    client = new LanguageClient(
        'bux-lsp',
        'Bux Language Server',
        serverOptions,
        clientOptions
    );

    client.start();
    vscode.window.showInformationMessage('Bux LSP started');
}

export function deactivate(): Thenable<void> | undefined {
    if (!client) {
        return undefined;
    }
    return client.stop();
}
