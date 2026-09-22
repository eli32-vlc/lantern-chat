import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import 'l10n.dart';

/// Distributed Web tab — content sharing, file hosting, BitTorrent-style.
class WebTab extends StatefulWidget {
  final AppState state;
  const WebTab({super.key, required this.state});

  @override
  State<WebTab> createState() => _WebTabState();
}

class _WebTabState extends State<WebTab> {
  List<Map<String, dynamic>> _published = [];
  List<Map<String, dynamic>> _available = [];
  bool _loading = true;
  String? _statusMsg;

  @override
  void initState() {
    super.initState();
    _load();
    widget.state.content?.onChanged = () { if (mounted) _load(); };
  }

  @override
  void dispose() {
    widget.state.content?.onChanged = null;
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.state.content == null) return;
    final published = await widget.state.content!.listPublished();
    final available = await widget.state.content!.listAvailable();
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
    try {
      final hash = await widget.state.content!.publish(result.single.path!);
      setState(() => _statusMsg = 'Published: ${hash.substring(0, 12)}…');
      _load();
    } catch (e) {
      setState(() => _statusMsg = 'Failed: $e');
    }
  }

  Future<void> _download(String hash) async {
    await widget.state.content!.request(hash);
    setState(() => _statusMsg = 'Requesting from peers…');
  }

  Future<void> _delete(String hash) async {
    await widget.state.content!.delete(hash);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(S.of(context).distributedWeb),
        actions: [
          IconButton(icon: Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  // Status message
                  if (_statusMsg != null)
                    Container(
                      padding: EdgeInsets.all(12),
                      margin: EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_statusMsg!, style: TextStyle(fontSize: 13)),
                    ),

                  // How it works
                  Container(
                    padding: EdgeInsets.all(12),
                    margin: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(S.of(context).howItWorks, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        SizedBox(height: 4),
                        Text(S.of(context).distributedWebDesc, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                      ],
                    ),
                  ),

                  // My published content
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(S.of(context).myFiles.toUpperCase(),
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey)),
                  ),
                  if (_published.isEmpty)
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text(S.of(context).noPublished, style: TextStyle(color: Colors.grey)),
                    ),
                  for (final item in _published) _buildItem(item, isPublished: true),

                  Divider(height: 1, indent: 16, endIndent: 16),

                  // Available from peers
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(S.of(context).fromPeers.toUpperCase(),
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey)),
                  ),
                  if (_available.isEmpty)
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text(S.of(context).noAvailable, style: TextStyle(color: Colors.grey)),
                    ),
                  for (final item in _available) _buildItem(item, isPublished: false),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _publish,
        tooltip: S.of(context).publishFile,
        child: Icon(Icons.add),
      ),
    );
  }

  Widget _buildItem(Map<String, dynamic> item, {required bool isPublished}) {
    final name = item['name'] as String? ?? 'Unknown';
    final size = item['size'] as int? ?? 0;
    final hash = item['hash'] as String? ?? '';
    final mime = item['mime_type'] as String? ?? '';
    final hasLocal = (item['local_path'] as String?)?.isNotEmpty == true;
    final shortHash = hash.length > 12 ? hash.substring(0, 12) : hash;

    return ListTile(
      leading: Icon(_mimeIcon(mime), size: 28),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${_formatSize(size)} · $shortHash…'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (!isPublished && !hasLocal)
          IconButton(icon: Icon(Icons.download, size: 20), onPressed: () => _download(hash)),
        if (isPublished)
          IconButton(icon: Icon(Icons.delete_outline, size: 20, color: Colors.red), onPressed: () => _delete(hash)),
      ]),
    );
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
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
