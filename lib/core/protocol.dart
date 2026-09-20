import 'dart:convert';
import 'dart:typed_data';

/// Wire protocol for Lantern v1. Must stay tiny and LAN-only.
///
/// Transport: plain TCP per peer (one ServerSocket per device).
/// Every frame: 4-byte big-endian length + UTF-8 JSON.
/// After `hello` exchange, `payload` frames carry AES-GCM ciphertext.
class LanternProtocol {
  static const serviceType = '_lantern._tcp';
  static const serviceNamePrefix = 'lantern-';
  static const protoVersion = 1;
  static const tcpBacklog = 16;
  static const frameMaxBytes = 8 * 1024 * 1024; // 8MB per frame (file chunks are 64KB)

  // TXT record keys broadcast over mDNS (all plaintext, non-sensitive except pubkey)
  static const txtId = 'id';
  static const txtName = 'nm';
  static const txtStatus = 'st';
  static const txtPort = 'pt';
  static const txtPub = 'pk'; // base64 raw 32-byte X25519 public key
  static const txtVer = 'v';

  static Uint8List encodeFrame(Map<String, dynamic> json) {
    final body = utf8.encode(jsonEncode(json));
    final out = Uint8List(4 + body.length);
    final view = ByteData.view(out.buffer);
    view.setUint32(0, body.length, Endian.big);
    out.setRange(4, out.length, body);
    return out;
  }
}

/// Logical message kinds stored in sqlite and rendered in UI.
enum LanternMsgKind { text, image, video, file, voice, callEvent, system }

extension LanternMsgKindX on LanternMsgKind {
  String get wire => switch (this) {
        LanternMsgKind.text => 'text',
        LanternMsgKind.image => 'image',
        LanternMsgKind.video => 'video',
        LanternMsgKind.file => 'file',
        LanternMsgKind.voice => 'voice',
        LanternMsgKind.callEvent => 'call',
        LanternMsgKind.system => 'sys',
      };
  static LanternMsgKind fromWire(String? s) => switch (s) {
        'image' => LanternMsgKind.image,
        'video' => LanternMsgKind.video,
        'file' => LanternMsgKind.file,
        'voice' => LanternMsgKind.voice,
        'call' => LanternMsgKind.callEvent,
        'sys' => LanternMsgKind.system,
        _ => LanternMsgKind.text,
      };
}
