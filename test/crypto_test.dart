import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lantern_chat/core/crypto.dart';
import 'package:lantern_chat/core/identity.dart';
import 'package:lantern_chat/core/mesh.dart';
import 'package:lantern_chat/core/protocol.dart';

void main() {
  test('frame encode/decode round-trips JSON', () {
    final frame = Mesh.encode({'t': 'hello', 'id': 'abc'});
    final reader = FrameReader();
    final out = reader.feed(frame);
    expect(out, hasLength(1));
    final decoded = jsonDecode(utf8.decode(out.single)) as Map<String, dynamic>;
    expect(decoded['id'], 'abc');
  });

  test('frame reader handles split chunks', () {
    final frame = Mesh.encode({'t': 'x', 'n': 42});
    final reader = FrameReader();
    final a = reader.feed(frame.sublist(0, 3));
    final b = reader.feed(frame.sublist(3));
    expect(a, isEmpty);
    expect(b, hasLength(1));
    final decoded = jsonDecode(utf8.decode(b.single)) as Map<String, dynamic>;
    expect(decoded['n'], 42);
  });

  test('X25519 + HKDF agree on both sides', () async {
    final a = await Device.create();
    final b = await Device.create();
    final ka = await a.sharedWith(b.pub.bytes);
    final kb = await b.sharedWith(a.pub.bytes);
    expect(ka, equals(kb));
    expect(ka, hasLength(32));
  });

  test('AES-GCM seal/open round-trips, tamper fails', () async {
    final a = await Device.create();
    final b = await Device.create();
    final key = await a.sharedWith(b.pub.bytes);
    final sealed = await Crypto.seal(key, {'kind': 'text', 'text': 'hi'});
    final plain = await Crypto.open(key, sealed);
    expect(plain['text'], 'hi');

    final bad = List<int>.from(sealed);
    bad[20] ^= 0xFF;
    expect(() => Crypto.open(key, bad), throwsA(anything));

    final c = await Device.create();
    final wrong = await a.sharedWith(c.pub.bytes);
    expect(() => Crypto.open(wrong, sealed), throwsA(anything));
  });

  test('handle is stable and formatted', () async {
    final a = await Account.create();
    final h1 = await a.handle;
    final h2 = await a.handle;
    expect(h1, h2);
    expect(h1.startsWith('#'), isTrue);
    expect(h1.length, 10); // #XXXX-XXXX
  });

  test('Ed25519 sign/verify round-trips', () async {
    final a = await Account.create();
    final msg = utf8.encode('hello world');
    final sig = await a.sign(msg);
    final valid = await Account.verify(msg, sig, a.signPub.bytes);
    expect(valid, isTrue);

    final wrong = await Account.create();
    final invalid = await Account.verify(msg, sig, wrong.signPub.bytes);
    expect(invalid, isFalse);
  });

  test('cryptography primitives available', () async {
    expect(X25519().toString(), isNotEmpty);
    expect(Hmac.sha256().toString(), isNotEmpty);
    expect(Ed25519().toString(), isNotEmpty);
  });
}
