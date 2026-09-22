import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import 'theme.dart';

/// Content tab — decentralized file sharing and browsing.
class ContentTab extends StatefulWidget {
  final AppState state;
  const ContentTab({super.key, required this.state});

  @override
  State<ContentTab> createState() => _ContentTabState();
}

class _ContentTabState extends State<ContentTab> {
  List<Map<String, dynamic>> _published = [];
  List<Map<String, dynamic>> _available = [];
  bool _loading = true;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _load();
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) => _load());
    widget.state.engine?.onContentChanged = () {
      if (mounted) _load();
    };
  }

  @override
  void dispose() {
    _refresh?.cancel();
    widget.state.engine?.onContentChanged = null;
    super.dispose();
  }

  Future<void> _load() async {
    final published = await widget.state.contentStore.listPublished();
    final available = await widget.state.contentStore.listAvailable();
    if (mounted) {
      setState(() {
        _published = published;
        _available = available;
        _loading = false;
      });
    }
  }

  Future<void> _publish() async {
    final result = await FilePicker.pickFiles();
    if (result.isEmpty || result.single.path == null) return;
    final path = result.single.path!;
    try {
      final hash = await widget.state.engine?.publishContent(path);
      if (hash != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Published: ${hash.substring(0, 12)}...')));
        _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _download(String hash) async {
    await widget.state.engine?.requestContent(hash);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Requesting content from peers...')));
    }
  }

  Future<void> _delete(String hash) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: L.txt('Delete content?', size: L.title),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: L.txt('Cancel', size: L.body)),
          TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: L.txt('Delete', size: L.body, color: Colors.red)),
        ],
      ),
    );
    if (confirm == true) {
      await widget.state.engine?.deleteContent(hash);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _load,
          child: ListView(
        children: [
          // Published content
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: L.txt('PUBLISHED', size: L.tiny,
                weight: FontWeight.w600, color: L.muted(context)),
          ),
          if (_published.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: L.muteTxt(context, 'No published content. Tap + to share a file.'),
            ),
          for (final item in _published) _buildItem(item, isPublished: true),
          const Divider(height: 1),
          // Available from peers
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: L.txt('FROM PEERS', size: L.tiny,
                weight: FontWeight.w600, color: L.muted(context)),
          ),
          if (_available.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: L.muteTxt(context, 'No content shared by peers yet.'),
            ),
          for (final item in _available) _buildItem(item, isPublished: false),
        ],
      ),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            heroTag: 'content_publish',
            onPressed: _publish,
            tooltip: 'Publish file',
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }

  Widget _buildItem(Map<String, dynamic> item, {required bool isPublished}) {
    final name = item['name'] as String? ?? 'Unknown';
    final size = item['size'] as int? ?? 0;
    final hash = item['hash'] as String? ?? '';
    final mime = item['mime_type'] as String? ?? '';
    final icon = _mimeIcon(mime);
    final hasLocal = (item['local_path'] as String?)?.isNotEmpty == true;
    final shortHash = hash.length > 12 ? hash.substring(0, 12) : hash;

    return ListTile(
      leading: Icon(icon, size: 28),
      title: L.txt(name, size: L.body, weight: FontWeight.w500),
      subtitle: L.muteTxt(context,
          '${_formatSize(size)} · $shortHash...'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isPublished && !hasLocal)
            IconButton(
              icon: const Icon(Icons.download, size: 20),
              tooltip: 'Download',
              onPressed: () => _download(hash),
            ),
          if (hasLocal && !isPublished)
            IconButton(
              icon: const Icon(Icons.push_pin, size: 20),
              tooltip: 'Pin',
              onPressed: () async {
                await widget.state.contentStore.db.update(
                    'content', {'is_pinned': 1},
                    where: 'hash = ?', whereArgs: [hash]);
                _load();
              },
            ),
          if (isPublished)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
              tooltip: 'Delete',
              onPressed: () => _delete(hash),
            ),
        ],
      ),
      onTap: () => _preview(item),
    );
  }

  void _preview(Map<String, dynamic> item) {
    final hash = item['hash'] as String? ?? '';
    final name = item['name'] as String? ?? 'Unknown';
    final mime = item['mime_type'] as String? ?? '';
    final localPath = item['local_path'] as String?;

    if (localPath == null || localPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Content not downloaded yet.')));
      return;
    }

    final file = File(localPath);
    if (!file.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File not found on disk.')));
      return;
    }

    if (mime.startsWith('image/')) {
      showDialog(
        context: context,
        builder: (d) => Dialog(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppBar(
                title: L.txt(name, size: L.body),
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(d),
                ),
              ),
              Flexible(
                child: InteractiveViewer(
                  child: Image.file(file),
                ),
              ),
            ],
          ),
        ),
      );
    } else if (mime.startsWith('text/') || mime == 'application/json' ||
        mime == 'application/javascript') {
      final text = await file.readAsString();
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (d) => Dialog(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppBar(
                  title: L.txt(name, size: L.body),
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(d),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(text,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 13)),
                  ),
                ),
              ],
            ),
          ),
        );
      );
    } else {
      showDialog(
        context: context,
        builder: (d) => AlertDialog(
          title: L.txt(name, size: L.title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              L.txt('Hash: $hash', size: L.small),
              L.txt('Size: ${_formatSize(item['size'] as int? ?? 0)}', size: L.small),
              L.txt('Type: $mime', size: L.small),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d),
              child: L.txt('Close', size: L.body),
            ),
          ],
        ),
      );
    }
  }

  IconData _mimeIcon(String mime) {
    if (mime.startsWith('image/')) return Icons.image;
    if (mime.startsWith('video/')) return Icons.video_file;
    if (mime.startsWith('audio/')) return Icons.audio_file;
    if (mime.startsWith('text/html')) return Icons.html;
    if (mime.startsWith('text/')) return Icons.description;
    if (mime == 'application/pdf') return Icons.picture_as_pdf;
    return Icons.insert_drive_file;
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
