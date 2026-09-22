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
  static const txtHandle = 'ah'; // cryptographic short handle, e.g. '#AB3K-7MPR'
  static const txtAccountId = 'aid'; // account UUID (shared across devices)
  static const txtVer = 'v';
  static const txtUdpPort = 'up'; // UDP port for fast payload delivery

  // UDP transport constants
  static const udpMaxPayload = 1400; // max payload per UDP packet (fits in MTU)
  static const udpTypeData = 0x01; // encrypted payload
  static const udpTypeAck = 0x02; // delivery acknowledgment
  static const udpMaxRetries = 10; // retry attempts before TCP fallback
  static const udpRetryMs = 300; // ms between retries
  // UDP header: [msgId 4B][type 1B][length 2B] = 7 bytes
  static const udpHeaderSize = 7;

  // Group protocol frame types
  static const frameGroupInvite = 'group_invite';
  static const frameGroupLeave = 'group_leave';
  static const frameGroupKeyRotate = 'group_key_rotate';

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
