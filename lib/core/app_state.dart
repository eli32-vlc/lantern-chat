import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'background_audio.dart';
import 'compat.dart';
import 'engine.dart';
import 'file_transfer.dart';
import 'identity.dart';
import 'protocol.dart';
import 'store.dart';

/// App-level state: identity, profile, engine, chat summaries.
class AppState extends ChangeNotifier {
  final ChatStore store = ChatStore();
  DeviceIdentity? identity;
  AccountIdentity? account;
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
  Future<void> _eventChain = Future.value();
  IncomingFileTransfer? _incomingFiles;

  LanPeer? trustRequest;

  Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    await store.open(docs.path);
    _incomingFiles = IncomingFileTransfer(Directory('${docs.path}/inbox'));
    unawaited(_incomingFiles!.cleanupStale());
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
    // Initialize background audio service (silent audio keep-alive for iOS)
    await BackgroundAudioService.instance.init();
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
    engine!.account = account;
    // start() never throws now, but guard anyway: the Peers tab must never
    // hang on a spinner because of an engine exception.
    try {
      await engine!.start();
    } catch (e) {
      engine!.startError = '$e';
    }
    engineUp = true;
    // Start background service to keep discovery alive.
    // Android: foreground service with notification + wake lock.
    // iOS: background fetch interval for periodic mDNS re-scan.
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await const MethodChannel('com.lantern/service')
            .invokeMethod('startService');
      } catch (_) {}
    }
    // Listen for iOS background fetch callbacks
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      const MethodChannel('com.lantern/service')
          .setMethodCallHandler((call) async {
        if (call.method == 'onBackgroundFetch') {
          // Re-scan mDNS peers and flush queued messages
          try {
            await engine?.refreshDiscovery();
            peers = engine?.currentPeers ?? peers;
            notifyListeners();
          } catch (_) {}
        }
      });
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
    _evtSub = engine!.events.listen((event) {
      // Preserve event order. Concurrent chunk handling can otherwise race
      // writes, duplicate suppression, and completion checks.
      _eventChain = _eventChain.then((_) => _onEvent(event));
    });
    // Plaintext compat server: stock AirChat apps inbound → stored under
    // 'compat:<host>:<port>' chats, surfaced in the chat list.
    AirchatCompatServer.instance.attachToStore(store, refreshChats);
    await refreshChats();
    notifyListeners();
  }

  Future<void> _onEvent(LanEvent e) async {
    final json = e.json;
    final kind = _asString(json['kind']) ?? 'text';
    final msgId = _asString(json['id']);
    final actualMsgId = (msgId != null && msgId.isNotEmpty) ? msgId : engine!.messageId();
    final ts = _asInt(json['ts']) ?? DateTime.now().millisecondsSinceEpoch;
    final gid = _asString(json['gid']);
    final chatId = gid ?? e.peerId;

    // Duplicate detection: skip if this message ID already exists in the store.
    final existing = await store.getMessage(actualMsgId);
    if (existing != null) {
      if (json['chunk'] != null && actualMsgId.isNotEmpty) {
        await engine?.acknowledgeEvent(e, success: true, complete: true);
      } else {
        await engine?.acknowledgeEvent(e, success: true);
      }
      return;
    }

    // file chunks arrive as separate payloads; assemble via _ingestChunk
    if (json['chunk'] != null) {
      await _ingestChunk(e);
      return;
    }

    // Non-chunked file data (single-shot transfer): save to disk
    final rawData = json['data'];
    if (rawData is String && rawData.isNotEmpty && kind != 'text') {
      try {
        final bytes = base64Decode(rawData);
        final declaredBytes = _asInt(json['bytes']);
        if (declaredBytes != null && declaredBytes != bytes.length) {
          await store.insertMessage(ChatMessage(
            id: actualMsgId,
            chatId: chatId,
            senderId: e.peerId,
            kind: LanternMsgKindX.fromWire(kind),
            text: _asString(json['text']),
            filePath: null,
            fileName: _asString(json['name']),
            fileBytes: bytes.length,
            durationMs: _asInt(json['dur']),
            ts: ts,
            outgoing: false,
          ));
          await engine?.acknowledgeEvent(e, success: false);
          return;
        }
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory('${docs.path}/inbox/${_safeIncomingFileName(e.peerId)}');
        await dir.create(recursive: true);
        final fname = _asString(json['name']) ?? actualMsgId;
        final safeName = _safeIncomingFileName(fname);
        final f = File('${dir.path}/$actualMsgId-$safeName');
        final part = File('${f.path}.part');
        await part.writeAsBytes(bytes, flush: true);
        if (await f.exists()) await f.delete();
        await part.rename(f.path);
        await store.insertMessage(ChatMessage(
          id: actualMsgId,
          chatId: chatId,
          senderId: e.peerId,
          kind: LanternMsgKindX.fromWire(kind),
          text: _asString(json['text']),
          filePath: f.path,
          fileName: fname,
          fileBytes: bytes.length,
          durationMs: _asInt(json['dur']),
          ts: ts,
          outgoing: false,
        ));
      } catch (_) {
        await store.insertMessage(ChatMessage(
          id: actualMsgId,
          chatId: chatId,
          senderId: e.peerId,
          kind: LanternMsgKindX.fromWire(kind),
          text: _asString(json['text']),
          filePath: null,
          fileName: _asString(json['name']),
          fileBytes: _asInt(json['bytes']),
          durationMs: _asInt(json['dur']),
          ts: ts,
          outgoing: false,
        ));
        await engine?.acknowledgeEvent(e, success: false);
        return;
      }
    } else {
      await store.insertMessage(ChatMessage(
        id: actualMsgId,
        chatId: chatId,
        senderId: e.peerId,
        kind: LanternMsgKindX.fromWire(kind),
        text: _asString(json['text']),
        filePath: null,
        fileName: _asString(json['name']),
        fileBytes: _asInt(json['bytes']),
        durationMs: _asInt(json['dur']),
        ts: ts,
        outgoing: false,
      ));
    }
    await refreshChats();
    notifyListeners();
    await engine?.acknowledgeEvent(e, success: true);
  }

  /// Safe JSON int extraction — handles int, double, String.
  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// Safe JSON string extraction.
  static String? _asString(dynamic v) {
    if (v is String) return v;
    return null;
  }

  static String _safeIncomingFileName(String name) {
    var safe = name.replaceAll(RegExp(r'[/\\:\r\n]'), '_').trim();
    if (safe.isEmpty) safe = 'file';
    if (safe.length > 160) safe = safe.substring(0, 160);
    return safe;
  }

  Future<void> _ingestChunk(LanEvent e) async {
    final json = e.json;
    final peerId = e.peerId;
    final msgId = _asString(json['id']);
    final index = _asInt(json['chunk']);
    final total = _asInt(json['chunks']);
    final encoded = _asString(json['data']);
    final declaredBytes = _asInt(json['bytes']);

    if (msgId == null ||
        index == null ||
        total == null ||
        total <= 0 ||
        index < 0 ||
        index >= total ||
        total > LanternProtocol.maxFileChunks ||
        declaredBytes == null ||
        declaredBytes < 0 ||
        declaredBytes > LanternProtocol.maxFileBytes) {
      await engine?.acknowledgeEvent(e, success: false);
      return;
    }
    if (encoded == null || (encoded.isEmpty && !(total == 1 && declaredBytes == 0))) {
      await engine?.acknowledgeEvent(e, success: false);
      return;
    }

    final bytes = base64Decode(encoded);
    final transfer = _incomingFiles;
    if (transfer == null) {
      await engine?.acknowledgeEvent(e, success: false);
      return;
    }
    final result = await transfer.accept(
      peerId: peerId,
      msgId: msgId,
      index: index,
      total: total,
      bytes: bytes,
      metadata: json,
    );
    if (!result.transportAccepted) {
      await engine?.acknowledgeEvent(e, success: false);
      return;
    }
    if (!result.complete) {
      await engine?.acknowledgeEvent(e, success: true);
      return;
    }

    if (!result.success) {
      await engine?.acknowledgeEvent(e, success: false, complete: true);
      return;
    }

    final existing = await store.getMessage(msgId);
    if (existing == null) {
      await store.insertMessage(ChatMessage(
        id: msgId,
        chatId: peerId,
        senderId: peerId,
        kind: LanternMsgKindX.fromWire(_asString(json['kind']) ?? 'file'),
        text: result.text,
        filePath: result.finalPath,
        fileName: result.fileName,
        fileBytes: result.fileBytes,
        durationMs: result.durationMs,
        ts: result.timestamp ?? DateTime.now().millisecondsSinceEpoch,
        outgoing: false,
      ));
      await refreshChats();
      notifyListeners();
    }
    await transfer.discardTransfer(peerId: peerId, msgId: msgId);
    await engine?.acknowledgeEvent(e, success: true, complete: true);
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
      delivered: false, // ack will set to true when peer confirms
    ));
    await refreshChats();
    return ok;
  }

  /// Send a file in durable 48KB chunks. The source is copied into app-owned
  /// storage, hashed while copying, then transmitted from that durable copy.
  Future<bool> sendFile(
    String peerId,
    String path,
    LanternMsgKind kind, {
    String? text,
    int? durationMs,
  }) async {
    final peer = peerById(peerId);
    final activeEngine = engine;
    if (peer == null || activeEngine == null) return false;

    final source = File(path);
    if (!await source.exists()) return false;
    final size = await source.length();
    if (size > LanternProtocol.maxFileBytes) return false;

    final docs = await getApplicationDocumentsDirectory();
    final outbox = Directory('${docs.path}/outbox');
    await outbox.create(recursive: true);
    final id = activeEngine.messageId();
    final rawName = _safeIncomingFileName(path.split(Platform.pathSeparator).last);
    final stored = File('${outbox.path}/$id-$rawName');
    final copy = await copyAndHash(source, stored);
    if (copy.bytes != size) {
      return false;
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final total = size == 0
        ? 1
        : (size / LanternProtocol.fileChunkSize).ceil();
    if (total > LanternProtocol.maxFileChunks) {
      return false;
    }

    await store.insertMessage(ChatMessage(
      id: id,
      chatId: peerId,
      senderId: identity!.id,
      kind: kind,
      text: text,
      filePath: stored.path,
      fileName: rawName,
      fileBytes: size,
      durationMs: durationMs,
      ts: ts,
      outgoing: true,
      delivered: false,
    ));

    var allQueued = true;
    for (var i = 0; i < total; i++) {
      final start = i * LanternProtocol.fileChunkSize;
      final end = size == 0
          ? 0
          : (start + LanternProtocol.fileChunkSize).clamp(0, size);
      final part = size == 0
          ? <int>[]
          : await _readFileRange(stored, start, end);
      final queued = await activeEngine.sendTo(peer, {
        'kind': kind.wire,
        'id': id,
        '_ack': '$id:c${i.toString().padLeft(6, '0')}',
        'ts': ts,
        'name': rawName,
        'bytes': size,
        'sha256': copy.hash,
        'chunk': i,
        'chunks': total,
        'data': base64Encode(part),
        if (text case final value) 'text': value,
        if (durationMs case final value) 'dur': value,
      });
      if (!queued) allQueued = false;
    }

    await refreshChats();
    return allQueued;
  }

  static Future<List<int>> _readFileRange(
    File file,
    int start,
    int endExclusive,
  ) async {
    if (start >= endExclusive) return const [];
    final output = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(start, endExclusive)) {
      output.add(chunk);
    }
    return output.takeBytes();
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
  void dispose() {
    _peerSub?.cancel();
    _evtSub?.cancel();
    _trustSub?.cancel();
    engine?.dispose();
    unawaited(BackgroundAudioService.instance.dispose());
    super.dispose();
  }
}
