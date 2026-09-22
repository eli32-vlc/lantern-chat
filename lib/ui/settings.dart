import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_state.dart';
import '../core/protocol.dart';
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
  bool _bgMode = true;

  @override
  void initState() {
    super.initState();
    _loadBgMode();
  }

  Future<void> _loadBgMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _bgMode = prefs.getBool('bg_mode') ?? true);
    }
  }

  Future<void> _toggleBgMode(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bg_mode', v);
    setState(() => _bgMode = v);
    if (v) {
      const MethodChannel('com.lantern/service').invokeMethod('startService');
    } else {
      const MethodChannel('com.lantern/service').invokeMethod('stopService');
    }
  }

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
          ListTile(
            dense: true,
            leading: const Icon(Icons.save_alt, size: 22),
            title: L.txt('Export to file', size: L.body),
            subtitle: L.muteTxt(context, 'Save account key as file'),
            onTap: () async {
              try {
                final json = await widget.state.exportAccountToFile();
                final dir = Directory.systemTemp;
                final file = File(
                    '${dir.path}/lantern-backup-${DateTime.now().millisecondsSinceEpoch}.json');
                await file.writeAsString(json);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Saved: ${file.path}')));
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Export failed: $e')));
                }
              }
            },
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.file_upload, size: 22),
            title: L.txt('Import from file', size: L.body),
            subtitle: L.muteTxt(context, 'Load account key from file'),
            onTap: () async {
              final result = await FilePicker.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['json']);
              if (result.isEmpty || result.single.path == null) return;
              final json = await File(result.single.path!).readAsString();
              final res = await widget.state.importAccountFromFile(json);
              if (!context.mounted) return;
              if (res == 'confirm') {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: L.txt('Replace account?', size: L.title),
                    content: L.txt(
                        'This will replace your current account. Continue?',
                        size: L.body),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(d, false),
                          child: L.txt('Cancel', size: L.body)),
                      TextButton(
                          onPressed: () => Navigator.pop(d, true),
                          child: L.txt('Replace', size: L.body, color: Colors.red)),
                    ],
                  ),
                );
                if (confirm == true) {
                  await widget.state.importAccountFromFile(json, forceConfirm: true);
                }
              } else if (res == 'true') {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Account imported!')));
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Import failed.')));
              }
            },
          ),
          if (defaultTargetPlatform == TargetPlatform.android)
            ListTile(
              dense: true,
              leading: const Icon(Icons.notifications_active, size: 22),
              title: L.txt('Background mode', size: L.body),
              subtitle: L.muteTxt(context,
                  'Keep discovering devices when app is closed'),
              trailing: Switch(
                value: _bgMode,
                onChanged: _toggleBgMode,
              ),
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
            subtitle: L.muteTxt(context, 'Version ${LanternProtocol.appVersion}'),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'Lantern',
              applicationVersion: LanternProtocol.appVersion,
            ),
          ),
          const Divider(height: 1),
          ListTile(
            dense: true,
            leading: const Icon(Icons.restore, size: 22, color: Colors.red),
            title: L.txt('Factory reset', size: L.body, color: Colors.red),
            subtitle: L.muteTxt(context, 'Erase everything and start fresh'),
            onTap: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (d) => AlertDialog(
                  title: L.txt('Factory reset?', size: L.title),
                  content: L.txt(
                      'This will delete ALL data: messages, contacts, groups, content. This cannot be undone.',
                      size: L.body),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(d, false),
                        child: L.txt('Cancel', size: L.body)),
                    TextButton(
                        onPressed: () => Navigator.pop(d, true),
                        child: L.txt('Reset everything',
                            size: L.body, color: Colors.red)),
                  ],
                ),
              );
              if (confirm == true) {
                await widget.state.factoryReset();
                if (context.mounted) {
                  Navigator.of(context).popUntil((r) => r.isFirst);
                }
              }
            },
          ),
        ],
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
              await state.updateProfile(name.text, status);
            },
            child: L.txt('Save', size: L.body, weight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
