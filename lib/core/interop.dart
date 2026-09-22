import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nsd/nsd.dart';

import 'diag.dart';
import 'protocol.dart';

/// AirChat interop: two-way presence + chat with the real AirChat app.
///
/// What we verified from AirChat_1.1.0.apk (base split, no libapp.so):
/// - Android NSD via nsd_android (register/discover/resolve), multicast lock
///   tag "AirChat_Multicast". The Dart service-type string lives in the
///   missing split, so we CANNOT hardcode it — instead we enumerate ALL
///   `_tcp` services on the LAN (`_services._dns-sd._udp`), resolve each,
///   and fingerprint AirChat by TXT keys / port behavior / probe handshake.
/// - Its ToS states messages are UNENCRYPTED. Lantern↔AirChat chats are
///   therefore labeled "Not encrypted" in the UI — never mixed into E2EE
///   Lantern chats.
///
/// Architecture:
/// - [InteropScanner.enumerate] browses `_services._dns-sd._udp`, then for
///   every discovered service type starts a targeted discovery, resolves
///   instances, and emits [InteropPeer]s.
/// - [InteropScanner.probe] handshakes a peer: sends nothing credentialed,
///   reads the banner/first frame, classifies the framing, and records the
///   verdict in DiagLog so the user can paste it back.
/// - [AirchatChannel] speaks the observed framing once classified. Today it
///   implements: raw UTF-8 lines, length-prefixed JSON (Lantern-style), and
///   newline-delimited JSON. If AirChat answers one of these, text chat
///   works both ways immediately.
class InteropPeer {
  final String name;
  final String host;
  final int port;
  final String serviceType;
  final Map<String, String> txt;
  final DateTime seen;
  String? framing; // classified by probe: 'lines' | 'lenprefix' | 'ndjson' | 'silent' | 'closed'

  InteropPeer({
    required this.name,
    required this.host,
    required this.port,
    required this.serviceType,
    required this.txt,
  }) : seen = DateTime.now();

  bool get looksLikeChat {
    final n = name.toLowerCase();
    final t = serviceType.toLowerCase();
    return n.contains('airchat') ||
        n.contains('air-chat') ||
        n.contains('wifi') ||
        t.contains('airchat') ||
        t.contains('chat') ||
        t.contains('lantern');
  }
}

class InteropScanner {
  /// Extra candidate types worth a direct browse even if enumeration misses
  /// them (some stacks don't answer enumeration queries).
  static const candidates = [
    '_wifi-chat._tcp',
    '_wifichat._tcp',
    '_http._tcp',
  ];

  static const enumType = '_services._dns-sd._udp';

  final _found = <String, InteropPeer>{};
  final _ctrl = StreamController<List<InteropPeer>>.broadcast();
  final _subs = <Discovery>[];
  Timer? _stopTimer;
  DateTime? _lastScan;

  Stream<List<InteropPeer>> get found => _ctrl.stream;
  List<InteropPeer> get current => _found.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  /// Full pass: enumerate all service types, then browse each for instances.
  /// Debounced: ignores calls within 20s of the previous scan start.
  Future<void> scan(
      {Duration browseWindow = const Duration(seconds: 15)}) async {
    final now = DateTime.now();
    if (_lastScan != null &&
        now.difference(_lastScan!) < const Duration(seconds: 20)) {
      DiagLog.add('interop', 'scan skipped (debounce)');
      return;
    }
    _lastScan = now;
    _stopTimer?.cancel();
    await stop(); // stop any previous discoveries before starting new ones
    DiagLog.add('interop', 'scan start');
    // 1) enumerate service types
    final types = <String>{...candidates, LanternProtocol.serviceType};
    try {
      final e = await startDiscovery(enumType,
          autoResolve: false, ipLookupType: IpLookupType.none);
      e.addServiceListener((svc, status) {
        final n = (svc.name ?? '').toLowerCase();
        final m = RegExp(r'_[a-z0-9-]+\._tcp').firstMatch(n);
        if (m != null) types.add(m.group(0)!);
      });
      // hold the browse briefly so listeners fire
      await Future<void>.delayed(const Duration(seconds: 4));
      for (final s in e.services) {
        final n = (s.name ?? '').toLowerCase();
        final m = RegExp(r'_[a-z0-9-]+\._tcp').firstMatch(n);
        if (m != null) types.add(m.group(0)!);
      }
      try {
        await stopDiscovery(e);
      } catch (_) {}
    } catch (err) {
      DiagLog.add('interop', 'enumeration browse failed: $err');
    }
    DiagLog.add('interop', 'types: ${types.join(', ')}');
    // 2) browse each type for instances
    for (final type in types) {
      if (type == enumType) continue;
      try {
        final d = await startDiscovery(type,
            autoResolve: true, ipLookupType: IpLookupType.v4);
        d.addServiceListener((svc, status) {
          DiagLog.add('interop',
              '$type ${status.name} name=${svc.name} host=${svc.host} port=${svc.port}');
          if (status == ServiceStatus.lost) return;
          _ingest(type, svc);
        });
        for (final s in d.services) {
          _ingest(type, s);
        }
        _subs.add(d);
      } catch (err) {
        DiagLog.add('interop', 'browse $type failed: $err');
      }
    }
    _stopTimer = Timer(browseWindow, stop);
  }

  void _ingest(String type, Service svc) {
    try {
      var host = svc.host ?? '';
      if (svc.addresses != null && svc.addresses!.isNotEmpty) {
        final v4 = svc.addresses!.where(
            (a) => a.type == InternetAddressType.IPv4 && !a.isLoopback);
        if (v4.isNotEmpty) host = v4.first.address;
      }
      if (host.isEmpty || (svc.port ?? 0) == 0) return;
      if (host.endsWith('.local') || host.endsWith('.local.')) {
        // try numeric resolve once; skip if it fails
        return;
      }
      final txt = <String, String>{};
      (svc.txt ?? {}).forEach((k, v) {
        if (v != null) txt[k] = utf8.decode(v, allowMalformed: true);
      });
      if (type == LanternProtocol.serviceType) return; // own engine handles
      final key = '$type/${svc.name}/$host:${svc.port}';
      _found[key] = InteropPeer(
        name: svc.name ?? 'Unknown device',
        host: host,
        port: svc.port!,
        serviceType: type,
        txt: txt,
      );
      DiagLog.add('interop',
          'peer $key txtKeys=${txt.keys.join(',')}');
      if (!_ctrl.isClosed) _ctrl.add(current);
    } catch (err) {
      DiagLog.add('interop', 'ingest failed: $err');
    }
  }

  /// Handshake + classify framing. Sets peer.framing. Safe: sends a Lantern
  /// hello frame (4-byte length-prefixed JSON) plus a plain-text line,
  /// reads ≤3s, never sends credentials.
  Future<String> probe(InteropPeer peer) async {
    DiagLog.add(
        'interop', 'probe ${peer.host}:${peer.port} (${peer.serviceType})');
    Socket? sock;
    try {
      sock = await Socket.connect(peer.host, peer.port,
          timeout: const Duration(seconds: 3));
      final buf = BytesBuilder();
      final done = Completer<void>();
      sock.listen(buf.add, onDone: () => done.complete(),
          onError: (_) => done.complete());
      // Send both formats: AirChat likely expects length-prefixed JSON
      // (it runs a Dart server), but try plain JSON line too.
      try {
        final hello = utf8.encode(jsonEncode({'t': 'probe', 'app': 'lantern'}));
        final lenPrefixed = Uint8List(4 + hello.length);
        ByteData.view(lenPrefixed.buffer).setUint32(0, hello.length, Endian.big);
        lenPrefixed.setRange(4, lenPrefixed.length, hello);
        sock.add(lenPrefixed);
        sock.add(utf8.encode('\n'));
        await sock.flush();
      } catch (_) {}
      await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
      final bytes = buf.toBytes();
      DiagLog.add('interop',
          'probe got ${bytes.length}B preview=${DiagLog.preview(bytes)}');
      if (bytes.isEmpty) {
        peer.framing = 'silent';
        if (!_ctrl.isClosed) _ctrl.add(current);
        return 'Silent — chat from Lantern side only. Its app must message first.';
      }
      // classify: length-prefix (first 4 bytes = remaining length)?
      if (bytes.length >= 4) {
        final claimed = ByteData.view(
                Uint8List.fromList(bytes).buffer, 0, 4)
            .getUint32(0, Endian.big);
        if (claimed == bytes.length - 4 ||
            (claimed <= 8 * 1024 * 1024 && claimed > 0)) {
          try {
            final body = utf8.decode(bytes.sublist(4), allowMalformed: true);
            jsonDecode(body);
            peer.framing = 'lenprefix';
            if (!_ctrl.isClosed) _ctrl.add(current);
            return 'Speaks length-prefixed JSON — chat enabled.';
          } catch (_) {}
        }
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      if (text.trimLeft().startsWith('{') ||
          text.trimLeft().startsWith('[')) {
        peer.framing = 'ndjson';
        if (!_ctrl.isClosed) _ctrl.add(current);
        return 'Speaks JSON lines — chat enabled.';
      }
      peer.framing = 'lines';
      if (!_ctrl.isClosed) _ctrl.add(current);
      return 'Answered ${bytes.length} bytes — raw-line chat enabled.';
    } catch (e) {
      peer.framing = 'closed';
      DiagLog.add('interop', 'probe failed: $e');
      return 'Unreachable ($e)';
    } finally {
      try {
        await sock?.close();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    _stopTimer?.cancel();
    for (final d in _subs) {
      try {
        await stopDiscovery(d);
      } catch (_) {}
    }
    _subs.clear();
  }

  void dispose() {
    stop();
    _ctrl.close();
  }
}

/// Two-way channel to a classified interop peer. Handles the three framings
/// our probe can detect. Incoming lines/frames are surfaced via [messages];
/// [sendText] uses the peer's classified framing.
class AirchatChannel {
  final InteropPeer peer;
  final _msgs = StreamController<String>.broadcast();
  Socket? _sock;
  final _reader = _RawReader();

  Stream<String> get messages => _msgs.stream;

  AirchatChannel(this.peer);

  Future<bool> connect() async {
    try {
      _sock = await Socket.connect(peer.host, peer.port,
          timeout: const Duration(seconds: 5));
      DiagLog.add('interop',
          'channel open ${peer.host}:${peer.port} framing=${peer.framing}');
      _sock!.listen((chunk) {
        for (final msg in _reader.feed(peer.framing ?? 'lines', chunk)) {
          DiagLog.add('interop', 'rx: ${msg.substring(0, msg.length > 160 ? 160 : msg.length)}');
          if (!_msgs.isClosed) _msgs.add(msg);
        }
      }, onDone: () => DiagLog.add('interop', 'channel closed by peer'),
          onError: (e) =>
              DiagLog.add('interop', 'channel error: $e'));
      return true;
    } catch (e) {
      DiagLog.add('interop', 'channel connect failed: $e');
      return false;
    }
  }

  Future<bool> sendText(String text) async {
    final s = _sock;
    if (s == null) return false;
    try {
      final framing = peer.framing ?? 'lines';
      if (framing == 'lenprefix') {
        final body = utf8.encode(jsonEncode({'type': 'text', 'text': text}));
        final out = Uint8List(4 + body.length);
        ByteData.view(out.buffer).setUint32(0, body.length, Endian.big);
        out.setRange(4, out.length, body);
        s.add(out);
      } else if (framing == 'ndjson') {
        s.add(utf8.encode('${jsonEncode({'type': 'text', 'text': text})}\n'));
      } else {
        s.add(utf8.encode('$text\n'));
      }
      await s.flush();
      return true;
    } catch (e) {
      DiagLog.add('interop', 'send failed: $e');
      return false;
    }
  }

  Future<void> close() async {
    try {
      await _sock?.close();
    } catch (_) {}
    _sock = null;
    await _msgs.close();
  }
}

/// Splits a raw TCP stream into messages per framing.
class _RawReader {
  final _buf = BytesBuilder();
  List<int> _bytes() => _buf.toBytes();

  List<String> feed(String framing, List<int> chunk) {
    _buf.add(chunk);
    final out = <String>[];
    if (framing == 'lenprefix') {
      while (true) {
        final b = _bytes();
        if (b.length < 4) break;
        final len =
            ByteData.view(Uint8List.fromList(b).buffer, 0, 4).getUint32(0, Endian.big);
        if (len > 8 * 1024 * 1024) {
          _buf.clear();
          break;
        }
        if (b.length < 4 + len) break;
        out.add(utf8.decode(b.sublist(4, 4 + len), allowMalformed: true));
        final rest = b.sublist(4 + len);
        _buf.clear();
        if (rest.isNotEmpty) _buf.add(rest);
        if (rest.isEmpty) break;
      }
      return out;
    }
    // lines / ndjson: split on \n, keep remainder buffered
    final text = utf8.decode(_bytes(), allowMalformed: true);
    final parts = text.split('\n');
    _buf.clear();
    _buf.add(utf8.encode(parts.removeLast()));
    for (final p in parts) {
      final t = p.trim();
      if (t.isNotEmpty) out.add(t);
    }
    return out;
  }
}
