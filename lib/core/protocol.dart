// Lantern wire protocol constants. No logic, just numbers.
class P {
  // Network
  static const serviceType = '_lantern._tcp';
  static const namePrefix = 'lantern-';
  static const protoVersion = 1;
  static const appVersion = '0.3.0';
  static const appBuild = 3;
  static const tcpBacklog = 16;
  static const frameMax = 8 * 1024 * 1024;
  static const pieceSize = 256 * 1024;

  // mDNS TXT keys
  static const txtId = 'id';
  static const txtName = 'nm';
  static const txtStatus = 'st';
  static const txtPort = 'pt';
  static const txtPub = 'pk';
  static const txtHandle = 'ah';
  static const txtAccountId = 'aid';
  static const txtSignPub = 'spk';
  static const txtUdpPort = 'up';
  static const txtVer = 'v';
  static const txtAppVer = 'av';
  static const txtAppBuild = 'ab';

  // Frame types
  static const hello = 'hello';
  static const payload = 'payload';
  static const ack = 'ack';
  static const syncReq = 'sync_req';
  static const syncMsgs = 'sync_msgs';
  static const groupInvite = 'group_invite';
  static const groupLeave = 'group_leave';
  static const groupKeyRotate = 'group_key_rotate';
  static const fileOffer = 'file_offer';
  static const fileAccept = 'file_accept';
  static const fileReject = 'file_reject';
  static const fileCancel = 'file_cancel';
  static const contentAnnounce = 'content_announce';
  static const contentReq = 'content_req';
  static const contentPiece = 'content_piece';
  static const contentSearch = 'content_search';
  static const contentFound = 'content_found';

  // UDP sub-types (first byte of payload)
  static const udpData = 0x01;
  static const udpAck = 0x02;
  static const udpTyping = 0x20;
  static const udpPttStart = 0x10;
  static const udpPttData = 0x11;
  static const udpPttStop = 0x12;
  static const udpPttPresence = 0x13;

  // UDP settings
  static const udpMaxPayload = 1400;
  static const udpMaxRetries = 10;
  static const udpRetryMs = 300;

  // Timing
  static const peerPruneMinutes = 5;
  static const peerPruneCheckSec = 30;
  static const healthCheckSec = 30;
  static const ackTimeoutSec = 30;
  static const ackCheckSec = 10;
  static const syncCooldownSec = 30;
  static const typingThrottleSec = 2;
  static const maxQueueAttempts = 5;
  static const queueMaxAgeHours = 1;
  static const maxFileSize = 50 * 1024 * 1024;
  static const rateLimitPerSec = 10;
  static const contentRequestPerMin = 5;
}
