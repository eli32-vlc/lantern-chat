import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'crypto.dart';
import 'diag.dart';
import 'mesh.dart';
import 'protocol.dart';
import 'store.dart';

/// Content-addressed storage for decentralized file sharing.
class Content {
  final Mesh mesh;
  final Store store;
  String? _basePath;
  void Function()? onChanged;

  Content({required this.mesh, required this.store});

  Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    _basePath = '${docs.path}/content';
    await Directory(_basePath!).create(recursive: true);
  }

  /// Publish a file. Returns the content hash.
  Future<String> publish(String filePath, {String? name}) async {
    final file = File(filePath);
    if (!await file.exists()) throw ArgumentError('File not found');
    final bytes = await file.readAsBytes();
    final hash = await Crypto.sha256Hex(bytes);
    final fileName = name ?? filePath.split(Platform.pathSeparator).last;
    final mime = _guessMime(fileName);
    final totalPieces = (bytes.length / P.pieceSize).ceil().clamp(1, 100000);

    for (var i = 0; i < totalPieces; i++) {
      final start = i * P.pieceSize;
      final end = (start + P.pieceSize).clamp(0, bytes.length);
      await store.storePiece(hash, i, Uint8List.fromList(bytes.sublist(start, end)));
    }

    await store.storeContent({
      'hash': hash, 'name': fileName, 'size': bytes.length,
      'mime_type': mime, 'pieces': totalPieces,
      'published_by': 'local',
      'published_at': DateTime.now().millisecondsSinceEpoch,
      'local_path': filePath, 'is_pinned': 1,
    });
    _announce();
    DiagLog.add('content', 'published $hash');
    onChanged?.call();
    return hash;
  }

  /// Request content from peers.
  Future<void> request(String hash) async {
    final peers = await store.contentPeers(hash);
    for (final peerId in peers) {
      final peer = mesh.currentPeers.where((p) => p.id == peerId).firstOrNull;
      if (peer == null) continue;
      await mesh.sendFrame(peer, {
        't': P.contentReq, 'from': mesh.device.id, 'hash': hash,
      });
    }
  }

  /// Search for content across peers.
  Future<void> search(String query) async {
    for (final peer in mesh.currentPeers) {
      await mesh.sendFrame(peer, {
        't': P.contentSearch, 'from': mesh.device.id, 'query': query,
      });
    }
  }

  /// Handle incoming content frame.
  Future<void> handleFrame(Map<String, dynamic> json) async {
    final t = json['t'] as String?;
    final from = json['from'] as String? ?? '';

    if (t == P.contentAnnounce) {
      final items = json['items'] as List<dynamic>? ?? [];
      // Verify trust
      if (from.isNotEmpty) {
        final known = await store.getPeer(from);
        if (known == null || known['trusted'] != 1) return;
      }
      for (final item in items) {
        final m = item as Map<String, dynamic>;
        final hash = m['hash'] as String? ?? '';
        if (hash.isEmpty) continue;
        await store.recordContentPeer(hash, from);
        if (await store.getContent(hash) == null) {
          await store.storeContent({
            'hash': hash, 'name': m['name'] ?? 'unknown',
            'size': m['size'] ?? 0, 'mime_type': m['mime'] ?? '',
            'pieces': m['pieces'] ?? 0, 'published_by': from,
            'published_at': DateTime.now().millisecondsSinceEpoch,
            'local_path': '', 'is_pinned': 0,
          });
        }
      }
      DiagLog.add('content', 'announce from $from: ${items.length} items');
    } else if (t == P.contentReq) {
      final hash = json['hash'] as String? ?? '';
      if (from.isEmpty || hash.isEmpty) return;
      final known = await store.getPeer(from);
      if (known == null || known['trusted'] != 1) return;
      final indices = await store.pieceIndices(hash);
      final peer = mesh.currentPeers.where((p) => p.id == from).firstOrNull;
      if (peer == null) return;
      for (final idx in indices) {
        final data = await store.getPiece(hash, idx);
        if (data == null) continue;
        await mesh.sendFrame(peer, {
          't': P.contentPiece, 'hash': hash,
          'idx': idx, 'total': indices.length,
          'data': base64Encode(data),
        });
        await Future.delayed(Duration(milliseconds: 20));
      }
    } else if (t == P.contentPiece) {
      final hash = json['hash'] as String? ?? '';
      final idx = json['idx'] as int? ?? 0;
      final total = json['total'] as int? ?? 1;
      final dataB64 = json['data'] as String? ?? '';
      if (hash.isEmpty || dataB64.isEmpty) return;
      final data = base64Decode(dataB64);
      if (data.length > P.pieceSize) return;
      await store.storePiece(hash, idx, Uint8List.fromList(data));
      final have = await store.pieceIndices(hash);
      final meta = await store.getContent(hash);
      final expected = meta?['pieces'] as int? ?? total;
      if (have.length >= expected) {
        await _assemble(hash);
        _announce();
      }
    } else if (t == P.contentSearch) {
      final query = json['query'] as String? ?? '';
      if (query.isEmpty || from.isEmpty) return;
      final known = await store.getPeer(from);
      if (known == null || known['trusted'] != 1) return;
      final results = await store.searchContent(query);
      if (results.isEmpty) return;
      final peer = mesh.currentPeers.where((p) => p.id == from).firstOrNull;
      if (peer == null) return;
      await mesh.sendFrame(peer, {
        't': P.contentFound,
        'items': results.map((r) => {
          'hash': r['hash'], 'name': r['name'],
          'size': r['size'], 'mime': r['mime_type'],
        }).toList(),
      });
    } else if (t == P.contentFound) {
      final items = json['items'] as List<dynamic>? ?? [];
      for (final item in items) {
        final m = item as Map<String, dynamic>;
        final hash = m['hash'] as String? ?? '';
        if (hash.isEmpty) continue;
        if (await store.getContent(hash) == null) {
          await store.storeContent({
            'hash': hash, 'name': m['name'] ?? 'unknown',
            'size': m['size'] ?? 0, 'mime_type': m['mime'] ?? '',
            'pieces': 0, 'published_by': 'search',
            'published_at': DateTime.now().millisecondsSinceEpoch,
            'local_path': '', 'is_pinned': 0,
          });
        }
      }
      DiagLog.add('content', 'found ${items.length} items');
    }
  }

  Future<void> _assemble(String hash) async {
    final meta = await store.getContent(hash);
    if (meta == null) return;
    final totalPieces = meta['pieces'] as int;
    final out = BytesBuilder();
    for (var i = 0; i < totalPieces; i++) {
      final data = await store.getPiece(hash, i);
      if (data == null) return;
      out.add(data);
    }
    final path = '$_basePath/$hash';
    await File(path).writeAsBytes(out.toBytes());
    await store.db.update('content', {'local_path': path},
        where: 'hash = ?', whereArgs: [hash]);
    DiagLog.add('content', 'assembled $hash');
  }

  Future<void> _announce() async {
    final items = await store.allContent();
    if (items.isEmpty) return;
    final frame = {
      't': P.contentAnnounce, 'from': mesh.device.id,
      'items': items.map((r) => {
        'hash': r['hash'], 'name': r['name'],
        'size': r['size'], 'mime': r['mime_type'], 'pieces': r['pieces'],
      }).toList(),
    };
    for (final peer in mesh.currentPeers) {
      await mesh.sendFrame(peer, frame);
    }
  }

  Future<void> delete(String hash) async {
    await store.deleteContent(hash);
    try { await File('$_basePath/$hash').delete(); } catch (_) {}
    onChanged?.call();
  }

  Future<List<Map<String, dynamic>>> listPublished() async {
    final all = await store.allContent();
    return all.where((r) => (r['is_pinned'] as int? ?? 0) == 1).toList();
  }

  Future<List<Map<String, dynamic>>> listAvailable() async {
    final all = await store.allContent();
    return all.where((r) {
      final localPath = r['local_path'] as String? ?? '';
      return localPath.isEmpty;
    }).toList();
  }

  String _guessMime(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'html' || 'htm' => 'text/html',
      'css' => 'text/css', 'js' => 'application/javascript',
      'json' => 'application/json',
      'md' || 'txt' => 'text/plain',
      'png' => 'image/png', 'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif', 'webp' => 'image/webp',
      'svg' => 'image/svg+xml', 'mp3' => 'audio/mpeg',
      'mp4' => 'video/mp4', 'pdf' => 'application/pdf',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }
}
