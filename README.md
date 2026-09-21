# Lantern

Private LAN chat with end-to-end encryption. No accounts, no servers, no internet required.

## What it does

Lantern discovers nearby devices over WiFi (mDNS) and connects them with X25519 key exchange + AES-256-GCM encryption. Messages never leave your local network.

- **E2EE by default** — keys pinned on first connect (TOFU), fingerprint verification
- **No accounts** — just pick a display name and go
- **No servers** — peer-to-peer over LAN, works offline
- **Cross-platform** — iOS, Android, macOS (Windows/Linux coming)
- **AirChat compatible** — can discover and message AirChat devices on the same network (plaintext, labeled)

## Building

```bash
flutter pub get
flutter build apk --release        # Android
flutter build ipa --release --no-codesign  # iOS (needs re-signing for device)
flutter build macos --release      # macOS desktop
```

CI builds all three automatically on push to `main`.

## Architecture

```
lib/
  core/
    protocol.dart    — wire format (4-byte length + JSON)
    identity.dart    — X25519 + HKDF + AES-256-GCM
    engine.dart      — TCP server, mDNS, peer sessions
    compat.dart      — AirChat plaintext sniffer + server
    interop.dart     — multi-protocol LAN scanner
    store.dart       — sqlite messages + peers
    permissions.dart — platform permission gates
    diag.dart        — diagnostics log
  ui/
    home.dart        — tab scaffold
    tabs.dart        — peers list + trust sheet
    chat.dart        — E2EE chat
    compat_chat.dart — plaintext chat (AirChat devices)
    settings.dart    — profile + diagnostics
```

## Security model

- First contact: TOFU prompt with combined fingerprint (SHA-256 of both public keys)
- All frames: 4-byte big-endian length + JSON body
- Hello: plaintext `{t:"hello", id, nm, pk, v}` — public key exchange
- Payload: `{t:"payload", blob}` — base64 AES-256-GCM sealed
- Compat traffic: always labeled "not encrypted", never mixed into E2EE chats

## License

MIT
