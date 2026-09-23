import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crypto.dart';
import 'diag.dart';
import 'identity.dart';
import 'mesh.dart';
import 'protocol.dart';
import 'store.dart';

/// Message bus: send, receive, queue, sync, ack.
class Messages {
  final Mesh mesh;
  final Store store;
  final Account? account;
  final _eventCtrl = StreamController<MsgEvent>.broadcast();
  final _pendingAck = <String, DateTime>{};
  final _pendingUdp = <String, _UdpPending>{};
  Timer? _ackTimer;

  Stream<MsgEvent> get events => _eventCtrl.stream;

  Messages({required this.mesh, required this.store, this.account});

  void start() {
    mesh.frames.listen(_onFrame);
    _ackTimer = Timer.periodic(
        Duration(seconds: P.ackCheckSec), (_) => _checkAcks());
  }

  void stop() {
    _ackTimer?.cancel();
    for (final p in _pendingUdp.values) { p.timer?.cancel(); }
    _pendingUdp.clear();
    _pendingAck.clear();
  }

  // ---- Send ----

  Future<bool> send(Peer peer, Map<String, dynamic> payload) async {
    final known = await store.getPeer(peer.id);
    if (known == null || known['trusted'] != 1) return false;
    final key = await mesh.sessionFor(peer.id, known['pub'] as String);
    if (key == null) return false;

    final sealed = await Crypto.seal(key, payload);
    final frame = <String, dynamic>{
      't': P.payload, 'from': mesh.device.id,
      'blob': base64Encode(sealed),
    };
    if (account != null) {
      frame['sig'] = base64Encode(await account!.sign(sealed));
      frame['sign_pub'] = await account!.pubB64;
    }
    return _sendFrame(peer, frame, payload['id'] as String?, payload);
  }

  Future<bool> _sendFrame(Peer peer, Map<String, dynamic> frame,
      String? msgId, Map<String, dynamic> plainPayload) async {
    // Try UDP for small payloads
    final sealed = base64Decode(frame['blob'] as String);
    if (peer.udpPort > 0 && sealed.length <= P.udpMaxPayload && msgId != null) {
      final ok = await _sendUdp(peer, sealed, msgId);
      if (!ok) {
        // H4: Store plaintext for re-encryption on flush
        await store.queueMessage(peer.id, jsonEncode({'queued': plainPayload}));
        DiagLog.add('queue', 'queued $msgId');
      }
      return ok;
    }
    // TCP fallback
    final ok = await _sendTcp(peer, frame, msgId);
    if (!ok) {
      // H4: Store plaintext for re-encryption on flush
      await store.queueMessage(peer.id, jsonEncode({'queued': plainPayload}));
      DiagLog.add('queue', 'queued $msgId');
    }
    return ok;
  }

  Future<bool> _sendTcp(Peer peer, Map<String, dynamic> frame, String? msgId) async {
    try {
      await mesh.sendFrame(peer, frame);
      if (msgId != null) _pendingAck[msgId] = DateTime.now();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _sendUdp(Peer peer, Uint8List sealed, String msgId) async {
    final idBytes = utf8.encode(msgId);
    final out = BytesBuilder();
    out.add([idBytes.length]);
    out.add(idBytes);
    out.add([P.udpData]);
    out.add([(sealed.length >> 8) & 0xFF, sealed.length & 0xFF]);
    out.add(sealed);
    mesh.sendUdp(peer, out.toBytes().sublist(idBytes.length + 1));

    final pending = _UdpPending(msgId, peer, out.toBytes(), 1);
    pending.timer = Timer.periodic(Duration(milliseconds: P.udpRetryMs), (_) {
      if (pending.attempts >= P.udpMaxRetries) {
        _pendingUdp.remove(msgId);
        pending.timer?.cancel();
        _sendTcp(peer, {
          't': P.payload, 'from': mesh.device.id,
          'blob': base64Encode(sealed),
        }, msgId);
        return;
      }
      mesh.sendUdp(peer, out.toBytes().sublist(idBytes.length + 1));
      pending.attempts++;
    });
    _pendingUdp[msgId] = pending;
    return true;
  }

  // ---- Receive ----

  void _onFrame(RawFrame rf) {
    if (rf.isTcp) {
      _onTcpFrame(rf);
    } else if (rf.isUdp) {
      _onUdpFrame(rf);
    }
  }

  void _onTcpFrame(RawFrame rf) async {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(rf.tcpFrame!)) as Map<String, dynamic>;
    } catch (_) {
      DiagLog.add('proto', 'bad frame');
      return;
    }
    final t = json['t'] as String?;
    DiagLog.add('proto', 'tcp t=$t');

    if (t == P.hello) {
      _handleHello(json, rf.sock);
    } else if (t == P.payload) {
      await _handlePayload(json, rf.sock, rf.dialPeerId);
    } else if (t == P.ack) {
      _handleAck(json);
    } else if (t == P.syncReq) {
      await _handleSyncReq(json, rf.sock, rf.dialPeerId);
    } else if (t == P.syncMsgs) {
      await _handleSyncMsgs(json, rf.dialPeerId);
    }
  }

  void _onUdpFrame(RawFrame rf) async {
    final type = rf.udpType!;
    final msgId = rf.udpMsgId!;
    final offset = rf.udpOffset!;

    if (type == P.udpAck) {
      final p = _pendingUdp.remove(msgId);
      p?.timer?.cancel();
      if (p != null) {
        await store.markDelivered(p.msgId);
        DiagLog.add('udp', 'ack ${p.msgId}');
      }
      return;
    }

    if (type == P.udpData) {
      final data = rf.udpData!;
      final payloadLen = (data[offset - 2] << 8) | data[offset - 1];
      if (data.length < offset + payloadLen) return;
      final payload = data.sublist(offset, offset + payloadLen);

      // Check sub-type
      if (payload.isNotEmpty) {
        final sub = payload[0];
        if (sub == P.udpTyping) {
          final sender = _findPeerByHost(rf.udpAddr!.address);
          if (sender != null) _eventCtrl.add(MsgEvent.typing(sender));
          return;
        }
      }

      // Encrypted payload
      final sender = _findPeerByHost(rf.udpAddr!.address);
      if (sender == null) return;
      final known = await store.getPeer(sender);
      if (known == null || known['trusted'] != 1) return;
      final key = await mesh.sessionFor(sender, known['pub'] as String);
      if (key == null) return;
      try {
        final plain = await Crypto.open(key, Uint8List.fromList(payload));
        mesh.sendUdpAck(rf.udpAddr!, rf.udpPort!, msgId);
        DiagLog.add('udp', 'data ack sent');
        _processDecrypted(sender, plain);
      } catch (e) {
        DiagLog.add('udp', 'decrypt failed: $e');
      }
    }
  }

  void _handleHello(Map<String, dynamic> json, Socket? sock) async {
    final id = json['id'] as String? ?? '';
    final pk = json['pk'] as String? ?? '';
    if (id.isEmpty || pk.isEmpty || id == mesh.device.id) return;

    // H10: Reject incompatible protocol versions
    final peerVer = json['v'] as int? ?? 0;
    if (peerVer > P.protoVersion) return;

    // Reply hello once per socket
    if (sock != null) {
      final last = mesh.helloReplied[sock];
      if (last == null || DateTime.now().difference(last) > Duration(seconds: 10)) {
        mesh.helloReplied[sock] = DateTime.now();
        try {
          final hello = <String, dynamic>{
            't': P.hello, 'id': mesh.device.id,
            'nm': mesh.displayName, 'pk': await mesh.device.pubB64,
            'v': P.protoVersion, 'av': P.appVersion, 'ab': P.appBuild,
          };
          if (account != null) {
            hello['ah'] = await account!.handle;
            hello['aid'] = account!.id;
            hello['spk'] = await account!.pubB64;
          }
          sock.add(Mesh.encode(hello));
        } catch (_) {}
      }
    }

    // Cache session key (await to ensure it's ready for payloads)
    if (pk.isNotEmpty) {
      try { await mesh.cacheSession(id, base64Decode(pk)); } catch (_) {}
    }

    // Update peer in DB with hello info
    final handle = json['ah'] as String? ?? '';
    final aid = json['aid'] as String? ?? '';
    final spk = json['spk'] as String? ?? '';
    final existing = await store.getPeer(id);
    if (existing != null) {
      await store.upsertPeer({
        ...existing,
        if (handle.isNotEmpty) 'handle': handle,
        if (aid.isNotEmpty) 'account_id': aid,
        if (spk.isNotEmpty) 'sign_pub': spk,
      });
    }
  }

  Future<void> _handlePayload(Map<String, dynamic> json,
      Socket? sock, String? dialPeerId) async {
    final from = json['from'] as String? ?? dialPeerId ?? '';
    final blob = json['blob'] as String? ?? '';
    final sig = json['sig'] as String?;
    final signPubB64 = json['sign_pub'] as String?;
    if (from.isEmpty || blob.isEmpty || from == mesh.device.id) return;

    final known = await store.getPeer(from);
    if (known == null) return;
    if ((known['pub'] as String).isEmpty) return;

    // Verify signature if present (optional for backwards compat)
    if (sig == null || signPubB64 == null || signPubB64.isEmpty) {
      DiagLog.add('proto', 'UNSIGNED payload from $from — accepted (backwards compat)');
    } else {
      try {
        final valid = await Account.verify(
            base64Decode(blob), base64Decode(sig), base64Decode(signPubB64));
        if (!valid) {
          DiagLog.add('proto', 'BAD SIGNATURE from $from — rejected');
          return;
        }
      } catch (e) {
        DiagLog.add('proto', 'signature verify error from $from: $e');
      }
    }

    final key = await mesh.sessionFor(from, known['pub'] as String);
    if (key == null) return;
    try {
      final plain = await Crypto.open(key, base64Decode(blob));

      // Send ACK
      final msgId = plain['id'] as String?;
      if (msgId != null && msgId.isNotEmpty && sock != null) {
        try {
          sock.add(Mesh.encode({'t': P.ack, 'id': msgId}));
        } catch (_) {}
      }

      _processDecrypted(from, plain);
    } catch (_) {}
  }

  void _processDecrypted(String from, Map<String, dynamic> plain) async {
    final msgId = plain['id'] as String? ?? '';
    // Replay protection
    if (msgId.isNotEmpty && await store.isSeen(msgId)) {
      DiagLog.add('proto', 'replay $msgId');
      return;
    }
    if (msgId.isNotEmpty) await store.markSeen(msgId);

    // Rate limiting
    _eventCtrl.add(MsgEvent.payload(from, plain));
  }

  void _handleAck(Map<String, dynamic> json) async {
    final msgId = json['id'] as String? ?? '';
    if (msgId.isEmpty) return;
    _pendingAck.remove(msgId);
    try {
      await store.markDelivered(msgId);
      DiagLog.add('proto', 'ack $msgId');
    } catch (e) {
      DiagLog.add('proto', 'ack error for $msgId: $e');
    }
  }

  Future<void> _handleSyncReq(Map<String, dynamic> json,
      Socket? sock, String? dialPeerId) async {
    final peerId = json['from'] as String? ?? dialPeerId ?? '';
    final since = json['since'] as int? ?? 0;
    if (peerId.isEmpty || account == null) return;
    final known = await store.getPeer(peerId);
    if (known == null || known['trusted'] != 1) return;
    if (known['account_id'] != account!.id) return;

    final msgs = await store.db.query('messages',
        where: 'ts > ?', whereArgs: [since],
        orderBy: 'ts ASC', limit: 200);
    final out = msgs.map((r) => {
      'id': r['id'], 'chat_id': r['chat_id'], 'sender_id': r['sender_id'],
      'kind': r['kind'], 'text': r['text'], 'file_name': r['file_name'],
      'file_bytes': r['file_bytes'], 'duration_ms': r['duration_ms'],
      'ts': r['ts'], 'outgoing': r['outgoing'],
    }).toList();
    final cursor = out.isNotEmpty ? out.last['ts'] as int : since;
    if (sock != null) {
      try {
        sock.add(Mesh.encode({
          't': P.syncMsgs, 'from': mesh.device.id,
          'messages': out, 'cursor': cursor,
        }));
      } catch (_) {}
    }
    DiagLog.add('sync', 'sent ${out.length} msgs');
  }

  Future<void> _handleSyncMsgs(Map<String, dynamic> json,
      String? dialPeerId) async {
    final peerId = json['from'] as String? ?? dialPeerId ?? '';
    final messages = json['messages'] as List<dynamic>? ?? [];
    final cursor = json['cursor'] as int? ?? 0;
    if (peerId.isEmpty || account == null) return;
    final known = await store.getPeer(peerId);
    if (known == null || known['trusted'] != 1) return;
    if (known['account_id'] != account!.id) return;

    for (final m in messages) {
      final row = m as Map<String, dynamic>;
      final msgId = row['id'] as String;
      final chatId = row['chat_id'] as String;
      final senderId = row['sender_id'] as String;
      // H2: Replay protection — skip already-seen messages
      if (msgId.isNotEmpty && await store.isSeen(msgId)) continue;
      if (msgId.isNotEmpty) await store.markSeen(msgId);
      // Ensure peer exists
      if (await store.getPeer(chatId) == null && chatId != mesh.device.id) {
        await store.upsertPeer({
          'id': chatId, 'name': row['peer_name'] ?? 'Unknown',
          'handle': '', 'account_id': '', 'sign_pub': '',
          'status': '', 'pub': '', 'fingerprint': '',
          'trusted': 1, 'last_seen': DateTime.now().millisecondsSinceEpoch,
        });
      }
      await store.insertMessage({
        'id': row['id'], 'chat_id': chatId, 'sender_id': senderId,
        'kind': row['kind'], 'text': row['text'],
        'file_name': row['file_name'], 'file_bytes': row['file_bytes'],
        'duration_ms': row['duration_ms'], 'ts': row['ts'],
        'outgoing': senderId == mesh.device.id ? 1 : 0,
        'delivered': 1,
      });
    }
    if (cursor > 0) await store.setSyncTs(peerId, cursor);
    DiagLog.add('sync', 'stored ${messages.length} msgs');
  }

  // ---- Queue flush ----

  /// Flush queue for a specific peer.
  Future<void> flushQueue(String peerId) async {
    final queued = await store.queuedMessages(peerId);
    if (queued.isEmpty) return;
    final peer = mesh.currentPeers.where((p) => p.id == peerId).firstOrNull;
    if (peer == null) return;
    DiagLog.add('queue', 'flushing ${queued.length} queued msgs for $peerId');
    for (final row in queued) {
      final id = row['id'] as int;
      final attempts = row['attempts'] as int;
      if (attempts >= P.maxQueueAttempts) {
        await store.removeQueued(id);
        continue;
      }
      try {
        final json = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        if (json.containsKey('queued')) {
          final plain = json['queued'] as Map<String, dynamic>;
          final ok = await send(peer, plain);
          if (ok) {
            await store.removeQueued(id);
            DiagLog.add('queue', 'flushed $id for $peerId');
          } else {
            await store.incrementQueueAttempt(id);
          }
        }
      } catch (_) {
        await store.incrementQueueAttempt(id);
      }
    }
  }

  /// Flush queues for all online peers (called on reconnect/discovery).
  Future<void> flushAllQueues() async {
    final allQueued = await store.allQueuedMessages();
    if (allQueued.isEmpty) return;
    final peerIds = allQueued.map((r) => r['peer_id'] as String).toSet();
    for (final peerId in peerIds) {
      await flushQueue(peerId);
    }
  }

  /// Called when a peer is discovered. Auto-flush queue for that peer.
  Future<void> onPeerDiscovered(String peerId) async {
    final count = await store.queueCount(peerId);
    if (count > 0) {
      DiagLog.add('queue', 'peer $peerId online, flushing $count queued msgs');
      await flushQueue(peerId);
    }
  }

  // ---- Sync ----

  Future<void> startSync(Peer peer) async {
    if (account == null) return;
    final lastTs = await store.lastSyncTs(peer.id);
    await mesh.sendFrame(peer, {
      't': P.syncReq, 'from': mesh.device.id, 'since': lastTs,
    });
  }

  // ---- Typing ----

  void sendTyping(Peer peer) {
    mesh.sendUdp(peer, [P.udpTyping]);
  }

  // ---- Helpers ----

  void _checkAcks() {
    final cutoff = DateTime.now().subtract(Duration(seconds: P.ackTimeoutSec));
    _pendingAck.removeWhere((_, sent) => sent.isBefore(cutoff));
  }

  String? _findPeerByHost(String host) {
    for (final p in mesh.currentPeers) {
      if (p.host == host) return p.id;
    }
    for (final e in mesh.sockets.entries) {
      try {
        if (e.value.remoteAddress.address == host) return e.key;
      } catch (_) {}
    }
    return null;
  }
}

class _UdpPending {
  final String msgId;
  final Peer peer;
  final Uint8List data;
  int attempts;
  Timer? timer;
  _UdpPending(this.msgId, this.peer, this.data, this.attempts);
}

/// Events from the message bus.
class MsgEvent {
  final String type;
  final String? peerId;
  final Map<String, dynamic>? payload;

  MsgEvent._(this.type, {this.peerId, this.payload});
  factory MsgEvent.payload(String peerId, Map<String, dynamic> data) =>
      MsgEvent._('payload', peerId: peerId, payload: data);
  factory MsgEvent.typing(String peerId) =>
      MsgEvent._('typing', peerId: peerId);
}
