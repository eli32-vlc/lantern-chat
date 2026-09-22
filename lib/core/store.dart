import 'dart:async';
import 'dart:convert';
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
  final String peerHandle; // cryptographic short handle
  final String? lastText;
  final int? lastTs;
  final int unread;

  ChatSummary({
    required this.peerId,
    required this.peerName,
    this.peerHandle = '',
    this.lastText,
    this.lastTs,
    this.unread = 0,
  });
}

/// Known/trusted peer (TOFU fingerprint pinning).
class KnownPeer {
  final String id;
  final String name;
  final String handle; // cryptographic short handle
  final String accountId; // account UUID (shared across devices)
  final String status;
  final String pubB64;
  final String fingerprint;
  final bool trusted;
  final int lastSeen;

  KnownPeer({
    required this.id,
    required this.name,
    this.handle = '',
    this.accountId = '',
    required this.status,
    required this.pubB64,
    required this.fingerprint,
    this.trusted = false,
    required this.lastSeen,
  });

  Map<String, dynamic> toRow() => {
        'id': id,
        'name': name,
        'handle': handle,
        'account_id': accountId,
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
      version: 7,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE peers(
            id TEXT PRIMARY KEY, name TEXT NOT NULL, handle TEXT NOT NULL DEFAULT '',
            account_id TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT '',
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
        await db.execute('''
          CREATE TABLE sync_state(
            peer_id TEXT PRIMARY KEY,
            last_sync_ts INTEGER NOT NULL DEFAULT 0
          )''');
        await db.execute('''
          CREATE TABLE groups(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            group_secret BLOB NOT NULL,
            created_by TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )''');
        await db.execute('''
          CREATE TABLE group_members(
            group_id TEXT NOT NULL,
            peer_id TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'member',
            joined_at INTEGER NOT NULL,
            PRIMARY KEY (group_id, peer_id)
          )''');
        await db.execute('''
          CREATE TABLE msg_queue(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            peer_id TEXT NOT NULL,
            frame BLOB NOT NULL,
            created_at INTEGER NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0
          )''');
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute(
              "ALTER TABLE peers ADD COLUMN handle TEXT NOT NULL DEFAULT ''");
        }
        if (oldV < 3) {
          await db.execute(
              "ALTER TABLE peers ADD COLUMN account_id TEXT NOT NULL DEFAULT ''");
        }
        if (oldV < 4) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS sync_state(
              peer_id TEXT PRIMARY KEY,
              last_sync_ts INTEGER NOT NULL DEFAULT 0
            )''');
        }
        if (oldV < 5) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS groups(
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              group_secret BLOB NOT NULL,
              created_by TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )''');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS group_members(
              group_id TEXT NOT NULL,
              peer_id TEXT NOT NULL,
              role TEXT NOT NULL DEFAULT 'member',
              joined_at INTEGER NOT NULL,
              PRIMARY KEY (group_id, peer_id)
            )''');
        }
        if (oldV < 6) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS msg_queue(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              peer_id TEXT NOT NULL,
              frame BLOB NOT NULL,
              created_at INTEGER NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0
            )''');
        }
        if (oldV < 7) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS content(
              hash TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              size INTEGER NOT NULL,
              mime_type TEXT,
              pieces INTEGER NOT NULL DEFAULT 1,
              published_by TEXT,
              published_at INTEGER,
              local_path TEXT,
              is_pinned INTEGER DEFAULT 0
            )''');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS content_pieces(
              hash TEXT NOT NULL,
              piece_idx INTEGER NOT NULL,
              data BLOB,
              PRIMARY KEY (hash, piece_idx)
            )''');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS content_peers(
              hash TEXT NOT NULL,
              peer_id TEXT NOT NULL,
              last_seen INTEGER,
              PRIMARY KEY (hash, peer_id)
            )''');
        }
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
      handle: (r['handle'] as String?) ?? '',
      accountId: (r['account_id'] as String?) ?? '',
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
              handle: (r['handle'] as String?) ?? '',
              accountId: (r['account_id'] as String?) ?? '',
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
    final seen = <String>{};
    Future<void> addSummary(String chatId, String name) async {
      if (!seen.add(chatId)) return;
      final rows = await db.query('messages',
          where: 'chat_id = ?',
          whereArgs: [chatId],
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
          [chatId]);
      out.add(ChatSummary(
        peerId: chatId,
        peerName: name,
        peerHandle: '',
        lastText: lastText,
        lastTs: lastTs,
        unread: (unreadRows.first['c'] as int?) ?? 0,
      ));
    }

    for (final peer in peers) {
      if (!seen.add(peer.id)) continue;
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
        peerHandle: peer.handle,
        lastText: lastText,
        lastTs: lastTs,
        unread: (unreadRows.first['c'] as int?) ?? 0,
      ));
    }
    // Group chats: include any that exist in our DB
    final allGroups = await db.query('groups');
    for (final g in allGroups) {
      final gid = g['id'] as String;
      if (seen.contains(gid)) continue;
      final gname = g['name'] as String;
      await addSummary(gid, '\u{1F465} $gname');
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

  // ---- sync state ----
  Future<int> getLastSyncTs(String peerId) async {
    final rows = await db.query('sync_state',
        where: 'peer_id = ?', whereArgs: [peerId]);
    if (rows.isEmpty) return 0;
    return (rows.first['last_sync_ts'] as int?) ?? 0;
  }

  Future<void> setLastSyncTs(String peerId, int ts) async {
    await db.insert('sync_state',
        {'peer_id': peerId, 'last_sync_ts': ts},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---- groups ----
  Future<void> storeGroup(String id, String name, List<int> secret,
      {required String createdBy}) async {
    await db.insert('groups', {
      'id': id,
      'name': name,
      'group_secret': Uint8List.fromList(secret),
      'created_by': createdBy,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> addGroupMember(String groupId, String peerId,
      {String role = 'member'}) async {
    await db.insert('group_members', {
      'group_id': groupId,
      'peer_id': peerId,
      'role': role,
      'joined_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> removeGroupMember(String groupId, String peerId) async {
    await db.delete('group_members',
        where: 'group_id = ? AND peer_id = ?',
        whereArgs: [groupId, peerId]);
  }

  Future<List<String>> groupMemberIds(String groupId) async {
    final rows = await db.query('group_members',
        where: 'group_id = ?', whereArgs: [groupId]);
    return rows.map((r) => r['peer_id'] as String).toList();
  }

  Future<Map<String, dynamic>?> getGroup(String groupId) async {
    final rows = await db.query('groups',
        where: 'id = ?', whereArgs: [groupId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> allGroups() async {
    return db.query('groups', orderBy: 'created_at DESC');
  }

  Future<bool> isInGroup(String groupId) async {
    final rows = await db.query('groups',
        where: 'id = ?', whereArgs: [groupId]);
    return rows.isNotEmpty;
  }

  // ---- message queue (store-and-forward) ----
  Future<void> queueMessage(String peerId, Uint8List frame) async {
    await db.insert('msg_queue', {
      'peer_id': peerId,
      'frame': frame,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'attempts': 0,
    });
  }

  Future<List<Map<String, dynamic>>> queuedMessages(String peerId) async {
    return db.query('msg_queue',
        where: 'peer_id = ?', whereArgs: [peerId], orderBy: 'created_at ASC');
  }

  Future<void> removeQueuedMessage(int id) async {
    await db.delete('msg_queue', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> incrementQueueAttempt(int id) async {
    await db.rawUpdate(
        'UPDATE msg_queue SET attempts = attempts + 1 WHERE id = ?', [id]);
  }

  Future<void> purgeOldQueue({int maxAgeMs = 3600000}) async {
    final cutoff =
        DateTime.now().subtract(Duration(milliseconds: maxAgeMs)).millisecondsSinceEpoch;
    await db.delete('msg_queue',
        where: 'created_at < ?', whereArgs: [cutoff]);
  }

  // ---- search ----
  Future<List<ChatMessage>> searchMessages(String query,
      {int limit = 50}) async {
    final rows = await db.query('messages',
        where: 'text LIKE ?',
        whereArgs: ['%$query%'],
        orderBy: 'ts DESC',
        limit: limit);
    return rows.reversed.map(ChatMessage.fromRow).toList();
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
