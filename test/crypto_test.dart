import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lantern_chat/core/identity.dart';
import 'package:lantern_chat/core/protocol.dart';
import 'package:lantern_chat/core/store.dart';

Future<DeviceIdentity> _ephemeral() {
  return DeviceIdentity.loadOrCreate(
    read: () async => null,
    write: (_) async {},
  );
}

void main() {
  test('frame encode/decode round-trips JSON', () {
    final frame =
        LanternProtocol.encodeFrame({'t': 'hello', 'id': 'abc'});
    final reader = FrameReader();
    final out = reader.feed(frame);
    expect(out, hasLength(1));
    expect(decodeJson(out.single)['id'], 'abc');
  });

  test('frame reader handles split chunks', () {
    final frame =
        LanternProtocol.encodeFrame({'t': 'x', 'n': 42});
    final reader = FrameReader();
    final a = reader.feed(frame.sublist(0, 3));
    final b = reader.feed(frame.sublist(3));
    expect(a, isEmpty);
    expect(b, hasLength(1));
    expect(decodeJson(b.single)['n'], 42);
  });

  test('X25519 + HKDF agree on both sides', () async {
    final a = await _ephemeral();
    final b = await _ephemeral();
    final ka = await a.sharedKey((await b.publicKeyB64).isEmpty
        ? <int>[]
        : base64Decode(await b.publicKeyB64));
    final kb = await b.sharedKey(base64Decode(await a.publicKeyB64));
    expect(ka, equals(kb));
    expect(ka, hasLength(32));
  });

  test('AES-GCM seal/open round-trips, tamper fails', () async {
    final a = await _ephemeral();
    final b = await _ephemeral();
    final key = await a.sharedKey(base64Decode(await b.publicKeyB64));
    final sealed = await PayloadBox.seal(key, {'kind': 'text', 'text': 'hi'});
    final plain = await PayloadBox.open(key, sealed);
    expect(plain['text'], 'hi');

    final bad = List<int>.from(sealed);
    bad[20] ^= 0xFF;
    expect(() => PayloadBox.open(key, bad), throwsA(anything));

    // wrong key fails
    final c = await _ephemeral();
    final wrong = await a.sharedKey(base64Decode(await c.publicKeyB64));
    expect(() => PayloadBox.open(wrong, sealed), throwsA(anything));
  });

  test('fingerprint is stable and formatted', () async {
    final a = await _ephemeral();
    final raw = base64Decode(await a.publicKeyB64);
    final f1 = await DeviceIdentity.fingerprint(raw);
    final f2 = await DeviceIdentity.fingerprint(raw);
    expect(f1, f2);
    expect(f1.split(' '), hasLength(4));
  });

  test('message kind wire mapping', () {
    expect(LanternMsgKindX.fromWire('text'), LanternMsgKind.text);
    expect(LanternMsgKindX.fromWire('image'), LanternMsgKind.image);
    expect(LanternMsgKindX.fromWire('nope'), LanternMsgKind.text);
    expect(LanternMsgKind.voice.wire, 'voice');
  });

  test('cryptography primitives available', () async {
    expect(X25519().toString(), isNotEmpty);
    expect(Hmac.sha256().toString(), isNotEmpty);
  });
}
