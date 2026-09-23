import 'dart:async';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';


/// SQLite store. One class, all tables, no business logic.
class Store {
  Database? _db;

  Future<Database> open(String dir) async {
    if (_db != null) return _db!;
    _db = await openDatabase(
      p.join(dir, 'lantern.db'),
      version: 1,
      onCreate: _create,
      onUpgrade: _upgrade,
    );
    return _db!;
  }

  Database get db => _db!;

  Future<void> _create(Database db, int v) async {
    await db.execute('''
      CREATE TABLE peers(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        handle TEXT NOT NULL DEFAULT '',
        account_id TEXT NOT NULL DEFAULT '',
        sign_pub TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT '',
        pub TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        trusted INTEGER NOT NULL DEFAULT 0,
        last_seen INTEGER NOT NULL DEFAULT 0
      )''');
    await db.execute('''
      CREATE TABLE messages(
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        text TEXT,
        file_path TEXT,
        file_name TEXT,
        file_bytes INTEGER,
        duration_ms INTEGER,
        ts INTEGER NOT NULL,
        outgoing INTEGER NOT NULL,
        delivered INTEGER NOT NULL DEFAULT 0,
        signature TEXT
      )''');
    await db.execute(
        'CREATE INDEX idx_msg_chat_ts ON messages(chat_id, ts)');
    await db.execute(
        'CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT NOT NULL)');
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
      CREATE TABLE content(
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
      CREATE TABLE content_pieces(
        hash TEXT NOT NULL,
        piece_idx INTEGER NOT NULL,
        data BLOB,
        PRIMARY KEY (hash, piece_idx)
      )''');
    await db.execute('''
      CREATE TABLE content_peers(
        hash TEXT NOT NULL,
        peer_id TEXT NOT NULL,
        last_seen INTEGER,
        PRIMARY KEY (hash, peer_id)
      )''');
    await db.execute('''
      CREATE TABLE msg_queue(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        peer_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0
      )''');
    await db.execute('''
      CREATE TABLE seen_messages(
        msg_id TEXT PRIMARY KEY,
        seen_at INTEGER NOT NULL
      )''');
  }

  Future<void> _upgrade(Database db, int old, int now) async {
    // Recreate all tables on any version change
    await _create(db, now);
  }

  // ---- KV ----
  Future<void> setKv(String k, String v) async {
    await db.insert('kv', {'k': k, 'v': v},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getKv(String k) async {
    final rows = await db.query('kv', where: 'k = ?', whereArgs: [k]);
    return rows.isEmpty ? null : rows.first['v'] as String;
  }

  // ---- Peers ----
  Future<void> upsertPeer(Map<String, dynamic> row) async {
    await db.insert('peers', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getPeer(String id) async {
    final rows = await db.query('peers', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> allPeers() async {
    return db.query('peers', orderBy: 'last_seen DESC');
  }

  Future<void> trustPeer(String id, bool trust) async {
    await db.update('peers', {'trusted': trust ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  // ---- Messages ----
  Future<void> insertMessage(Map<String, dynamic> row) async {
    await db.insert('messages', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Atomic: insert message + mark delivered in one transaction.
  Future<void> insertAndMarkDelivered(Map<String, dynamic> row) async {
    await db.transaction((txn) async {
      await txn.insert('messages', row,
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.update('messages', {'delivered': 1},
          where: 'id = ?', whereArgs: [row['id']]);
    });
  }

  /// Atomic: insert message + refresh chat timestamp.
  Future<void> insertIncomingMessage(Map<String, dynamic> row) async {
    await db.transaction((txn) async {
      await txn.insert('messages', row,
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<List<Map<String, dynamic>>> messagesFor(String chatId,
      {int limit = 200}) async {
    return db.query('messages',
        where: 'chat_id = ?', whereArgs: [chatId],
        orderBy: 'ts ASC', limit: limit);
  }

  Future<List<Map<String, dynamic>>> searchMessages(String q,
      {int limit = 50}) async {
    final esc = q.replaceAll('%', '\\%').replaceAll('_', '\\_');
    return db.query('messages',
        where: 'text LIKE ?', whereArgs: ['%$esc%'],
        orderBy: 'ts DESC', limit: limit);
  }

  Future<void> markDelivered(String id) async {
    await db.update('messages', {'delivered': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> markRead(String chatId) async {
    await db.update('messages', {'delivered': 1},
        where: 'chat_id = ? AND outgoing = 0', whereArgs: [chatId]);
  }

  Future<void> deleteChat(String chatId) async {
    await db.delete('messages', where: 'chat_id = ?', whereArgs: [chatId]);
  }

  // ---- Seen messages (replay protection) ----
  Future<bool> isSeen(String msgId) async {
    final rows = await db.query('seen_messages',
        where: 'msg_id = ?', whereArgs: [msgId]);
    return rows.isNotEmpty;
  }

  Future<void> markSeen(String msgId) async {
    await db.insert('seen_messages', {
      'msg_id': msgId,
      'seen_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> cleanSeen({int maxAgeMs = 86400000}) async {
    final cutoff =
        DateTime.now().subtract(Duration(milliseconds: maxAgeMs))
            .millisecondsSinceEpoch;
    await db.delete('seen_messages', where: 'seen_at < ?', whereArgs: [cutoff]);
  }

  // ---- Sync state ----
  Future<int> lastSyncTs(String peerId) async {
    final rows = await db.query('sync_state',
        where: 'peer_id = ?', whereArgs: [peerId]);
    return rows.isEmpty ? 0 : (rows.first['last_sync_ts'] as int? ?? 0);
  }

  Future<void> setSyncTs(String peerId, int ts) async {
    await db.insert('sync_state', {'peer_id': peerId, 'last_sync_ts': ts},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---- Groups ----
  Future<void> storeGroup(String id, String name, List<int> secret,
      {required String createdBy}) async {
    await db.insert('groups', {
      'id': id, 'name': name,
      'group_secret': Uint8List.fromList(secret),
      'created_by': createdBy,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateGroupSecret(String id, List<int> secret) async {
    await db.update('groups', {'group_secret': Uint8List.fromList(secret)},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<Map<String, dynamic>?> getGroup(String id) async {
    final rows = await db.query('groups', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> allGroups() async {
    return db.query('groups', orderBy: 'created_at DESC');
  }

  Future<List<Map<String, dynamic>>> myGroups() async {
    final rows = await db.rawQuery('''
      SELECT g.* FROM groups g
      INNER JOIN group_members gm ON g.id = gm.group_id
      GROUP BY g.id
      ORDER BY g.created_at DESC
    ''');
    return rows;
  }

  Future<void> addMember(String gid, String pid, {String role = 'member'}) async {
    await db.insert('group_members', {
      'group_id': gid, 'peer_id': pid, 'role': role,
      'joined_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> removeMember(String gid, String pid) async {
    await db.delete('group_members',
        where: 'group_id = ? AND peer_id = ?', whereArgs: [gid, pid]);
  }

  Future<List<String>> memberIds(String gid) async {
    final rows = await db.query('group_members',
        where: 'group_id = ?', whereArgs: [gid]);
    return rows.map((r) => r['peer_id'] as String).toList();
  }

  // ---- Content ----
  Future<void> storeContent(Map<String, dynamic> row) async {
    await db.insert('content', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getContent(String hash) async {
    final rows = await db.query('content', where: 'hash = ?', whereArgs: [hash]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> storePiece(String hash, int idx, Uint8List data) async {
    await db.insert('content_pieces', {
      'hash': hash, 'piece_idx': idx, 'data': data,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<int>> pieceIndices(String hash) async {
    final rows = await db.query('content_pieces',
        columns: ['piece_idx'], where: 'hash = ?', whereArgs: [hash]);
    return rows.map((r) => r['piece_idx'] as int).toList()..sort();
  }

  Future<Uint8List?> getPiece(String hash, int idx) async {
    final rows = await db.query('content_pieces',
        where: 'hash = ? AND piece_idx = ?', whereArgs: [hash, idx]);
    return rows.isEmpty ? null : rows.first['data'] as Uint8List;
  }

  Future<void> recordContentPeer(String hash, String peerId) async {
    await db.insert('content_peers', {
      'hash': hash, 'peer_id': peerId,
      'last_seen': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<String>> contentPeers(String hash) async {
    final rows = await db.query('content_peers',
        where: 'hash = ?', whereArgs: [hash]);
    return rows.map((r) => r['peer_id'] as String).toList();
  }

  Future<List<Map<String, dynamic>>> allContent() async {
    return db.query('content', orderBy: 'published_at DESC');
  }

  Future<List<Map<String, dynamic>>> searchContent(String q) async {
    final esc = q.replaceAll('%', '\\%').replaceAll('_', '\\_');
    return db.query('content',
        where: 'name LIKE ? OR hash LIKE ?',
        whereArgs: ['%$esc%', '%$esc%'],
        orderBy: 'published_at DESC');
  }

  Future<void> deleteContent(String hash) async {
    await db.delete('content', where: 'hash = ?', whereArgs: [hash]);
    await db.delete('content_pieces', where: 'hash = ?', whereArgs: [hash]);
    await db.delete('content_peers', where: 'hash = ?', whereArgs: [hash]);
  }

  // ---- Queue ----
  static const _maxQueueSize = 1000;

  Future<void> queueMessage(String peerId, String payload) async {
    // Cap queue size
    final count = await db.rawQuery('SELECT COUNT(*) c FROM msg_queue');
    final current = (count.first['c'] as int?) ?? 0;
    if (current >= _maxQueueSize) {
      // Remove oldest
      await db.rawDelete(
          'DELETE FROM msg_queue WHERE id IN (SELECT id FROM msg_queue ORDER BY created_at ASC LIMIT ?)',
          [current - _maxQueueSize + 1]);
    }
    await db.insert('msg_queue', {
      'peer_id': peerId, 'payload': payload,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'attempts': 0,
    });
  }

  Future<List<Map<String, dynamic>>> queuedMessages(String peerId) async {
    return db.query('msg_queue',
        where: 'peer_id = ?', whereArgs: [peerId],
        orderBy: 'created_at ASC');
  }

  Future<List<Map<String, dynamic>>> allQueuedMessages() async {
    return db.query('msg_queue', orderBy: 'created_at ASC');
  }

  Future<void> removeQueued(int id) async {
    await db.delete('msg_queue', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> incrementQueueAttempt(int id) async {
    await db.rawUpdate(
        'UPDATE msg_queue SET attempts = attempts + 1 WHERE id = ?', [id]);
  }

  Future<void> purgeQueue({int maxAgeMs = 3600000}) async {
    final cutoff =
        DateTime.now().subtract(Duration(milliseconds: maxAgeMs))
            .millisecondsSinceEpoch;
    await db.delete('msg_queue', where: 'created_at < ?', whereArgs: [cutoff]);
  }

  /// Save all pending messages from memory to DB (lifecycle kill recovery).
  Future<void> persistPendingMessages(
      List<Map<String, dynamic>> pending) async {
    if (pending.isEmpty) return;
    await db.transaction((txn) async {
      for (final row in pending) {
        await txn.insert('msg_queue', row,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// Count queued messages for a peer.
  Future<int> queueCount(String peerId) async {
    final rows = await db.rawQuery(
        'SELECT COUNT(*) c FROM msg_queue WHERE peer_id = ?', [peerId]);
    return (rows.first['c'] as int?) ?? 0;
  }

  /// Remove all queued messages for a peer.
  Future<void> clearQueue(String peerId) async {
    await db.delete('msg_queue', where: 'peer_id = ?', whereArgs: [peerId]);
  }
}
