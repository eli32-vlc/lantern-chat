# Lantern

LAN chat. No internet, no accounts, no servers.

## What it does

Discovers nearby devices over WiFi. Messages are end-to-end encrypted. Works offline.

- Text, files, voice messages
- Group chat
- Push-to-talk
- QR code device linking
- Content sharing between devices
- English + 中文

## Build

```bash
flutter pub get
flutter build apk --release          # Android
flutter build ipa --release --no-codesign  # iOS
flutter build macos --release        # macOS
```

## How it works

1. Open app on two devices on the same WiFi
2. Devices find each other automatically
3. Tap "Verify" to confirm identity
4. Chat

Messages never leave your local network.

## Crypto

- X25519 key agreement
- Ed25519 message signing
- AES-256-GCM encryption
- TOFU trust model (like SSH)

## License

MIT
