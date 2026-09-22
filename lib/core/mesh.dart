import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nsd/nsd.dart';

import 'crypto.dart';
import 'diag.dart';
import 'identity.dart';
import 'protocol.dart';
import 'store.dart';

/// A peer discovered on the LAN.
class Peer {
  final String id;
  final String name;
  final String handle;
  final String accountId;
  final String signPubB64;
  final String status;
  final String host;
  final int port;
  final int udpPort;
  final String pubB64;
  final int version;
  DateTime lastSeen;

  Peer({
    required this.id,
    required this.name,
    this.handle = '',
    this.accountId = '',
    this.signPubB64 = '',
    this.status = '',
    required this.host,
    required this.port,
    this.udpPort = 0,
    required this.pubB64,
    required this.version,
  }) : lastSeen = DateTime.now();

  String get key => '$id@$host:$port';
}

/// Decrypted event from the network.
class NetEvent {
  final String peerId;
  final Map<String, dynamic> data;
  NetEvent(this.peerId, this.data);
}

/// Network transport: mDNS, TCP, UDP. No business logic.
class Mesh {
  final Device device;
  final Store store;
  String displayName;
  String status;

  ServerSocket? _server;
  Registration? _reg;
  Discovery? _discovery;
  RawDatagramSocket? _udp;
  int _udpPort = 0;
  Timer? _prune;
  Timer? _health;

  final _peers = <String, Peer>{};
  final _peerCtrl = StreamController<List<Peer>>.broadcast();
  final _frameCtrl = StreamController<RawFrame>.broadcast();
  final _sessions = <String, List<int>>{};
  final sockets = <String, Socket>{};
  final helloReplied = <Socket, DateTime>{};
  final _doneHandled = <Socket>{};

  Stream<List<Peer>> get peers => _peerCtrl.stream;
  Stream<RawFrame> get frames => _frameCtrl.stream;
  List<Peer> get currentPeers => _peers.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  Mesh({
    required this.device,
    required this.store,
    required this.displayName,
    required this.status,
  });

  int get port => _server?.port ?? 0;
  int get udpPort => _udpPort;

  /// Set handle (call before start, or after account change).
  void setHandle(String h) { _handle = h; }

  // ---- Lifecycle ----

  Future<void> start() async {
    try {
      DiagLog.add('mesh', 'start');
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0,
          backlog: P.tcpBacklog);
      DiagLog.add('mesh', 'port $port');
      _server!.listen(_onInbound);

      // UDP socket
      try {
        _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port + 1);
        _udpPort = _udp!.port;
        _udp!.listen(_onUdp);
        DiagLog.add('mesh', 'udp port $_udpPort');
      } catch (e) {
        DiagLog.add('mesh', 'udp failed: $e');
      }

      // mDNS register
      try {
        _reg = await register(Service(
          name: '${P.namePrefix}${device.id.substring(0, 8)}',
          type: P.serviceType,
          port: port,
          txt: await _txt(),
        ));
        DiagLog.add('mesh', 'registered');
      } catch (e) {
        DiagLog.add('mesh', 'register failed: $e');
      }

      // mDNS discover
      try {
        _discovery = await startDiscovery(P.serviceType,
            autoResolve: true, ipLookupType: IpLookupType.v4);
        _discovery!.addServiceListener(_onService);
        for (final s in _discovery!.services) {
          _processService(s);
        }
      } catch (e) {
        DiagLog.add('mesh', 'discovery failed: $e');
      }

      // Timers
      _prune = Timer.periodic(
          Duration(seconds: P.peerPruneCheckSec), (_) => _prunePeers());
      _health = Timer.periodic(
          Duration(seconds: P.healthCheckSec), (_) => _checkHealth());
    } catch (e) {
      DiagLog.add('mesh', 'start failed: $e');
    }
    if (!_peerCtrl.isClosed) _peerCtrl.add(currentPeers);
  }

  Future<void> stop() async {
    _prune?.cancel();
    _health?.cancel();
    try { await _discovery?.let(stopDiscovery); } catch (_) {}
    _discovery = null;
    try { if (_reg != null) await unregister(_reg!); } catch (_) {}
    _reg = null;
    try { await _server?.close(); } catch (_) {}
    _server = null;
    try { _udp?.close(); } catch (_) {}
    _udp = null;
    _udpPort = 0;
    for (final s in sockets.values) {
      try { s.destroy(); } catch (_) {}
    }
    sockets.clear();
    helloReplied.clear();
    _doneHandled.clear();
    _sessions.clear();
  }

  void dispose() {
    unawaited(stop());
    _peerCtrl.close();
    _frameCtrl.close();
  }

  // ---- mDNS ----

  String _handle = '';

  Future<Map<String, Uint8List?>> _txt() async => {
    P.txtId: _b(device.id),
    P.txtName: _b(displayName),
    P.txtStatus: _b(status),
    P.txtPort: _b('$port'),
    P.txtPub: _b(await device.pubB64),
    P.txtHandle: _b(_handle),
    P.txtVer: _b('${P.protoVersion}'),
    P.txtAppVer: _b(P.appVersion),
    P.txtAppBuild: _b('${P.appBuild}'),
    P.txtUdpPort: _b('$_udpPort'),
  };

  void _onService(Service s, ServiceStatus st) {
    if (st == ServiceStatus.lost) {
      _peers.removeWhere((_, p) => p.name == s.name);
      if (!_peerCtrl.isClosed) _peerCtrl.add(currentPeers);
      return;
    }
    _processService(s);
  }

  Future<void> _processService(Service s) async {
    try {
      final txt = s.txt ?? {};
      final id = _t(txt[P.txtId]);
      if (id.isEmpty || id == device.id) return;
      String? host = s.host;
      if (s.addresses != null && s.addresses!.isNotEmpty) {
        final v4 = s.addresses!.where(
            (a) => a.type == InternetAddressType.IPv4 && !a.isLoopback);
        if (v4.isNotEmpty) host = v4.first.address;
      }
      final port = int.tryParse(_t(txt[P.txtPort])) ?? s.port ?? 0;
      if (host == null || host.isEmpty || port == 0) return;
      if (host.endsWith('.local') || host.endsWith('.local.')) {
        try {
          final r = await InternetAddress.lookup(
              host.replaceAll(RegExp(r'\.$'), ''));
          final v4 = r.where(
              (a) => a.type == InternetAddressType.IPv4 && !a.isLoopback);
          if (v4.isEmpty) return;
          host = v4.first.address;
        } catch (_) {
          return;
        }
      }
      final peer = Peer(
        id: id,
        name: _t(txt[P.txtName]).isEmpty ? 'Lantern' : _t(txt[P.txtName]),
        handle: _t(txt[P.txtHandle]),
        accountId: _t(txt[P.txtAccountId]),
        signPubB64: _t(txt[P.txtSignPub]),
        status: _t(txt[P.txtStatus]),
        host: host,
        port: port,
        udpPort: int.tryParse(_t(txt[P.txtUdpPort])) ?? 0,
        pubB64: _t(txt[P.txtPub]),
        version: int.tryParse(_t(txt[P.txtVer])) ?? 1,
      );
      final isNew = !_peers.containsKey(peer.key);
      _peers.removeWhere((k, v) => v.id == peer.id && k != peer.key);
      _peers[peer.key] = peer;
      if (!_peerCtrl.isClosed) _peerCtrl.add(currentPeers);

      // Store peer in DB
      if (peer.pubB64.isNotEmpty) {
        final rawPub = base64Decode(peer.pubB64);
        final fp = await Crypto.sha256Hex(rawPub);
        final existing = await store.getPeer(id);
        await store.upsertPeer({
          'id': id,
          'name': peer.name,
          'handle': peer.handle,
          'account_id': peer.accountId,
          'sign_pub': peer.signPubB64,
          'status': peer.status,
          'pub': peer.pubB64,
          'fingerprint': fp,
          'trusted': existing?['trusted'] ?? 0,
          'last_seen': DateTime.now().millisecondsSinceEpoch,
        });
        if (isNew) {
          DiagLog.add('mesh', 'new peer $id (${peer.name})');
        }
      }
    } catch (_) {}
  }

  // ---- TCP ----

  void _onInbound(Socket sock) {
    DiagLog.add('tcp', 'inbound ${sock.remoteAddress.address}:${sock.remotePort}');
    final reader = FrameReader();
    sock.listen(
      (chunk) {
        for (final frame in reader.feed(Uint8List.fromList(chunk))) {
          _frameCtrl.add(RawFrame(sock, null, frame));
        }
      },
      onError: (_) { try { sock.destroy(); } catch (_) {} },
      onDone: () { try { sock.destroy(); } catch (_) {} },
    );
  }

  Future<Socket?> dial(Peer peer) async {
    final cached = _sockets[peer.id];
    if (cached != null) {
      try {
        await cached.done.timeout(Duration.zero);
        if (_sockets[peer.id] == cached) sockets.remove(peer.id);
      } on TimeoutException {
        return cached;
      } catch (_) {
        if (_sockets[peer.id] == cached) sockets.remove(peer.id);
      }
    }
    try {
      final sock = await Socket.connect(peer.host, peer.port,
          timeout: const Duration(seconds: 5));
      _sockets[peer.id] = sock;
      final reader = FrameReader();
      sock.listen(
        (chunk) {
          for (final frame in reader.feed(Uint8List.fromList(chunk))) {
            _frameCtrl.add(RawFrame(sock, peer.id, frame));
          }
        },
        onError: (_) { sockets.remove(peer.id); },
        onDone: () { sockets.remove(peer.id); },
      );
      // Send hello
      await _sendHello(sock);
      return sock;
    } catch (_) {
      sockets.remove(peer.id);
      return null;
    }
  }

  Account? _account;

  void setAccount(Account? acc) { _account = acc; }

  Future<void> _sendHello(Socket sock) async {
    final hello = <String, dynamic>{
      't': P.hello,
      'id': device.id,
      'nm': displayName,
      'pk': await device.pubB64,
      'v': P.protoVersion,
      'av': P.appVersion,
      'ab': P.appBuild,
    };
    if (_account != null) {
      hello['ah'] = await _account!.handle;
      hello['aid'] = _account!.id;
      hello['spk'] = await _account!.pubB64;
    }
    sock.add(_encode(hello));
  }

  Future<void> sendFrame(Peer peer, Map<String, dynamic> frame) async {
    final sock = await dial(peer);
    if (sock == null) return;
    try {
      sock.add(_encode(frame));
      await sock.flush();
    } catch (_) {
      sockets.remove(peer.id);
    }
  }

  // ---- UDP ----

  void _onUdp(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _udp?.receive();
    if (dg == null) return;
    final data = dg.data;
    if (data.length < 4) return;
    final idLen = data[0];
    if (data.length < 1 + idLen + 3) return;
    final msgId = utf8.decode(data.sublist(1, 1 + idLen), allowMalformed: true);
    final type = data[1 + idLen];
    final offset = 1 + idLen + 3;
    _frameCtrl.add(RawFrame(null, null, null,
        udpData: data, udpType: type, udpMsgId: msgId,
        udpOffset: offset, udpAddr: dg.address, udpPort: dg.port));
  }

  void sendUdp(Peer peer, List<int> subTypeAndPayload) {
    if (_udp == null || peer.udpPort == 0) return;
    final idBytes = utf8.encode('udp-${DateTime.now().microsecondsSinceEpoch % 100000}');
    final out = BytesBuilder();
    out.add([idBytes.length]);
    out.add(idBytes);
    out.add(subTypeAndPayload);
    _udp!.send(out.toBytes(), InternetAddress(peer.host), peer.udpPort);
  }

  void sendUdpAck(InternetAddress addr, int port, String msgId) {
    if (_udp == null) return;
    final idBytes = utf8.encode(msgId);
    final out = BytesBuilder();
    out.add([idBytes.length]);
    out.add(idBytes);
    out.add([P.udpAck, 0, 0]);
    _udp!.send(out.toBytes(), addr, port);
  }

  // ---- Session keys ----

  Future<List<int>?> sessionFor(String peerId, String pubB64) async {
    if (_sessions.containsKey(peerId)) return _sessions[peerId];
    final known = await store.getPeer(peerId);
    if (known == null || known['trusted'] != 1) return null;
    final key = await device.sharedWith(base64Decode(pubB64));
    _sessions[peerId] = key;
    return key;
  }

  Future<void> cacheSession(String peerId, List<int> pubBytes) async {
    _sessions[peerId] = await device.sharedWith(pubBytes);
  }

  // ---- Internal ----

  void _prunePeers() {
    final cutoff =
        DateTime.now().subtract(Duration(minutes: P.peerPruneMinutes));
    final dead = <String>[];
    _peers.forEach((_, p) { if (p.lastSeen.isBefore(cutoff)) dead.add(p.id); });
    for (final id in dead) {
      _peers.removeWhere((_, p) => p.id == id);
    }
    if (!_peerCtrl.isClosed) _peerCtrl.add(currentPeers);
  }

  /// Re-register mDNS (call after name/status change).
  Future<void> reregister() async {
    try { if (_reg != null) await unregister(_reg!); } catch (_) {}
    _reg = null;
    try {
      _reg = await register(Service(
        name: '${P.namePrefix}${device.id.substring(0, 8)}',
        type: P.serviceType,
        port: port,
        txt: await _txt(),
      ));
    } catch (_) {}
  }

  void _checkHealth() {
    final dead = <String>[];
    for (final e in sockets.entries) {
      try {
        if (!_doneHandled.contains(e.value)) {
          _doneHandled.add(e.value);
          e.value.done.then((_) {
            if (_sockets[e.key] == e.value) sockets.remove(e.key);
            helloReplied.remove(e.value);
            _doneHandled.remove(e.value);
          }).catchError((_) { _doneHandled.remove(e.value); });
        }
        // H5: Don't send zero-byte writes — rely on done.future instead
      } catch (_) {
        dead.add(e.key);
      }
    }
    for (final id in dead) {
      final s = sockets.remove(id);
      if (s != null) { helloReplied.remove(s); _doneHandled.remove(s); }
      _sessions.remove(id);
    }
  }

  static Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));
  static String _t(Uint8List? b) =>
      b == null ? '' : utf8.decode(b, allowMalformed: true);

  static Uint8List encode(Map<String, dynamic> json) {
    final body = utf8.encode(jsonEncode(json));
    final out = Uint8List(4 + body.length);
    ByteData.view(out.buffer).setUint32(0, body.length, Endian.big);
    out.setRange(4, out.length, body);
    return out;
  }
}

/// Raw frame from TCP or UDP.
class RawFrame {
  final Socket? sock;
  final String? dialPeerId;
  final Uint8List? tcpFrame;
  final Uint8List? udpData;
  final int? udpType;
  final String? udpMsgId;
  final int? udpOffset;
  final InternetAddress? udpAddr;
  final int? udpPort;

  RawFrame(this.sock, this.dialPeerId, this.tcpFrame,
      {this.udpData, this.udpType, this.udpMsgId,
       this.udpOffset, this.udpAddr, this.udpPort});

  bool get isTcp => tcpFrame != null;
  bool get isUdp => udpData != null;
}

/// Frame reader: 4-byte length prefix.
class FrameReader {
  final _buf = BytesBuilder();

  List<Uint8List> feed(Uint8List chunk) {
    _buf.add(chunk);
    final out = <Uint8List>[];
    while (true) {
      final bytes = _buf.toBytes();
      if (bytes.length < 4) break;
      final len = ByteData.view(bytes.buffer, bytes.offsetInBytes, 4)
          .getUint32(0);
      if (len > P.frameMax) { _buf.clear(); break; }
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

extension<T> on T {
  Future<R?> let<R>(Future<R> Function(T) f) async => f(this);
}
