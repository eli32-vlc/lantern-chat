import 'package:flutter/material.dart';

import '../core/app_state.dart';
import 'adaptive.dart';

const statuses = [
  'Available',
  'Busy',
  'At work',
  'In a meeting',
  'Sleeping',
  'No Calls, Lantern Only',
];

class OnboardingPage extends StatefulWidget {
  final AppState state;
  const OnboardingPage({super.key, required this.state});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _name = TextEditingController();
  String _status = statuses.first;
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return LanternScaffold(
      title: 'Welcome to Lantern',
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 24),
          Icon(Icons.lan_outlined,
              size: 72, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text('Chat over local WiFi.',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text(
            'No accounts. No servers. No tracking.\n'
            'Pick a display name — it only ever leaves your network '
            'inside encrypted chats.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _name,
            maxLength: 24,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Display name',
              hintText: 'e.g. Alex',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _status,
            decoration: const InputDecoration(
              labelText: 'Status',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final s in statuses)
                DropdownMenuItem(value: s, child: Text(s)),
            ],
            onChanged: (v) => setState(() => _status = v ?? _status),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
          const SizedBox(height: 24),
          AdaptiveButton(
            label: _busy ? 'Starting…' : 'Start chatting',
            onPressed: _busy
                ? null
                : () async {
                    final name = _name.text.trim();
                    if (name.isEmpty) {
                      setState(() => _error = 'Please enter a display name.');
                      return;
                    }
                    setState(() {
                      _busy = true;
                      _error = null;
                    });
                    try {
                      await widget.state
                          .completeOnboarding(name, _status);
                    } catch (e) {
                      setState(() {
                        _error = 'Could not start: $e';
                        _busy = false;
                      });
                    }
                  },
          ),
          const SizedBox(height: 12),
          const Text(
            'Messages are end-to-end encrypted (X25519 + AES-256-GCM). '
            'Verify the safety code on first connect.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
