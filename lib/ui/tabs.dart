import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/identity.dart';
import '../core/interop.dart';
import '../core/permissions.dart';
import '../core/store.dart';
import 'interop_chat.dart';
import 'theme.dart';

class ChatsTab extends StatelessWidget {
  final AppState state;
  final void Function(String peerId, String name) onOpen;
  const ChatsTab({super.key, required this.state, required this.onOpen});

  String _ago(int ts) {
    final d =
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        if (state.chats.isEmpty) {
          return const LEmpty(
            icon: Icons.forum_outlined,
            title: 'No chats',
            hint: 'Go to Peers to find devices.',
          );
        }
        return RefreshIndicator(
          onRefresh: state.refreshChats,
          child: ListView.separated(
            itemCount: state.chats.length,
            separatorBuilder: (context, _) =>
                const Divider(height: 1, indent: 72),
            itemBuilder: (context, i) {
              final chat = state.chats[i];
              return Dismissible(
                key: ValueKey(chat.peerId),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Colors.red,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child:
                      const Icon(Icons.delete, color: Colors.white, size: 22),
                ),
                confirmDismiss: (_) async =>
                    await showDialog<bool>(
                      context: context,
                      builder: (d) => AlertDialog(
                        title: L.txt('Delete chat with ${chat.peerName}?',
                            size: L.title),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(d, false),
                              child: L.txt('Cancel', size: L.body)),
                          TextButton(
                              onPressed: () => Navigator.pop(d, true),
                              child: L.txt('Delete', size: L.body)),
                        ],
                      ),
                    ) ??
                    false,
                onDismissed: (_) async {
                  await state.store.deleteChat(chat.peerId);
                  await state.refreshChats();
                },
                child: ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: L.pad, vertical: 4),
                  leading: CircleAvatar(
                    radius: 20,
                    child: L.txt(
                      chat.peerName.isEmpty
                          ? '?'
                          : chat.peerName[0].toUpperCase(),
                      size: L.title,
                    ),
                  ),
                  title: L.txt(chat.peerName,
                      size: L.body,
                      weight: FontWeight.w600,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  subtitle: L.muteTxt(
                      context, chat.lastText ?? 'Say hello',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (chat.lastTs != null)
                        L.txt(_ago(chat.lastTs!),
                            size: L.tiny, color: L.muted(context)),
                      if (chat.unread > 0)
                        Container(
                          margin: const EdgeInsets.only(top: 2),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 1),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: L.txt('${chat.unread}',
                              size: L.tiny, color: Colors.white),
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

class PeersTab extends StatefulWidget {
  final AppState state;
  final void Function(String peerId, String name) onOpen;
  const PeersTab({super.key, required this.state, required this.onOpen});

  @override
  State<PeersTab> createState() => _PeersTabState();
}

class _PeersTabState extends State<PeersTab> {
  String? _gateMsg;
  bool _checking = true;
  final _interop = InteropScanner();
  List<InteropPeer> _interopPeers = [];
  StreamSubscription<List<InteropPeer>>? _interopSub;

  @override
  void initState() {
    super.initState();
    _check();
    _interopSub = _interop.found.listen((p) {
      if (mounted) setState(() => _interopPeers = p);
    });
    _interop.scan();
  }

  @override
  void dispose() {
    _interopSub?.cancel();
    _interop.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    final r = await LanPermissions.ensureDiscovery();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _gateMsg = r.gate == LanGate.ok ? null : r.summary;
    });
    if (r.gate != LanGate.ok) {
      // Engine may already run; discovery just yields nothing until granted.
      widget.state.refreshPeers();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final st = widget.state;
        if (_checking || !st.engineUp) {
          // Material spinner: CupertinoActivityIndicator inside a Material
          // list context can paint blank on iOS 16; the Material spinner
          // renders everywhere because tab bodies have a Material ancestor.
          return const Center(
              child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5)));
        }
        final peers = st.peers;
        return RefreshIndicator(
          onRefresh: () async {
            await _check();
            await st.refreshPeers();
            await _interop.scan();
          },
          child: ListView(
            children: [
              if (_gateMsg != null)
                _GateBanner(msg: _gateMsg!, onRetry: _check),
              if (peers.isEmpty && _interopPeers.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 48),
                  child: LEmpty(
                    icon: Icons.wifi_find,
                    title: 'No peers',
                    hint: 'Same WiFi, both apps open.',
                  ),
                )
              else ...[
                for (var i = 0; i < peers.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 72),
                  _PeerRow(
                      state: st,
                      index: i,
                      onOpen: widget.onOpen,
                      onVerify: (ctx, p) => showCupertinoOrMaterialSheet(
                          ctx, TrustSheet(peer: p, state: st))),
                ],
                if (_interopPeers.isNotEmpty) ...[
                  const _SectionLabel('Other apps'),
                  for (final ip in _interopPeers)
                    _InteropRow(scanner: _interop, peer: ip),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}

class _GateBanner extends StatelessWidget {
  final String msg;
  final VoidCallback onRetry;
  const _GateBanner({required this.msg, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(L.pad, 8, L.pad, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(L.radius),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 18, color: Theme.of(context).colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: L.txt(msg,
                size: L.small,
                color: Theme.of(context).colorScheme.onErrorContainer),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () async {
              final blocked = msg.contains('Settings');
              if (blocked) {
                await LanPermissions.openSettings();
              } else {
                onRetry();
              }
            },
            child:
                L.txt(msg.contains('Settings') ? 'Settings' : 'Retry',
                    size: L.small),
          ),
        ],
      ),
    );
  }
}

class _PeerRow extends StatelessWidget {
  final AppState state;
  final int index;
  final void Function(String peerId, String name) onOpen;
  final void Function(BuildContext, dynamic) onVerify;
  const _PeerRow(
      {required this.state,
      required this.index,
      required this.onOpen,
      required this.onVerify});

  @override
  Widget build(BuildContext context) {
    final p = state.peers[index];
    return FutureBuilder<KnownPeer?>(
      future: state.store.getPeer(p.id),
      builder: (context, snap) {
        final trusted = snap.data?.trusted ?? false;
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
              horizontal: L.pad, vertical: 4),
          leading: CircleAvatar(
            radius: 20,
            backgroundColor: trusted
                ? Colors.green.shade100
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Icon(trusted ? Icons.lock : Icons.lock_open,
                size: 20,
                color: trusted ? Colors.green.shade800 : L.muted(context)),
          ),
          title: L.txt(p.name,
              size: L.body,
              weight: FontWeight.w600,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          subtitle: L.muteTxt(
            context,
            p.status.isEmpty ? 'Nearby' : p.status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: trusted
              ? Icon(Icons.chevron_right,
                  size: 20, color: L.muted(context))
              : TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => onVerify(context, p),
                  child: L.txt('Verify', size: L.body),
                ),
          onTap: trusted
              ? () => onOpen(p.id, p.name)
              : () => onVerify(context, p),
        );
      },
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
      final raw = base64Decode(widget.peer.pubB64 as String);
      final fp = await DeviceIdentity.fingerprint(raw);
      if (mounted) setState(() => _fp = fp);
    } catch (_) {
      if (mounted) setState(() => _fp = 'unavailable');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.peer;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            L.txt('Verify ${p.name}',
                size: L.title, weight: FontWeight.w600),
            const SizedBox(height: 4),
            LMute('Match this code with ${p.name}, then chat.',
                align: TextAlign.center),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest,
                borderRadius: BorderRadius.circular(L.radius),
              ),
              child: SelectableText(_fp,
                  style: TextStyle(
                      fontSize: L.title,
                      fontFamily: 'monospace',
                      letterSpacing: 1.2,
                      decoration: TextDecoration.none,
                      color: Theme.of(context).colorScheme.onSurface)),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      textStyle: const TextStyle(fontSize: L.body),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: L.txt('Later', size: L.body),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      textStyle: const TextStyle(
                          fontSize: L.body, fontWeight: FontWeight.w600),
                    ),
                    onPressed: () async {
                      await widget.state.engine?.trust(p);
                      if (context.mounted) Navigator.pop(context);
                      await widget.state.refreshPeers();
                    },
                    child: L.txt('Match', size: L.body, weight: FontWeight.w600),
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

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(L.pad, 16, L.pad, 4),
      child: L.txt(text.toUpperCase(),
          size: L.tiny,
          weight: FontWeight.w600,
          color: L.muted(context)),
    );
  }
}

/// Row for a non-Lantern device found on the LAN (e.g. AirChat).
/// Probe classifies framing; once classified, tapping opens a two-way
/// chat. The chat is labeled NOT ENCRYPTED — AirChat traffic is plaintext
/// per its own ToS, so it never mixes with E2EE Lantern chats.
class _InteropRow extends StatefulWidget {
  final InteropScanner scanner;
  final InteropPeer peer;
  const _InteropRow({required this.scanner, required this.peer});

  @override
  State<_InteropRow> createState() => _InteropRowState();
}

class _InteropRowState extends State<_InteropRow> {
  String? _verdict;
  bool _busy = false;

  Future<void> _probe() async {
    setState(() {
      _busy = true;
      _verdict = null;
    });
    final v = await widget.scanner.probe(widget.peer);
    if (mounted) {
      setState(() {
        _busy = false;
        _verdict = v;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.peer;
    return ListTile(
      dense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: L.pad, vertical: 4),
      leading: CircleAvatar(
        radius: 20,
        backgroundColor:
            Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(Icons.devices_outlined,
            size: 20, color: L.muted(context)),
      ),
      title: L.txt('${p.name} · ${p.serviceType}', size: L.body),
      subtitle: L.muteTxt(
          context, _verdict ?? _hint(p),
          maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => _tap(context),
              child: L.txt(_action(p), size: L.body),
            ),
      onTap: _busy ? null : () => _tap(context),
    );
  }

  String _hint(InteropPeer p) {
    if (p.framing == 'lenprefix' ||
        p.framing == 'ndjson' ||
        p.framing == 'lines') {
      return '${p.host}:${p.port} · tap to chat (not encrypted)';
    }
    return '${p.host}:${p.port} · tap to probe';
  }

  String _action(InteropPeer p) {
    if (p.framing == 'lenprefix' ||
        p.framing == 'ndjson' ||
        p.framing == 'lines') {
      return 'Chat';
    }
    return 'Probe';
  }

  Future<void> _tap(BuildContext context) async {
    final p = widget.peer;
    if (p.framing == 'lenprefix' ||
        p.framing == 'ndjson' ||
        p.framing == 'lines') {
      _openChat(context);
      return;
    }
    await _probe();
    if (!context.mounted) return;
    if (p.framing == 'lenprefix' ||
        p.framing == 'ndjson' ||
        p.framing == 'lines') {
      _openChat(context);
    }
  }

  void _openChat(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => InteropChatPage(peer: widget.peer)));
  }
}
