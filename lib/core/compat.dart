import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'diag.dart';
import 'protocol.dart';
import 'store.dart';

/// AirChat-compatible plaintext server side.
///
/// Problem it solves: stock AirChat connects to a TCP port and speaks an
/// unknown framing. Previously Lantern answered those sockets with silence
/// ("silent framed server") because only Lantern length-prefixed frames were
/// accepted. Now every inbound socket is sniffed first:
///
/// - If the first bytes look like a Lantern frame (4-byte length + JSON with
///   a `t` key), the socket is handed back to the E2EE engine untouched.
/// - Otherwise the socket becomes a plaintext compat session: raw lines,
///   newline-JSON, or length-prefixed JSON are all accepted, and anything
///   AirChat sends is surfaced as a chat message labeled NOT ENCRYPTED.
///   Our replies go back in the same framing the peer used.
///
/// Compat messages are stored in the same sqlite `messages` table but under
/// a synthetic chat id `compat:<host>:<port>` with sender `compat:<name>`,
/// so they can never be confused with verified E2EE peers.
class CompatMessage {
  final String chatId;
  final String text;
  final String peerLabel;
  CompatMessage(
      {required this.chatId, required this.text, required this.peerLabel});
}

class CompatSniffer {
  /// Inspect the first chunk of [sock]. Lantern frames start with a 4-byte
  /// big-endian length whose value matches the remaining bytes and whose
  /// body parses as JSON with a String `t`. Anything else => compat.
  static void route(Socket sock,
      {required FrameReader reader,
      required void Function(Socket s) onLantern}) {
    var done = false;
    late final StreamSubscription sub;
    final buf = BytesBuilder();
    sub = sock.listen((chunk) async {
      if (done) return;
      buf.add(chunk);
      final bytes = buf.toBytes();
      if (bytes.length < 8) return; // need more to decide
      done = true;
      unawaited(sub.cancel());
      if (_looksLikeLantern(bytes)) {
        DiagLog.add('compat', 'lantern framing — handing to E2EE engine');
        onLantern(_PrefixSocket(sock, bytes));
      } else {
        DiagLog.add('compat',
            'non-lantern framing preview=${DiagLog.preview(bytes, 160)} — compat session');
        // ignore: unawaited_futures
        AirchatCompatServer.instance.serve(sock, prelude: bytes);
      }
    }, onError: (_) {
      if (!done) {
        done = true;
        unawaited(sub.cancel());
        onLantern(sock);
      }
    }, onDone: () {
      if (!done) {
        done = true;
        try {
          sock.destroy();
        } catch (_) {}
      }
    });
    // If the peer says nothing within 3s, assume Lantern (our dialer always
    // greets immediately; silent inbound is usually our own hello pending).
    Timer(const Duration(seconds: 3), () {
      if (!done) {
        done = true;
        unawaited(sub.cancel());
        onLantern(_PrefixSocket(sock, buf.toBytes()));
      }
    });
  }

  static bool _looksLikeLantern(List<int> bytes) {
    try {
      if (bytes.length < 5) return false;
      final len = ByteData.view(Uint8List.fromList(bytes).buffer, 0, 4)
          .getUint32(0, Endian.big);
      if (len == 0 || len > 8 * 1024 * 1024) return false;
      if (bytes.length < 4 + len) return false;
      final body = utf8.decode(bytes.sublist(4, 4 + len));
      final m = jsonDecode(body);
      return m is Map && m['t'] is String;
    } catch (_) {
      return false;
    }
  }
}

/// A Socket wrapper that replays already-read bytes first, then live data.
/// Uses a single-subscription controller (not broadcast) so no events are
/// dropped between construction and listen(). The inner socket subscription
/// is created lazily in listen() to avoid data loss.
class _PrefixSocket extends Stream<Uint8List> implements Socket {
  final Socket _inner;
  final List<int> _prefix;
  final _ctrl = StreamController<Uint8List>();
  bool _wired = false;

  _PrefixSocket(this._inner, List<int> prefix) : _prefix = prefix;

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    if (!_wired) {
      _wired = true;
      // Replay prefix bytes immediately, then pipe live socket data.
      if (_prefix.isNotEmpty) {
        // Schedule microtask so the listener is attached first.
        Future.microtask(() {
          if (!_ctrl.isClosed) _ctrl.add(Uint8List.fromList(_prefix));
        });
      }
      _inner.listen(
        (c) { if (!_ctrl.isClosed) _ctrl.add(c); },
        onError: (Object e) { if (!_ctrl.isClosed) _ctrl.addError(e); },
        onDone: () { if (!_ctrl.isClosed) _ctrl.close(); },
      );
    }
    return _ctrl.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  dynamic noSuchMethod(Invocation i) => (_inner as dynamic).noSuchMethod(i);
}

/// Singleton plaintext server. Owns no ports itself — the Lantern engine's
/// ServerSocket hands it sniffed non-Lantern sockets.
class AirchatCompatServer {
  static final AirchatCompatServer instance = AirchatCompatServer._();
  AirchatCompatServer._();

  final _msgCtrl = StreamController<CompatMessage>.broadcast();
  Stream<CompatMessage> get messages => _msgCtrl.stream;

  final _sessions = <String, _CompatSession>{};

  /// Called by AppState.init: pipes compat messages into the store.
  void attachToStore(ChatStore store, Future<void> Function() onChanged) {
    messages.listen((m) async {
      await store.insertMessage(ChatMessage(
        id: 'compat-${DateTime.now().microsecondsSinceEpoch}',
        chatId: m.chatId,
        senderId: m.chatId,
        kind: LanternMsgKind.text,
        text: m.text,
        ts: DateTime.now().millisecondsSinceEpoch,
        outgoing: false,
      ));
      await onChanged();
    });
  }

  Future<void> serve(Socket sock, {List<int>? prelude}) {
    final label =
        '${sock.remoteAddress.address}:${sock.remotePort}';
    final chatId = 'compat:$label';
    final session = _CompatSession(
      sock,
      chatId: chatId,
      peerLabel: label,
      onText: (text) {
        DiagLog.add('compat', 'rx [$label]: ${text.length > 120 ? '${text.substring(0, 120)}…' : text}');
        if (!_msgCtrl.isClosed) {
          _msgCtrl.add(
              CompatMessage(chatId: chatId, text: text, peerLabel: label));
        }
      },
      onClose: () => _sessions.remove(chatId),
    );
    _sessions[chatId] = session;
    // greet in the framing the peer seems to use (updated after first rx)
    session.start(prelude: prelude);
    return Future.value();
  }

  /// Send a plaintext reply on a compat chat (framing auto-matches peer).
  Future<bool> sendText(String chatId, String text) async {
    final s = _sessions[chatId];
    if (s == null) return false;
    return s.send(text);
  }

  bool hasSession(String chatId) => _sessions.containsKey(chatId);
}

class _CompatSession {
  final Socket sock;
  final String chatId;
  final String peerLabel;
  final void Function(String text) onText;
  final void Function() onClose;
  String _framing = 'lines';
  bool _framingLocked = false;
  final _lineBuf = BytesBuilder();
  final _lenBuf = BytesBuilder();

  _CompatSession(this.sock,
      {required this.chatId,
      required this.peerLabel,
      required this.onText,
      required this.onClose});

  void start({List<int>? prelude}) {
    DiagLog.add('compat', 'session open [$peerLabel]');
    if (prelude != null && prelude.isNotEmpty) _feed(prelude);
    sock.listen(_feed, onDone: _done, onError: (_) => _done());
  }

  void _done() {
    DiagLog.add('compat', 'session closed [$peerLabel]');
    try {
      sock.destroy();
    } catch (_) {}
    onClose();
  }

  void _feed(List<int> chunk) {
    // Try length-prefixed first (only if it validates); else lines.
    _lenBuf.add(chunk);
    final lb = _lenBuf.toBytes();
    if (!_framingLocked && lb.length >= 4) {
      try {
        final len = ByteData.view(Uint8List.fromList(lb).buffer, 0, 4)
            .getUint32(0, Endian.big);
        if (len > 0 &&
            len <= 8 * 1024 * 1024 &&
            lb.length >= 4 + len) {
          final body = utf8.decode(lb.sublist(4, 4 + len),
              allowMalformed: true);
          _framing = 'lenprefix';
          _framingLocked = true;
          _emit(body);
          final rest = lb.sublist(4 + len);
          _lenBuf.clear();
          if (rest.isNotEmpty) _feed(rest);
          return;
        }
      } catch (_) {}
    }
    // lines / ndjson
    _lineBuf.add(chunk);
    final text = utf8.decode(_lineBuf.toBytes(), allowMalformed: true);
    final parts = text.split('\n');
    _lineBuf.clear();
    _lineBuf.add(utf8.encode(parts.removeLast()));
    for (final p in parts) {
      final t = p.trim();
      if (t.isEmpty) continue;
      if (!_framingLocked) {
        _framing =
            (t.startsWith('{') || t.startsWith('[')) ? 'ndjson' : 'lines';
        _framingLocked = true;
      }
      _emit(t);
    }
  }

  void _emit(String raw) {
    onText(_display(raw));
  }

  String _display(String raw) {
    final t = raw.trim();
    if ((t.startsWith('{') && t.endsWith('}')) ||
        (t.startsWith('[') && t.endsWith(']'))) {
      try {
        final m = jsonDecode(t);
        if (m is Map) {
          for (final k in ['text', 'message', 'body', 'msg', 'content']) {
            if (m[k] is String && (m[k] as String).isNotEmpty) {
              return m[k] as String;
            }
          }
          // AirChat-style nested? stringify compactly
          final s = m.toString();
          return s.length > 300 ? '${s.substring(0, 300)}…' : s;
        }
      } catch (_) {}
    }
    return t.length > 500 ? '${t.substring(0, 500)}…' : t;
  }

  Future<bool> send(String text) async {
    try {
      if (_framing == 'lenprefix') {
        final body = utf8.encode(jsonEncode({'type': 'text', 'text': text}));
        final out = Uint8List(4 + body.length);
        ByteData.view(out.buffer).setUint32(0, body.length, Endian.big);
        out.setRange(4, out.length, body);
        sock.add(out);
      } else if (_framing == 'ndjson') {
        sock.add(utf8.encode('${jsonEncode({'type': 'text', 'text': text})}\n'));
      } else {
        sock.add(utf8.encode('$text\n'));
      }
      await sock.flush();
      return true;
    } catch (e) {
      DiagLog.add('compat', 'send failed [$peerLabel]: $e');
      return false;
    }
  }
}
