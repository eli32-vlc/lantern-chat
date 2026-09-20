import 'package:flutter/material.dart';

import '../core/app_state.dart';
import 'theme.dart';

const statuses = [
  'Available',
  'Busy',
  'At work',
  'In a meeting',
  'Sleeping',
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
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: L.txt('Lantern')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 16),
          Icon(Icons.lan_outlined,
              size: 56, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          L.txt('Local WiFi chat',
              size: 20, weight: FontWeight.w700, align: TextAlign.center),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            maxLength: 24,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Display name',
              hintText: 'e.g. Alex',
              border: OutlineInputBorder(),
              counterText: '',
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
                DropdownMenuItem(value: s, child: L.txt(s, size: L.body)),
            ],
            onChanged: (v) => setState(() => _status = v ?? _status),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            L.txt(_error!,
                size: L.small, color: Theme.of(context).colorScheme.error),
          ],
          const SizedBox(height: 20),
          LButton(
            label: _busy ? 'Starting…' : 'Start',
            onPressed: _busy
                ? null
                : () async {
                    final name = _name.text.trim();
                    if (name.isEmpty) {
                      setState(() => _error = 'Enter a display name.');
                      return;
                    }
                    setState(() {
                      _busy = true;
                      _error = null;
                    });
                    try {
                      await widget.state.completeOnboarding(name, _status);
                    } catch (e) {
                      setState(() {
                        _error = 'Could not start.';
                        _busy = false;
                      });
                    }
                  },
          ),
        ],
      ),
    );
  }
}
