import 'dart:async';

import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/identity.dart';
import '../core/store.dart';

class ChatsTab extends StatelessWidget {
  final AppState state;
  final void Function(String peerId, String name) onOpen;
  const ChatsTab({super.key, required this.state, required this.onOpen});

  String _ago(int ts) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (_, __) {
        if (state.chats.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.forum_outlined,
                      size: 64,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 12),
                  const Text('No chats yet',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text(
                    'Find nearby devices in the Peers tab, verify the safety code, and start chatting.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: state.refreshChats,
          child: ListView.separated(
            itemCount: state.chats.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (c, i) {
              final chat = state.chats[i];
              return Dismissible(
                key: ValueKey(chat.peerId),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Colors.red,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                confirmDismiss: (_) async => await showDialog<bool>(
                      context: c,
                      builder: (d) => AlertDialog(
                        title: Text('Delete chat with ${chat.peerName}?'),
                        content: const Text(
                            'All messages will be permanently removed from this device.'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(d, false),
                              child: const Text('Cancel')),
                          TextButton(
                              onPressed: () => Navigator.pop(d, true),
                              child: const Text('Delete')),
                        ],
                      ),
                    ) ??
                    false,
                onDismissed: (_) async {
                  await state.store.deleteChat(chat.peerId);
                  await state.refreshChats();
                },
                child: ListTile(
                  leading: CircleAvatar(
                    child: Text(chat.peerName.isEmpty
                        ? '?'
                        : chat.peerName[0].toUpperCase()),
                  ),
                  title: Text(chat.peerName,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(chat.lastText ?? 'Say hello 👋',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (chat.lastTs != null)
                        Text(_ago(chat.lastTs!),
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                      if (chat.unread > 0)
                        Container(
                          margin: const EdgeInsets.only(top: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text('${chat.unread}',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12)),
                        ),
                    ],
                  ),
                  onTap: () => onOpen(chat.peerId, chat.peerName),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class PeersTab extends StatelessWidget {
  final AppState state;
  final void Function(String peerId, String name) onOpen;
  const PeersTab({super.key, required this.state, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (_, __) {
        final peers = state.peers;
        if (!state.engineUp) {
          return const Center(child: CircularProgressIndicator());
        }
        if (peers.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi_find,
                      size: 64,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 12),
                  const Text('No peers discovered',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text(
                    'Make sure you are on the same WiFi as other devices running Lantern.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () => state.refreshPeers(),
          child: ListView.separated(
            itemCount: peers.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (c, i) {
              final p = peers[i];
              return FutureBuilder<KnownPeer?>(
                future: state.store.getPeer(p.id),
                builder: (ctx, snap) {
                  final trusted = snap.data?.trusted ?? false;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: trusted
                          ? Colors.green.shade100
                          : Colors.grey.shade300,
                      child: Icon(
                          trusted ? Icons.lock : Icons.lock_open,
                          color: trusted ? Colors.green.shade800 : Colors.grey),
                    ),
                    title: Text(p.name),
                    subtitle: Text(
                        p.status.isEmpty ? 'Online nearby' : p.status),
                    trailing: trusted
                        ? const Icon(Icons.chevron_right)
                        : TextButton(
                            onPressed: () => _showTrustSheet(ctx, p),
                            child: const Text('Verify'),
                          ),
                    onTap: trusted
                        ? () => onOpen(p.id, p.name)
                        : () => _showTrustSheet(ctx, p),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  void _showTrustSheet(BuildContext context, peer) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => TrustSheet(peer: peer, state: state),
    );
  }
}

class TrustSheet extends StatefulWidget {
  final dynamic peer; // LanPeer
  final AppState state;
  const TrustSheet({super.key, required this.peer, required this.state});

  @override
  State<TrustSheet> createState() => _TrustSheetState();
}

class _TrustSheetState extends State<TrustSheet> {
  String _fp = '…';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = _b64(widget.peer.pubB64 as String);
      final fp = await DeviceIdentity.fingerprint(raw);
      if (mounted) setState(() => _fp = fp);
    } catch (_) {
      if (mounted) setState(() => _fp = 'unavailable');
    }
  }

  List<int> _b64(String s) => base64Decode(s);

  @override
  Widget build(BuildContext context) {
    final p = widget.peer;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield_outlined, size: 48),
            const SizedBox(height: 12),
            Text('Verify ${p.name}',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              'Compare this safety code in person or over a trusted channel. '
              'Only chat after it matches — this stops WiFi snoopers.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_fp,
                  style: const TextStyle(
                      fontSize: 20,
                      fontFamily: 'monospace',
                      letterSpacing: 1.5)),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Not now'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      await widget.state.engine?.trust(p);
                      if (context.mounted) Navigator.pop(context);
                      await widget.state.refreshPeers();
                    },
                    child: const Text('Codes match'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
