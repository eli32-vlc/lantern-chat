import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'compat.dart';
import 'engine.dart';
import 'identity.dart';
import 'protocol.dart';
import 'store.dart';

/// App-level state: identity, profile, engine, chat summaries.
class AppState extends ChangeNotifier {
  final ChatStore store = ChatStore();
  DeviceIdentity? identity;
  LanEngine? engine;
  String displayName = '';
  String status = 'Available';
  bool onboarded = false;
  bool engineUp = false;

  List<LanPeer> peers = [];
  List<ChatSummary> chats = [];
  StreamSubscription? _peerSub;
  StreamSubscription? _evtSub;
  StreamSubscription? _trustSub;

  LanPeer? trustRequest;

  Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    await store.open(docs.path);
    final prefs = await SharedPreferences.getInstance();
    displayName = prefs.getString('name') ?? '';
    status = prefs.getString('status') ?? 'Available';
    onboarded = prefs.getBool('onboarded') ?? displayName.isNotEmpty;

    identity = await DeviceIdentity.loadOrCreate(
      read: () async {
        final id = await store.getKv('device_id');
        final priv = await store.getKv('device_priv');
        if (id == null || priv == null) return null;
        return {'id': id, 'priv': priv};
      },
      write: (m) async {
        await store.setKv('device_id', m['id']!);
        await store.setKv('device_priv', m['priv']!);
      },
    );
    if (onboarded && displayName.isNotEmpty) {
      await startEngine();
    }
    notifyListeners();
  }

  Future<void> completeOnboarding(String name, String st) async {
    final prefs = await SharedPreferences.getInstance();
    displayName = name.trim();
    status = st;
    await prefs.setString('name', displayName);
    await prefs.setString('status', status);
    await prefs.setBool('onboarded', true);
    onboarded = true;
    notifyListeners();
    await startEngine();
  }

  Future<void> updateProfile(String name, String st) async {
    final prefs = await SharedPreferences.getInstance();
    displayName = name.trim();
    status = st;
    await prefs.setString('name', displayName);
    await prefs.setString('status', status);
    await engine?.updateProfile(displayName, status);
    notifyListeners();
  }

  Future<void> startEngine() async {
    if (engineUp || identity == null) return;
    engine = LanEngine(
      me: identity!,
      store: store,
      displayName: displayName,
      status: status,
    );
    await engine!.start();
    engineUp = true;
    _peerSub = engine!.peers.listen((p) {
      peers = p;
      notifyListeners();
    });
    peers = engine!.currentPeers;
    _trustSub = engine!.pendingTrust.listen((p) {
      trustRequest = p;
      notifyListeners();
    });
    _evtSub = engine!.events.listen(_onEvent);
    // Plaintext compat server: stock AirChat apps inbound → stored under
    // 'compat:<host>:<port>' chats, surfaced in the chat list.
    AirchatCompatServer.instance.attachToStore(store, refreshChats);
    await refreshChats();
    notifyListeners();
  }

  Future<void> _onEvent(LanEvent e) async {
    final kind = e.json['kind'] as String? ?? 'text';
    final msgId = e.json['id'] as String? ?? engine!.messageId();
    final ts = e.json['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch;
    final m = ChatMessage(
      id: msgId,
      chatId: e.peerId,
      senderId: e.peerId,
      kind: LanternMsgKindX.fromWire(kind),
      text: e.json['text'] as String?,
      filePath: null,
      fileName: e.json['name'] as String?,
      fileBytes: e.json['bytes'] as int?,
      durationMs: e.json['dur'] as int?,
      ts: ts,
      outgoing: false,
    );
    // file chunks arrive as separate payloads; assemble in chat screen via store watcher
    if (e.json['chunk'] != null) {
      await _ingestChunk(e.peerId, e.json);
      return;
    }
    await store.insertMessage(m);
    await refreshChats();
    notifyListeners();
  }

  /// Chunked file receiver state: chatId/msgId -> parts
  final _chunks = <String, Map<int, List<int>>>{};
  final _chunkMeta = <String, Map<String, dynamic>>{};

  Future<void> _ingestChunk(String peerId, Map<String, dynamic> j) async {
    final msgId = j['id'] as String;
    final idx = j['chunk'] as int;
    final total = j['chunks'] as int;
    final data = j['data'] as String; // base64 of raw file bytes
    final key = '$peerId/$msgId';
    _chunks.putIfAbsent(key, () => {})[idx] = base64Decode(data);
    _chunkMeta[key] = j;
    if (_chunks[key]!.length == total) {
      final parts = <int>[];
      for (var i = 0; i < total; i++) {
        parts.addAll(_chunks[key]![i]!);
      }
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/inbox/$peerId');
      await dir.create(recursive: true);
      final fname = (j['name'] as String?) ?? msgId;
      final f = File('${dir.path}/$fname');
      await f.writeAsBytes(parts);
      await store.insertMessage(ChatMessage(
        id: msgId,
        chatId: peerId,
        senderId: peerId,
        kind: LanternMsgKindX.fromWire(j['kind'] as String? ?? 'file'),
        text: j['text'] as String?,
        filePath: f.path,
        fileName: fname,
        fileBytes: parts.length,
        durationMs: j['dur'] as int?,
        ts: j['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch,
        outgoing: false,
      ));
      _chunks.remove(key);
      _chunkMeta.remove(key);
      await refreshChats();
      notifyListeners();
    }
  }

  Future<void> refreshChats() async {
    chats = await store.chatSummaries();
    notifyListeners();
  }

  /// Pull-to-refresh hook: re-emit peers + reload summaries.
  Future<void> refreshPeers() async {
    peers = engine?.currentPeers ?? peers;
    await refreshChats();
  }

  LanPeer? peerById(String id) {
    for (final p in peers) {
      if (p.id == id) return p;
    }
    return null;
  }

  static bool isCompatChat(String chatId) => chatId.startsWith('compat:');

  /// Send on a plaintext compat chat (AirChat-style device).
  Future<bool> sendCompatText(String chatId, String text) async {
    final id =
        'compat-${DateTime.now().microsecondsSinceEpoch}';
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ok =
        await AirchatCompatServer.instance.sendText(chatId, text);
    await store.insertMessage(ChatMessage(
      id: id,
      chatId: chatId,
      senderId: identity!.id,
      kind: LanternMsgKind.text,
      text: text,
      ts: ts,
      outgoing: true,
      delivered: ok,
    ));
    await refreshChats();
    return ok;
  }

  Future<bool> sendText(String peerId, String text) async {
    final peer = peerById(peerId);
    if (peer == null || engine == null) return false;
    final id = engine!.messageId();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ok = await engine!.sendTo(peer, {
      'kind': 'text',
      'id': id,
      'ts': ts,
      'text': text,
    });
    await store.insertMessage(ChatMessage(
      id: id,
      chatId: peerId,
      senderId: identity!.id,
      kind: LanternMsgKind.text,
      text: text,
      ts: ts,
      outgoing: true,
      delivered: ok,
    ));
    await refreshChats();
    return ok;
  }

  /// Send a file in 48KB raw chunks (each chunk is its own sealed payload).
  Future<bool> sendFile(
    String peerId,
    String path,
    LanternMsgKind kind, {
    String? text,
    int? durationMs,
  }) async {
    final peer = peerById(peerId);
    if (peer == null || engine == null) return false;
    final bytes = await File(path).readAsBytes();
    final fname = path.split(Platform.pathSeparator).last;
    final id = engine!.messageId();
    final ts = DateTime.now().millisecondsSinceEpoch;
    const chunkSize = 48 * 1024;
    final total = (bytes.length / chunkSize).ceil().clamp(1, 1 << 20);
    var ok = true;
    for (var i = 0; i < total; i++) {
      final end = ((i + 1) * chunkSize).clamp(0, bytes.length);
      final part = bytes.sublist(i * chunkSize, end);
      final b64 = base64Encode(part);
      final sent = await engine!.sendTo(peer, {
        'kind': kind.wire,
        'id': id,
        'ts': ts,
        'name': fname,
        'bytes': bytes.length,
        'chunk': i,
        'chunks': total,
        'data': b64,
        if (text case final t) 'text': t,
        if (durationMs case final d) 'dur': d,
      });
      if (!sent) ok = false;
    }
    await store.insertMessage(ChatMessage(
      id: id,
      chatId: peerId,
      senderId: identity!.id,
      kind: kind,
      text: text,
      filePath: path,
      fileName: fname,
      fileBytes: bytes.length,
      durationMs: durationMs,
      ts: ts,
      outgoing: true,
      delivered: ok,
    ));
    await refreshChats();
    return ok;
  }

  Future<void> dismissTrust() async {
    trustRequest = null;
    notifyListeners();
  }

  Future<void> acceptTrust() async {
    final p = trustRequest;
    trustRequest = null;
    if (p != null && engine != null) {
      await engine!.trust(p);
    }
    await refreshChats();
    notifyListeners();
  }

  @override
  void dispose() {
    _peerSub?.cancel();
    _evtSub?.cancel();
    _trustSub?.cancel();
    engine?.dispose();
    super.dispose();
  }
}
