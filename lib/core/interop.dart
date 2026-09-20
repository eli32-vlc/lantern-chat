import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nsd/nsd.dart';

import 'protocol.dart';

/// Interop listener: alongside our own `_lantern._tcp` service, also browse
/// for AirChat instances and surface them read-only in the Peers tab as
/// "AirChat (incompatible)" with a one-tap probe action.
///
/// Why read-only: AirChat's Dart snapshot (service type, TXT keys, socket
/// framing, auth) is not in the base APK we audited — it ships in a split
/// bundle (libapp.so). Until its real wire format is captured on-LAN with
/// tool/airchat_probe.dart, we cannot exchange messages with it, and its
/// messages are UNENCRYPTED per its own ToS — bridging them into Lantern's
/// E2EE chats would be a security downgrade. So we show presence only.
///
/// Once the probe captures the real format, implement `AirchatFramer`
/// (below, stubbed) and flip `canChat` per peer.
class InteropPeer {
  final String name;
  final String host;
  final int port;
  final String serviceType;
  final Map<String, String> txt;
  final DateTime seen;

  InteropPeer({
    required this.name,
    required this.host,
    required this.port,
    required this.serviceType,
    required this.txt,
  }) : seen = DateTime.now();
}

/// Candidate AirChat-like service types to browse. Cheap: a handful of
/// parallel NSD discoveries; each is stopped after [browseWindow].
class InteropScanner {
  static const candidates = [
    '_airchat._tcp',
    '_air-chat._tcp',
    '_wifi-chat._tcp',
    '_wifichat._tcp',
    '_lantern._tcp', // our own, for self-test
  ];

  final _found = <String, InteropPeer>{};
  final _ctrl = StreamController<List<InteropPeer>>.broadcast();
  final _subs = <Discovery>[];
  Timer? _stopTimer;

  Stream<List<InteropPeer>> get found => _ctrl.stream;
  List<InteropPeer> get current => _found.values.toList();

  /// Browse for [browseWindow], then stop discoveries (battery-friendly).
  /// Call again on pull-to-refresh.
  Future<void> scan(
      {Duration browseWindow = const Duration(seconds: 12)}) async {
    _stopTimer?.cancel();
    for (final type in candidates) {
      try {
        final d = await startDiscovery(type,
            autoResolve: true, ipLookupType: IpLookupType.v4);
        d.addServiceListener((svc, status) {
          if (status == ServiceStatus.lost) return;
          _ingest(type, svc);
        });
        for (final s in d.services) {
          _ingest(type, s);
        }
        _subs.add(d);
      } catch (_) {
        // invalid/unsupported type on this OS — skip
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
      if (host.endsWith('.local') || host.endsWith('.local.')) return;
      final txt = <String, String>{};
      (svc.txt ?? {}).forEach((k, v) {
        if (v != null) {
          txt[k] = utf8.decode(v, allowMalformed: true);
        }
      });
      // Skip our own Lantern instances (handled by the main engine).
      if (type == LanternProtocol.serviceType) return;
      final key = '$type/${svc.name}/$host:${svc.port}';
      _found[key] = InteropPeer(
        name: svc.name ?? 'AirChat device',
        host: host,
        port: svc.port!,
        serviceType: type,
        txt: txt,
      );
      if (!_ctrl.isClosed) _ctrl.add(current);
    } catch (_) {}
  }

  /// Best-effort plaintext probe of an interop peer. Returns a short
  /// human-readable verdict. Never sends credentials.
  Future<String> probe(InteropPeer peer) async {
    Socket? sock;
    try {
      sock = await Socket.connect(peer.host, peer.port,
          timeout: const Duration(seconds: 3));
      final buf = BytesBuilder();
      final done = Completer<void>();
      sock.listen(buf.add, onDone: () => done.complete(),
          onError: (_) => done.complete());
      try {
        sock.add(utf8.encode('{"t":"probe","app":"lantern"}\n'));
        await sock.flush();
      } catch (_) {}
      await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      final n = buf.length;
      if (n == 0) {
        return 'Silent framed server — format unknown. Capture with tool/airchat_probe.dart.';
      }
      final bytes = buf.toBytes();
      final sample =
          utf8.decode(bytes.take(200).toList(), allowMalformed: true);
      return 'Answered $n bytes: $sample';
    } catch (e) {
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
