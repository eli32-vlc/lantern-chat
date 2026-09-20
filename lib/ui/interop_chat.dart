import 'dart:async';

import 'package:flutter/material.dart';

import '../core/interop.dart';
import 'theme.dart';

/// Two-way chat with a non-Lantern LAN device (e.g. AirChat).
///
/// Hard rule, shown in the UI: this channel is NOT encrypted. AirChat's own
/// ToS states its messages are plaintext on the wire. This page never touches
/// Lantern's E2EE sessions — separate socket, separate framing, separate UI.
class InteropChatPage extends StatefulWidget {
  final InteropPeer peer;
  const InteropChatPage({super.key, required this.peer});

  @override
  State<InteropChatPage> createState() => _InteropChatPageState();
}

class _InteropChatPageState extends State<InteropChatPage> {
  AirchatChannel? _ch;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _lines = <({bool me, String text})>[];
  StreamSubscription<String>? _sub;
  bool _connecting = true;
  bool _open = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    final ch = AirchatChannel(widget.peer);
    final ok = await ch.connect();
    if (!mounted) {
      await ch.close();
      return;
    }
    setState(() {
      _ch = ch;
      _open = ok;
      _connecting = false;
    });
    if (ok) {
      _sub = ch.messages.listen((m) {
        if (!mounted) return;
        setState(() => _lines.add((me: false, text: _display(m))));
        _jump();
      });
    }
  }

  /// Render an incoming raw message: try JSON pretty-print of a text field,
  /// else raw (truncated).
  String _display(String raw) {
    final t = raw.trim();
    if ((t.startsWith('{') && t.endsWith('}')) ||
        (t.startsWith('[') && t.endsWith(']'))) {
      final m = RegExp(r'"text"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(t) ??
          RegExp(r'"message"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(t) ??
          RegExp(r'"body"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(t);
      if (m != null) {
        return m
            .group(1)!
            .replaceAll(r'\"', '"')
            .replaceAll(r'\n', '\n')
            .replaceAll(r'\\', r'\');
      }
    }
    return t.length > 500 ? '${t.substring(0, 500)}…' : t;
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final ch = _ch;
    if (text.isEmpty || ch == null || !_open || _sending) return;
    setState(() => _sending = true);
    _input.clear();
    final ok = await ch.sendText(text);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _lines.add((me: true, text: text));
    });
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Send failed — device silent.')));
    }
    _jump();
  }

  void _jump() {
    Future.delayed(const Duration(milliseconds: 60), () {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ch?.close();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            L.txt(widget.peer.name,
                size: L.title, weight: FontWeight.w600),
            L.txt('${widget.peer.host}:${widget.peer.port} · not encrypted',
                size: L.tiny,
                color: Theme.of(context).colorScheme.error),
          ],
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Theme.of(context).colorScheme.errorContainer,
            child: L.txt(
              'Plaintext channel — anyone on this WiFi could read it.',
              size: L.small,
              color: Theme.of(context).colorScheme.onErrorContainer,
              align: TextAlign.center,
            ),
          ),
          Expanded(
            child: _connecting
                ? const Center(child: CircularProgressIndicator())
                : !_open
                    ? const LEmpty(
                        icon: Icons.cloud_off_outlined,
                        title: 'Could not connect',
                        hint: 'Device may have left the network.',
                      )
                    : _lines.isEmpty
                        ? const LEmpty(
                            icon: Icons.forum_outlined,
                            title: 'Connected',
                            hint: 'Say hello.',
                          )
                        : ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.all(12),
                            itemCount: _lines.length,
                            itemBuilder: (context, i) {
                              final l = _lines[i];
                              return Align(
                                alignment: l.me
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: Container(
                                  margin: const EdgeInsets.symmetric(
                                      vertical: 4),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                  constraints: BoxConstraints(
                                      maxWidth:
                                          MediaQuery.of(context).size.width *
                                              L.bubbleMax),
                                  decoration: BoxDecoration(
                                    color: l.me
                                        ? L.bubbleMe(context)
                                        : L.bubblePeer(context),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: L.txt(l.text, size: L.body),
                                ),
                              );
                            },
                          ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: _open && !_connecting,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Message (plaintext)…',
                        border: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.all(Radius.circular(20)),
                        ),
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _open && !_connecting ? _send : null,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                    tooltip: 'Send',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
