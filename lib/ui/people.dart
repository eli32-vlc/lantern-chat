import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/crypto.dart';
import 'group_create.dart';
import 'l10n.dart';

/// People tab — peers + groups + content in one list.
class PeopleTab extends StatefulWidget {
  final AppState state;
  final void Function(String id, String name, {bool group}) onOpen;
  const PeopleTab({super.key, required this.state, required this.onOpen});

  @override
  State<PeopleTab> createState() => _PeopleTabState();
}

class _PeopleTabState extends State<PeopleTab> {
  @override
  Widget build(BuildContext context) {
    final peers = widget.state.peers;
    final s = widget.state;
    return Scaffold(
      appBar: AppBar(
        title: Text(S.of(context).people),
        actions: [
          IconButton(
            icon: Icon(Icons.group_add),
            tooltip: S.of(context).newGroup,
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => GroupCreateScreen(state: s))),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {},
        child: ListView(
          children: [
            if (peers.isEmpty)
              Padding(
                padding: EdgeInsets.only(top: 48),
                child: Center(child: Column(
                  children: [
                    Icon(Icons.wifi_find, size: 48, color: Colors.grey),
                    SizedBox(height: 12),
                    Text(S.of(context).noPeers, style: TextStyle(color: Colors.grey)),
                    SizedBox(height: 4),
                    Text(S.of(context).sameWifi, style: TextStyle(color: Colors.grey, fontSize: 13)),
                  ],
                )),
              ),
            for (final p in peers)
              FutureBuilder<Map<String, dynamic>?>(
                future: s.store.getPeer(p.id),
                builder: (context, snap) {
                  final trusted = snap.data?['trusted'] == 1;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: trusted ? Colors.green.shade100 : null,
                      child: Icon(
                        trusted ? Icons.lock : Icons.lock_open,
                        size: 20,
                        color: trusted ? Colors.green.shade800 : Colors.grey,
                      ),
                    ),
                    title: Text('${p.name} ${p.handle}'.trim(),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(p.status.isEmpty ? S.of(context).nearby : p.status),
                    trailing: trusted
                        ? Icon(Icons.chevron_right)
                        : TextButton(
                            onPressed: () => _verify(p),
                            child: Text(S.of(context).verify),
                          ),
                    onTap: trusted ? () => widget.onOpen(p.id, p.name) : null,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  void _verify(dynamic peer) {
    // Show trust sheet
    showModalBottomSheet(
      context: context,
      builder: (_) => _TrustSheet(peer: peer, state: widget.state),
    );
  }
}

class _TrustSheet extends StatefulWidget {
  final dynamic peer;
  final AppState state;
  const _TrustSheet({required this.peer, required this.state});
  @override
  State<_TrustSheet> createState() => _TrustSheetState();
}

class _TrustSheetState extends State<_TrustSheet> {
  String _code = '…';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final myPub = widget.state.device!.pub.bytes;
      final peerPub = base64Decode(widget.peer.pubB64 as String);
      final code = await Crypto.verificationCode(myPub, peerPub);
      if (mounted) setState(() => _code = code);
    } catch (e) {
      if (mounted) setState(() => _code = 'unavailable');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.peer;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${S.of(context).verify} ${p.name}',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            SizedBox(height: 4),
            Text(S.of(context).matchCode, style: TextStyle(color: Colors.grey)),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_code,
                  style: TextStyle(fontSize: 20, fontFamily: 'monospace', letterSpacing: 1.2)),
            ),
            SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(S.of(context).later),
                )),
                SizedBox(width: 12),
                Expanded(child: FilledButton(
                  onPressed: () async {
                    await widget.state.store.trustPeer(widget.peer.id, true);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: Text(S.of(context).match),
                )),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
