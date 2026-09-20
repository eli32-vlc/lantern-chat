import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
  final String status;
  final String host;
  final int port;
  final String pubB64;
  final int version;
  DateTime lastSeen;

  LanPeer({
    required this.id,
    required this.name,
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
  String displayName;
  String status;

  ServerSocket? _server;
  Registration? _reg;
  Discovery? _discovery;
  Timer? _prune;

  final _peers = <String, LanPeer>{};
  final _peerCtrl = StreamController<List<LanPeer>>.broadcast();
  final _eventCtrl = StreamController<LanEvent>.broadcast();
  final _pendingTrust = StreamController<LanPeer>.broadcast();

  /// sessionKey cache per peer id
  final _sessions = <String, List<int>>{};
  final _sockets = <String, Socket>{};

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
        LanternProtocol.txtVer: _txtBytes('${LanternProtocol.protoVersion}'),
      };

  Future<void> start() async {
    DiagLog.add('engine', 'start');
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0,
        backlog: LanternProtocol.tcpBacklog);
    DiagLog.add('engine', 'listening on port $port');
    _server!.listen(_onInbound);

    final svc = Service(
      name: '${LanternProtocol.serviceNamePrefix}${me.id.substring(0, 8)}',
      type: LanternProtocol.serviceType,
      port: port,
      txt: await _txt(port),
    );
    _reg = await register(svc);
    DiagLog.add('mdns', 'registered ${svc.name} type=${svc.type} port=$port');

    _discovery = await startDiscovery(LanternProtocol.serviceType,
        autoResolve: true, ipLookupType: IpLookupType.v4);
    DiagLog.add('mdns', 'browsing ${LanternProtocol.serviceType}');
    _discovery!.addServiceListener(_onServiceEvent);
    // seed with already-found services
    for (final s in _discovery!.services) {
      _onService(s);
    }

    _prune = Timer.periodic(const Duration(seconds: 15), (_) {
      final cutoff = DateTime.now().subtract(const Duration(seconds: 60));
      _peers.removeWhere((_, p) => p.lastSeen.isBefore(cutoff));
      if (!_peerCtrl.isClosed) _peerCtrl.add(currentPeers);
    });
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
            status: peer.status,
            pubB64: known.pubB64,
            fingerprint: known.fingerprint,
            trusted: known.trusted,
            lastSeen: DateTime.now().millisecondsSinceEpoch,
          ));
        }
      }
    } catch (_) {
      // ignore malformed services
    }
  }

  // ---------- sockets ----------

  void _onInbound(Socket sock) {
    DiagLog.add('tcp',
        'inbound from ${sock.remoteAddress.address}:${sock.remotePort}');
    // Hand inbound sockets to the compat sniffer FIRST: if the first bytes
    // are not Lantern framing, the compat server answers in plaintext
    // (lines/ndjson/lenprefix) instead of dropping a "silent server".
    CompatSniffer.route(sock, reader: FrameReader(), onLantern: (s) {
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
    if (known != null) return known;
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
      if (id.isEmpty || pk.isEmpty || id == me.id) return;
      try {
        sock.add(LanternProtocol.encodeFrame({
          't': 'hello',
          'id': me.id,
          'nm': displayName,
          'pk': await me.publicKeyB64,
          'v': LanternProtocol.protoVersion,
        }));
      } catch (_) {}
      final known = await store.getPeer(id);
      if (known != null && known.trusted && known.pubB64 == pk) {
        _sessions[id] = await me.sharedKey(base64Decode(pk));
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
        if (!_eventCtrl.isClosed) _eventCtrl.add(LanEvent(from, plain));
      } catch (_) {
        // bad MAC => drop
      }
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

  String messageId() => const Uuid().v4();

  Future<void> stop() async {
    _prune?.cancel();
    _prune = null;
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
  }

  void dispose() {
    unawaited(stop());
    _peerCtrl.close();
    _eventCtrl.close();
    _pendingTrust.close();
  }
}
