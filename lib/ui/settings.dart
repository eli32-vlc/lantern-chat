import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_state.dart';
import '../core/background_audio.dart';
import 'diag_page.dart';
import 'onboarding.dart';
import 'qr_screens.dart';
import 'theme.dart';

class SettingsTab extends StatefulWidget {
  final AppState state;
  const SettingsTab({super.key, required this.state});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  String _bgMode = 'keepAlive';

  @override
  void initState() {
    super.initState();
    _loadBgMode();
  }

  Future<void> _loadBgMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _bgMode = prefs.getString('bgMode') ?? 'keepAlive');
    }
  }

  Future<void> _setBgMode(String mode) async {
    // Update the background audio service (starts/stops silent audio loop)
    await BackgroundAudioService.instance.setMode(mode);
    if (mounted) setState(() => _bgMode = mode);
  }

  String _bgModeLabel(String mode) => switch (mode) {
        'keepAlive' => 'Keep Alive',
        'musicMode' => 'Music Mode',
        'off' => 'Off',
        _ => mode,
      };

  /// Android: foreground service with notification (like Termux).
  /// iOS: background fetch / silent audio keep-alive.
  bool get _isAndroid => Platform.isAndroid;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const SizedBox(height: 8),
          Center(
            child: Column(
              children: [
                CircleAvatar(
                  radius: 30,
                  child: L.txt(
                    widget.state.displayName.isEmpty
                        ? '?'
                        : widget.state.displayName[0].toUpperCase(),
                    size: 22,
                  ),
                ),
                const SizedBox(height: 6),
                L.txt(widget.state.displayName,
                    size: L.title, weight: FontWeight.w600),
                L.muteTxt(context, widget.state.status),
                if (widget.state.identity != null)
                  FutureBuilder<String>(
                    future: widget.state.identity!.handle,
                    builder: (context, snap) {
                      if (!snap.hasData || snap.data!.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return L.txt(snap.data!,
                          size: L.small, color: L.muted(context));
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            dense: true,
            leading: const Icon(Icons.edit_outlined, size: 22),
            title: L.txt('Name & status', size: L.body),
            onTap: () => _editProfile(context),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.qr_code_2, size: 22),
            title: L.txt('Link another device', size: L.body),
            subtitle: L.muteTxt(context, 'Show QR code to link a second device'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => QrExportScreen(state: widget.state))),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.qr_code_scanner, size: 22),
            title: L.txt('Import account', size: L.body),
            subtitle: L.muteTxt(context, 'Scan QR from another device'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => QrImportScreen(state: widget.state))),
          ),
          if (_isAndroid)
            ListTile(
              dense: true,
              leading: const Icon(Icons.notifications_active, size: 22),
              title: L.txt('Background service', size: L.body),
              subtitle: L.muteTxt(context, 'Always on — shows notification while running'),
              onTap: () {
                showDialog(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: L.txt('Background service', size: L.title),
                    content: L.txt(
                      'Lantern runs a foreground service with a persistent notification '
                      'to stay alive in background, similar to Termux. '
                      'This is the most reliable way to keep LAN discovery running on Android.',
                      size: L.body),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(d),
                        child: L.txt('Got it', size: L.body)),
                    ],
                  ),
                );
              },
            )
          else
            ListTile(
              dense: true,
              leading: const Icon(Icons.phone_android, size: 22),
              title: L.txt('Background mode', size: L.body),
              subtitle: L.muteTxt(context, _bgModeLabel(_bgMode)),
              onTap: () => _showBgModePicker(context),
            ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.share_outlined, size: 22),
            title: L.txt('Share', size: L.body),
            onTap: () => SharePlus.instance.share(ShareParams(
                text: 'Lantern — private WiFi chat.')),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.bug_report_outlined, size: 22),
            title: L.txt('Diagnostics', size: L.body),
            subtitle: L.muteTxt(context, 'Connection log'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const DiagPage())),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.info_outline, size: 22),
            title: L.txt('About', size: L.body),
            subtitle: L.muteTxt(context, 'Version 0.1.0'),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'Lantern',
              applicationVersion: '0.1.0',
            ),
          ),
        ],
      ),
    );
  }

  void _showBgModePicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: L.txt('Background mode', size: L.title, weight: FontWeight.w600),
            ),
            for (final mode in ['keepAlive', 'musicMode', 'off'])
              RadioListTile<String>(
                value: mode,
                groupValue: _bgMode,
                onChanged: (v) {
                  if (v != null) _setBgMode(v);
                  Navigator.pop(ctx);
                },
                title: L.txt(_bgModeLabel(mode), size: L.body),
                subtitle: L.muteTxt(context, switch (mode) {
                  'keepAlive' => 'Background fetch + mDNS re-scan',
                  'musicMode' => 'Plays silent audio — most reliable on iOS',
                  'off' => 'App suspends when backgrounded',
                  _ => '',
                }),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: L.muteTxt(context,
                'Music Mode uses silent audio to prevent iOS from suspending the app. '
                'Keep Alive uses background fetch (less reliable but no audio session).',
                align: TextAlign.start),
            ),
          ],
        ),
      ),
    );
  }

  void _editProfile(BuildContext context) {
    final name = TextEditingController(text: widget.state.displayName);
    var status = widget.state.status;
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: L.txt('Profile', size: L.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              maxLength: 24,
              decoration: const InputDecoration(
                  labelText: 'Display name', counterText: ''),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: status,
              items: [
                for (final s in statuses)
                  DropdownMenuItem(value: s, child: Text(s)),
              ],
              onChanged: (v) => status = v ?? status,
              decoration: const InputDecoration(labelText: 'Status'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d),
              child: L.txt('Cancel', size: L.body)),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) return;
              Navigator.pop(d);
              await widget.state.updateProfile(name.text, status);
            },
            child: L.txt('Save', size: L.body, weight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
