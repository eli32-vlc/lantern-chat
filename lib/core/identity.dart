import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

/// Device identity: random UUID + X25519 keypair, stored only on-device.
///
/// First-run: generate and persist locally. Peer auth: exchange public keys
/// via `hello`, derive shared secret with X25519 + HKDF, then AES-GCM per
/// payload. TOFU: show the peer key fingerprint on first connect (like SSH)
/// so LAN eavesdroppers can't MITM silently.
class DeviceIdentity {
  final String id;
  final SimpleKeyPair keyPair;
  final SimplePublicKey publicKey;

  DeviceIdentity._(this.id, this.keyPair, this.publicKey);

  static Future<DeviceIdentity> loadOrCreate({
    required Future<Map<String, String>?> Function() read,
    required Future<void> Function(Map<String, String>) write,
  }) async {
    final x25519 = X25519();
    final stored = await read();
    if (stored != null && stored['id'] != null && stored['priv'] != null) {
      final seed = base64Decode(stored['priv']!);
      final kp = await x25519.newKeyPairFromSeed(seed);
      final pub = await kp.extractPublicKey();
      return DeviceIdentity._(stored['id']!, kp, pub);
    }
    final kp = await x25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    final seed = await kp.extractPrivateKeyBytes();
    final fresh = DeviceIdentity._(const Uuid().v4(), kp, pub);
    await write({'id': fresh.id, 'priv': base64Encode(seed)});
    return fresh;
  }

  Future<String> get publicKeyB64 async => base64Encode(publicKey.bytes);

  /// Short fingerprint shown on first-connect sheet, e.g. "a3f9 11c0 …".
  static Future<String> fingerprint(List<int> rawPub) async {
    final h = await Sha256().hash(rawPub);
    final hex =
        h.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return List.generate(4, (i) => hex.substring(i * 4, i * 4 + 4)).join(' ');
  }

  Future<List<int>> sharedKey(List<int> peerPubBytes) async {
    final remote = SimplePublicKey(peerPubBytes, type: KeyPairType.x25519);
    final secret = await X25519()
        .sharedSecretKey(keyPair: keyPair, remotePublicKey: remote);
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: secret,
      nonce: utf8.encode('lantern-chat-v1'),
      info: utf8.encode('payload'),
    );
    return derived.extractBytes();
  }
}

/// AES-256-GCM payload box. Nonce = 12 random bytes prepended to ciphertext.
class PayloadBox {
  static final _algo = AesGcm.with256bits();

  static Future<Uint8List> seal(List<int> key, Map<String, dynamic> plain) async {
    final secretKey = SecretKey(key);
    final nonce = _algo.newNonce();
    final box = await _algo.encrypt(
      utf8.encode(jsonEncode(plain)),
      secretKey: secretKey,
      nonce: nonce,
    );
    final out =
        Uint8List(nonce.length + box.cipherText.length + box.mac.bytes.length);
    out.setAll(0, nonce);
    out.setAll(nonce.length, box.cipherText);
    out.setAll(nonce.length + box.cipherText.length, box.mac.bytes);
    return out;
  }

  static Future<Map<String, dynamic>> open(
      List<int> key, List<int> packed) async {
    final secretKey = SecretKey(key);
    final nonce = packed.sublist(0, 12);
    final macBytes = packed.sublist(packed.length - 16);
    final cipher = packed.sublist(12, packed.length - 16);
    final box = SecretBox(cipher, nonce: nonce, mac: Mac(macBytes));
    final clear = await _algo.decrypt(box, secretKey: secretKey);
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }
}
