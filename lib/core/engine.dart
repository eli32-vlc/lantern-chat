import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nsd/nsd.dart';
import 'package:uuid/uuid.dart';

import 'compat.dart';
import 'diag.dart';
import 'identity.dart';
import 'protocol.dart';
import 'store.dart';

/// Live peer seen on the LAN via mDNS.
class LanPeer {
  final String id;
  final String name;
  final String handle; // cryptographic short handle
  final String accountId; // account UUID (shared across devices)
  final String status;
  final String host;
  final int port;
  final String pubB64;
  final int version;
  DateTime lastSeen;

  LanPeer({
    required this.id,
    required this.name,
    required this.handle,
    this.accountId = '',
    required this.status,
    required this.host,
    required this.port,
    required this.pubB64,
    required this.version,
  }) : lastSeen = DateTime.now();

  String get key => '$id@$host:$port';
}

/// Incoming decrypted event from the transport.
class LanEvent {
  final String peerId;
  final Map<String, dynamic> json;

  LanEvent(this.peerId, this.json);
}

Uint8List _txtBytes(String s) => Uint8List.fromList(utf8.encode(s));
String _txtString(Uint8List? b) =>
    b == null ? '' : utf8.decode(b, allowMalformed: true);

/// Owns: TCP server, mDNS register+discovery, per-peer sessions.
///
/// Security model:
/// - `hello` frames are plaintext JSON: {t:'hello', id, name, pk, v}
/// - `payload` frames are base64 AES-GCM sealed blobs.
/// - First contact: TOFU prompt with fingerprint; stored pin in sqlite.
/// - Changed key for a known id => untrust + surface warning.
///
/// Compat: [compat] (AirchatCompatServer) runs alongside on the same port
/// family and speaks the observed plaintext framings (lines / ndjson /
/// lenprefix-JSON) so stock AirChat apps can message back. Compat traffic
/// is NEVER mixed into E2EE sessions — separate events, separate UI.
class LanEngine {
  final DeviceIdentity me;
  final ChatStore store;
  AccountIdentity? account;
  String displayName;
  String status;

  ServerSocket? _server;
  Registration? _reg;
  Registration? _regAirchat; // AirChat compat mDNS registration
  Discovery? _discovery;
  Timer? _prune;

  final _peers = <String, LanPeer>{};
  final _peerCtrl = StreamController<List<LanPeer>>.broadcast();
  final _eventCtrl = StreamController<LanEvent>.broadcast();
  final _pendingTrust = StreamController<LanPeer>.broadcast();

  /// sessionKey cache per peer id
  final _sessions = <String, List<int>>{};
  final _sockets = <String, Socket>{};
  /// Tracks which sockets we already replied 'hello' on — prevents the
  /// hello echo storm (A→B hello, B replies hello, A replies hello…).
  final _helloReplied = <Socket, DateTime>{};
  /// Pending delivery acks: msgId → send time. Expired after 30s.
  final _pendingAcks = <String, DateTime>{};
  Timer? _ackTimer;

  Stream<List<LanPeer>> get peers => _peerCtrl.stream;
  Stream<LanEvent> get events => _eventCtrl.stream;
  Stream<LanPeer> get pendingTrust => _pendingTrust.stream;
  List<LanPeer> get currentPeers => _peers.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  LanEngine({
    required this.me,
    required this.store,
    required this.displayName,
    required this.status,
  });

  int get port => _server?.port ?? 0;

  Future<Map<String, Uint8List?>> _txt(int p) async => {
        LanternProtocol.txtId: _txtBytes(me.id),
        LanternProtocol.txtName: _txtBytes(displayName),
        LanternProtocol.txtStatus: _txtBytes(status),
        LanternProtocol.txtPort: _txtBytes('$port'),
        LanternProtocol.txtPub: _txtBytes(await me.publicKeyB64),
        LanternProtocol.txtHandle: _txtBytes(await me.handle),
        if (account != null) ...{
          LanternProtocol.txtAccountId: _txtBytes(account!.id),
        },
        LanternProtocol.txtVer: _txtBytes('${LanternProtocol.protoVersion}'),
      };

  /// Guarded start: NEVER throws. On failure records the cause in DiagLog,
  /// marks [startError], and still notifies so the Peers tab shows the
  /// real reason instead of an infinite spinner (the old white-screen).
  String? startError;
  bool starting = false;

  Future<void> start() async {
    if (starting) return;
    starting = true;
    startError = null;
    try {
      DiagLog.add('engine', 'start');
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0,
          backlog: LanternProtocol.tcpBacklog);
      DiagLog.add('engine', 'listening on port $port');
      _server!.listen(_onInbound);

      // Register on BOTH _lantern._tcp (our native protocol) and _airchat._tcp
      // so AirChat can discover us as a peer on the LAN.
      final svc = Service(
        name: '${LanternProtocol.serviceNamePrefix}${me.id.substring(0, 8)}',
        type: LanternProtocol.serviceType,
        port: port,
        txt: await _txt(port),
      );
      try {
        _reg = await register(svc);
        DiagLog.add(
            'mdns', 'registered ${svc.name} type=${svc.type} port=$port');
      } catch (e) {
        DiagLog.add('mdns', 'register failed: $e');
      }
      // AirChat compat registration: same port, AirChat-style TXT keys.
      try {
        final airchatSvc = Service(
          name: displayName,
          type: '_airchat._tcp',
          port: port,
          txt: {
            'id': _txtBytes(me.id),
            'name': _txtBytes(displayName),
          },
        );
        _regAirchat = await register(airchatSvc);
        DiagLog.add('mdns',
            'registered ${airchatSvc.name} type=_airchat._tcp port=$port');
      } catch (e) {
        DiagLog.add('mdns', 'airchat register failed: $e');
      }

      try {
        _discovery = await startDiscovery(LanternProtocol.serviceType,
            autoResolve: true, ipLookupType: IpLookupType.v4);
        DiagLog.add('mdns', 'browsing ${LanternProtocol.serviceType}');
        _discovery!.addServiceListener(_onServiceEvent);
        // seed with already-found services
        for (final s in _discovery!.services) {
          _onService(s);
        }
      } catch (e) {
        DiagLog.add('mdns', 'browse failed: $e');
        startError = 'Discovery failed: $e';
      }

      _prune ??= Timer.periodic(const Duration(seconds: 15), (_) {
        final cutoff =
            DateTime.now().subtract(const Duration(seconds: 60));
        _peers.removeWhere((_, p) => p.lastSeen.isBefore(cutoff));
        if (!_peerCtrl.isClosed) _peerCtrl.add(currentPeers);
      });
      _ackTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
        final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
        _pendingAcks.removeWhere((_, sent) => sent.isBefore(cutoff));
      });
    } catch (e) {
      startError = '$e';
      DiagLog.add('engine', 'start FAILED: $e');
    } finally {
      starting = false;
      if (!_peerCtrl.isClosed) _peerCtrl.add(currentPeers);
    }
  }

  Future<void> updateProfile(String name, String st) async {
    displayName = name;
    status = st;
    // Re-register TXT on the same port. Simplest reliable path: full restart.
    await stop();
    await start();
  }

  Future<void> _onServiceEvent(Service s, ServiceStatus st) async {
    DiagLog.add(
        'mdns', '${st.name} name=${s.name} host=${s.host} port=${s.port}');
    if (st == ServiceStatus.lost) {
      _peers.removeWhere((_, p) => p.name == s.name);
      if (!_peerCtrl.isClosed) _peerCtrl.add(currentPeers);
      return;
    }
    await _onService(s);
  }

  Future<void> _onService(Service s) async {
    try {
      final txt = s.txt ?? {};
      final id = _txtString(txt[LanternProtocol.txtId]);
      String? rHost = s.host;
      // Prefer resolved IPv4 address when available
      if (s.addresses != null && s.addresses!.isNotEmpty) {
        final v4 = s.addresses!.where(
            (a) => a.type == InternetAddressType.IPv4 && !a.isLoopback);
        if (v4.isNotEmpty) rHost = v4.first.address;
      }
      final portTxt = _txtString(txt[LanternProtocol.txtPort]);
      final rPort = int.tryParse(portTxt) ?? s.port ?? 0;
      DiagLog.add('mdns',
          'resolve name=${s.name} host=$rHost port=$rPort txtKeys=${txt.keys.join(',')}');
      if (id.isEmpty || id == me.id) return; // ignore self
      String? host = rHost;
      final port = rPort;
      if (host == null || host.isEmpty || port == 0) return;
      // Skip unresolved mdns hostnames we can't dial directly
      if (host.endsWith('.local') || host.endsWith('.local.')) {
        try {
          final resolved =
              await InternetAddress.lookup(host.replaceAll(RegExp(r'\.$'), ''));
          final v4 = resolved.where(
              (a) => a.type == InternetAddressType.IPv4 && !a.isLoopback);
          if (v4.isEmpty) return;
          host = v4.first.address;
        } catch (_) {
          return;
        }
      }
      final peer = LanPeer(
        id: id,
        name: _txtString(txt[LanternProtocol.txtName]).isEmpty
            ? 'Lantern user'
            : _txtString(txt[LanternProtocol.txtName]),
        handle: _txtString(txt[LanternProtocol.txtHandle]),
        accountId: _txtString(txt[LanternProtocol.txtAccountId]),
        status: _txtString(txt[LanternProtocol.txtStatus]),
        host: host,
        port: port,
        pubB64: _txtString(txt[LanternProtocol.txtPub]),
        version:
            int.tryParse(_txtString(txt[LanternProtocol.txtVer])) ?? 1,
      );
      final isNew = !_peers.containsKey(peer.key);
      // expire older entries for same id on different addr
      _peers.removeWhere((k, v) => v.id == peer.id && k != peer.key);
      _peers[peer.key] = peer;
      if (!_peerCtrl.isClosed) _peerCtrl.add(currentPeers);

      if (peer.pubB64.isNotEmpty) {
        final rawPub = base64Decode(peer.pubB64);
        final fp = await DeviceIdentity.fingerprint(rawPub);
        final known = await store.getPeer(id);
        if (known == null) {
          await store.upsertPeer(KnownPeer(
            id: id,
            name: peer.name,
            handle: peer.handle,
            accountId: peer.accountId,
            status: peer.status,
            pubB64: peer.pubB64,
            fingerprint: fp,
            trusted: false,
            lastSeen: DateTime.now().millisecondsSinceEpoch,
          ));
          if (isNew && !_pendingTrust.isClosed) _pendingTrust.add(peer);
        } else if (known.pubB64 != peer.pubB64) {
          await store.upsertPeer(KnownPeer(
            id: id,
            name: peer.name,
            handle: peer.handle,
            accountId: peer.accountId,
            status: peer.status,
            pubB64: peer.pubB64,
            fingerprint: fp,
            trusted: false,
            lastSeen: DateTime.now().millisecondsSinceEpoch,
          ));
          _sessions.remove(id);
          if (!_pendingTrust.isClosed) _pendingTrust.add(peer);
        } else {
          await store.upsertPeer(KnownPeer(
            id: known.id,
            name: peer.name,
            handle: peer.handle.isNotEmpty ? peer.handle : known.handle,
            accountId: peer.accountId.isNotEmpty ? peer.accountId : known.accountId,
            status: peer.status,
            pubB64: known.pubB64,
            fingerprint: known.fingerprint,
            trusted: known.trusted,
            lastSeen: DateTime.now().millisecondsSinceEpoch,
          ));
        }
      }
      // Trigger sync with same-account peers
      if (peer.accountId.isNotEmpty &&
          account != null &&
          peer.accountId == account!.id) {
        _startSync(id);
      }
    } catch (_) {
      // ignore malformed services
    }
  }

  /// Initiate sync with a same-account peer.
  Future<void> _startSync(String peerId) async {
    if (account == null) return;
    // Find the peer in our live peer list
    final peer = _peers.values.where((p) => p.id == peerId).firstOrNull;
    if (peer == null) return;
    final lastTs = await store.getLastSyncTs(peerId);
    DiagLog.add('sync', 'starting sync with $peerId, since=$lastTs');
    final sock = await _dial(peer);
    if (sock == null) return;
    try {
      sock.add(LanternProtocol.encodeFrame({
        't': 'sync_req',
        'from': me.id,
        'since': lastTs,
      }));
    } catch (_) {}
  }

  // ---------- sockets ----------

  void _onInbound(Socket sock) {
    DiagLog.add('tcp',
        'inbound from ${sock.remoteAddress.address}:${sock.remotePort}');
    // Hand inbound sockets to the compat sniffer FIRST: if the first bytes
    // are not Lantern framing, the compat server answers in plaintext
    // (lines/ndjson/lenprefix) instead of dropping a "silent server".
    CompatSniffer.route(sock, onLantern: (s) {
      final reader = FrameReader();
      s.listen((chunk) async {
        try {
          for (final frame in reader.feed(Uint8List.fromList(chunk))) {
            DiagLog.add('tcp',
                'inbound frame ${frame.length}B preview=${DiagLog.preview(frame, 120)}');
            await _onFrame(s, null, frame);
          }
        } catch (_) {
          try {
            s.destroy();
          } catch (_) {}
        }
      }, onError: (_) {
        try {
          s.destroy();
        } catch (_) {}
      }, onDone: () {
        try {
          s.destroy();
        } catch (_) {}
      });
    });
  }

  Future<Socket?> _dial(LanPeer peer) async {
    final known = _sockets[peer.id];
    if (known != null) {
      // Verify socket is still alive before reusing.
      try {
        await known.done.timeout(Duration.zero);
        // Future completed => socket is dead; remove and dial fresh.
        if (_sockets[peer.id] == known) _sockets.remove(peer.id);
      } on TimeoutException {
        // Timeout => socket is still open (expected). Reuse it.
        return known;
      } catch (_) {
        if (_sockets[peer.id] == known) _sockets.remove(peer.id);
      }
    }
    try {
      final sock = await Socket.connect(peer.host, peer.port,
          timeout: const Duration(seconds: 5));
      _sockets[peer.id] = sock;
      final reader = FrameReader();
      sock.listen((chunk) async {
        try {
          for (final frame in reader.feed(Uint8List.fromList(chunk))) {
            await _onFrame(sock, peer.id, frame);
          }
        } catch (_) {
          _sockets.remove(peer.id);
          try {
            sock.destroy();
          } catch (_) {}
        }
      }, onError: (_) {
        _sockets.remove(peer.id);
      }, onDone: () {
        _sockets.remove(peer.id);
      });
      sock.add(LanternProtocol.encodeFrame({
        't': 'hello',
        'id': me.id,
        'nm': displayName,
        'pk': await me.publicKeyB64,
        if (account != null) ...{
          'ah': await account!.handle,
          'aid': account!.id,
        },
        'v': LanternProtocol.protoVersion,
      }));
      return sock;
    } catch (_) {
      _sockets.remove(peer.id);
      return null;
    }
  }

  Future<List<int>?> _sessionFor(String peerId, String peerPubB64) async {
    if (_sessions.containsKey(peerId)) return _sessions[peerId];
    final known = await store.getPeer(peerId);
    if (known == null || !known.trusted) return null;
    final key = await me.sharedKey(base64Decode(peerPubB64));
    _sessions[peerId] = key;
    return key;
  }

  Future<void> _onFrame(
      Socket sock, String? dialPeerId, Uint8List frame) async {
    Map<String, dynamic> json;
    try {
      json = decodeJson(frame);
      DiagLog.add('proto', 'frame t=${json['t']} keys=${json.keys.join(',')}');
    } catch (_) {
      DiagLog.add('proto',
          'non-JSON frame ${frame.length}B preview=${DiagLog.preview(frame, 160)}');
      return;
    }
    final t = json['t'] as String?;
    if (t == 'hello') {
      final id = json['id'] as String? ?? '';
      final pk = json['pk'] as String? ?? '';
      final ah = json['ah'] as String? ?? '';
      final aid = json['aid'] as String? ?? '';
      if (id.isEmpty || pk.isEmpty || id == me.id) return;
      // Track inbound socket by peer id so sendTo can reuse it.
      // This prevents duplicate dials and the hello echo loop.
      if (dialPeerId == null && !_sockets.containsKey(id)) {
        _sockets[id] = sock;
        // Clean up socket tracking when the peer disconnects.
        sock.done.then((_) {
          if (_sockets[id] == sock) _sockets.remove(id);
        }).catchError((_) {});
      }
      // Reply hello ONCE per socket: the other side does the same,
      // breaking the A→B→A→B… echo storm.
      final lastReplied = _helloReplied[sock];
      if (lastReplied == null ||
          DateTime.now().difference(lastReplied) > const Duration(seconds: 10)) {
        _helloReplied[sock] = DateTime.now();
        try {
          sock.add(LanternProtocol.encodeFrame({
            't': 'hello',
            'id': me.id,
            'nm': displayName,
            'pk': await me.publicKeyB64,
            if (account != null) ...{
              'ah': await account!.handle,
              'aid': account!.id,
            },
            'v': LanternProtocol.protoVersion,
          }));
        } catch (_) {}
      }
      // Always cache the session key when we know the peer's public key.
      // Trust is checked later in the payload handler.
      if (pk.isNotEmpty) {
        try {
          _sessions[id] = await me.sharedKey(base64Decode(pk));
        } catch (_) {}
      }
      // Update peer's handle and account ID from hello frame.
      if (ah.isNotEmpty || aid.isNotEmpty) {
        final existing = await store.getPeer(id);
        if (existing != null) {
          await store.upsertPeer(KnownPeer(
            id: existing.id,
            name: existing.name,
            handle: ah.isNotEmpty ? ah : existing.handle,
            accountId: aid.isNotEmpty ? aid : existing.accountId,
            status: existing.status,
            pubB64: existing.pubB64,
            fingerprint: existing.fingerprint,
            trusted: existing.trusted,
            lastSeen: existing.lastSeen,
          ));
        }
      }
      return;
    }
    if (t == 'payload') {
      final from = json['from'] as String? ?? dialPeerId ?? '';
      final blob = json['blob'] as String? ?? '';
      if (from.isEmpty || blob.isEmpty || from == me.id) return;
      final known = await store.getPeer(from);
      if (known == null || !known.trusted) return;
      if (known.pubB64.isEmpty) return;
      final key = await _sessionFor(from, known.pubB64);
      if (key == null) return;
      try {
        final plain = await PayloadBox.open(key, base64Decode(blob));
        // Send delivery ack so the sender knows the message was received.
        final msgId = plain['id'] as String?;
        if (msgId != null && msgId.isNotEmpty) {
          try {
            sock.add(LanternProtocol.encodeFrame({
              't': 'ack',
              'id': msgId,
            }));
          } catch (_) {}
        }
        if (!_eventCtrl.isClosed) _eventCtrl.add(LanEvent(from, plain));
      } catch (_) {
        // bad MAC => drop
      }
      return;
    }
    if (t == 'ack') {
      final msgId = json['id'] as String? ?? '';
      if (msgId.isEmpty) return;
      _pendingAcks.remove(msgId);
      await store.db.update('messages', {'delivered': 1},
          where: 'id = ?', whereArgs: [msgId]);
      DiagLog.add('proto', 'ack received for $msgId');
      return;
    }
    // ---- Sync: same-account devices exchange message history ----
    if (t == 'sync_req') {
      final peerId = json['from'] as String? ?? dialPeerId ?? '';
      final since = json['since'] as int? ?? 0;
      if (peerId.isEmpty) return;
      // Only sync with same-account peers that are trusted
      if (account == null) return;
      final peerKnown = await store.getPeer(peerId);
      if (peerKnown == null || !peerKnown.trusted) return;
      if (peerKnown.accountId != account!.id) return;
      DiagLog.add('sync', 'sync_req from $peerId since=$since');
      // Fetch messages newer than 'since'
      final msgs = await store.db.query('messages',
          where: 'ts > ?', whereArgs: [since], orderBy: 'ts ASC', limit: 500);
      final List<Map<String, dynamic>> outMsgs = [];
      for (final row in msgs) {
        outMsgs.add({
          'id': row['id'] as String,
          'chat_id': row['chat_id'] as String,
          'sender_id': row['sender_id'] as String,
          'kind': row['kind'] as String,
          'text': row['text'] as String?,
          'file_name': row['file_name'] as String?,
          'file_bytes': row['file_bytes'] as int?,
          'duration_ms': row['duration_ms'] as int?,
          'ts': row['ts'] as int,
          'outgoing': row['outgoing'] as int,
        });
      }
      final cursor = outMsgs.isNotEmpty
          ? (outMsgs.last['ts'] as int)
          : since;
      try {
        sock.add(LanternProtocol.encodeFrame({
          't': 'sync_msgs',
          'from': me.id,
          'messages': outMsgs,
          'cursor': cursor,
        }));
      } catch (_) {}
      DiagLog.add('sync', 'sent ${outMsgs.length} msgs, cursor=$cursor');
      return;
    }
    if (t == 'sync_msgs') {
      final peerId = json['from'] as String? ?? dialPeerId ?? '';
      final messages = json['messages'] as List<dynamic>? ?? [];
      final cursor = json['cursor'] as int? ?? 0;
      if (peerId.isEmpty) return;
      // Only accept sync from same-account peers
      if (account == null) return;
      final peerKnown = await store.getPeer(peerId);
      if (peerKnown == null || !peerKnown.trusted) return;
      if (peerKnown.accountId != account!.id) return;
      DiagLog.add('sync',
          'sync_msgs from $peerId: ${messages.length} msgs, cursor=$cursor');
      int stored = 0;
      for (final m in messages) {
        final row = m as Map<String, dynamic>;
        final msgId = row['id'] as String;
        final origChatId = row['chat_id'] as String;
        final senderId = row['sender_id'] as String;
        final isFromMe = senderId == peerId;
        // Resolve the chat ID on this device:
        // - If message is from the sync peer (peerId), use origChatId
        //   (the peer we're syncing from was the sender)
        // - Otherwise it's a message I sent to someone else; use origChatId
        final chatId = origChatId;
        // Ensure the peer exists in our DB
        final existingPeer = await store.getPeer(chatId);
        if (existingPeer == null && chatId != me.id) {
          // Create a placeholder peer entry
          final handle = row['handle'] as String? ?? '';
          await store.upsertPeer(KnownPeer(
            id: chatId,
            name: row['peer_name'] as String? ?? 'Unknown',
            handle: handle,
            accountId: '',
            status: '',
            pubB64: '',
            fingerprint: '',
            trusted: false,
            lastSeen: DateTime.now().millisecondsSinceEpoch,
          ));
        }
        // Determine if this message is outgoing on this device
        final outgoing = isFromMe ? 0 : (senderId == me.id ? 1 : 0);
        await store.insertMessage(ChatMessage(
          id: msgId,
          chatId: chatId,
          senderId: senderId,
          kind: LanternMsgKindX.fromWire(row['kind'] as String?),
          text: row['text'] as String?,
          fileName: row['file_name'] as String?,
          fileBytes: row['file_bytes'] as int?,
          durationMs: row['duration_ms'] as int?,
          ts: row['ts'] as int,
          outgoing: outgoing == 1,
          delivered: true,
        ));
        stored++;
      }
      // Update sync cursor
      if (cursor > 0) {
        await store.setLastSyncTs(peerId, cursor);
      }
      DiagLog.add('sync', 'stored $stored msgs from $peerId');
      if (!_peerCtrl.isClosed) _peerCtrl.add(currentPeers);
      return;
    }
    // ---- Group protocol ----
    if (t == 'group_invite') {
      final from = json['from'] as String? ?? dialPeerId ?? '';
      final gid = json['gid'] as String? ?? '';
      final gname = json['gname'] as String? ?? 'Group';
      final gsecB64 = json['gsec'] as String? ?? '';
      if (from.isEmpty || gid.isEmpty || gsecB64.isEmpty) return;
      // Must be from a trusted peer
      final known = await store.getPeer(from);
      if (known == null || !known.trusted) return;
      // Decrypt the group secret with our pairwise key
      final key = await _sessionFor(from, known.pubB64);
      if (key == null) return;
      try {
        final plain = await PayloadBox.open(key, base64Decode(gsecB64));
        final groupSecret = base64Decode(plain['secret'] as String);
        // Store the group
        await store.storeGroup(gid, gname, groupSecret, createdBy: from);
        await store.addGroupMember(gid, from, role: 'admin');
        await store.addGroupMember(gid, me.id);
        DiagLog.add('group', 'joined group $gname ($gid)');
        if (!_peerCtrl.isClosed) _peerCtrl.add(currentPeers);
      } catch (e) {
        DiagLog.add('group', 'invite decrypt failed: $e');
      }
      return;
    }
    if (t == 'group_leave') {
      final from = json['from'] as String? ?? dialPeerId ?? '';
      final gid = json['gid'] as String? ?? '';
      if (from.isEmpty || gid.isEmpty) return;
      await store.removeGroupMember(gid, from);
      DiagLog.add('group', '$from left group $gid');
      return;
    }
    if (t == 'group_key_rotate') {
      final from = json['from'] as String? ?? dialPeerId ?? '';
      final gid = json['gid'] as String? ?? '';
      final gsecB64 = json['gsec'] as String? ?? '';
      if (from.isEmpty || gid.isEmpty || gsecB64.isEmpty) return;
      final known = await store.getPeer(from);
      if (known == null || !known.trusted) return;
      final key = await _sessionFor(from, known.pubB64);
      if (key == null) return;
      try {
        final plain = await PayloadBox.open(key, base64Decode(gsecB64));
        final newSecret = base64Decode(plain['secret'] as String);
        await store.storeGroup(gid, '', newSecret, createdBy: from);
        DiagLog.add('group', 'key rotated for $gid');
      } catch (_) {}
      return;
    }
  }

  /// Send an encrypted payload to a peer. Requires trusted pin.
  Future<bool> sendTo(LanPeer peer, Map<String, dynamic> payload) async {
    final known = await store.getPeer(peer.id);
    if (known == null || !known.trusted) return false;
    final key = await _sessionFor(peer.id, known.pubB64);
    if (key == null) return false;
    final sealed = await PayloadBox.seal(key, payload);
    final frame = LanternProtocol.encodeFrame({
      't': 'payload',
      'from': me.id,
      'blob': base64Encode(sealed),
    });
    final sock = await _dial(peer);
    if (sock == null) return false;
    try {
      sock.add(frame);
      await sock.flush();
      // Track for delivery ack (timeout after 30s).
      final msgId = payload['id'] as String?;
      if (msgId != null) {
        _pendingAcks[msgId] = DateTime.now();
      }
      return true;
    } catch (_) {
      _sockets.remove(peer.id);
      return false;
    }
  }

  Future<void> trust(LanPeer peer) async {
    await store.trustPeer(peer.id, true);
    if (peer.pubB64.isNotEmpty) {
      _sessions[peer.id] = await me.sharedKey(base64Decode(peer.pubB64));
    }
  }

  // ---- Group operations ----

  /// Create a group and invite initial members.
  Future<String> createGroup(String name, List<String> memberIds) async {
    final gid = 'grp-${const Uuid().v4()}';
    final secret = List<int>.generate(32, (_) => _secureRng.nextInt(256));
    // Store locally
    await store.storeGroup(gid, name, secret, createdBy: me.id);
    await store.addGroupMember(gid, me.id, role: 'admin');
    for (final mid in memberIds) {
      await store.addGroupMember(gid, mid);
    }
    // Send invites to all members
    final secretB64 = base64Encode(secret);
    // Encrypt with each member's pairwise key
    for (final mid in memberIds) {
      final known = await store.getPeer(mid);
      if (known == null || !known.trusted) continue;
      final key = await _sessionFor(mid, known.pubB64);
      if (key == null) continue;
      final sealed = await PayloadBox.seal(key, {'secret': secretB64});
      final peer = _peers.values.where((p) => p.id == mid).firstOrNull;
      if (peer == null) continue;
      final sock = await _dial(peer);
      if (sock == null) continue;
      try {
        sock.add(LanternProtocol.encodeFrame({
          't': 'group_invite',
          'from': me.id,
          'gid': gid,
          'gname': name,
          'gsec': base64Encode(sealed),
        }));
      } catch (_) {}
    }
    DiagLog.add('group', 'created group $name ($gid) with ${memberIds.length} members');
    return gid;
  }

  /// Send a message to a group.
  Future<bool> sendGroupMessage(
      String groupId, List<int> groupSecret, Map<String, dynamic> payload) async {
    final gk = GroupKey(groupSecret);
    final sealed = await gk.encrypt(payload);
    final members = await store.groupMemberIds(groupId);
    var anySent = false;
    for (final mid in members) {
      if (mid == me.id) continue;
      final peer = _peers.values.where((p) => p.id == mid).firstOrNull;
      if (peer == null) continue;
      final sock = await _dial(peer);
      if (sock == null) continue;
      try {
        sock.add(LanternProtocol.encodeFrame({
          't': 'payload',
          'from': me.id,
          'blob': base64Encode(sealed),
          'gid': groupId,
        }));
        anySent = true;
      } catch (_) {}
    }
    return anySent;
  }

  /// Leave a group.
  Future<void> leaveGroup(String groupId) async {
    final members = await store.groupMemberIds(groupId);
    for (final mid in members) {
      if (mid == me.id) continue;
      final peer = _peers.values.where((p) => p.id == mid).firstOrNull;
      if (peer == null) continue;
      final sock = await _dial(peer);
      if (sock == null) continue;
      try {
        sock.add(LanternProtocol.encodeFrame({
          't': 'group_leave',
          'from': me.id,
          'gid': groupId,
        }));
      } catch (_) {}
    }
    await store.removeGroupMember(groupId, me.id);
    // Delete group data if we're the last member
    final remaining = await store.groupMemberIds(groupId);
    if (remaining.isEmpty) {
      await store.db.delete('groups', where: 'id = ?', whereArgs: [groupId]);
    }
  }

  static final _secureRng = Random.secure();

  String messageId() => const Uuid().v4();

  Future<void> stop() async {
    _prune?.cancel();
    _prune = null;
    _ackTimer?.cancel();
    _ackTimer = null;
    if (_discovery != null) {
      try {
        await stopDiscovery(_discovery!);
      } catch (_) {}
      _discovery = null;
    }
    if (_reg != null) {
      try {
        await unregister(_reg!);
      } catch (_) {}
      _reg = null;
    }
    if (_regAirchat != null) {
      try {
        await unregister(_regAirchat!);
      } catch (_) {}
      _regAirchat = null;
    }
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
    for (final s in _sockets.values) {
      try {
        s.destroy();
      } catch (_) {}
    }
    _sockets.clear();
    _helloReplied.clear();
    _pendingAcks.clear();
  }

  void dispose() {
    unawaited(stop());
    _peerCtrl.close();
    _eventCtrl.close();
    _pendingTrust.close();
  }
}
