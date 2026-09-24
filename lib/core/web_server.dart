import 'dart:convert';
import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';
import 'package:nsd/nsd.dart';

import 'diag.dart';
import 'protocol.dart';
import 'store.dart';

/// Lightweight HTTP server that serves shared files to any browser on the LAN.
/// Advertises via mDNS as _lantern-web._tcp for auto-discovery.
class LanternWebServer {
  HttpServer? _server;
  Registration? _reg;
  int port = 0;
  String _host = '';
  String _displayName = '';
  ChatStore? _store;

  /// URL other devices on the same LAN can open.
  String get url {
    if (_host.isEmpty || port == 0) return '';
    return 'http://$_host:$port';
  }

  /// URL WKWebView should use. Loopback avoids Wi-Fi routing and mDNS issues
  /// when previewing the server on the device that is hosting it.
  String get localUrl {
    if (port == 0) return '';
    return 'http://127.0.0.1:$port';
  }

  bool get isRunning => _server != null;

  /// Start the HTTP server and register mDNS service.
  Future<bool> start(ChatStore store, String displayName) async {
    if (_server != null) return true;
    _store = store;
    _displayName = displayName;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      port = _server!.port;
    } catch (e) {
      DiagLog.add('web', 'bind failed: $e');
      return false;
    }

    // Get local IP for URL display
    _host = await _resolveLocalIp();

    DiagLog.add('web', 'listening on $_host:$port');
    _server!.listen(
      _handleRequest,
      onError: (e) => DiagLog.add('web', 'server error: $e'),
    );

    // Register mDNS for browser auto-discovery
    try {
      _reg = await register(Service(
        name: 'Lantern Files - $displayName',
        type: '_lantern-web._tcp',
        port: port,
      ));
      DiagLog.add('mdns', 'registered web service on port $port');
    } catch (e) {
      DiagLog.add('mdns', 'web register failed: $e');
      // Non-fatal: server still works via manual URL
    }
    return true;
  }

  /// Stop the server and unregister mDNS.
  Future<void> stop() async {
    final reg = _reg;
    _reg = null;
    if (reg != null) {
      try { await unregister(reg); } catch (_) {}
    }
    final srv = _server;
    _server = null;
    port = 0;
    _host = '';
    if (srv != null) {
      try { await srv.close(force: true); } catch (_) {}
    }
    DiagLog.add('web', 'stopped');
  }

  /// Count of files that exist on disk and are available for serving.
  Future<int> servedFileCount() async {
    final store = _store;
    if (store == null) return 0;
    var count = 0;
    for (final f in await store.outgoingFiles()) {
      if (f.filePath != null && File(f.filePath!).existsSync()) count++;
    }
    for (final f in await store.incomingFiles()) {
      if (f.filePath != null && File(f.filePath!).existsSync()) count++;
    }
    return count;
  }

  // ---- request handling ----

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      // CORS preflight
      if (req.method == 'OPTIONS') {
        _corsHeaders(req.response);
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
        return;
      }
      _corsHeaders(req.response);

      final path = req.uri.path;
      if (req.method != 'GET' && req.method != 'HEAD') {
        req.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..headers.set(HttpHeaders.allowHeader, 'GET, HEAD, OPTIONS');
        await req.response.close();
        return;
      }
      if (path == '/health') {
        await _serveHealth(req);
      } else if (path == '/' || path == '') {
        await _serveIndex(req);
      } else if (path == '/api/files') {
        await _serveJson(req);
      } else if (path.startsWith('/file/')) {
        await _serveFileDownload(req, path.substring(6));
      } else {
        _respondError(req, HttpStatus.notFound, 'Not Found');
      }
    } catch (e) {
      DiagLog.add('web', 'request error: $e');
      try { req.response.statusCode = HttpStatus.internalServerError; } catch (_) {}
      try { await req.response.close(); } catch (_) {}
    }
  }

  /// Lightweight endpoint used by the in-app Preview button.
  Future<void> _serveHealth(HttpRequest req) async {
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..write(jsonEncode({'ok': true, 'port': port}));
    await req.response.close();
  }

  /// Serve the main HTML file listing page.
  Future<void> _serveIndex(HttpRequest req) async {
    final files = await _availableFiles();
    final rows = files.map(_fileRow).join('\n');
    final count = files.length;

    final html = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${_esc(_displayName)} — Lantern Files</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#f8f9fa;color:#212529;padding:16px}
.header{display:flex;align-items:center;gap:12px;margin-bottom:16px}
.header h1{font-size:1.4em;font-weight:600}
.badge{background:#e8f5e9;color:#2e7d32;padding:4px 10px;border-radius:12px;font-size:0.8em;font-weight:500}
.info{background:#e3f2fd;border:1px solid #90caf9;border-radius:8px;padding:12px;margin-bottom:16px;font-size:0.85em;color:#1565c0}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,0.08)}
th{text-align:left;padding:10px 12px;font-size:0.8em;color:#6c757d;font-weight:600;border-bottom:2px solid #e9ecef;background:#f8f9fa}
td{padding:10px 12px;border-bottom:1px solid #f1f3f5;font-size:0.9em}
tr:last-child td{border-bottom:none}
tr:hover{background:#f8f9fa}
a{color:#00897b;text-decoration:none;font-weight:500}
a:hover{text-decoration:underline}
.size{color:#6c757d;font-size:0.85em;white-space:nowrap}
.dir{text-align:center}
.empty{text-align:center;padding:48px 16px;color:#adb5bd}
.empty p{margin-top:8px;font-size:0.9em}
.footer{margin-top:24px;text-align:center;color:#adb5bd;font-size:0.75em}
.footer a{color:#6c757d}
</style>
</head>
<body>
<div class="header">
<h1>🏮 ${_esc(_displayName)}</h1>
<span class="badge">$count file${count == 1 ? '' : 's'}</span>
</div>
<div class="info">🔒 Files are served from your local network only. Nothing leaves your WiFi.</div>
${count == 0
    ? '<div class="empty"><p>No shared files yet.</p><p>Files you share in Lantern chats will appear here.</p></div>'
    : '<table><thead><tr><th></th><th>Name</th><th>Size</th><th>From</th><th></th></tr></thead><tbody>$rows</tbody></table>'}
<div class="footer">Lantern · <a href="/api/files">JSON API</a> · Served on port $port</div>
</body>
</html>''';

    req.response
      ..headers.contentType = ContentType.html
      ..write(html);
    await req.response.close();
  }

  /// Serve file list as JSON.
  Future<void> _serveJson(HttpRequest req) async {
    final files = await _availableFiles();
    final items = files.map((f) => {
      'id': f.id,
      'name': f.fileName ?? 'file',
      'size': f.fileBytes ?? 0,
      'kind': f.kind.wire,
      'timestamp': f.ts,
      'direction': f.outgoing ? 'sent' : 'received',
    }).toList();

    req.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'files': items, 'count': items.length}));
    await req.response.close();
  }

  /// Serve a file download.
  Future<void> _serveFileDownload(HttpRequest req, String fileId) async {
    if (fileId.isEmpty) {
      _respondError(req, HttpStatus.badRequest, 'Missing file ID');
      return;
    }

    // Look up the message by primary key.
    final store = _store;
    if (store == null) {
      _respondError(req, HttpStatus.internalServerError, 'Server not ready');
      return;
    }
    final msg = await store.fileMessageById(fileId);
    if (msg == null || msg.filePath == null) {
      _respondError(req, HttpStatus.notFound, 'File not available on this device');
      return;
    }

    final file = File(msg.filePath!);
    if (!await file.exists()) {
      _respondError(req, HttpStatus.notFound, 'File has been removed');
      return;
    }

    final fileName = _safeDownloadName(msg.fileName ?? 'file');
    final fileLen = await file.length();
    final mimeType = _mimeType(fileName);

    req.response
      ..headers.contentType = ContentType.parse(mimeType)
      ..headers.add('Content-Disposition',
          'attachment; filename="download"; filename*=UTF-8\'\'${Uri.encodeComponent(fileName)}')
      ..headers.add('Content-Length', '$fileLen')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');

    // Stream the file in chunks to avoid loading large files entirely in memory
    await for (final chunk in file.openRead()) {
      req.response.add(chunk);
    }
    await req.response.close();
  }

  // ---- helpers ----

  /// Get all files that exist on disk.
  Future<List<ChatMessage>> _availableFiles() async {
    final store = _store;
    if (store == null) return [];
    final outgoing = await store.outgoingFiles();
    final incoming = await store.incomingFiles();
    final all = [...outgoing, ...incoming];
    final available = <ChatMessage>[];
    for (final f in all) {
      if (f.filePath != null && File(f.filePath!).existsSync()) {
        available.add(f);
      }
    }
    return available;
  }

  /// Generate an HTML table row for a file.
  String _fileRow(ChatMessage f) {
    final icon = switch (f.kind) {
      LanternMsgKind.image => '🖼️',
      LanternMsgKind.video => '🎬',
      LanternMsgKind.voice => '🎙️',
      _ => '📄',
    };
    final size = f.fileBytes != null ? _humanSize(f.fileBytes!) : '';
    final dir = f.outgoing ? '↑ Sent' : '↓ Received';
    return '<tr><td>$icon</td><td><a href="/file/${f.id}">${_esc(f.fileName ?? 'File')}</a></td>'
        '<td class="size">$size</td><td class="dir">$dir</td>'
        '<td><a href="/file/${f.id}" download>⬇</a></td></tr>';
  }

  void _corsHeaders(HttpResponse res) {
    res.headers
      ..add('Access-Control-Allow-Origin', '*')
      ..add('Access-Control-Allow-Methods', 'GET, OPTIONS')
      ..add('Access-Control-Allow-Headers', 'Content-Type');
  }

  void _respondError(HttpRequest req, int code, String msg) {
    req.response
      ..statusCode = code
      ..headers.contentType = ContentType.html
      ..write(_errorPage(code, msg));
    req.response.close();
  }

  String _errorPage(int code, String msg) => '''<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>$code</title></head>
<body style="font-family:sans-serif;text-align:center;padding:48px">
<h1>$code</h1><p>$msg</p><p><a href="/">← Back</a></p></body></html>''';

  static String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

  static String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// MIME type from file extension.
  static String _mimeType(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'svg' => 'image/svg+xml',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'avi' => 'video/x-msvideo',
      'webm' => 'video/webm',
      'mp3' => 'audio/mpeg',
      'm4a' => 'audio/mp4',
      'wav' => 'audio/wav',
      'ogg' => 'audio/ogg',
      'aac' => 'audio/aac',
      'pdf' => 'application/pdf',
      'doc' || 'docx' => 'application/msword',
      'xls' || 'xlsx' => 'application/vnd.ms-excel',
      'zip' => 'application/zip',
      'json' => 'application/json',
      'txt' || 'log' => 'text/plain',
      'html' || 'htm' => 'text/html',
      'csv' => 'text/csv',
      _ => 'application/octet-stream',
    };
  }

  /// Resolve the Wi-Fi address used by other LAN devices.
  Future<String> _resolveLocalIp() async {
    try {
      final wifiIp = await NetworkInfo().getWifiIP();
      if (wifiIp != null && wifiIp.isNotEmpty && wifiIp != '0.0.0.0') {
        return wifiIp;
      }
    } catch (e) {
      DiagLog.add('web', 'Wi-Fi IP lookup failed: $e');
    }
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLinkLocal: false);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && !addr.address.startsWith('169.254.')) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return 'localhost';
  }

  static String _safeDownloadName(String name) {
    var safe = name.replaceAll(RegExp(r'[\r\n"\\/]'), '_').trim();
    if (safe.isEmpty) safe = 'file';
    if (safe.length > 180) {
      final dot = safe.lastIndexOf('.');
      final ext = dot > 0 && safe.length - dot <= 12 ? safe.substring(dot) : '';
      safe = safe.substring(0, 180 - ext.length) + ext;
    }
    return safe;
  }
}
