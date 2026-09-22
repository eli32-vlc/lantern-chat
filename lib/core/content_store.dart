import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Content-addressed storage for decentralized file sharing.
/// Files are identified by SHA256 hash, split into pieces for
/// BitTorrent-style multi-peer download.
class ContentStore {
  Database? _db;
  String? _basePath;

  /// Expose database for direct queries.
  Database get db => _db!;

  Future<void> open(Database db) async {
    _db = db;
    final docs = await getApplicationDocumentsDirectory();
    _basePath = '${docs.path}/content';
    await Directory(_basePath!).create(recursive: true);
    await Directory('$_basePath/pieces').create(recursive: true);
  }

  /// Hash a file and store it. Returns the content hash.
  Future<String> publish(String filePath, {String? name}) async {
    final file = File(filePath);
    if (!await file.exists()) throw ArgumentError('File not found');
    final bytes = await file.readAsBytes();
    final hash = await _hashBytes(bytes);
    final fileName = name ?? filePath.split(Platform.pathSeparator).last;
    final mime = _guessMime(fileName);
    const pieceSize = 256 * 1024; // 256KB
    final totalPieces = (bytes.length / pieceSize).ceil().clamp(1, 100000);

    // Store pieces
    for (var i = 0; i < totalPieces; i++) {
      final start = i * pieceSize;
      final end = (start + pieceSize).clamp(0, bytes.length);
      final piece = bytes.sublist(start, end);
      await _db!.insert('content_pieces', {
        'hash': hash,
        'piece_idx': i,
        'data': Uint8List.fromList(piece),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    // Store metadata
    await _db!.insert('content', {
      'hash': hash,
      'name': fileName,
      'size': bytes.length,
      'mime_type': mime,
      'pieces': totalPieces,
      'published_by': 'local',
      'published_at': DateTime.now().millisecondsSinceEpoch,
      'local_path': filePath,
      'is_pinned': 1,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    return hash;
  }

  /// Import content from raw bytes (received from peer).
  Future<String> importBytes(Uint8List bytes, {
    required String name,
    String? mimeType,
    String? publishedBy,
  }) async {
    final hash = await _hashBytes(bytes);
    final mime = mimeType ?? _guessMime(name);
    const pieceSize = 256 * 1024;
    final totalPieces = (bytes.length / pieceSize).ceil().clamp(1, 100000);

    for (var i = 0; i < totalPieces; i++) {
      final start = i * pieceSize;
      final end = (start + pieceSize).clamp(0, bytes.length);
      final piece = bytes.sublist(start, end);
      await _db!.insert('content_pieces', {
        'hash': hash,
        'piece_idx': i,
        'data': Uint8List.fromList(piece),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    // Save assembled file to disk
    final localPath = '$_basePath/$hash';
    await File(localPath).writeAsBytes(bytes);

    await _db!.insert('content', {
      'hash': hash,
      'name': name,
      'size': bytes.length,
      'mime_type': mime,
      'pieces': totalPieces,
      'published_by': publishedBy ?? 'peer',
      'published_at': DateTime.now().millisecondsSinceEpoch,
      'local_path': localPath,
      'is_pinned': 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    return hash;
  }

  /// Store a single piece received from a peer.
  Future<void> storePiece(String hash, int idx, Uint8List data) async {
    await _db!.insert('content_pieces', {
      'hash': hash,
      'piece_idx': idx,
      'data': data,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Check if we have all pieces for a content hash.
  Future<bool> hasContent(String hash) async {
    final rows = await _db!.query('content', where: 'hash = ?', whereArgs: [hash]);
    return rows.isNotEmpty;
  }

  /// Get which piece indices we have for a hash.
  Future<List<int>> getPieceIndices(String hash) async {
    final rows = await _db!.query('content_pieces',
        columns: ['piece_idx'], where: 'hash = ?', whereArgs: [hash]);
    return rows.map((r) => r['piece_idx'] as int).toList()..sort();
  }

  /// Get a single piece's data.
  Future<Uint8List?> getPiece(String hash, int idx) async {
    final rows = await _db!.query('content_pieces',
        where: 'hash = ? AND piece_idx = ?', whereArgs: [hash, idx]);
    if (rows.isEmpty) return null;
    return rows.first['data'] as Uint8List;
  }

  /// Assemble all pieces into a complete file. Returns the local path.
  Future<String?> assemble(String hash) async {
    final meta = await _db!.query('content', where: 'hash = ?', whereArgs: [hash]);
    if (meta.isEmpty) return null;
    final totalPieces = meta.first['pieces'] as int;

    final pieces = <int, Uint8List>{};
    for (var i = 0; i < totalPieces; i++) {
      final data = await getPiece(hash, i);
      if (data == null) return null; // missing piece
      pieces[i] = data;
    }

    final out = BytesBuilder();
    for (var i = 0; i < totalPieces; i++) {
      out.add(pieces[i]!);
    }

    final localPath = '$_basePath/$hash';
    await File(localPath).writeAsBytes(out.toBytes());

    await _db!.update('content', {'local_path': localPath},
        where: 'hash = ?', whereArgs: [hash]);

    return localPath;
  }

  /// Get metadata for a content hash.
  Future<Map<String, dynamic>?> getContent(String hash) async {
    final rows = await _db!.query('content', where: 'hash = ?', whereArgs: [hash]);
    return rows.isEmpty ? null : rows.first;
  }

  /// List all known content.
  Future<List<Map<String, dynamic>>> listAll() async {
    return _db!.query('content', orderBy: 'published_at DESC');
  }

  /// List content published by us.
  Future<List<Map<String, dynamic>>> listPublished() async {
    return _db!.query('content',
        where: 'is_pinned = 1', orderBy: 'published_at DESC');
  }

  /// List content available from peers (not yet downloaded).
  Future<List<Map<String, dynamic>>> listAvailable() async {
    final rows = await _db!.query('content_peers',
        columns: ['hash', 'peer_id', 'last_seen'],
        orderBy: 'last_seen DESC');
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final hash = row['hash'] as String;
      if (seen.add(hash)) {
        // Check if we already have it locally
        final local = await hasContent(hash);
        if (!local) {
          final meta = await getContent(hash);
          if (meta != null) {
            result.add(meta);
          }
        }
      }
    }
    return result;
  }

  /// Record that a peer has a piece of content.
  Future<void> recordPeer(String hash, String peerId) async {
    await _db!.insert('content_peers', {
      'hash': hash,
      'peer_id': peerId,
      'last_seen': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Get peers that have a given content hash.
  Future<List<String>> getPeers(String hash) async {
    final rows = await _db!.query('content_peers',
        where: 'hash = ?', whereArgs: [hash]);
    return rows.map((r) => r['peer_id'] as String).toList();
  }

  /// Delete content and its pieces.
  Future<void> delete(String hash) async {
    await _db!.delete('content', where: 'hash = ?', whereArgs: [hash]);
    await _db!.delete('content_pieces', where: 'hash = ?', whereArgs: [hash]);
    await _db!.delete('content_peers', where: 'hash = ?', whereArgs: [hash]);
    try {
      await File('$_basePath/$hash').delete();
    } catch (_) {}
  }

  /// Search content by name.
  Future<List<Map<String, dynamic>>> search(String query) async {
    return _db!.query('content',
        where: 'name LIKE ?', whereArgs: ['%$query%'],
        orderBy: 'published_at DESC');
  }

  /// Get all content hashes we have (for announcing).
  Future<List<Map<String, dynamic>>> getAnnouncement() async {
    return _db!.query('content',
        columns: ['hash', 'name', 'size', 'mime_type', 'pieces']);
  }

  Future<String> _hashBytes(List<int> bytes) async {
    final hash = await Sha256().hash(bytes);
    return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String _guessMime(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'html' || 'htm' => 'text/html',
      'css' => 'text/css',
      'js' => 'application/javascript',
      'json' => 'application/json',
      'md' || 'txt' => 'text/plain',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'svg' => 'image/svg+xml',
      'mp3' => 'audio/mpeg',
      'mp4' => 'video/mp4',
      'pdf' => 'application/pdf',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }
}
