import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// LAN permission flow. Must be friendly and honest: every prompt gets a
/// plain-language reason, denied-permanent routes to Settings, and the app
/// keeps working in read-only/offline mode where possible.
///
/// Platform matrix:
/// - Android 13+ (API 33+): NEARBY_WIFI_DEVICES (neverForLocation) for NSD +
///   WiFi name lookup; LOCATION only if the user wants SSID display on
///   API <= 32 semantics. Mic/photos asked lazily at point of use.
/// - Android <= 12: LOCATION (while-in-use) is required by the OS for WiFi
///   scans + NSD. We say so explicitly: "Android requires it, we never
///   track you."
/// - iOS: Local Network (system prompt on first NSD browse/advertise) +
///   Bonjour service in Info.plist. Location is NOT needed on iOS.
///   Mic/photos asked lazily at point of use.
enum LanGate { ok, wifiOnly, blocked }

class LanPermissions {
  /// Permissions needed before the discovery engine starts.
  static Future<List<Permission>> discoveryPermissions() async {
    if (Platform.isAndroid) {
      // nearbyWifiDevices covers API 33+; location covers <= 32.
      return [Permission.nearbyWifiDevices, Permission.locationWhenInUse];
    }
    if (Platform.isIOS) {
      // Local-network prompt is triggered by the OS itself on first NSD use
      // (accessLocalNetwork is iOS 14+ remappable via plist; asking here is
      // harmless and lets us detect denial early).
      return [Permission.accessLocalNetwork];
    }
    return [];
  }

  /// Ask for discovery permissions. Returns a gate decision + human summary.
  static Future<({LanGate gate, String summary})> ensureDiscovery() async {
    final wants = await discoveryPermissions();
    if (wants.isEmpty) return (gate: LanGate.ok, summary: 'ok');
    final results = <Permission, PermissionStatus>{};
    for (final p in wants) {
      var st = await p.status;
      if (st.isDenied) st = await p.request();
      results[p] = st;
    }
    if (Platform.isAndroid) {
      // Grant if EITHER path is granted (API-dependent).
      final nearbyOk =
          (results[Permission.nearbyWifiDevices]?.isGranted ?? false);
      final locOk =
          (results[Permission.locationWhenInUse]?.isGranted ?? false);
      if (nearbyOk || locOk) {
        return (
          gate: LanGate.ok,
          summary: nearbyOk && !locOk
              ? 'Nearby-devices granted (no location needed)'
              : 'ok'
        );
      }
      final permDenied = results.values.any((s) => s.isPermanentlyDenied);
      return (
        gate: permDenied ? LanGate.blocked : LanGate.wifiOnly,
        summary: permDenied
            ? 'Discovery permission permanently denied — open Settings to re-enable'
            : 'Discovery permission denied — chats with known peers still work'
      );
    }
    // iOS
    final st = results[Permission.accessLocalNetwork];
    if (st != null && st.isGranted) {
      return (gate: LanGate.ok, summary: 'ok');
    }
    final permDenied = st?.isPermanentlyDenied ?? false;
    return (
      gate: permDenied ? LanGate.blocked : LanGate.wifiOnly,
      summary: permDenied
          ? 'Local Network access is off — enable it in Settings > Lantern'
          : 'Local Network not granted — enable it when iOS asks'
    );
  }

  /// Lazily ask for the mic (voice notes). Call at point of use only.
  static Future<bool> ensureMic() async {
    var st = await Permission.microphone.status;
    if (st.isDenied) st = await Permission.microphone.request();
    return st.isGranted;
  }

  /// Lazily ask for photos (image share). Call at point of use only.
  static Future<bool> ensurePhotos() async {
    if (Platform.isIOS) {
      var st = await Permission.photos.status;
      if (st.isDenied || st.isLimited) {
        st = await Permission.photos.request();
      }
      return st.isGranted || st.isLimited;
    }
    var st = await Permission.photos.status;
    if (st.isDenied) st = await Permission.photos.request();
    return st.isGranted || st.isLimited;
  }

  /// Lazily ask for camera. Call at point of use only.
  static Future<bool> ensureCamera() async {
    var st = await Permission.camera.status;
    if (st.isDenied) st = await Permission.camera.request();
    return st.isGranted;
  }

  static Future<bool> openSettings() => openAppSettings();

  static String rationaleFor(Permission p) {
    if (p == Permission.nearbyWifiDevices) {
      return 'Find nearby Lantern devices on your WiFi. No location tracking.';
    }
    if (p == Permission.locationWhenInUse ||
        p == Permission.location ||
        p == Permission.locationAlways) {
      return 'Android requires Location for WiFi discovery on this version. '
          'Lantern never tracks or shares your location.';
    }
    if (p == Permission.accessLocalNetwork) {
      return 'Find nearby Lantern devices on your WiFi. Nothing leaves your network.';
    }
    if (p == Permission.microphone) {
      return 'Record voice messages. They stay encrypted on your WiFi.';
    }
    if (p == Permission.photos) {
      return 'Share photos you choose. They stay encrypted on your WiFi.';
    }
    if (p == Permission.camera) {
      return 'Take photos to share. They stay encrypted on your WiFi.';
    }
    return 'Needed for local chat to work.';
  }

  @visibleForTesting
  static bool granted(PermissionStatus s) =>
      s.isGranted || s.isLimited;
}
