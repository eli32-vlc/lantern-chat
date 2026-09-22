import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nsd/nsd.dart';
import 'package:uuid/uuid.dart';

import 'content_store.dart';
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
  final int port; // TCP port
  final int udpPort; // UDP port for fast payload delivery
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
    this.udpPort = 0,
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
class LanEngine {
  final DeviceIdentity me;
  final ChatStore store;
  final ContentStore contentStore;
  AccountIdentity? account;
  String displayName;
  String status;

  ServerSocket? _server;
  Registration? _reg;
  Discovery? _discovery;
  Timer? _prune;
  RawDatagramSocket? _udpSocket;
  int _udpPort = 0;

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
  Timer? _healthTimer;
  /// Tracks in-progress syncs to avoid duplicates.
  final _syncing = <String>{};
  /// Sync cooldown: peerId → last sync start time.
  final _syncCooldown = <String, DateTime>{};
  /// Pending UDP acks: msgId -> pending info.
  final _pendingUdpAcks = <String, _UdpPendingAck>{};
  /// Active file transfers: transferId -> state.
  final _fileTransfers = <String, _FileTransferState>{};
  /// Sockets that already have a done handler registered.
  final _doneHandled = <Socket>{};

  Stream<List<LanPeer>> get peers => _peerCtrl.stream;
  Stream<LanEvent> get events => _eventCtrl.stream;
  Stream<LanPeer> get pendingTrust => _pendingTrust.stream;
  List<LanPeer> get currentPeers => _peers.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  LanEngine({
    required this.me,
    required this.store,
    required this.contentStore,
    required this.displayName,
    required this.status,
  });

  int get port => _server?.port ?? 0;
  int get udpPort => _udpPort;

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
        LanternProtocol.txtUdpPort: _txtBytes('$_udpPort'),
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

      // Bind UDP socket for fast payload delivery (send-wait-ack).
      // UDP port = TCP port +1 for easy discovery.
      try {
        _udpSocket = await RawDatagramSocket.bind(
            InternetAddress.anyIPv4, port + 1);
        _udpPort = _udpSocket!.port;
        _udpSocket!.listen(_onUdpDatagram);
        DiagLog.add('udp', 'listening on port $_udpPort');
      } catch (e) {
        DiagLog.add('udp', 'bind failed: $e (TCP-only mode)');
      }

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

      _prune ??= Timer.periodic(const Duration(seconds: 30), (_) {
        final cutoff =
            DateTime.now().subtract(const Duration(minutes: 5));
        _peers.removeWhere((_, p) => p.lastSeen.isBefore(cutoff));
        if (!_peerCtrl.isClosed) _peerCtrl.add(currentPeers);
      });
      _ackTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
        final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
        _pendingAcks.removeWhere((_, sent) => sent.isBefore(cutoff));
      });
      // Periodic socket health check — detect dead connections
      // (e.g., after iOS sleep, network change, peer restart)
      _healthTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
        _checkSocketHealth();
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
    // B44: Don't restart engine — just update mDNS TXT record
    // Preserve session cache and socket pool
    try {
      if (_reg != null) {
        await unregister(_reg!);
      }
      final svc = Service(
        name: '${LanternProtocol.serviceNamePrefix}${me.id.substring(0, 8)}',
        type: LanternProtocol.serviceType,
        port: port,
        txt: await _txt(port),
      );
      _reg = await register(svc);
      DiagLog.add('mdns', 're-registered with new profile');
    } catch (e) {
      DiagLog.add('mdns', 'profile re-register failed: $e');
    }
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
        udpPort: int.tryParse(
                _txtString(txt[LanternProtocol.txtUdpPort])) ??
            0,
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
      // Flush queued messages for this peer
      _flushQueue(id);
      // Announce our content to newly discovered peer
      _announceContent();
    } catch (_) {
      // ignore malformed services
    }
  }

  /// Initiate sync with a same-account peer.
  Future<void> _startSync(String peerId) async {
    if (account == null) return;
    // Debounce: skip if already syncing or cooled down
    if (_syncing.contains(peerId)) return;
    final lastSync = _syncCooldown[peerId];
    if (lastSync != null &&
        DateTime.now().difference(lastSync) < const Duration(seconds: 30)) {
      return;
    }
    // Find the peer in our live peer list
    final peer = _peers.values.where((p) => p.id == peerId).firstOrNull;
    if (peer == null) return;
    final lastTs = await store.getLastSyncTs(peerId);
    DiagLog.add('sync', 'starting sync with $peerId, since=$lastTs');
    _syncing.add(peerId);
    _syncCooldown[peerId] = DateTime.now();
    try {
      final sock = await _dial(peer);
      if (sock == null) return;
      sock.add(LanternProtocol.encodeFrame({
        't': 'sync_req',
        'from': me.id,
        'since': lastTs,
      }));
    } catch (_) {} finally {
      _syncing.remove(peerId);
    }
  }

  /// Flush queued messages for a peer that just came online.
  Future<void> _flushQueue(String peerId) async {
    final queued = await store.queuedMessages(peerId);
    if (queued.isEmpty) return;
    DiagLog.add('queue', 'flushing ${queued.length} queued msgs for $peerId');
    final peer = _peers.values.where((p) => p.id == peerId).firstOrNull;
    if (peer == null) return;
    for (final row in queued) {
      final id = row['id'] as int;
      final frameData = row['frame'] as Uint8List;
      final attempts = row['attempts'] as int;
      if (attempts >= 5) {
        await store.removeQueuedMessage(id);
        continue;
      }
      // B18: Decode and re-encrypt with current session key
      try {
        final json = decodeJson(frameData);
        if (json.containsKey('queued_payload')) {
          final payload =
              Map<String, dynamic>.from(json['queued_payload'] as Map);
          final ok = await sendTo(peer, payload);
          if (ok) {
            await store.removeQueuedMessage(id);
            DiagLog.add('queue', 'delivered queued msg $id');
          } else {
            await store.incrementQueueAttempt(id);
          }
        } else {
          // Legacy: try sending pre-encrypted frame directly
          final sock = await _dial(peer);
          if (sock == null) break;
          try {
            sock.add(frameData);
            await sock.flush();
            await store.removeQueuedMessage(id);
          } catch (_) {
            await store.incrementQueueAttempt(id);
          }
        }
      } catch (_) {
        await store.incrementQueueAttempt(id);
      }
    }
  }

  /// Send typing indicator to a peer.
  void sendTyping(LanPeer peer) {
    if (_udpSocket == null || peer.udpPort == 0) return;
    // Throttle to once per 2 seconds (B17)
    final now = DateTime.now();
    if (_lastTypingSent != null &&
        now.difference(_lastTypingSent!) < _typingThrottle) {
      return;
    }
    _lastTypingSent = now;
    final packet = _buildUdpData(
        'typ-${now.millisecondsSinceEpoch % 10000}',
        Uint8List.fromList([LanternProtocol.udpTypeTyping]));
    _udpSocket!.send(
        packet, InternetAddress(peer.host), peer.udpPort);
  }

  // Typing indicator callback (set by UI)
  void Function(String peerId)? onTyping;
  DateTime? _lastTypingSent;
  static const _typingThrottle = Duration(seconds: 2);

  // PTT callbacks (set by UI)
  void Function(String peerId, List<int> audioData)? onPttData;
  void Function(String peerId)? onPttStart;
  void Function(String peerId)? onPttStop;
  void Function(String peerId, String channel)? onPttPresence;

  /// Send PTT voice data to a peer.
  void sendPttData(LanPeer peer, List<int> audioChunk) {
    if (_udpSocket == null || peer.udpPort == 0) return;
    // Split into sub-1400 byte pieces to avoid UDP fragmentation (B14)
    const maxChunk = 1300; // leave room for header
    for (var i = 0; i < audioChunk.length; i += maxChunk) {
      final end = (i + maxChunk).clamp(0, audioChunk.length);
      final piece = audioChunk.sublist(i, end);
      final packet = _buildUdpData(
          'ptt', Uint8List.fromList([LanternProtocol.udpTypePttData, ...piece]));
      _udpSocket!.send(
          packet, InternetAddress(peer.host), peer.udpPort);
    }
  }

  /// Send PTT start signal.
  void sendPttStart(LanPeer peer) {
    if (_udpSocket == null || peer.udpPort == 0) return;
    final packet = _buildUdpData(
        'ptt', Uint8List.fromList([LanternProtocol.udpTypePttStart]));
    _udpSocket!.send(
        packet, InternetAddress(peer.host), peer.udpPort);
  }

  /// Send PTT stop signal.
  void sendPttStop(LanPeer peer) {
    if (_udpSocket == null || peer.udpPort == 0) return;
    final packet = _buildUdpData(
        'ptt', Uint8List.fromList([LanternProtocol.udpTypePttStop]));
    _udpSocket!.send(
        packet, InternetAddress(peer.host), peer.udpPort);
  }

  /// Send PTT channel presence.
  void sendPttPresence(LanPeer peer, String channel) {
    if (_udpSocket == null || peer.udpPort == 0) return;
    final channelBytes = utf8.encode(channel);
    final packet = _buildUdpData(
        'ptt-pr',
        Uint8List.fromList([LanternProtocol.udpTypePttPresence, ...channelBytes]));
    _udpSocket!.send(
        packet, InternetAddress(peer.host), peer.udpPort);
  }

  // ---- File transfer ----

  /// Progress callback for file transfers (set by UI).
  void Function(String transferId, double progress)? onFileProgress;
  /// Completion callback (set by UI).
  void Function(String transferId, bool success)? onFileComplete;

  /// Offer a file to a peer. Returns transferId.
  /// The file is not sent until the peer accepts.
  Future<String> offerFile(LanPeer peer, String filePath,
      {required String kind, String? text, int? durationMs}) async {
    final transferId = 'ft-${const Uuid().v4()}';
    final file = File(filePath);
    if (!await file.exists()) return transferId;
    final stat = await file.stat();
    final fileName = filePath.split(Platform.pathSeparator).last;

    final ft = _FileTransferState(
      transferId: transferId,
      peerId: peer.id,
      fileName: fileName,
      fileSize: stat.size,
      filePath: filePath,
      kind: kind,
    );
    _fileTransfers[transferId] = ft;

    // Send offer frame via TCP (reliable)
    final sock = await _dial(peer);
    if (sock == null) {
      _fileTransfers.remove(transferId);
      return transferId;
    }
    try {
      sock.add(LanternProtocol.encodeFrame({
        't': LanternProtocol.frameFileOffer,
        'from': me.id,
        'tid': transferId,
        'name': fileName,
        'size': stat.size,
        'kind': kind,
        if (text != null) 'text': text,
        if (durationMs != null) 'dur': durationMs,
      }));
      DiagLog.add('file',
          'offered $fileName (${stat.size}B) to ${peer.id} tid=$transferId');
    } catch (_) {
      _fileTransfers.remove(transferId);
    }
    return transferId;
  }

  /// Start sending file chunks after peer accepts.
  void _startFileSend(_FileTransferState ft) async {
    try {
      final peer = _peers.values.where((p) => p.id == ft.peerId).firstOrNull;
      if (peer == null) {
        if (onFileComplete != null) onFileComplete!(ft.transferId, false);
        _fileTransfers.remove(ft.transferId);
        return;
      }
      final file = File(ft.filePath);
      if (!await file.exists()) {
        if (onFileComplete != null) onFileComplete!(ft.transferId, false);
        _fileTransfers.remove(ft.transferId);
        return;
      }

      final bytes = await file.readAsBytes();
      const chunkSize = 48 * 1024;
      final total = (bytes.length / chunkSize).ceil();

      for (var i = 0; i < total; i++) {
        if (ft.cancelled) break;
        final end = ((i + 1) * chunkSize).clamp(0, bytes.length);
        final chunk = bytes.sublist(i * chunkSize, end);

        final ok = await sendTo(peer, {
          'kind': ft.kind,
          'id': ft.transferId,
          'ts': DateTime.now().millisecondsSinceEpoch,
          'name': ft.fileName,
          'bytes': ft.fileSize,
          'chunk': i,
          'chunks': total,
          'data': base64Encode(chunk),
        });

        ft.bytesSent = end;
        if (onFileProgress != null) {
          onFileProgress!(ft.transferId, ft.progress);
        }

        if (!ok) {
          DiagLog.add('file', 'chunk $i failed for ${ft.transferId}');
          if (onFileComplete != null) onFileComplete!(ft.transferId, false);
          _fileTransfers.remove(ft.transferId);
          return;
        }

        await Future.delayed(const Duration(milliseconds: 50));
      }

      if (!ft.cancelled) {
        if (onFileComplete != null) {
          onFileComplete!(ft.transferId, true);
        }
        DiagLog.add('file', 'sent ${ft.fileName} tid=${ft.transferId}');
      }
      _fileTransfers.remove(ft.transferId);
    } catch (e) {
      DiagLog.add('file', 'send error: $e');
      if (onFileComplete != null) onFileComplete!(ft.transferId, false);
      _fileTransfers.remove(ft.transferId);
    }
  }

  /// Cancel a file transfer.
  void cancelFileTransfer(String transferId) {
    final ft = _fileTransfers[transferId];
    if (ft == null) return;
    ft.cancelled = true;
    ft.chunkTimer?.cancel();

    // Notify peer
    final peer = _peers.values.where((p) => p.id == ft.peerId).firstOrNull;
    if (peer != null) {
      _dial(peer).then((sock) {
        try {
          sock?.add(LanternProtocol.encodeFrame({
            't': LanternProtocol.frameFileCancel,
            'tid': transferId,
          }));
        } catch (_) {}
      });
    }
    _fileTransfers.remove(transferId);
    DiagLog.add('file', 'cancelled $transferId');
  }

  // ---- Content-addressed storage ----

  /// Content change callback (set by UI).
  void Function()? onContentChanged;

  /// Publish a file to the content store and announce to peers.
  Future<String> publishContent(String filePath, {String? name}) async {
    final hash = await contentStore.publish(filePath, name: name);
    _announceContent();
    DiagLog.add('content', 'published $hash from $filePath');
    return hash;
  }

  /// Announce our content to all connected peers.
  Future<void> _announceContent({String? excludePeerId}) async {
    final items = await contentStore.getAnnouncement();
    if (items.isEmpty) return;
    final payload = {
      't': LanternProtocol.frameContentAnnounce,
      'from': me.id,
      'items': items,
    };
    final frame = LanternProtocol.encodeFrame(payload);
    for (final peer in _peers.values) {
      if (peer.id == excludePeerId) continue; // B4: don't echo back
      final sock = await _dial(peer);
      if (sock == null) continue;
      try {
        sock.add(frame);
      } catch (_) {}
    }
    DiagLog.add('content', 'announced ${items.length} items');
  }

  /// Request content from peers.
  Future<void> requestContent(String hash) async {
    final peers = await contentStore.getPeers(hash);
    for (final peerId in peers) {
      final peer = _peers.values.where((p) => p.id == peerId).firstOrNull;
      if (peer == null) continue;
      final sock = await _dial(peer);
      if (sock == null) continue;
      try {
        sock.add(LanternProtocol.encodeFrame({
          't': LanternProtocol.frameContentRequest,
          'from': me.id,
          'hash': hash,
        }));
        DiagLog.add('content', 'requested $hash from $peerId');
      } catch (_) {}
    }
  }

  /// Search for content across peers.
  Future<void> searchContent(String query) async {
    final frame = LanternProtocol.encodeFrame({
      't': LanternProtocol.frameContentSearch,
      'from': me.id,
      'query': query,
    });
    for (final peer in _peers.values) {
      final sock = await _dial(peer);
      if (sock == null) continue;
      try {
        sock.add(frame);
      } catch (_) {}
    }
  }

  /// Delete content from local store.
  Future<void> deleteContent(String hash) async {
    await contentStore.delete(hash);
    if (onContentChanged != null) onContentChanged!();
  }

  /// Verify socket health — removes dead sockets.
  /// Called periodically and on app resume.
  void _checkSocketHealth() {
    final dead = <String>[];
    for (final entry in _sockets.entries) {
      try {
        // Register done handler only once per socket (B39)
        if (!_doneHandled.contains(entry.value)) {
          _doneHandled.add(entry.value);
          entry.value.done.then((_) {
            if (_sockets[entry.key] == entry.value) {
              _sockets.remove(entry.key);
              _helloReplied.remove(entry.value);
              _doneHandled.remove(entry.value);
              DiagLog.add('health', 'removed dead socket for ${entry.key}');
            }
          }).catchError((_) {
            _doneHandled.remove(entry.value);
          });
        }
        // Try a zero-byte write to detect broken pipe
        entry.value.add(Uint8List(0));
      } catch (_) {
        dead.add(entry.key);
      }
    }
    // Apply removals after iteration (B15)
    for (final id in dead) {
      final sock = _sockets.remove(id);
      if (sock != null) {
        _helloReplied.remove(sock);
        _doneHandled.remove(sock);
      }
      _sessions.remove(id);
      DiagLog.add('health', 'cleaned dead socket for $id');
    }
    if (dead.isNotEmpty) {
      DiagLog.add('health', '${dead.length} dead sockets cleaned');
    }
  }

  // ---------- sockets ----------

  void _onInbound(Socket sock) {
    DiagLog.add('tcp',
        'inbound from ${sock.remoteAddress.address}:${sock.remotePort}');
    final reader = FrameReader();
    sock.listen((chunk) async {
      try {
        for (final frame in reader.feed(Uint8List.fromList(chunk))) {
          DiagLog.add('tcp',
              'inbound frame ${frame.length}B preview=${DiagLog.preview(frame, 120)}');
          await _onFrame(sock, null, frame);
        }
      } catch (_) {
        try {
          sock.destroy();
        } catch (_) {}
      }
    }, onError: (_) {
      try {
        sock.destroy();
      } catch (_) {}
    }, onDone: () {
      try {
        sock.destroy();
      } catch (_) {}
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
          'spk': await account!.signPubB64,
        },
        'v': LanternProtocol.protoVersion,
        'av': LanternProtocol.appVersion,
        'ab': LanternProtocol.appBuild,
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
    DiagLog.add('proto', 'frame t=$t from=$dialPeerId');
    if (t == 'hello') {
      final id = json['id'] as String? ?? '';
      final pk = json['pk'] as String? ?? '';
      final ah = json['ah'] as String? ?? '';
      final aid = json['aid'] as String? ?? '';
      final peerVersion = json['v'] as int? ?? 0;
      final peerAppVersion = json['av'] as String? ?? '';
      final peerAppBuild = json['ab'] as int? ?? 0;
      final peerSignPub = json['spk'] as String? ?? '';
      if (id.isEmpty || pk.isEmpty || id == me.id) return;
      // B48: Reject incompatible protocol versions
      if (peerVersion > LanternProtocol.protoVersion) return;
      // Log version info
      if (peerAppVersion.isNotEmpty) {
        DiagLog.add('proto',
            'peer $id version=$peerAppVersion build=$peerAppBuild');
        if (peerAppBuild > LanternProtocol.appBuild) {
          DiagLog.add('proto',
              'WARNING: peer $id has newer version ($peerAppVersion)');
        }
      }
      // Track inbound socket by peer id so sendTo can reuse it.
      // This prevents duplicate dials and the hello echo loop.
      if (dialPeerId == null && !_sockets.containsKey(id)) {
        _sockets[id] = sock;
        sock.done.then((_) {
          if (_sockets[id] == sock) _sockets.remove(id);
        }).catchError((_) {});
      }
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
              'spk': await account!.signPubB64,
            },
            'v': LanternProtocol.protoVersion,
            'av': LanternProtocol.appVersion,
            'ab': LanternProtocol.appBuild,
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
      if (ah.isNotEmpty || aid.isNotEmpty || peerSignPub.isNotEmpty) {
        final existing = await store.getPeer(id);
        if (existing != null) {
          await store.upsertPeer(KnownPeer(
            id: existing.id,
            name: existing.name,
            handle: ah.isNotEmpty ? ah : existing.handle,
            accountId: aid.isNotEmpty ? aid : existing.accountId,
            signPubB64: peerSignPub.isNotEmpty ? peerSignPub : existing.signPubB64,
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
      final sig = json['sig'] as String?;
      final signPubB64 = json['sign_pub'] as String?;
      if (from.isEmpty || blob.isEmpty || from == me.id) return;
      final known = await store.getPeer(from);
      if (known == null || !known.trusted) return;
      if (known.pubB64.isEmpty) return;
      // Verify signature if present (prevents impersonation)
      if (sig != null && signPubB64 != null) {
        final valid = await AccountIdentity.verify(
            base64Decode(blob), sig, signPubB64);
        if (!valid) {
          DiagLog.add('proto', 'INVALID signature from $from — possible impersonation');
          return;
        }
      }
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
      // Fetch messages newer than 'since' (cap at200 per sync)
      final msgs = await store.db.query('messages',
          where: 'ts > ?', whereArgs: [since], orderBy: 'ts ASC', limit: 200);
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
          // Create a placeholder peer entry (trusted if same account)
          final handle = row['handle'] as String? ?? '';
          await store.upsertPeer(KnownPeer(
            id: chatId,
            name: row['peer_name'] as String? ?? 'Unknown',
            handle: handle,
            accountId: '',
            status: '',
            pubB64: '',
            fingerprint: '',
            trusted: true, // same-account sync = auto-trust
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
      // If we're already in the group, only accept invites from admins
      final existingMembers = await store.groupMemberIds(gid);
      if (existingMembers.isNotEmpty && !existingMembers.contains(from)) return;
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
      // Verify sender is an admin of the group
      final members = await store.groupMemberIds(gid);
      if (!members.contains(from)) return;
      final key = await _sessionFor(from, known.pubB64);
      if (key == null) return;
      try {
        final plain = await PayloadBox.open(key, base64Decode(gsecB64));
        final newSecret = base64Decode(plain['secret'] as String);
        // Update secret only (don't overwrite name)
        await store.db.update('groups',
            {'group_secret': Uint8List.fromList(newSecret)},
            where: 'id = ?', whereArgs: [gid]);
        DiagLog.add('group', 'key rotated for $gid');
      } catch (_) {}
      return;
    }
    // ---- File transfer protocol ----
    if (t == LanternProtocol.frameFileOffer) {
      final from = json['from'] as String? ?? dialPeerId ?? '';
      final transferId = json['tid'] as String? ?? '';
      final fileName = json['name'] as String? ?? 'file';
      final fileSize = json['size'] as int? ?? 0;
      if (from.isEmpty || transferId.isEmpty) return;
      // B9: Reject files > 50MB automatically
      if (fileSize > 50 * 1024 * 1024) {
        DiagLog.add('file', 'rejected $fileName ($fileSize bytes) — too large');
        try {
          sock.add(LanternProtocol.encodeFrame({
            't': LanternProtocol.frameFileReject,
            'tid': transferId,
          }));
        } catch (_) {}
        return;
      }
      DiagLog.add('file',
          'offer from $from: $fileName ($fileSize bytes) tid=$transferId');
      // Auto-accept for now (could add UI prompt later)
      try {
        sock.add(LanternProtocol.encodeFrame({
          't': LanternProtocol.frameFileAccept,
          'tid': transferId,
        }));
      } catch (_) {}
      return;
    }
    if (t == LanternProtocol.frameFileAccept) {
      final transferId = json['tid'] as String? ?? '';
      final ft = _fileTransfers[transferId];
      if (ft == null) return;
      DiagLog.add('file', 'accepted tid=$transferId, starting send');
      _startFileSend(ft);
      return;
    }
    if (t == LanternProtocol.frameFileReject) {
      final transferId = json['tid'] as String? ?? '';
      _fileTransfers.remove(transferId);
      DiagLog.add('file', 'rejected tid=$transferId');
      return;
    }
    if (t == LanternProtocol.frameFileCancel) {
      final transferId = json['tid'] as String? ?? '';
      final ft = _fileTransfers.remove(transferId);
      ft?.chunkTimer?.cancel();
      DiagLog.add('file', 'cancelled tid=$transferId');
      return;
    }
    // ---- Content-addressed storage protocol ----
    if (t == LanternProtocol.frameContentAnnounce) {
      final from = json['from'] as String? ?? dialPeerId ?? '';
      final items = json['items'] as List<dynamic>? ?? [];
      if (from.isEmpty) return;
      // B37: Verify peer is trusted
      final knownPeer = await store.getPeer(from);
      if (knownPeer == null || !knownPeer.trusted) return;
      for (final item in items) {
        final m = item as Map<String, dynamic>;
        final hash = m['hash'] as String? ?? '';
        if (hash.isEmpty) continue;
        await contentStore.recordPeer(hash, from);
        // Store metadata if we don't have it yet
        final existing = await contentStore.getContent(hash);
        if (existing == null) {
          await contentStore.importBytes(
            Uint8List(0), // placeholder, no data yet
            name: m['name'] as String? ?? 'unknown',
            mimeType: m['mime'] as String?,
            publishedBy: from,
          );
        }
      }
      DiagLog.add('content', 'announce from $from: ${items.length} items');
      return;
    }
    if (t == LanternProtocol.frameContentRequest) {
      final from = json['from'] as String? ?? dialPeerId ?? '';
      final hash = json['hash'] as String? ?? '';
      if (from.isEmpty || hash.isEmpty) return;
      // B37: Verify peer is trusted
      final reqKnown = await store.getPeer(from);
      if (reqKnown == null || !reqKnown.trusted) return;
      // Send pieces we have
      final indices = await contentStore.getPieceIndices(hash);
      DiagLog.add('content',
          'request from $from for $hash: ${indices.length} pieces');
      for (final idx in indices) {
        final data = await contentStore.getPiece(hash, idx);
        if (data == null) continue;
        // Send piece via TCP (reliable)
        final peer = _peers.values.where((p) => p.id == from).firstOrNull;
        if (peer == null) break;
        final sock = await _dial(peer);
        if (sock == null) break;
        try {
          sock.add(LanternProtocol.encodeFrame({
            't': LanternProtocol.frameContentPiece,
            'hash': hash,
            'idx': idx,
            'total': indices.length,
            'data': base64Encode(data),
          }));
        } catch (_) {
          break;
        }
        // Small delay between pieces
        await Future.delayed(const Duration(milliseconds: 20));
      }
      return;
    }
    if (t == LanternProtocol.frameContentPiece) {
      final hash = json['hash'] as String? ?? '';
      final idx = json['idx'] as int? ?? 0;
      final total = json['total'] as int? ?? 1;
      final dataB64 = json['data'] as String? ?? '';
      if (hash.isEmpty || dataB64.isEmpty) return;
      final data = base64Decode(dataB64);
      // B40: Validate piece size
      if (data.length > LanternProtocol.contentPieceSize) return;
      await contentStore.storePiece(hash, idx, Uint8List.fromList(data));
      DiagLog.add('content', 'piece $idx/$total for $hash');
      // Check if we have all pieces
      final have = await contentStore.getPieceIndices(hash);
      // B2: Check against metadata total, not sender's total
      final meta = await contentStore.getContent(hash);
      final expectedTotal = meta?['pieces'] as int? ?? total;
      if (have.length >= expectedTotal) {
        await contentStore.assemble(hash);
        DiagLog.add('content', 'assembled $hash');
        // B4: Announce to other peers that we now have it (not back to sender)
        _announceContent();
      }
      return;
    }
    if (t == LanternProtocol.frameContentSearch) {
      final query = json['query'] as String? ?? '';
      if (query.isEmpty) return;
      final from = json['from'] as String? ?? dialPeerId ?? '';
      if (from.isEmpty) return;
      // B37: Verify peer is trusted
      final searchKnown = await store.getPeer(from);
      if (searchKnown == null || !searchKnown.trusted) return;
      final results = await contentStore.search(query);
      final peer = _peers.values.where((p) => p.id == from).firstOrNull;
      if (peer == null) return;
      final sock = await _dial(peer);
      if (sock == null) return;
      try {
        sock.add(LanternProtocol.encodeFrame({
          't': LanternProtocol.frameContentFound,
          'items': results.map((r) => {
            'hash': r['hash'],
            'name': r['name'],
            'size': r['size'],
            'mime': r['mime_type'],
          }).toList(),
        }));
      } catch (_) {}
      return;
    }
    if (t == LanternProtocol.frameContentFound) {
      final items = json['items'] as List<dynamic>? ?? [];
      for (final item in items) {
        final m = item as Map<String, dynamic>;
        final hash = m['hash'] as String? ?? '';
        if (hash.isEmpty) continue;
        final existing = await contentStore.getContent(hash);
        if (existing == null) {
          await contentStore.importBytes(
            Uint8List(0),
            name: m['name'] as String? ?? 'unknown',
            mimeType: m['mime'] as String?,
            publishedBy: 'search',
          );
        }
      }
      DiagLog.add('content', 'found ${items.length} items');
      return;
    }
  }

  /// Send an encrypted payload to a peer. Requires trusted pin.
  /// Tries UDP first for small payloads (fast, no TCP slow start).
  /// Falls back to TCP for large payloads or if UDP fails.
  /// Queues message for store-and-forward if peer is offline.
  Future<bool> sendTo(LanPeer peer, Map<String, dynamic> payload) async {
    final known = await store.getPeer(peer.id);
    if (known == null || !known.trusted) return false;
    final key = await _sessionFor(peer.id, known.pubB64);
    if (key == null) return false;
    final sealed = await PayloadBox.seal(key, payload);
    final msgId = payload['id'] as String?;
    // Sign the payload for authenticity (prevents impersonation on public WiFi)
    String? sig;
    if (account != null) {
      sig = await account!.sign(sealed);
    }
    final frame = LanternProtocol.encodeFrame({
      't': 'payload',
      'from': me.id,
      'blob': base64Encode(sealed),
      if (sig != null) 'sig': sig,
      if (account != null) 'sign_pub': await account!.signPubB64,
    });

    // Try UDP for small payloads if peer has a UDP port
    if (peer.udpPort > 0 &&
        sealed.length <= LanternProtocol.udpMaxPayload &&
        msgId != null &&
        _udpSocket != null) {
      DiagLog.add('udp',
          'send $msgId ${sealed.length}B to ${peer.host}:${peer.udpPort}');
      final ok = await _sendUdp(peer, sealed, msgId);
      if (!ok) {
        // B18: Store plaintext for re-encryption on flush
        await store.queueMessage(peer.id,
            LanternProtocol.encodeFrame({'queued_payload': payload}));
        DiagLog.add('queue', 'queued $msgId for ${peer.id}');
      }
      return ok;
    }

    // Fall back to TCP
    final ok = await _sendTcpTo(peer, frame, msgId);
    if (!ok) {
      // B18: Store plaintext for re-encryption on flush
      await store.queueMessage(peer.id,
          LanternProtocol.encodeFrame({'queued_payload': payload}));
      DiagLog.add('queue', 'queued $msgId for ${peer.id}');
    }
    return ok;
  }

  /// Send via UDP with application-level ACK/retry.
  Future<bool> _sendUdp(
      LanPeer peer, Uint8List sealed, String msgId) async {
    final addr = InternetAddress(peer.host);
    final port = peer.udpPort;
    final packet = _buildUdpData(msgId, sealed);

    _udpSocket!.send(packet, addr, port);

    // Start ACK wait with retries
    final pending = _UdpPendingAck(
      msgId: msgId,
      addr: addr,
      port: port,
      data: packet,
      attempts: 1,
    );
    pending.retryTimer = Timer.periodic(
      const Duration(milliseconds: LanternProtocol.udpRetryMs),
      (_) {
        if (pending.attempts >= LanternProtocol.udpMaxRetries) {
          DiagLog.add('udp',
              'max retries for $msgId, falling back to TCP');
          _pendingUdpAcks.remove(msgId);
          pending.retryTimer?.cancel();
          // Build TCP frame and fall back
          final frame = LanternProtocol.encodeFrame({
            't': 'payload',
            'from': me.id,
            'blob': base64Encode(sealed),
          });
          _sendTcpTo(peer, frame, msgId);
          return;
        }
        _udpSocket!.send(pending.data, pending.addr, pending.port);
        pending.attempts++;
        DiagLog.add(
            'udp', 'retry $msgId attempt ${pending.attempts}');
      },
    );
    _pendingUdpAcks[msgId] = pending;
    return true;
  }

  /// Send via TCP to a specific peer.
  Future<bool> _sendTcpTo(LanPeer peer, Uint8List frame, String? msgId) async {
    final sock = await _dial(peer);
    if (sock == null) return false;
    try {
      sock.add(frame);
      await sock.flush();
      if (msgId != null) {
        _pendingAcks[msgId] = DateTime.now();
      }
      return true;
    } catch (_) {
      _sockets.remove(peer.id);
      return false;
    }
  }

  /// Send via TCP (legacy: any connected socket).
  Future<bool> _sendTcp(Uint8List frame, String? msgId) async {
    if (_sockets.isEmpty) return false;
    final sock = _sockets.values.first;
    try {
      sock.add(frame);
      await sock.flush();
      if (msgId != null) {
        _pendingAcks[msgId] = DateTime.now();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Build UDP data packet: [msgIdLen 1B][msgId NB][type 1B][len 2B][payload].
  Uint8List _buildUdpData(String msgId, Uint8List payload) {
    final idBytes = utf8.encode(msgId);
    final out = BytesBuilder();
    out.add([idBytes.length]);
    out.add(idBytes);
    out.add([LanternProtocol.udpTypeData]);
    out.add([(payload.length >> 8) & 0xFF, payload.length & 0xFF]);
    out.add(payload);
    return out.toBytes();
  }

  /// Build UDP ACK packet: [msgIdLen 1B][msgId NB][type 1B][0,0].
  Uint8List _buildUdpAck(String msgId) {
    final idBytes = utf8.encode(msgId);
    final out = BytesBuilder();
    out.add([idBytes.length]);
    out.add(idBytes);
    out.add([LanternProtocol.udpTypeAck, 0, 0]);
    return out.toBytes();
  }

  /// Parse UDP packet header, returns (msgId, type, payloadStartOffset).
  /// Returns null if packet is too short.
  (String, int, int)? _parseUdpHeader(List<int> data) {
    if (data.length < 4) return null;
    final idLen = data[0];
    if (data.length < 1 + idLen + 3) return null;
    final msgId = utf8.decode(data.sublist(1, 1 + idLen), allowMalformed: true);
    final type = data[1 + idLen];
    final offset = 1 + idLen + 3; // after [len][id][type][payloadLen 2B]
    return (msgId, type, offset);
  }

  /// Handle incoming UDP datagram.
  void _onUdpDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _udpSocket!.receive();
    if (dg == null) return;
    final data = dg.data;

    final parsed = _parseUdpHeader(data);
    if (parsed == null) return;
    final (msgId, type, payloadOffset) = parsed;

    if (type == LanternProtocol.udpTypeAck) {
      // ACK received — cancel retry timer, mark delivered
      final pending = _pendingUdpAcks.remove(msgId);
      pending?.retryTimer?.cancel();
      if (pending != null) {
        store.db.update('messages', {'delivered': 1},
            where: 'id = ?', whereArgs: [pending.msgId]);
        DiagLog.add('udp', 'ACK received for ${pending.msgId}');
      }
      return;
    }

    if (type == LanternProtocol.udpTypeData) {
      final payloadLen =
          (data[payloadOffset - 2] << 8) | data[payloadOffset - 1];
      if (data.length < payloadOffset + payloadLen) return;
      final payload = data.sublist(payloadOffset, payloadOffset + payloadLen);

      // Check for special sub-types (typing, PTT)
      if (payload.isNotEmpty) {
        final subType = payload[0];
        if (subType == LanternProtocol.udpTypeTyping) {
          // Typing indicator — find sender, notify UI
          final sender = _findPeerByHost(dg.address.address);
          if (sender != null && onTyping != null) {
            onTyping!(sender);
          }
          return;
        }
        if (subType == LanternProtocol.udpTypePttStart) {
          final sender = _findPeerByHost(dg.address.address);
          if (sender != null && onPttStart != null) {
            onPttStart!(sender);
          }
          return;
        }
        if (subType == LanternProtocol.udpTypePttData) {
          final sender = _findPeerByHost(dg.address.address);
          if (sender != null && onPttData != null && payload.length > 1) {
            onPttData!(sender, payload.sublist(1));
          }
          return;
        }
        if (subType == LanternProtocol.udpTypePttStop) {
          final sender = _findPeerByHost(dg.address.address);
          if (sender != null && onPttStop != null) {
            onPttStop!(sender);
          }
          return;
        }
        if (subType == LanternProtocol.udpTypePttPresence && payload.length > 1) {
          final sender = _findPeerByHost(dg.address.address);
          if (sender != null && onPttPresence != null) {
            final channel = utf8.decode(payload.sublist(1), allowMalformed: true);
            onPttPresence!(sender, channel);
          }
          return;
        }
      }

      // Process the payload — ACK sent only after successful decryption
      final success = await _processPayloadWithAck(
          payload, dg.address.address, dg.port, msgId);
    }
  }

  /// Process payload and send ACK only on successful decryption.
  Future<bool> _processPayloadWithAck(
      List<int> sealed, String senderHost, int senderPort, String msgId) async {
    final from = _findPeerByHost(senderHost);
    if (from == null) {
      DiagLog.add('udp', 'unknown sender $senderHost, dropping');
      return false;
    }
    final known = await store.getPeer(from);
    if (known == null || !known.trusted || known.pubB64.isEmpty) {
      DiagLog.add('udp', 'untrusted sender $from, dropping');
      return false;
    }
    final key = await _sessionFor(from, known.pubB64);
    if (key == null) return false;
    try {
      final plain = await PayloadBox.open(key, Uint8List.fromList(sealed));
      // Decrypt succeeded — send ACK now (B12)
      _udpSocket!.send(
          Uint8List.fromList(_buildUdpAck(msgId)),
          InternetAddress(senderHost), senderPort);
      DiagLog.add('udp', 'DATA decrypted, ACK sent for $msgId');
      if (!_eventCtrl.isClosed) {
        _eventCtrl.add(LanEvent(from, plain));
      }
      return true;
    } catch (e) {
      DiagLog.add('udp', 'decrypt failed: $e');
      return false;
    }
  }

  /// Find peer ID by IP address.
  String? _findPeerByHost(String host) {
    for (final p in _peers.values) {
      if (p.host == host) return p.id;
    }
    for (final entry in _sockets.entries) {
      try {
        if (entry.value.remoteAddress.address == host) {
          return entry.key;
        }
      } catch (_) {}
    }
    return null;
  }

  /// Process an encrypted payload (shared by TCP and UDP paths).
  Future<void> _processPayload(
      List<int> sealed, String senderHost) async {
    // We need to find who sent this. For UDP, we only have the IP.
    // Look up the peer by IP address.
    String? from;
    for (final entry in _sockets.entries) {
      // Check if any known socket matches this IP
      try {
        if (entry.value.remoteAddress.address == senderHost) {
          from = entry.key;
          break;
        }
      } catch (_) {}
    }
    // Also check live peers by IP
    if (from == null) {
      for (final p in _peers.values) {
        if (p.host == senderHost) {
          from = p.id;
          break;
        }
      }
    }
    if (from == null) {
      DiagLog.add('udp', 'unknown sender $senderHost, dropping');
      return;
    }

    final known = await store.getPeer(from);
    if (known == null || !known.trusted || known.pubB64.isEmpty) {
      DiagLog.add('udp', 'untrusted sender $from, dropping');
      return;
    }
    final key = await _sessionFor(from, known.pubB64);
    if (key == null) return;

    try {
      final plain =
          await PayloadBox.open(key, Uint8List.fromList(sealed));
      if (!_eventCtrl.isClosed) {
        _eventCtrl.add(LanEvent(from, plain));
      }
    } catch (e) {
      DiagLog.add('udp', 'decrypt failed: $e');
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
    final futures = <Future<bool>>[];
    for (final mid in members) {
      if (mid == me.id) continue;
      futures.add(_sendToMember(mid, sealed, groupId));
    }
    if (futures.isEmpty) return false;
    // B42: Use timeout per member, don't block on slowest
    final results = await Future.wait(
        futures.map((f) => f.timeout(
            const Duration(seconds: 3), onTimeout: () => false)));
    return results.any((r) => r);
  }

  Future<bool> _sendToMember(
      String peerId, Uint8List sealed, String groupId) async {
    final peer = _peers.values.where((p) => p.id == peerId).firstOrNull;
    if (peer == null) return false;
    final sock = await _dial(peer);
    if (sock == null) return false;
    try {
      sock.add(LanternProtocol.encodeFrame({
        't': 'payload',
        'from': me.id,
        'blob': base64Encode(sealed),
        'gid': groupId,
      }));
      return true;
    } catch (_) {
      return false;
    }
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
    _healthTimer?.cancel();
    _healthTimer = null;
    // Cancel all pending UDP acks
    for (final pending in _pendingUdpAcks.values) {
      pending.retryTimer?.cancel();
    }
    _pendingUdpAcks.clear();
    // Close UDP socket
    try {
      _udpSocket?.close();
    } catch (_) {}
    _udpSocket = null;
    _udpPort = 0;
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
    _syncing.clear();
    _syncCooldown.clear();
    _doneHandled.clear();
  }

  void dispose() {
    _prune?.cancel();
    _ackTimer?.cancel();
    _healthTimer?.cancel();
    unawaited(stop());
    _peerCtrl.close();
    _eventCtrl.close();
    _pendingTrust.close();
  }
}

/// Tracks a pending UDP message waiting for ACK.
class _UdpPendingAck {
  final String msgId;
  final InternetAddress addr;
  final int port;
  final Uint8List data;
  int attempts;
  Timer? retryTimer;

  _UdpPendingAck({
    required this.msgId,
    required this.addr,
    required this.port,
    required this.data,
    required this.attempts,
  });
}

/// Tracks an active file transfer.
class _FileTransferState {
  final String transferId;
  final String peerId;
  final String fileName;
  final int fileSize;
  final String filePath;
  final String kind;
  bool cancelled = false;
  int bytesSent = 0;
  Timer? chunkTimer;

  _FileTransferState({
    required this.transferId,
    required this.peerId,
    required this.fileName,
    required this.fileSize,
    required this.filePath,
    required this.kind,
  });

  double get progress => fileSize > 0 ? bytesSent / fileSize : 0;
}
