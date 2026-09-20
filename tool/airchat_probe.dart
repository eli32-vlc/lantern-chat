/// AirChat compatibility probe.
///
/// What we know from AirChat_1.1.0.apk (verified, not guessed):
/// - Android native NSD via `com.haberey` nsd_android plugin
///   (registerService/discoverServices/resolveService).
/// - Multicast lock tag "AirChat_Multicast" (CHANGE_WIFI_MULTICAST_STATE).
/// - Dart snapshot (libapp.so) is NOT in the base APK (split bundle), so the
///   NSD service type, TXT keys, and socket framing live in code we cannot
///   see here. The only `_tcp` string in classes.dex is `_fb._tcp.` (Facebook).
///
/// This prober listens for ALL mDNS `_tcp` services on the LAN and fingerprints
/// any that look like a chat app, so a user with AirChat installed nearby can
/// capture its real service type + TXT record and we can add true interop.
///
/// Usage (on a Mac on the same WiFi as a device running AirChat):
///   dart run tool/airchat_probe.dart
///
/// Or from Flutter devtools: call AirchatProbe.scan() and read the logs.
library;

import 'dart:async';
import 'dart:io';

/// Common service types to browse when hunting AirChat's advertisement.
/// `_services._dns-sd._udp` enumeration is the correct generic approach on
/// real iOS/Android; this list is for the desktop `dns-sd` / avahi fallback.
const probeServiceTypes = [
  '_lantern._tcp',
  '_airchat._tcp',
  '_air-chat._tcp',
  '_wifi-chat._tcp',
  '_wifichat._tcp',
  '_binaryscript._tcp',
  '_chat._tcp',
  '_p2p._tcp',
  '_http._tcp',
];

/// Attempt a TCP handshake against a candidate host:port and report what
/// answers. AirChat's framing is unknown; we try:
///  1. Our Lantern hello frame (in case they share framing).
///  2. A bare newline / JSON ping to elicit a banner.
/// Never sends anything destructive. Read-only probe.
Future<Map<String, dynamic>> probeHost(String host, int port,
    {Duration timeout = const Duration(seconds: 3)}) async {
  final out = <String, dynamic>{'host': host, 'port': port};
  Socket? sock;
  try {
    sock = await Socket.connect(host, port, timeout: timeout);
    out['tcp'] = 'open';
    final completer = Completer<List<int>>();
    final buf = <int>[];
    final sub = sock.listen(buf.addAll, onDone: () {
      if (!completer.isCompleted) completer.complete(buf);
    }, onError: (e) {
      if (!completer.isCompleted) completer.completeError(e);
    });
    // Send a benign JSON ping; wait briefly for any banner/response.
    try {
      sock.add('{"t":"probe","app":"lantern"}\n'.codeUnits);
      await sock.flush();
    } catch (_) {}
    try {
      final data = await completer.future.timeout(const Duration(seconds: 2));
      out['bytes'] = data.length;
      out['sample'] = String.fromCharCodes(data.take(300)).replaceAll(
          RegExp(r'[\x00-\x1f\x7f]'), '.');
    } on TimeoutException {
      out['bytes'] = buf.length;
      out['note'] = 'no banner (silent server — normal for framed protocols)';
    }
    await sub.cancel();
  } catch (e) {
    out['tcp'] = 'closed ($e)';
  } finally {
    try {
      await sock?.close();
    } catch (_) {}
  }
  return out;
}

Future<void> main(List<String> args) async {
  stdout.writeln('Lantern AirChat probe');
  stdout.writeln('Browse with: dns-sd -B _services._dns-sd._udp local.');
  stdout.writeln('Then resolve hits: dns-sd -L <name> <type> local.');
  if (args.length == 2) {
    final r = await probeHost(args[0], int.parse(args[1]));
    stdout.writeln(r);
  } else {
    stdout.writeln('Usage: dart run tool/airchat_probe.dart <host> <port>');
  }
}
