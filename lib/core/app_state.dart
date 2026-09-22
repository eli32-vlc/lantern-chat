import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'content.dart';
import 'crypto.dart';
import 'diag.dart';
import 'groups.dart';
import 'identity.dart';
import 'mesh.dart';
import 'messages.dart';
import 'protocol.dart';
import 'store.dart';

/// App state: the single source of truth.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  final store = Store();
  Device? device;
  Account? account;
  Mesh? mesh;
  Messages? msgs;
  Groups? groups;
  Content? content;

  String displayName = '';
  String status = 'Available';
  bool onboarded = false;
  bool running = false;
  bool notificationsEnabled = true;
  String bgMode = 'notification'; // 'notification', 'music', 'none'
  List<Peer> peers = [];
  DateTime? _lastResume;

  // In-app notification callback (set by HomeShell)
  void Function(String senderName, String text, String chatId)? onMessage;

  // iOS background keep-alive via silent audio
  AudioPlayer? _bgPlayer;
  bool _bgAudioActive = false;

  // Rate limiting
  final _sendTimes = <String, List<DateTime>>{};

  // Lifecycle

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    final docs = await getApplicationDocumentsDirectory();
    await store.open(docs.path);
    final prefs = await SharedPreferences.getInstance();
    displayName = prefs.getString('name') ?? '';
    status = prefs.getString('status') ?? 'Available';
    onboarded = prefs.getBool('onboarded') ?? false;
    notificationsEnabled = prefs.getBool('notifications') ?? true;
    bgMode = prefs.getString('bg_mode') ?? 'notification';

    // Load device
    final devId = await store.getKv('device_id');
    final devPriv = await store.getKv('device_priv');
    if (devId != null && devPriv != null) {
      device = await Device.load(devId, base64Decode(devPriv));
    } else {
      device = await Device.create();
      await store.setKv('device_id', device!.id);
      await store.setKv('device_priv', base64Encode(await device!.seed));
    }

    // Load account
    final accId = await store.getKv('account_id');
    final accPriv = await store.getKv('account_sign_priv');
    if (accId != null && accPriv != null) {
      account = await Account.load(accId, base64Decode(accPriv));
    } else {
      account = await Account.create();
      await store.setKv('account_id', account!.id);
      await store.setKv('account_sign_priv', base64Encode(await account!.seed));
    }

    content = Content(mesh: mesh ?? _dummyMesh(), store: store);
    await content!.init();

    if (onboarded && displayName.isNotEmpty) {
      await startEngine();
    }
    notifyListeners();
  }

  Mesh _dummyMesh() => Mesh(
    device: device!, store: store, displayName: displayName, status: status);

  Future<void> startEngine() async {
    if (running || device == null) return;
    mesh = Mesh(
      device: device!, store: store,
      displayName: displayName, status: status,
    );
    // C2: Set handle and account on mesh
    if (account != null) {
      final h = await account!.handle;
      mesh!.setHandle(h);
    }
    mesh!.setAccount(account);
    await mesh!.start();

    msgs = Messages(mesh: mesh!, store: store, account: account);
    msgs!.start();

    groups = Groups(mesh: mesh!, store: store, account: account);
    content = Content(mesh: mesh!, store: store);
    await content!.init();

    // Wire: when peer discovered, auto-flush queued messages
    mesh!.onPeerDiscovered = (peerId) {
      msgs?.onPeerDiscovered(peerId);
    };

    running = true;
    // C3: Cancel old subscriptions before creating new ones
    _peerSub?.cancel();
    _evtSub?.cancel();
    _peerSub = mesh!.peers.listen((p) { peers = p; notifyListeners(); });
    _evtSub = msgs!.events.listen(_onEvent);
    peers = mesh!.currentPeers;

    // Flush any queued messages from previous session
    msgs?.flushAllQueues();

    notifyListeners();
  }

  Future<void> stopEngine() async {
    msgs?.stop();
    await mesh?.stop();
    mesh?.dispose();
    mesh = null;
    msgs = null;
    groups = null;
    running = false;
    peers = [];
    notifyListeners();
  }

  Future<void> restartEngine() async {
    await stopEngine();
    await startEngine();
  }

  // Lifecycle

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _onPause();
    if (state == AppLifecycleState.resumed) _onResume();
  }

  /// Save pending messages to DB before app is killed.
  Future<void> _onPause() async {
    DiagLog.add('lifecycle', 'paused — saving state');
    if (msgs != null && mesh != null) {
      await store.purgeQueue();
      await store.cleanSeen();
    }
    // Start background audio on iOS to keep app alive
    if (Platform.isIOS && bgMode != 'none') {
      _startBgAudio();
    }
  }

  Future<void> _onResume() async {
    final now = DateTime.now();
    if (_lastResume != null && now.difference(_lastResume!) < Duration(seconds: 5)) return;
    _lastResume = now;
    DiagLog.add('lifecycle', 'resumed');
    // Stop background audio
    _stopBgAudio();
    if (mesh == null || !running) {
      if (onboarded) await restartEngine();
      return;
    }
    if (mesh!.port == 0 || mesh!.udpPort == 0) {
      DiagLog.add('lifecycle', 'dead, restarting');
      await restartEngine();
      return;
    }
    // Flush queued messages
    msgs?.flushAllQueues();
    notifyListeners();
  }

  /// Start silent audio to keep iOS app alive in background. to keep iOS app alive in background.
  void _startBgAudio() {
    if (_bgAudioActive) return;
    _bgAudioActive = true;
    try {
      _bgPlayer = AudioPlayer();
      // Play a silent audio source on loop
      // The asset must exist in assets/ or we use a data URI
      _bgPlayer!.setReleaseMode(ReleaseMode.loop);
      _bgPlayer!.setVolume(0.0);
      // Use a tiny silent WAV as a data URI
      _bgPlayer!.play(UrlSource(
          'data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQAAAAA='));
      DiagLog.add('lifecycle', 'iOS background audio started');
    } catch (e) {
      DiagLog.add('lifecycle', 'bg audio failed: $e');
      _bgAudioActive = false;
    }
  }

  /// Stop background audio.
  void _stopBgAudio() {
    if (!_bgAudioActive) return;
    _bgAudioActive = false;
    try {
      _bgPlayer?.stop();
      _bgPlayer?.dispose();
      _bgPlayer = null;
      DiagLog.add('lifecycle', 'iOS background audio stopped');
    } catch (_) {}
  }

  // Events

  void _onEvent(MsgEvent e) async {
    if (e.type == 'payload' && e.payload != null) {
      try {
        final p = e.payload!;
        final kind = p['kind'] as String? ?? 'text';
        final msgId = p['id'] as String? ?? const Uuid().v4();
        final ts = p['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch;
        final gid = p['gid'] as String?;
        final chatId = gid ?? e.peerId!;

        await store.insertMessage({
          'id': msgId, 'chat_id': chatId, 'sender_id': e.peerId!,
          'kind': kind, 'text': p['text'],
          'file_name': p['name'], 'file_bytes': p['bytes'],
          'duration_ms': p['dur'], 'ts': ts,
          'outgoing': 0, 'delivered': 0,
        });
        await _refreshChats();
        notifyListeners();

        // In-app notification
        if (onMessage != null) {
          final peer = await store.getPeer(e.peerId!);
          final name = peer?['name'] as String? ?? 'Someone';
          final text = p['text'] as String? ?? (kind == 'voice' ? '🎤 Voice message' : '📎 Attachment');
          onMessage!(name, text, chatId);
        }
      } catch (err) {
        DiagLog.add('event', 'error processing payload: $err');
      }
    }
  }

  // Send

  Future<bool> sendText(String peerId, String text) async {
    final peer = _peerById(peerId);
    if (peer == null || mesh == null) return false;
    if (!_rateOk(peerId)) return false;

    final id = const Uuid().v4();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ok = await msgs!.send(peer, {
      'kind': 'text', 'id': id, 'ts': ts, 'text': text,
    });
    await store.insertMessage({
      'id': id, 'chat_id': peerId, 'sender_id': device!.id,
      'kind': 'text', 'text': text, 'ts': ts,
      'outgoing': 1, 'delivered': 0,
    });
    await _refreshChats();
    return ok;
  }

  Future<bool> sendGroupText(String gid, String text) async {
    if (groups == null) return false;
    final g = await store.getGroup(gid);
    if (g == null) return false;
    final secret = (g['group_secret'] as Uint8List).toList();
    final id = const Uuid().v4();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ok = await groups!.sendMessage(gid, secret, {
      'kind': 'text', 'id': id, 'ts': ts, 'text': text, 'gid': gid,
    });
    await store.insertMessage({
      'id': id, 'chat_id': gid, 'sender_id': device!.id,
      'kind': 'text', 'text': text, 'ts': ts,
      'outgoing': 1, 'delivered': 0,
    });
    await _refreshChats();
    return ok;
  }

  Future<String?> createGroup(String name, List<String> memberIds) async {
    if (groups == null) return null;
    final gid = await groups!.create(name, memberIds);
    await _refreshChats();
    return gid;
  }

  // Content

  Future<String> publishContent(String path, {String? name}) async {
    return content!.publish(path, name: name);
  }

  Future<void> requestContent(String hash) async {
    await content!.request(hash);
  }

  Future<void> deleteContent(String hash) async {
    await content!.delete(hash);
  }

  // Export/Import

  Future<(String, String)> exportQr() async {
    if (account == null) throw StateError('No account');
    final seed = await account!.seed;
    // M4: Direct JSON, no double encoding
    final plain = utf8.encode(jsonEncode({
      'account_id': account!.id,
      'sign_seed': base64Encode(seed),
      'name': displayName, 'status': status, 'v': 1,
    }));
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    final pass = List.generate(8, (_) => chars[rng.nextInt(chars.length)]).join();
    final key = await Crypto.deriveKey(
      secret: utf8.encode(pass),
      nonce: utf8.encode('lantern-export-v1'),
      info: utf8.encode('account-export'),
    );
    final sealed = await Crypto.seal(key, {'data': base64Encode(plain)});
    return (base64Encode(sealed), pass);
  }

  Future<String> importQr(String qrB64, String pass, {bool force = false}) async {
    if (account != null && onboarded && !force) return 'confirm';
    try {
      final packed = base64Decode(qrB64);
      if (packed.length < 28) return 'false';
      final key = await Crypto.deriveKey(
        secret: utf8.encode(pass),
        nonce: utf8.encode('lantern-export-v1'),
        info: utf8.encode('account-export'),
      );
      final plain = await Crypto.open(key, packed);
      final data = jsonDecode(utf8.decode(base64Decode(plain['data'] as String))) as Map<String, dynamic>;
      final imported = await Account.importJson(jsonEncode(data));
      await store.setKv('account_id', imported.id);
      await store.setKv('account_sign_priv', base64Encode(await imported.seed));
      account = imported;
      displayName = data['name'] as String? ?? displayName;
      status = data['status'] as String? ?? status;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('name', displayName);
      await prefs.setString('status', status);
      await prefs.setBool('onboarded', true);
      onboarded = true;
      // New device keypair
      device = await Device.create();
      await store.setKv('device_id', device!.id);
      await store.setKv('device_priv', base64Encode(await device!.seed));
      await restartEngine();
      notifyListeners();
      return 'true';
    } catch (_) {
      return 'false';
    }
  }

  Future<String> exportToFile() async {
    if (account == null) throw StateError('No account');
    return account!.exportJson();
  }

  Future<String> importFromFile(String json, {bool force = false}) async {
    if (account != null && onboarded && !force) return 'confirm';
    try {
      final imported = await Account.importJson(json);
      await store.setKv('account_id', imported.id);
      await store.setKv('account_sign_priv', base64Encode(await imported.seed));
      account = imported;
      device = await Device.create();
      await store.setKv('device_id', device!.id);
      await store.setKv('device_priv', base64Encode(await device!.seed));
      await restartEngine();
      notifyListeners();
      return 'true';
    } catch (_) {
      return 'false';
    }
  }

  Future<void> factoryReset() async {
    await stopEngine();
    await store.db.delete('messages');
    await store.db.delete('peers');
    await store.db.delete('groups');
    await store.db.delete('group_members');
    await store.db.delete('content');
    await store.db.delete('content_pieces');
    await store.db.delete('content_peers');
    await store.db.delete('sync_state');
    await store.db.delete('msg_queue');
    await store.db.delete('seen_messages');
    await store.db.delete('kv');
    account = null;
    device = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    onboarded = false;
    displayName = '';
    status = 'Available';
    notifyListeners();
  }

  // Onboarding

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
    // H6: Re-register mDNS with new name
    if (mesh != null) {
      mesh!.displayName = displayName;
      mesh!.status = status;
      await mesh!.reregister();
    }
    notifyListeners();
  }

  // Helpers

  Peer? _peerById(String id) {
    for (final p in peers) {
      if (p.id == id) return p;
    }
    return null;
  }

  bool _rateOk(String peerId) {
    final now = DateTime.now();
    final times = _sendTimes.putIfAbsent(peerId, () => []);
    times.removeWhere((t) => now.difference(t) > Duration(seconds: 1));
    if (times.length >= P.rateLimitPerSec) return false;
    times.add(now);
    return true;
  }

  Future<void> refreshChats() async => _refreshChats();

  Future<void> setNotifications(bool enabled) async {
    notificationsEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications', enabled);
    notifyListeners();
  }

  Future<void> setBgMode(String mode) async {
    bgMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bg_mode', mode);
    if (Platform.isAndroid) {
      if (mode == 'notification' || mode == 'music') {
        await const MethodChannel('com.lantern/service').invokeMethod('startService');
      } else {
        await const MethodChannel('com.lantern/service').invokeMethod('stopService');
      }
    }
    if (Platform.isIOS) {
      if (mode == 'music') {
        _startBgAudio();
      } else {
        _stopBgAudio();
      }
    }
    notifyListeners();
  }

  List<ChatSummary> _chats = [];
  List<ChatSummary> get chats => _chats;

  // C3: Track subscriptions for cleanup
  StreamSubscription? _peerSub;
  StreamSubscription? _evtSub;

  Future<void> _refreshChats() async {
    final peers = await store.allPeers();
    final out = <ChatSummary>[];
    final seen = <String>{};

    for (final peer in peers) {
      if (!seen.add(peer['id'] as String)) continue;
      final rows = await store.messagesFor(peer['id'] as String, limit: 1);
      String? lastText;
      int? lastTs;
      if (rows.isNotEmpty) {
        final m = rows.first;
        lastText = m['text'] as String? ?? (m['file_name'] != null ? '📎 ${m['file_name']}' : m['kind'] as String);
        lastTs = m['ts'] as int;
      }
      final unreadRows = await store.db.rawQuery(
          'SELECT COUNT(*) c FROM messages WHERE chat_id = ? AND outgoing = 0 AND delivered = 0',
          [peer['id']]);
      out.add(ChatSummary(
        id: peer['id'] as String,
        name: peer['name'] as String,
        handle: peer['handle'] as String? ?? '',
        lastText: lastText, lastTs: lastTs,
        unread: (unreadRows.first['c'] as int?) ?? 0,
        isGroup: false,
      ));
    }

    // Groups — only show groups we're members of
    final allGroups = await store.myGroups();
    for (final g in allGroups) {
      final gid = g['id'] as String;
      if (seen.contains(gid)) continue;
      final rows = await store.messagesFor(gid, limit: 1);
      String? lastText;
      int? lastTs;
      if (rows.isNotEmpty) {
        final m = rows.first;
        lastText = m['text'] as String? ?? m['kind'] as String;
        lastTs = m['ts'] as int;
      }
      // H1: Group unread count
      final unreadRows = await store.db.rawQuery(
          'SELECT COUNT(*) c FROM messages WHERE chat_id = ? AND outgoing = 0 AND delivered = 0',
          [gid]);
      out.add(ChatSummary(
        id: gid, name: '👥 ${g['name']}', handle: '',
        lastText: lastText, lastTs: lastTs,
        unread: (unreadRows.first['c'] as int?) ?? 0,
        isGroup: true,
      ));
    }

    out.sort((a, b) => (b.lastTs ?? 0).compareTo(a.lastTs ?? 0));
    _chats = out;
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _peerSub?.cancel();
    _evtSub?.cancel();
    _stopBgAudio();
    msgs?.stop();
    mesh?.dispose();
    super.dispose();
  }
}

class ChatSummary {
  final String id;
  final String name;
  final String handle;
  final String? lastText;
  final int? lastTs;
  final int unread;
  final bool isGroup;

  ChatSummary({
    required this.id, required this.name, this.handle = '',
    this.lastText, this.lastTs, this.unread = 0, this.isGroup = false,
  });
}
