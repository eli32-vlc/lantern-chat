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

  /// Cryptographic short handle derived from public key.
  /// Format: '#AB3K-7MPR' (8 Crockford base32 chars + dash).
  /// Deterministic: same key always produces the same handle.
  static Future<String> deriveHandle(SimplePublicKey pub) async {
    final h = await Sha256().hash(pub.bytes);
    final b = h.bytes;
    // Use first 5 bytes (40 bits) → 8 base32 chars
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    final bits = (b[0] << 32) | (b[1] << 24) | (b[2] << 16) | (b[3] << 8) | b[4];
    var val = bits;
    final chars = List<String>.filled(8, '0');
    for (var i = 7; i >= 0; i--) {
      chars[i] = alphabet[val & 0x1F];
      val >>= 5;
    }
    return '#${chars.sublist(0, 4).join()}-${chars.sublist(4).join()}';
  }

  Future<String> get handle async {
    // Delegate to account handle if available (all devices share same handle)
    if (AccountIdentity._instance != null) {
      return AccountIdentity._instance!.handle;
    }
    // Fallback: derive from device key (pre-account setup)
    return deriveHandle(publicKey);
  }

  /// Short fingerprint shown on first-connect sheet, e.g. "a3f9 11c0 …".
  static Future<String> fingerprint(List<int> rawPub) async {
    final h = await Sha256().hash(rawPub);
    final hex =
        h.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return List.generate(4, (i) => hex.substring(i * 4, i * 4 + 4)).join(' ');
  }

  /// Combined fingerprint for verification: SHA256 of both public keys
  /// sorted lexicographically. Same on both devices so users can compare.
  static Future<String> combinedFingerprint(
      List<int> rawPubA, List<int> rawPubB) async {
    final sorted = [rawPubA, rawPubB]
      ..sort((a, b) {
        for (var i = 0; i < a.length && i < b.length; i++) {
          if (a[i] != b[i]) return a[i].compareTo(b[i]);
        }
        return a.length.compareTo(b.length);
      });
    final combined = <int>[...sorted[0], ...sorted[1]];
    final h = await Sha256().hash(combined);
    final hex =
        h.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return List.generate(4, (i) => hex.substring(i * 8, i * 8 + 8))
        .join('\n');
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

/// Account identity: Ed25519 signing keypair + handle.
/// One account per person, can have multiple devices.
/// The handle is derived from the account's public key (not device key),
/// so all devices under the same account share the same handle.
class AccountIdentity {
  final String id;
  final SimpleKeyPair signKP;
  final SimplePublicKey signPub;

  AccountIdentity._(this.id, this.signKP, this.signPub);

  static AccountIdentity? _instance;
  static AccountIdentity get instance => _instance!;

  static Future<AccountIdentity> loadOrCreate({
    required Future<Map<String, String>?> Function(String key) readKv,
    required Future<void> Function(String key, String value) writeKv,
  }) async {
    if (_instance != null) return _instance!;
    final ed25519 = Ed25519();
    final storedId = await readKv('account_id');
    final storedPriv = await readKv('account_sign_priv');
    if (storedId != null && storedPriv != null) {
      final seed = base64Decode(storedPriv);
      final kp = await ed25519.newKeyPairFromSeed(seed);
      final pub = await kp.extractPublicKey();
      _instance = AccountIdentity._(storedId, kp, pub);
      return _instance!;
    }
    final kp = await ed25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    final seed = await kp.extractSeed();
    final fresh = AccountIdentity._(const Uuid().v4(), kp, pub);
    await writeKv('account_id', fresh.id);
    await writeKv('account_sign_priv', base64Encode(seed));
    _instance = fresh;
    return fresh;
  }

  Future<String> get publicKeyB64 async => base64Encode(signPub.bytes);

  /// Cryptographic short handle from account public key.
  static Future<String> deriveHandle(SimplePublicKey pub) async {
    final h = await Sha256().hash(pub.bytes);
    final b = h.bytes;
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    final bits =
        (b[0] << 32) | (b[1] << 24) | (b[2] << 16) | (b[3] << 8) | b[4];
    var val = bits;
    final chars = List<String>.filled(8, '0');
    for (var i = 7; i >= 0; i--) {
      chars[i] = alphabet[val & 0x1F];
      val >>= 5;
    }
    return '#${chars.sublist(0, 4).join()}-${chars.sublist(4).join()}';
  }

  Future<String> get handle => deriveHandle(signPub);
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
