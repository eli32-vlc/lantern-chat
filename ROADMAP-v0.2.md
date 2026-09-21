# Lantern v0.2 Roadmap

Identity, Multi-Device Sync, Group Chat, Verification.

---

## Problem Statement

Today Lantern has three identity gaps:
1. **Name collisions** — Two people named "alex" on the same LAN are indistinguishable
2. **Single device** — Identity is locked to one device; losing it means losing all history
3. **No groups** — 1:1 chat only; no way to have a room with 3+ people
4. **Weak verification** — TOFU fingerprint is shown once, easy to ignore

---

## Architecture: Account != Device

The biggest structural change: **separate Account from Device**.

```
Today:
  DeviceIdentity (UUID + X25519 keypair) = everything

Tomorrow:
  AccountIdentity (UUID + Ed25519 signing key) = the "person"
    +-- DeviceIdentity (UUID + X25519 keypair) = one installation
    +-- DeviceIdentity (UUID + X25519 keypair) = another installation
```

- **Account** = who you are. One per person. Generates a short handle.
- **Device** = where you are. One per phone/laptop. Owns the X25519 keypair used for E2EE.
- **Account signs Device** — a device linked to an account carries a signed certificate
  ("I am device X belonging to account Y"). Other peers verify the signature.

---

## Feature 1: Cryptographic Short Handle

**Goal:** Every user has a unique, short, verifiable identifier that prevents
"two Alexes" confusion.

**Design:**
```
handle = '#' + base32(SHA256(account_pubkey)[:5])
       = '#AB3K-7MPR'
```

- 8 chars (plus dash for readability), derived deterministically from the account's
  public key
- Displayed everywhere: peers list, chat header, trust sheet
- Format: `alex #AB3K` (name + short handle)
- The handle is **not secret** — it's public identity
- Changing your name doesn't change the handle

**Data model:**
```dart
class AccountIdentity {
  final String id;              // UUID
  final SimpleKeyPair signKP;   // Ed25519 signing key
  final SimplePublicKey signPub;
  final String handle;          // '#AB3K-7MPR'

  // Signs device certificates
  Future<List<int>> signDevice(SimplePublicKey devicePub);
}
```

**mDNS TXT changes:**
```
  ah: '#AB3K-7MPR'                    (account handle)
  ad: <base64 of device certificate>  (signed by account key)
```

---

## Feature 2: Key Export & Multi-Device Sync

**Goal:** Use Lantern on phone + laptop. Same identity, synced history.

### 2a. Key Export (QR Code)

**Flow:**
1. Device A (already set up): Settings -> "Link another device" -> shows QR code
2. QR encodes: `{ account_id, account_sign_privkey, display_name, status }`
   encrypted with a one-time passphrase shown on screen
3. Device B: Onboarding -> "I have an account" -> scans QR -> enters passphrase
4. Device B generates its own X25519 device keypair, gets signed by the account key
5. Both devices now belong to the same account

**QR content (encrypted):**
```json
{
  "account_id": "uuid",
  "sign_seed": "base64 Ed25519 seed",
  "name": "alex",
  "status": "Available",
  "v": 1
}
```
Encrypted with AES-256-GCM using a 6-digit passphrase displayed on the
exporter's screen. The passphrase is derived via HKDF from the digits.

### 2b. LAN Message Sync

**When:** Devices with the same `account_id` discover each other on LAN.

**Protocol:**
```
Device A -> Device B:  { t:'sync_req', since: <last_known_ts> }
Device B -> Device A:  { t:'sync_msgs', messages: [...], cursor: <newest_ts> }
Device A: stores any missing messages, updates cursor
```

**Key rule:** Only sync between devices that share the same `account_id` AND have
mutually verified device certificates. This prevents a compromised device from
harvesting another user's history.

**Conflict resolution:** Last-write-wins on `(chat_id, msg_id)` primary key.
Messages are immutable once created.

---

## Feature 3: Group Chat

**Goal:** E2EE chat rooms with 3+ people.

### Group Creation
1. Creator generates: `group_id` (UUID) + `group_name`
2. Creator picks initial members from trusted peers
3. For each member: encrypt the group secret with the member's pairwise shared key,
   send as `{t:'group_invite', group_id, group_name, group_key_encrypted}`

### Group Encryption
```
Group key = HKDF(group_secret, "lantern-group-v1")
Each message: AES-GCM(plaintext, group_key)
```

- Encrypt **once** with the group key, send the same ciphertext to all members
- Each member decrypts with the shared group key
- Efficient: O(1) encryption regardless of group size

### Member Changes
- **Add:** Encrypt group key with new member's pairwise key, send invite
- **Remove:** Generate new group key, re-encrypt and send to remaining members.
  Old key is discarded.
- **Leave:** Member sends `{t:'group_leave', group_id}`. Creator rotates key.

### Group Metadata

```sql
CREATE TABLE groups(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  group_key BLOB NOT NULL,
  created_by TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE group_members(
  group_id TEXT NOT NULL,
  peer_id TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member',  -- 'admin' | 'member'
  joined_at INTEGER NOT NULL,
  PRIMARY KEY (group_id, peer_id)
);
```

### Message Routing
- Sender encrypts once with group key
- Sends to each online member via existing `sendTo` (inner payload has
  `{'t':'gmsg', 'gid': group_id, ...}`)
- Offline members get the message when they come online (stored by other group
  members temporarily, or via sync)

---

## Feature 4: Verification Upgrades

**Goal:** Make verification easy, visual, and persistent.

### 4a. QR Code Verification
- Trust sheet shows a QR code encoding both fingerprints
- Scanning the other person's QR auto-verifies if fingerprints match
- Works when you're physically together (most secure)

### 4b. Safety Numbers
```
safety_number = SHA256(sorted([my_account_pubkey, peer_account_pubkey]))
displayed as: 12345 67890 12345 67890 12345 67890 (30 digits, 6 groups)
```

- Shown in chat header (tap to expand)
- Changes if either party's key changes -> visible warning banner
- Users can compare safety numbers out-of-band (e.g., read over a phone call)

### 4c. Device Attestation (Multi-Device Trust)
- When a new device is linked to an account, existing peers see:
  "Alex linked a new device"
- The new device inherits the trust level of the account
- Peers verify the device certificate signature before accepting

---

## Database Migration (v1 -> v2)

```sql
-- New tables
CREATE TABLE accounts(
  id TEXT PRIMARY KEY,
  handle TEXT NOT NULL UNIQUE,
  sign_pub BLOB NOT NULL,
  sign_priv BLOB NOT NULL,
  display_name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'Available'
);

CREATE TABLE devices(
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  pub BLOB NOT NULL,
  priv BLOB NOT NULL,
  cert BLOB NOT NULL,          -- signed by account key
  is_current INTEGER NOT NULL DEFAULT 0,
  linked_at INTEGER NOT NULL,
  FOREIGN KEY (account_id) REFERENCES accounts(id)
);

CREATE TABLE groups(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  group_key BLOB NOT NULL,
  created_by TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE group_members(
  group_id TEXT NOT NULL,
  peer_id TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member',
  joined_at INTEGER NOT NULL,
  PRIMARY KEY (group_id, peer_id)
);

CREATE TABLE sync_state(
  peer_id TEXT PRIMARY KEY,
  last_sync_ts INTEGER NOT NULL DEFAULT 0
);

-- Modify existing
ALTER TABLE peers ADD COLUMN account_id TEXT;
ALTER TABLE peers ADD COLUMN handle TEXT;
ALTER TABLE peers ADD COLUMN device_cert BLOB;
ALTER TABLE messages ADD COLUMN group_id TEXT;
ALTER TABLE messages ADD COLUMN account_sender_id TEXT;
```

---

## Wire Protocol Extensions (v2)

| Frame                                   | Direction          | Purpose                        |
|-----------------------------------------|--------------------|--------------------------------|
| `{t:'hello', ..., ah, ac}`              | both               | Hello with account handle + device certificate |
| `{t:'sync_req', since}`                 | between own devices| Request message sync           |
| `{t:'sync_msgs', messages, cursor}`     | between own devices| Sync response                  |
| `{t:'group_invite', gid, gname, gk}`   | creator->member    | Invite to group                |
| `{t:'group_leave', gid}`                | member->group      | Leave group                    |
| `{t:'group_key_rotate', gid, gk_new}`  | admin->group       | Rotate group key               |
| `{t:'ack', id}`                         | receiver->sender   | Delivery confirmation (done)   |
| `{t:'typing', gid?}`                    | sender             | Typing indicator               |
| `{t:'read', id, gid?}`                  | receiver           | Read receipt                   |

---

## Implementation Order

| Phase | Feature                              | Effort | Depends on |
|-------|--------------------------------------|--------|------------|
| **1** | Cryptographic handle                 | Small  | Nothing    |
| **2** | Account identity + device model      | Medium | Phase 1    |
| **3** | QR key export / device linking       | Medium | Phase 2    |
| **4** | LAN message sync                     | Medium | Phase 3    |
| **5** | Group chat (small groups)            | Large  | Phase 2    |
| **6** | Verification upgrades (QR + safety)  | Small  | Phase 2    |
| **7** | Group key rotation + member mgmt     | Medium | Phase 5    |

---

## Open Questions

1. **Ed25519 vs X25519 for account key** — Ed25519 is for signing (certificates),
   X25519 is for key agreement. Use both, or X25519 with signatures
   (libsodium-style `crypto_sign_ed25519_pk_to_curve25519`)?

2. **Group history for new members** — When someone joins a group, should they
   see past messages or only new ones?

3. **Sync scope** — Should devices sync ALL messages from ALL chats, or only
   messages involving their shared account?

4. **Offline group messages** — If member A is offline and member B sends a group
   message, who holds it? The sender (delivers when A comes online), or relay
   approach where any online group member can forward?
