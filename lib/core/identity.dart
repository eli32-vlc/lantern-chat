import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import 'crypto.dart';

/// Device identity: X25519 keypair for encryption.
class Device {
  final String id;
  final SimpleKeyPair kp;
  final SimplePublicKey pub;

  Device._(this.id, this.kp, this.pub);

  static Future<Device> create() async {
    final kp = await Crypto.x25519New();
    final pub = await Crypto.x25519Pub(kp);
    return Device._(const Uuid().v4(), kp, pub);
  }

  static Future<Device> load(String id, List<int> seed) async {
    final kp = await Crypto.x25519FromSeed(seed);
    final pub = await Crypto.x25519Pub(kp);
    return Device._(id, kp, pub);
  }

  Future<String> get pubB64 async => base64Encode(pub.bytes);
  Future<List<int>> get seed async => Crypto.x25519Seed(kp);
  Future<List<int>> sharedWith(List<int> peerPub) =>
      Crypto.sharedSecret(kp, peerPub);
}

/// Account identity: Ed25519 signing keypair + handle.
/// One account per person. All devices share the same account.
class Account {
  final String id;
  final SimpleKeyPair signKp;
  final SimplePublicKey signPub;

  Account._(this.id, this.signKp, this.signPub);

  static Future<Account> create() async {
    final kp = await Crypto.ed25519New();
    final pub = await Crypto.ed25519Pub(kp);
    return Account._(const Uuid().v4(), kp, pub);
  }

  static Future<Account> load(String id, List<int> seed) async {
    final kp = await Crypto.ed25519FromSeed(seed);
    final pub = await Crypto.ed25519Pub(kp);
    return Account._(id, kp, pub);
  }

  Future<String> get pubB64 async => base64Encode(signPub.bytes);
  Future<List<int>> get seed async => Crypto.ed25519Seed(signKp);

  Future<String> get handle async {
    final h = await Crypto.sha256Hex(signPub.bytes);
    const abc = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    var val = 0;
    for (var i = 0; i < 5; i++) {
      val = (val << 8) | h.codeUnitAt(i * 2);
    }
    final chars = List<String>.filled(8, '0');
    for (var i = 7; i >= 0; i--) {
      chars[i] = abc[val & 0x1F];
      val >>= 5;
    }
    return '#${chars.sublist(0, 4).join()}-${chars.sublist(4).join()}';
  }

  Future<List<int>> sign(List<int> message) =>
      Crypto.sign(signKp, message);

  static Future<bool> verify(
          List<int> message, List<int> sig, List<int> pub) =>
      Crypto.verify(message, sig, pub);

  Future<String> exportJson() async {
    final s = await seed;
    return jsonEncode({
      'account_id': id,
      'sign_seed': base64Encode(s),
      'v': 1,
    });
  }

  static Future<Account> importJson(String json) async {
    final data = jsonDecode(json) as Map<String, dynamic>;
    return load(
      data['account_id'] as String,
      base64Decode(data['sign_seed'] as String),
    );
  }
}
