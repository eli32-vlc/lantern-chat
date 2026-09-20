import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'protocol.dart';

/// Single chat message row.
class ChatMessage {
  final String id;
  final String chatId; // peer device id
  final String senderId;
  final LanternMsgKind kind;
  final String? text;
  final String? filePath;
  final String? fileName;
  final int? fileBytes;
  final int? durationMs;
  final int ts;
  final bool outgoing;
  final bool delivered;

  ChatMessage({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.kind,
    this.text,
    this.filePath,
    this.fileName,
    this.fileBytes,
    this.durationMs,
    required this.ts,
    required this.outgoing,
    this.delivered = false,
  });

  Map<String, dynamic> toRow() => {
        'id': id,
        'chat_id': chatId,
        'sender_id': senderId,
        'kind': kind.wire,
        'text': text,
        'file_path': filePath,
        'file_name': fileName,
        'file_bytes': fileBytes,
        'duration_ms': durationMs,
        'ts': ts,
        'outgoing': outgoing ? 1 : 0,
        'delivered': delivered ? 1 : 0,
      };

  static ChatMessage fromRow(Map<String, dynamic> r) => ChatMessage(
        id: r['id'] as String,
        chatId: r['chat_id'] as String,
        senderId: r['sender_id'] as String,
        kind: LanternMsgKindX.fromWire(r['kind'] as String?),
        text: r['text'] as String?,
        filePath: r['file_path'] as String?,
        fileName: r['file_name'] as String?,
        fileBytes: r['file_bytes'] as int?,
        durationMs: r['duration_ms'] as int?,
        ts: r['ts'] as int,
        outgoing: (r['outgoing'] as int) == 1,
        delivered: (r['delivered'] as int) == 1,
      );
}

/// Chat list entry: one per peer.
class ChatSummary {
  final String peerId;
  final String peerName;
  final String? lastText;
  final int? lastTs;
  final int unread;

  ChatSummary({
    required this.peerId,
    required this.peerName,
    this.lastText,
    this.lastTs,
    this.unread = 0,
  });
}

/// Known/trusted peer (TOFU fingerprint pinning).
class KnownPeer {
  final String id;
  final String name;
  final String status;
  final String pubB64;
  final String fingerprint;
  final bool trusted;
  final int lastSeen;

  KnownPeer({
    required this.id,
    required this.name,
    required this.status,
    required this.pubB64,
    required this.fingerprint,
    this.trusted = false,
    required this.lastSeen,
  });

  Map<String, dynamic> toRow() => {
        'id': id,
        'name': name,
        'status': status,
        'pub': pubB64,
        'fingerprint': fingerprint,
        'trusted': trusted ? 1 : 0,
        'last_seen': lastSeen,
      };
}

class ChatStore {
  Database? _db;

  Future<Database> open(String dir) async {
    if (_db != null) return _db!;
    final path = p.join(dir, 'lantern.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE peers(
            id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT NOT NULL DEFAULT '',
            pub TEXT NOT NULL, fingerprint TEXT NOT NULL,
            trusted INTEGER NOT NULL DEFAULT 0, last_seen INTEGER NOT NULL DEFAULT 0
          )''');
        await db.execute('''
          CREATE TABLE messages(
            id TEXT PRIMARY KEY, chat_id TEXT NOT NULL, sender_id TEXT NOT NULL,
            kind TEXT NOT NULL, text TEXT, file_path TEXT, file_name TEXT,
            file_bytes INTEGER, duration_ms INTEGER, ts INTEGER NOT NULL,
            outgoing INTEGER NOT NULL, delivered INTEGER NOT NULL DEFAULT 0
          )''');
        await db.execute(
            'CREATE INDEX idx_msg_chat_ts ON messages(chat_id, ts)');
        await db.execute('''
          CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT NOT NULL)''');
      },
    );
    return _db!;
  }

  Database get db => _db!;

  // ---- peers ----
  Future<void> upsertPeer(KnownPeer peer) async {
    await db.insert('peers', peer.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<KnownPeer?> getPeer(String id) async {
    final rows = await db.query('peers', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return KnownPeer(
      id: r['id'] as String,
      name: r['name'] as String,
      status: (r['status'] as String?) ?? '',
      pubB64: r['pub'] as String,
      fingerprint: r['fingerprint'] as String,
      trusted: (r['trusted'] as int) == 1,
      lastSeen: r['last_seen'] as int,
    );
  }

  Future<List<KnownPeer>> allPeers() async {
    final rows = await db.query('peers', orderBy: 'last_seen DESC');
    return rows
        .map((r) => KnownPeer(
              id: r['id'] as String,
              name: r['name'] as String,
              status: (r['status'] as String?) ?? '',
              pubB64: r['pub'] as String,
              fingerprint: r['fingerprint'] as String,
              trusted: (r['trusted'] as int) == 1,
              lastSeen: r['last_seen'] as int,
            ))
        .toList();
  }

  Future<void> trustPeer(String id, bool trusted) async {
    await db.update('peers', {'trusted': trusted ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  // ---- messages ----
  Future<void> insertMessage(ChatMessage m) async {
    await db.insert('messages', m.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<ChatMessage>> messagesFor(String chatId,
      {int limit = 200}) async {
    final rows = await db.query('messages',
        where: 'chat_id = ?',
        whereArgs: [chatId],
        orderBy: 'ts DESC',
        limit: limit);
    return rows.reversed.map(ChatMessage.fromRow).toList();
  }

  Stream<List<ChatMessage>> watchMessages(String chatId) {
    // Simple poll-based stream; good enough for LAN chat scale.
    late StreamController<List<ChatMessage>> ctrl;
    Timer? t;
    ctrl = StreamController<List<ChatMessage>>.broadcast(onListen: () async {
      ctrl.add(await messagesFor(chatId));
      t = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        if (!ctrl.isClosed) ctrl.add(await messagesFor(chatId));
      });
    }, onCancel: () => t?.cancel());
    return ctrl.stream;
  }

  Future<List<ChatSummary>> chatSummaries() async {
    final peers = await allPeers();
    final out = <ChatSummary>[];
    for (final peer in peers) {
      final rows = await db.query('messages',
          where: 'chat_id = ?',
          whereArgs: [peer.id],
          orderBy: 'ts DESC',
          limit: 1);
      String? lastText;
      int? lastTs;
      if (rows.isNotEmpty) {
        final m = ChatMessage.fromRow(rows.first);
        lastText = m.text ??
            (m.fileName != null ? '📎 ${m.fileName}' : m.kind.wire);
        lastTs = m.ts;
      }
      final unreadRows = await db.rawQuery(
          'SELECT COUNT(*) c FROM messages WHERE chat_id = ? AND outgoing = 0 AND delivered = 0',
          [peer.id]);
      out.add(ChatSummary(
        peerId: peer.id,
        peerName: peer.name,
        lastText: lastText,
        lastTs: lastTs,
        unread: (unreadRows.first['c'] as int?) ?? 0,
      ));
    }
    out.sort((a, b) => (b.lastTs ?? 0).compareTo(a.lastTs ?? 0));
    return out;
  }

  Future<void> markRead(String chatId) async {
    await db.update('messages', {'delivered': 1},
        where: 'chat_id = ? AND outgoing = 0', whereArgs: [chatId]);
  }

  Future<void> deleteChat(String chatId) async {
    await db.delete('messages', where: 'chat_id = ?', whereArgs: [chatId]);
  }

  // ---- kv ----
  Future<void> setKv(String k, String v) async {
    await db.insert('kv', {'k': k, 'v': v},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getKv(String k) async {
    final rows = await db.query('kv', where: 'k = ?', whereArgs: [k]);
    return rows.isEmpty ? null : rows.first['v'] as String;
  }
}

/// Frame reader: 4-byte length prefix + bytes, with max guard.
class FrameReader {
  final _buf = BytesBuilder();

  List<Uint8List> feed(Uint8List chunk) {
    _buf.add(chunk);
    final out = <Uint8List>[];
    while (true) {
      final bytes = _buf.toBytes();
      if (bytes.length < 4) break;
      final len =
          ByteData.view(bytes.buffer, bytes.offsetInBytes, 4).getUint32(0);
      if (len > LanternProtocol.frameMaxBytes) {
        _buf.clear();
        throw StateError('frame too large: $len');
      }
      if (bytes.length < 4 + len) break;
      out.add(Uint8List.fromList(bytes.sublist(4, 4 + len)));
      final rest = bytes.sublist(4 + len);
      _buf.clear();
      if (rest.isNotEmpty) _buf.add(rest);
      if (rest.isEmpty) break;
    }
    return out;
  }
}

Map<String, dynamic> decodeJson(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
