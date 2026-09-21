import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/app_state.dart';
import 'diag_page.dart';
import 'onboarding.dart';
import 'qr_screens.dart';
import 'theme.dart';

class SettingsTab extends StatelessWidget {
  final AppState state;
  const SettingsTab({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
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
                    state.displayName.isEmpty
                        ? '?'
                        : state.displayName[0].toUpperCase(),
                    size: 22,
                  ),
                ),
                const SizedBox(height: 6),
                L.txt(state.displayName,
                    size: L.title, weight: FontWeight.w600),
                L.muteTxt(context, state.status),
                if (state.identity != null)
                  FutureBuilder<String>(
                    future: state.identity!.handle,
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
                builder: (_) => QrExportScreen(state: state))),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.qr_code_scanner, size: 22),
            title: L.txt('Import account', size: L.body),
            subtitle: L.muteTxt(context, 'Scan QR from another device'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => QrImportScreen(state: state))),
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

  void _editProfile(BuildContext context) {
    final name = TextEditingController(text: state.displayName);
    var status = state.status;
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
