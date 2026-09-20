import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/store.dart';
import 'theme.dart';

/// Chat screen for plaintext compat sessions (stock AirChat devices).
/// Reads/writes the `compat:<host>:<port>` message rows via AppState.
/// Always labeled NOT ENCRYPTED — never confused with E2EE chats.
class CompatChatPage extends StatefulWidget {
  final String chatId;
  final String title;
  const CompatChatPage(
      {super.key, required this.chatId, required this.title});

  @override
  State<CompatChatPage> createState() => _CompatChatPageState();
}

class _CompatChatPageState extends State<CompatChatPage> {
  AppState? _state;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage> _msgs = [];
  Timer? _poll;
  bool _sending = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _state ??= context
        .findAncestorStateOfType<State>()
        ?.widget is StatefulWidget
        ? _lookup()
        : null;
  }

  AppState? _lookup() {
    // CompatChatPage is pushed from HomeShell which owns the AppState;
    // walk up via the page route's builder closure instead: the caller
    // passes state through CompatChatStoreScope below. Fallback: none.
    return CompatChatStoreScope.of(context);
  }

  Future<void> _reload() async {
    final st = _state;
    if (st == null || !mounted) return;
    final msgs =
        await st.store.messagesFor(widget.chatId, limit: 300);
    if (!mounted) return;
    final changed = msgs.length != _msgs.length ||
        (msgs.isNotEmpty &&
            _msgs.isNotEmpty &&
            msgs.last.id != _msgs.last.id);
    setState(() => _msgs = msgs);
    await st.store.markRead(widget.chatId);
    if (changed) {
      await Future.delayed(const Duration(milliseconds: 50));
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    }
  }

  Future<void> _send() async {
    final st = _state;
    final text = _input.text.trim();
    if (text.isEmpty || st == null || _sending) return;
    setState(() => _sending = true);
    _input.clear();
    final ok = await st.sendCompatText(widget.chatId, text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Device silent — message saved, not delivered.')));
    }
    _reload();
  }

  @override
  void initState() {
    super.initState();
    _poll =
        Timer.periodic(const Duration(milliseconds: 800), (_) => _reload());
  }

  @override
  void dispose() {
    _poll?.cancel();
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
            L.txt(widget.title,
                size: L.title, weight: FontWeight.w600),
            L.txt('not encrypted',
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
              'Plaintext — anyone on this WiFi could read it.',
              size: L.small,
              color: Theme.of(context).colorScheme.onErrorContainer,
              align: TextAlign.center,
            ),
          ),
          Expanded(
            child: _msgs.isEmpty
                ? const LEmpty(
                    icon: Icons.forum_outlined,
                    title: 'No messages',
                    hint: 'Say hello.',
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _msgs.length,
                    itemBuilder: (context, i) {
                      final m = _msgs[i];
                      final me = m.outgoing;
                      return Align(
                        alignment: me
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin:
                              const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width *
                                  L.bubbleMax),
                          decoration: BoxDecoration(
                            color: me
                                ? L.bubbleMe(context)
                                : L.bubblePeer(context),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: L.txt(m.text ?? '', size: L.body),
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
                    onPressed: _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2))
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

/// Provides AppState to CompatChatPage without threading it through routes.
class CompatChatStoreScope extends InheritedWidget {
  final AppState state;
  const CompatChatStoreScope(
      {super.key, required this.state, required super.child});

  static AppState? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CompatChatStoreScope>()?.state;

  @override
  bool updateShouldNotify(CompatChatStoreScope old) => state != old.state;
}
