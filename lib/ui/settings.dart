import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/app_state.dart';
import 'onboarding.dart';

class SettingsTab extends StatelessWidget {
  final AppState state;
  const SettingsTab({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, __) => ListView(
        children: [
          const SizedBox(height: 12),
          Center(
            child: Column(
              children: [
                CircleAvatar(
                  radius: 36,
                  child: Text(
                    state.displayName.isEmpty
                        ? '?'
                        : state.displayName[0].toUpperCase(),
                    style: const TextStyle(fontSize: 28),
                  ),
                ),
                const SizedBox(height: 8),
                Text(state.displayName,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                Text(state.status,
                    style: const TextStyle(color: Colors.grey)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('Name & status'),
            subtitle: const Text('Shown to nearby devices only'),
            onTap: () => _editProfile(context),
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('How encryption works'),
            subtitle: const Text('X25519 + AES-256-GCM, TOFU verified'),
            onTap: () => showDialog(
              context: context,
              builder: (d) => const AlertDialog(
                title: Text('Private by design'),
                content: Text(
                  '• Identity key created on first launch, never leaves this device.\n'
                  '• Each chat uses its own secret (X25519 + HKDF).\n'
                  '• Messages sealed with AES-256-GCM.\n'
                  '• Verify the safety code once per device.\n'
                  '• No accounts, no servers, no analytics.',
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.share),
            title: const Text('Share Lantern'),
            onTap: () => SharePlus.instance.share(
                ShareParams(
                    text: 'Lantern — private WiFi chat with no accounts or tracking.')),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            subtitle: const Text('Lantern 0.1.0 • LAN only'),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'Lantern',
              applicationVersion: '0.1.0',
              children: const [
                Text('Local WiFi messaging. No accounts, no cloud, no tracking.')
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Everything stays on your WiFi network. '
              'Uninstalling removes all keys and history.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
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
        title: const Text('Edit profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              maxLength: 24,
              decoration: const InputDecoration(labelText: 'Display name'),
            ),
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
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) return;
              Navigator.pop(d);
              await state.updateProfile(name.text, status);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
