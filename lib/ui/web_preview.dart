import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/content.dart';
import '../core/store.dart';

/// In-app browser for distributed web content.
/// Opens HTML files with hash.web virtual domain.
class WebPreviewScreen extends StatefulWidget {
  final String hash;
  final String title;
  final String localPath;
  final Content content;
  final Store store;

  const WebPreviewScreen({
    super.key,
    required this.hash,
    required this.title,
    required this.localPath,
    required this.content,
    required this.store,
  });

  @override
  State<WebPreviewScreen> createState() => _WebPreviewScreenState();
}

class _WebPreviewScreenState extends State<WebPreviewScreen> {
  late final WebViewController _controller;
  String _url = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (_) => setState(() => _loading = false),
        onNavigationRequest: (request) async {
          final url = request.url;
          // Allow file:// URLs (local content)
          if (url.startsWith('file://')) {
            return NavigationDecision.navigate;
          }
          // Resolve .web URLs through content store
          if (url.contains('.web')) {
            final hash = url.split('.web').first.split('/').last;
            if (hash.length >= 8) {
              final content = await widget.store.getContent(hash);
              if (content != null) {
                final path = content['local_path'] as String?;
                if (path != null && path.isNotEmpty && await File(path).exists()) {
                  _loadFile(path);
                  return NavigationDecision.prevent;
                }
              }
            }
          }
          // Block external URLs (security: no network access from distributed web)
          return NavigationDecision.prevent;
        },
      ));
    _loadFile(widget.localPath);
  }

  void _loadFile(String path) {
    final file = File(path);
    if (!file.existsSync()) return;

    // Read HTML and resolve relative resource URLs
    final html = file.readAsStringSync();
    final resolved = _resolveRelativeUrls(html, widget.hash);
    _controller.loadHtmlString(resolved, baseUrl: Uri.parse('file://${file.parent.path}/'));
    setState(() {
      _url = '${widget.hash.substring(0, 12)}.web';
      _loading = false;
    });
  }

  /// Resolve relative URLs in HTML to content store lookups.
  /// Converts src="image.png" and href="style.css" to file:// URLs
  /// pointing to the content store directory.
  String _resolveRelativeUrls(String html, String baseHash) {
    final basePath = widget.localPath;
    final dir = File(basePath).parent.path;
    // Replace relative src= and href= with absolute file:// paths
    var resolved = html;
    // src="relative/path" -> src="file:///content/dir/relative/path"
    resolved = resolved.replaceAllMapped(
      RegExp(r'(src|href)="([^"#][^"]*)"', caseSensitive: false),
      (m) {
        final attr = m.group(1)!;
        final url = m.group(2)!;
        if (url.startsWith('http://') || url.startsWith('https://') ||
            url.startsWith('file://') || url.startsWith('data:')) {
          return m.group(0)!; // Already absolute
        }
        return '$attr="file://$dir/$url"';
      },
    );
    return resolved;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: TextStyle(fontSize: 14)),
            Text(_url, style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: () => _loadFile(widget.localPath),
          ),
          IconButton(
            icon: Icon(Icons.copy),
            onPressed: () {
              // Copy the hash.web URL
              final url = '${widget.hash}.web';
              Clipboard.setData(ClipboardData(text: url));
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Copied: $url')));
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}

/// Screen for browsing all published web content.
class WebBrowserScreen extends StatefulWidget {
  final Content content;
  final Store store;
  const WebBrowserScreen({super.key, required this.content, required this.store});

  @override
  State<WebBrowserScreen> createState() => _WebBrowserScreenState();
}

class _WebBrowserScreenState extends State<WebBrowserScreen> {
  final _urlCtrl = TextEditingController();
  List<Map<String, dynamic>> _sites = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await widget.store.allContent();
    final htmlSites = all.where((r) {
      final mime = r['mime_type'] as String? ?? '';
      return mime == 'text/html' && (r['local_path'] as String?)?.isNotEmpty == true;
    }).toList();
    setState(() {
      _sites = htmlSites;
      _loading = false;
    });
  }

  void _openSite(Map<String, dynamic> site) {
    final hash = site['hash'] as String;
    final name = site['name'] as String;
    final path = site['local_path'] as String;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => WebPreviewScreen(
        hash: hash, title: name, localPath: path,
        content: widget.content, store: widget.store,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Distributed Web'),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator())
          : _sites.isEmpty
              ? Center(child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.language, size: 48, color: Colors.grey),
                    SizedBox(height: 12),
                    Text('No websites published yet', style: TextStyle(color: Colors.grey)),
                    SizedBox(height: 4),
                    Text('Publish an HTML file to create a site', style: TextStyle(color: Colors.grey, fontSize: 13)),
                  ],
                ))
              : ListView.builder(
                  itemCount: _sites.length,
                  itemBuilder: (context, i) {
                    final site = _sites[i];
                    final name = site['name'] as String;
                    final hash = site['hash'] as String;
                    final shortHash = hash.substring(0, 12);
                    return ListTile(
                      leading: Icon(Icons.language, color: Colors.blue),
                      title: Text(name),
                      subtitle: Text('$shortHash.web'),
                      trailing: Icon(Icons.chevron_right),
                      onTap: () => _openSite(site),
                    );
                  },
                ),
    );
  }
}
