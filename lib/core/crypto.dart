import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// All cryptographic operations in one place.
/// No business logic, no DB, no network — pure crypto.
class Crypto {
  static final _aes = AesGcm.with256bits();
  static final _ed25519 = Ed25519();
  static final _x25519 = X25519();

  // ---- Hashing ----

  static Future<String> sha256Hex(List<int> bytes) async {
    final h = await Sha256().hash(bytes);
    return h.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ---- X25519 (key agreement) ----

  static Future<SimpleKeyPair> x25519New() => _x25519.newKeyPair();
  static Future<SimpleKeyPair> x25519FromSeed(List<int> seed) =>
      _x25519.newKeyPairFromSeed(seed);
  static Future<SimplePublicKey> x25519Pub(SimpleKeyPair kp) =>
      kp.extractPublicKey();
  static Future<List<int>> x25519Seed(SimpleKeyPair kp) =>
      kp.extractPrivateKeyBytes();

  static Future<List<int>> sharedSecret(
      SimpleKeyPair local, List<int> remotePubBytes) async {
    final remote = SimplePublicKey(remotePubBytes, type: KeyPairType.x25519);
    final secret =
        await _x25519.sharedSecretKey(keyPair: local, remotePublicKey: remote);
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: secret,
      nonce: utf8.encode('lantern-chat-v1'),
      info: utf8.encode('payload'),
    );
    return derived.extractBytes();
  }

  // ---- Ed25519 (signing) ----

  static Future<SimpleKeyPair> ed25519New() => _ed25519.newKeyPair();
  static Future<SimpleKeyPair> ed25519FromSeed(List<int> seed) =>
      _ed25519.newKeyPairFromSeed(seed);
  static Future<SimplePublicKey> ed25519Pub(SimpleKeyPair kp) =>
      kp.extractPublicKey();
  static Future<List<int>> ed25519Seed(SimpleKeyPair kp) =>
      kp.extractPrivateKeyBytes();

  static Future<List<int>> sign(SimpleKeyPair kp, List<int> message) async {
    final sig = await _ed25519.sign(message, keyPair: kp);
    return sig.bytes;
  }

  static Future<bool> verify(
      List<int> message, List<int> sigBytes, List<int> pubBytes) async {
    try {
      final pub = SimplePublicKey(pubBytes, type: KeyPairType.ed25519);
      final sig = Signature(sigBytes, publicKey: pub);
      return await _ed25519.verify(message, signature: sig);
    } catch (_) {
      return false;
    }
  }

  // ---- AES-256-GCM (authenticated encryption) ----

  /// Encrypt plaintext with AES-256-GCM.
  /// Returns: nonce (12B) || ciphertext || mac (16B)
  static Future<Uint8List> seal(
      List<int> key, Map<String, dynamic> plain) async {
    final sk = SecretKey(key);
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(plain)),
      secretKey: sk,
      nonce: nonce,
    );
    final out = Uint8List(
        nonce.length + box.cipherText.length + box.mac.bytes.length);
    out.setAll(0, nonce);
    out.setAll(nonce.length, box.cipherText);
    out.setAll(nonce.length + box.cipherText.length, box.mac.bytes);
    return out;
  }

  /// Decrypt AES-256-GCM ciphertext.
  /// Input: nonce (12B) || ciphertext || mac (16B)
  static Future<Map<String, dynamic>> open(
      List<int> key, List<int> packed) async {
    if (packed.length < 28) {
      throw ArgumentError('ciphertext too short: ${packed.length} bytes');
    }
    final sk = SecretKey(key);
    final nonce = packed.sublist(0, 12);
    final macBytes = packed.sublist(packed.length - 16);
    final cipher = packed.sublist(12, packed.length - 16);
    final box = SecretBox(cipher, nonce: nonce, mac: Mac(macBytes));
    final clear = await _aes.decrypt(box, secretKey: sk);
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }

  // ---- Derived key (for groups, exports) ----

  static Future<List<int>> deriveKey({
    required List<int> secret,
    required List<int> nonce,
    required List<int> info,
  }) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(secret),
      nonce: nonce,
      info: info,
    );
    return derived.extractBytes();
  }

  // ---- Verification ----

  /// Generate a verification code from two public keys.
  /// Both devices compute the same code by sorting the keys first.
  static Future<String> verificationCode(List<int> pubA, List<int> pubB) async {
    final sorted = [pubA, pubB]..sort((a, b) {
      for (var i = 0; i < a.length && i < b.length; i++) {
        if (a[i] != b[i]) return a[i].compareTo(b[i]);
      }
      return a.length.compareTo(b.length);
    });
    final combined = [...sorted[0], ...sorted[1]];
    final h = await sha256Hex(combined);
    final groups = <String>[];
    for (var i = 0; i < 30 && i + 5 <= h.length; i += 5) {
      groups.add(h.substring(i, i + 5));
    }
    return groups.join(' ');
  }
}
