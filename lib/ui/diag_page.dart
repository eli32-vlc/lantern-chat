import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../core/diag.dart';
import 'theme.dart';

/// Diagnostics: the live LAN log. Users paste this back when something
/// doesn't connect, so bugs get fixed with evidence instead of guesses.
class DiagPage extends StatefulWidget {
  const DiagPage({super.key});

  @override
  State<DiagPage> createState() => _DiagPageState();
}

class _DiagPageState extends State<DiagPage> {
  @override
  void initState() {
    super.initState();
    DiagLog.ticks.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = DiagLog.entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics',
            style: TextStyle(fontSize: L.title, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy, size: 20),
            tooltip: 'Copy log',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: DiagLog.dump()));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Log copied.')));
            },
          ),
          IconButton(
            icon: const Icon(Icons.share, size: 20),
            tooltip: 'Share log',
            onPressed: () => SharePlus.instance.share(
                ShareParams(text: DiagLog.dump())),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: 'Clear',
            onPressed: () => setState(DiagLog.clear),
          ),
        ],
      ),
      body: entries.isEmpty
          ? const LEmpty(
              icon: Icons.bug_report_outlined,
              title: 'No events yet',
              hint: 'Open Peers to start discovery.',
            )
          : ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final e = entries[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: SelectableText(e.toString(),
                      style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          decoration: TextDecoration.none,
                          color: Theme.of(context).colorScheme.onSurface)),
                );
              },
            ),
    );
  }
}
