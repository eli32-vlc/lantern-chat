import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../core/app_state.dart';
import '../core/protocol.dart';
import '../core/store.dart';
import '../core/web_server.dart';
import 'theme.dart';

/// Shared Files tab with three sub-tabs: From Me, From Others, Distributed Web.
class SharedFilesTab extends StatefulWidget {
  final AppState state;
  const SharedFilesTab({super.key, required this.state});

  @override
  State<SharedFilesTab> createState() => _SharedFilesTabState();
}

class _SharedFilesTabState extends State<SharedFilesTab>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: TabBar(
            controller: _tabCtrl,
            tabs: const [
              Tab(icon: Icon(Icons.upload_outlined, size: 20), text: 'From Me'),
              Tab(icon: Icon(Icons.download_outlined, size: 20), text: 'From Others'),
              Tab(icon: Icon(Icons.language, size: 20), text: 'Distributed Web'),
            ],
            labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 12),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabCtrl,
            children: [
              _FileList(
                state: widget.state,
                futureFiles: () => widget.state.store.outgoingFiles(),
                emptyIcon: Icons.upload_outlined,
                emptyTitle: 'No sent files',
                emptyHint: 'Files you share in chats appear here.',
                showPeerLabel: true,
              ),
              _FileList(
                state: widget.state,
                futureFiles: () => widget.state.store.incomingFiles(),
                emptyIcon: Icons.download_outlined,
                emptyTitle: 'No received files',
                emptyHint: 'Files others share with you appear here.',
                showPeerLabel: true,
              ),
              _DistributedWebTab(state: widget.state),
            ],
          ),
        ),
      ],
    );
  }
}

/// Reusable file list widget.
class _FileList extends StatefulWidget {
  final AppState state;
  final Future<List<ChatMessage>> Function() futureFiles;
  final IconData emptyIcon;
  final String emptyTitle;
  final String emptyHint;
  final bool showPeerLabel;

  const _FileList({
    required this.state,
    required this.futureFiles,
    required this.emptyIcon,
    required this.emptyTitle,
    required this.emptyHint,
    this.showPeerLabel = false,
  });

  @override
  State<_FileList> createState() => _FileListState();
}

class _FileListState extends State<_FileList> {
  List<ChatMessage> _files = [];
  bool _loading = true;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _reload();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _reload());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final files = await widget.futureFiles();
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_files.isEmpty) {
      return LEmpty(
        icon: widget.emptyIcon,
        title: widget.emptyTitle,
        hint: widget.emptyHint,
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        itemCount: _files.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, i) => _FileTile(
          message: _files[i],
          showPeerLabel: widget.showPeerLabel,
          state: widget.state,
        ),
      ),
    );
  }
}

/// Single file tile in the shared files list.
class _FileTile extends StatelessWidget {
  final ChatMessage message;
  final bool showPeerLabel;
  final AppState state;

  const _FileTile({
    required this.message,
    required this.showPeerLabel,
    required this.state,
  });

  String _formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatTime(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  IconData _kindIcon(LanternMsgKind kind) => switch (kind) {
        LanternMsgKind.image => Icons.image_outlined,
        LanternMsgKind.video => Icons.videocam_outlined,
        LanternMsgKind.voice => Icons.mic_outlined,
        LanternMsgKind.file => Icons.insert_drive_file_outlined,
        _ => Icons.insert_drive_file_outlined,
      };

  Future<String> _peerName(String peerId) async {
    // Check live peers first
    for (final p in state.peers) {
      if (p.id == peerId) return p.name;
    }
    // Fallback to store
    final known = await state.store.getPeer(peerId);
    return known?.name ?? peerId;
  }

  @override
  Widget build(BuildContext context) {
    final m = message;
    final exists = m.filePath != null && File(m.filePath!).existsSync();
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: exists
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(_kindIcon(m.kind),
            size: 20,
            color: exists
                ? Theme.of(context).colorScheme.primary
                : L.muted(context)),
      ),
      title: L.txt(m.fileName ?? 'File',
          size: L.body,
          weight: FontWeight.w600,
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          L.muteTxt(context,
              '${_formatSize(m.fileBytes)} · ${_formatTime(m.ts)}'),
          if (showPeerLabel)
            FutureBuilder<String>(
              future: _peerName(m.outgoing ? m.chatId : m.senderId),
              builder: (context, snap) {
                if (!snap.hasData) return const SizedBox.shrink();
                return L.txt(
                    m.outgoing ? '→ ${snap.data}' : '← ${snap.data}',
                    size: L.tiny,
                    color: L.muted(context));
              },
            ),
        ],
      ),
      trailing: exists
          ? IconButton(
              icon: const Icon(Icons.open_in_new, size: 20),
              onPressed: () => _openFile(context),
              tooltip: 'Open',
            )
          : Icon(Icons.file_download_off, size: 20, color: L.muted(context)),
      onTap: exists ? () => _openFile(context) : null,
    );
  }

  void _openFile(BuildContext context) {
    // Show the file in a simple dialog or share it
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: L.txt('Open file', size: L.body),
              onTap: () {
                Navigator.pop(ctx);
                // File opening is platform-specific; for now just show path
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('File: ${message.filePath}')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: L.txt('Share file', size: L.body),
              onTap: () {
                Navigator.pop(ctx);
                SharePlus.instance
                    .share(ShareParams(files: [XFile(message.filePath!)]));
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Distributed Web sub-tab: HTTP server that serves shared files to LAN browsers.
class _DistributedWebTab extends StatefulWidget {
  final AppState state;
  const _DistributedWebTab({required this.state});

  @override
  State<_DistributedWebTab> createState() => _DistributedWebTabState();
}

class _DistributedWebTabState extends State<_DistributedWebTab> {
  final LanternWebServer _server = LanternWebServer();
  bool _running = false;
  String _url = '';
  int _fileCount = 0;
  bool _previewing = false;
  String? _previewError;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refreshStats());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _server.stop();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _previewError = null;
    });
    try {
      if (_running) {
        await _server.stop();
        if (mounted) {
          setState(() {
            _running = false;
            _url = '';
            _fileCount = 0;
            _previewing = false;
          });
        }
        return;
      }

      final started = await _server.start(
        widget.state.store,
        widget.state.displayName,
      );
      if (!mounted) return;
      if (!started) {
        setState(() {
          _busy = false;
          _previewError = 'Could not start the local web server.';
        });
        return;
      }
      final health = await _checkHealth();
      if (!mounted) return;
      if (!health) {
        setState(() {
          _busy = false;
          _previewError =
              'The server started but did not answer on its local port.';
        });
        return;
      }
      setState(() {
        _running = true;
        _url = _server.url;
        _busy = false;
        _previewError = null;
      });
      await _refreshStats();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _previewError = 'Web server error: $e';
        });
      }
    }
  }

  bool _busy = false;

  Future<bool> _checkHealth() async {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse('${_server.localUrl}/health'))
          .timeout(const Duration(seconds: 3));
      final response = await request.close().timeout(const Duration(seconds: 3));
      final body = await response.transform(utf8.decoder).join();
      return response.statusCode == HttpStatus.ok && body.contains('"ok":true');
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _openPreview() async {
    if (!_running || _previewing || Platform.isIOS == false) return;
    setState(() {
      _previewing = true;
      _previewError = null;
    });
    try {
      final health = await _checkHealth();
      if (!health) {
        throw StateError('The local server is not responding.');
      }
      await const MethodChannel('com.lantern/web').invokeMethod<void>(
        'openPreview',
        <String, dynamic>{'url': _server.localUrl},
      );
      if (mounted) setState(() => _previewing = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _previewing = false;
          _previewError = 'Preview failed: $e';
        });
      }
    }
  }

  Future<void> _refreshStats() async {
    if (!_running) return;
    final count = await _server.servedFileCount();
    if (mounted) setState(() => _fileCount = count);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Server toggle
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(_running ? Icons.language : Icons.language_outlined,
                        size: 28,
                        color: _running
                            ? Theme.of(context).colorScheme.primary
                            : L.muted(context)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          L.txt('Web File Server',
                              size: L.title, weight: FontWeight.w600),
                          L.muteTxt(context,
                              _running
                                  ? 'Serving $_fileCount files on your LAN'
                                  : 'Share files via any web browser on your WiFi'),
                        ],
                      ),
                    ),
                    Switch(
                      value: _running,
                      onChanged: (_) => _toggle(),
                    ),
                  ],
                ),
                if (_previewError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _previewError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: L.small,
                      ),
                    ),
                  ),
                if (_running && _url.isNotEmpty) ...[
                  const Divider(height: 24),
                  if (Platform.isIOS)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: _previewing ? null : _openPreview,
                        icon: _previewing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.visibility_outlined, size: 18),
                        label: Text(_previewing ? 'Opening…' : 'Preview'),
                      ),
                    ),
                  if (Platform.isIOS) const SizedBox(height: 16),
                  // URL display
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.link, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SelectableText(_url,
                              style: TextStyle(
                                fontSize: L.body,
                                fontFamily: 'monospace',
                                color: Theme.of(context).colorScheme.primary,
                              )),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 18),
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: _url));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('URL copied')),
                              );
                            }
                          },
                          tooltip: 'Copy URL',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // QR code
                  L.txt('Scan to open in browser',
                      size: L.small, color: L.muted(context)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(
                      data: _url,
                      size: 160,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Info card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.info_outline, size: 20),
                    const SizedBox(width: 8),
                    L.txt('How it works', size: L.body, weight: FontWeight.w600),
                  ],
                ),
                const SizedBox(height: 8),
                L.muteTxt(context,
                    'When enabled, any device on your WiFi can open the URL '
                    'in a browser to browse and download shared files. '
                    'The server is only accessible on your local network — '
                    'nothing goes to the internet.',
                    align: TextAlign.start),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
