import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'content_store.dart';
import 'diag.dart';
import 'engine.dart';
import 'identity.dart';
import 'protocol.dart';
import 'store.dart';

/// App-level state: identity, profile, engine, chat summaries.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  final ChatStore store = ChatStore();
  final ContentStore contentStore = ContentStore();
  DeviceIdentity? identity;
  AccountIdentity? account;
  LanEngine? engine;
  String displayName = '';
  String status = 'Available';
  bool onboarded = false;
  bool engineUp = false;
  DateTime? _lastResume;

  List<LanPeer> peers = [];
  List<ChatSummary> chats = [];
  StreamSubscription? _peerSub;
  StreamSubscription? _evtSub;
  StreamSubscription? _trustSub;

  LanPeer? trustRequest;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    final docs = await getApplicationDocumentsDirectory();
    await store.open(docs.path);
    await contentStore.open(store.db);
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
    // Load or create account identity (Ed25519 signing key + handle)
    account = await AccountIdentity.loadOrCreate(
      readKv: (k) => store.getKv(k),
      writeKv: (k, v) => store.setKv(k, v),
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
      contentStore: contentStore,
      displayName: displayName,
      status: status,
    );
    engine!.account = account;
    // start() never throws now, but guard anyway: the Peers tab must never
    // hang on a spinner because of an engine exception.
    try {
      await engine!.start();
    } catch (e) {
      engine!.startError = '$e';
    }
    engineUp = true;
    // Start Android foreground service to keep discovery alive in background.
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await const MethodChannel('com.lantern/service')
            .invokeMethod('startService');
      } catch (_) {}
    }
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
    await refreshChats();
    notifyListeners();
  }

  Future<void> _onEvent(LanEvent e) async {
    final kind = e.json['kind'] as String? ?? 'text';
    final msgId = e.json['id'] as String? ?? engine!.messageId();
    final ts = e.json['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch;
    final gid = e.json['gid'] as String?; // group message
    final chatId = gid ?? e.peerId;
    final m = ChatMessage(
      id: msgId,
      chatId: chatId,
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

  /// Tear down the engine (after a failure) and start fresh.
  Future<void> restartEngine() async {
    try {
      await engine?.stop();
    } catch (_) {}
    engine?.dispose();
    engine = null;
    engineUp = false;
    peers = [];
    notifyListeners();
    await startEngine();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onResume();
    }
  }

  /// Called when app resumes from background (iOS sleep/wake, Android doze).
  /// Verifies socket health and restarts discovery if needed.
  Future<void> _onResume() async {
    final now = DateTime.now();
    // Debounce: ignore if resumed less than 5s ago
    if (_lastResume != null &&
        now.difference(_lastResume!) < const Duration(seconds: 5)) {
      return;
    }
    _lastResume = now;
    DiagLog.add('lifecycle', 'app resumed — checking engine health');

    if (engine == null || !engineUp) {
      if (onboarded) {
        DiagLog.add('lifecycle', 'engine not running, restarting');
        await restartEngine();
      }
      return;
    }

    // Verify TCP server is still listening
    try {
      // Quick health check: if port is0, server is dead
      if (engine!.port == 0) {
        DiagLog.add('lifecycle', 'TCP server dead, restarting engine');
        await restartEngine();
        return;
      }
    } catch (_) {
      DiagLog.add('lifecycle', 'engine health check failed, restarting');
      await restartEngine();
      return;
    }

    // Force mDNS re-scan
    DiagLog.add('lifecycle', 'refreshing peers');
    await refreshPeers();
    notifyListeners();
  }

  LanPeer? peerById(String id) {
    for (final p in peers) {
      if (p.id == id) return p;
    }
    return null;
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
      delivered: false, // ack will set to true when peer confirms
    ));
    await refreshChats();
    return ok;
  }

  /// Send a file using the file transfer protocol (offer → accept → chunks).
  Future<bool> sendFile(
    String peerId,
    String path,
    LanternMsgKind kind, {
    String? text,
    int? durationMs,
  }) async {
    final peer = peerById(peerId);
    if (peer == null || engine == null) return false;
    final fname = path.split(Platform.pathSeparator).last;
    final file = File(path);
    if (!await file.exists()) return false;
    final stat = await file.stat();
    final id = engine!.messageId();
    final ts = DateTime.now().millisecondsSinceEpoch;

    // Insert message into DB immediately (shows in chat)
    await store.insertMessage(ChatMessage(
      id: id,
      chatId: peerId,
      senderId: identity!.id,
      kind: kind,
      text: text,
      filePath: path,
      fileName: fname,
      fileBytes: stat.size,
      durationMs: durationMs,
      ts: ts,
      outgoing: true,
      delivered: false,
    ));
    await refreshChats();

    // Offer file via file transfer protocol (non-blocking)
    final transferId = await engine!.offerFile(
      peer, path,
      kind: kind.wire, text: text, durationMs: durationMs,
    );
    DiagLog.add('file', 'offered $fname tid=$transferId');
    return true; // optimistic; progress via callbacks
  }

  // ---- Account export / import (QR key transfer) ----

  /// Generate encrypted QR data for linking another device.
  /// Returns [qrData, passphrase] where qrData is the base64 QR content
  /// and passphrase is the 6-digit code the user must enter on the new device.
  Future<(String, String)> exportAccountQr() async {
    if (account == null) throw StateError('No account');
    final signSeed = await account!.signKP.extractPrivateKeyBytes();
    final plain = utf8.encode(jsonEncode({
      'account_id': account!.id,
      'sign_seed': base64Encode(signSeed),
      'name': displayName,
      'status': status,
      'v': 1,
    }));
    // Generate random 8-char alphanumeric passcode (~48 bits entropy)
    const passChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    final passcode = List.generate(8, (_) => passChars[rng.nextInt(passChars.length)]).join();
    // Derive encryption key from passphrase via HKDF
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final key = await hkdf.deriveKey(
      secretKey: SecretKey(utf8.encode(passcode)),
      nonce: utf8.encode('lantern-export-v1'),
      info: utf8.encode('account-export'),
    );
    final keyBytes = await key.extractBytes();
    // AES-GCM encrypt
    final algo = AesGcm.with256bits();
    final nonce = algo.newNonce();
    final box = await algo.encrypt(plain, secretKey: SecretKey(keyBytes), nonce: nonce);
    final packed = Uint8List(nonce.length + box.cipherText.length + box.mac.bytes.length);
    packed.setAll(0, nonce);
    packed.setAll(nonce.length, box.cipherText);
    packed.setAll(nonce.length + box.cipherText.length, box.mac.bytes);
    return (base64Encode(packed), passcode);
  }

  /// Import account from QR data + passphrase. Replaces current account.
  /// Returns true on success.
  Future<bool> importAccountFromQr(String qrB64, String passcode) async {
    try {
      final packed = base64Decode(qrB64);
      // Derive key from passphrase
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final key = await hkdf.deriveKey(
        secretKey: SecretKey(utf8.encode(passcode)),
        nonce: utf8.encode('lantern-export-v1'),
        info: utf8.encode('account-export'),
      );
      final keyBytes = await key.extractBytes();
      // AES-GCM decrypt
      final algo = AesGcm.with256bits();
      final nonce = packed.sublist(0, 12);
      final macBytes = packed.sublist(packed.length - 16);
      final cipher = packed.sublist(12, packed.length - 16);
      final box = SecretBox(cipher, nonce: nonce, mac: Mac(macBytes));
      final clear = await algo.decrypt(box, secretKey: SecretKey(keyBytes));
      final data = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      final accountId = data['account_id'] as String;
      final signSeed = base64Decode(data['sign_seed'] as String);
      final name = data['name'] as String? ?? displayName;
      final newStatus = data['status'] as String? ?? status;
      // Import account: create Ed25519 keypair from seed
      final imported = await AccountIdentity.fromSeed(accountId, signSeed);
      // Persist
      await store.setKv('account_id', accountId);
      await store.setKv('account_sign_priv', base64Encode(signSeed));
      AccountIdentity.instance = imported;
      account = imported;
      // Update profile
      displayName = name;
      status = newStatus;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('name', displayName);
      await prefs.setString('status', status);
      await prefs.setBool('onboarded', true);
      onboarded = true;
      // Generate a new device keypair (this device is new to the account)
      final x25519 = X25519();
      final deviceKP = await x25519.newKeyPair();
      final deviceSeed = await deviceKP.extractPrivateKeyBytes();
      final deviceId = const Uuid().v4();
      await store.setKv('device_id', deviceId);
      await store.setKv('device_priv', base64Encode(deviceSeed));
      identity = await DeviceIdentity.fromSeed(deviceId, deviceSeed);
      // Restart engine with new identity
      await restartEngine();
      notifyListeners();
      return true;
    } catch (e) {
      return false;
    }
  }

  // ---- Group operations ----

  /// Create a group with selected peers.
  Future<String?> createGroup(String name, List<String> memberIds) async {
    if (engine == null) return null;
    final gid = await engine!.createGroup(name, memberIds);
    await refreshChats();
    return gid;
  }

  /// Send a text message to a group.
  Future<bool> sendGroupText(String groupId, String text) async {
    if (engine == null) return false;
    final g = await store.getGroup(groupId);
    if (g == null) return false;
    final secret = (g['group_secret'] as Uint8List).toList();
    final id = engine!.messageId();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ok = await engine!.sendGroupMessage(groupId, secret, {
      'kind': 'text',
      'id': id,
      'ts': ts,
      'text': text,
      'gid': groupId,
    });
    await store.insertMessage(ChatMessage(
      id: id,
      chatId: groupId,
      senderId: identity!.id,
      kind: LanternMsgKind.text,
      text: text,
      ts: ts,
      outgoing: true,
      delivered: false, // group ack not implemented yet
    ));
    await refreshChats();
    return ok;
  }

  /// Leave a group.
  Future<void> leaveGroup(String groupId) async {
    if (engine != null) {
      await engine!.leaveGroup(groupId);
    }
    await store.db.delete('messages',
        where: 'chat_id = ?', whereArgs: [groupId]);
    await refreshChats();
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
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _peerSub?.cancel();
    _evtSub?.cancel();
    _trustSub?.cancel();
    engine?.dispose();
    super.dispose();
  }
}
