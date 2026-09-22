import 'dart:convert';
import 'dart:math';

import 'package:uuid/uuid.dart';

import 'crypto.dart';
import 'diag.dart';
import 'identity.dart';
import 'mesh.dart';
import 'protocol.dart';
import 'store.dart';

/// Group chat operations.
class Groups {
  final Mesh mesh;
  final Store store;
  final Account? account;
  static final _rng = Random.secure();

  Groups({required this.mesh, required this.store, this.account});

  /// Create a group and invite members.
  Future<String> create(String name, List<String> memberIds) async {
    final gid = 'grp-${const Uuid().v4()}';
    final secret = List<int>.generate(32, (_) => _rng.nextInt(256));
    await store.storeGroup(gid, name, secret, createdBy: mesh.device.id);
    await store.addMember(gid, mesh.device.id, role: 'admin');
    for (final mid in memberIds) {
      await store.addMember(gid, mid);
    }
    // Send invites
    final secretB64 = base64Encode(secret);
    for (final mid in memberIds) {
      final known = await store.getPeer(mid);
      if (known == null || known['trusted'] != 1) continue;
      final key = await mesh.sessionFor(mid, known['pub'] as String);
      if (key == null) continue;
      final sealed = await Crypto.seal(key, {'secret': secretB64});
      final peer = mesh.currentPeers.where((p) => p.id == mid).firstOrNull;
      if (peer == null) continue;
      await mesh.sendFrame(peer, {
        't': P.groupInvite, 'from': mesh.device.id,
        'gid': gid, 'gname': name, 'gsec': base64Encode(sealed),
      });
    }
    DiagLog.add('group', 'created $name ($gid)');
    return gid;
  }

  /// Send a message to a group.
  Future<bool> sendMessage(String gid, List<int> secret,
      Map<String, dynamic> payload) async {
    final key = await Crypto.deriveKey(
      secret: secret,
      nonce: utf8.encode('lantern-group-v1'),
      info: utf8.encode('group-encrypt'),
    );
    final sealed = await Crypto.seal(key, payload);
    final members = await store.memberIds(gid);
    var anySent = false;
    for (final mid in members) {
      if (mid == mesh.device.id) continue;
      final peer = mesh.currentPeers.where((p) => p.id == mid).firstOrNull;
      if (peer == null) continue;
      try {
        final frame = <String, dynamic>{
          't': P.payload, 'from': mesh.device.id,
          'blob': base64Encode(sealed), 'gid': gid,
        };
        // Sign the group message
        if (account != null) {
          frame['sig'] = base64Encode(await account!.sign(sealed));
          frame['sign_pub'] = await account!.pubB64;
        }
        await mesh.sendFrame(peer, frame);
        anySent = true;
      } catch (_) {}
    }
    return anySent;
  }

  /// Leave a group.
  Future<void> leave(String gid) async {
    final members = await store.memberIds(gid);
    for (final mid in members) {
      if (mid == mesh.device.id) continue;
      final peer = mesh.currentPeers.where((p) => p.id == mid).firstOrNull;
      if (peer == null) continue;
      try {
        await mesh.sendFrame(peer, {
          't': P.groupLeave, 'from': mesh.device.id, 'gid': gid,
        });
      } catch (_) {}
    }
    await store.removeMember(gid, mesh.device.id);
    final remaining = await store.memberIds(gid);
    if (remaining.isEmpty) {
      await store.db.delete('groups', where: 'id = ?', whereArgs: [gid]);
    }
  }

  /// Handle incoming group frame.
  Future<void> handleFrame(Map<String, dynamic> json) async {
    final t = json['t'] as String?;
    final from = json['from'] as String? ?? '';

    if (t == P.groupInvite) {
      final gid = json['gid'] as String? ?? '';
      final gname = json['gname'] as String? ?? 'Group';
      final gsecB64 = json['gsec'] as String? ?? '';
      if (from.isEmpty || gid.isEmpty || gsecB64.isEmpty) return;
      final known = await store.getPeer(from);
      if (known == null || known['trusted'] != 1) return;
      final key = await mesh.sessionFor(from, known['pub'] as String);
      if (key == null) return;
      try {
        final plain = await Crypto.open(key, base64Decode(gsecB64));
        final groupSecret = base64Decode(plain['secret'] as String);
        await store.storeGroup(gid, gname, groupSecret, createdBy: from);
        await store.addMember(gid, from, role: 'admin');
        await store.addMember(gid, mesh.device.id);
        DiagLog.add('group', 'joined $gname ($gid)');
      } catch (e) {
        DiagLog.add('group', 'invite decrypt failed: $e');
      }
    } else if (t == P.groupLeave) {
      final gid = json['gid'] as String? ?? '';
      if (from.isEmpty || gid.isEmpty) return;
      await store.removeMember(gid, from);
      DiagLog.add('group', '$from left $gid');
    } else if (t == P.groupKeyRotate) {
      final gid = json['gid'] as String? ?? '';
      final gsecB64 = json['gsec'] as String? ?? '';
      if (from.isEmpty || gid.isEmpty || gsecB64.isEmpty) return;
      final known = await store.getPeer(from);
      if (known == null || known['trusted'] != 1) return;
      final key = await mesh.sessionFor(from, known['pub'] as String);
      if (key == null) return;
      try {
        final plain = await Crypto.open(key, base64Decode(gsecB64));
        final newSecret = base64Decode(plain['secret'] as String);
        await store.updateGroupSecret(gid, newSecret);
        DiagLog.add('group', 'key rotated $gid');
      } catch (_) {}
    }
  }
}
