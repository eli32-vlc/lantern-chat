import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import 'l10n.dart';

/// 1:1 chat screen.
class ChatPage extends StatefulWidget {
  final AppState state;
  final String peerId;
  final String peerName;
  const ChatPage({super.key, required this.state, required this.peerId, required this.peerName});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _msgs = [];
  Timer? _poll;
  String _peerHandle = '';

  @override
  void initState() {
    super.initState();
    widget.state.store.markRead(widget.peerId);
    _reload();
    _poll = Timer.periodic(Duration(milliseconds: 800), (_) => _reload());
    widget.state.store.getPeer(widget.peerId).then((p) {
      if (p != null && (p['handle'] as String).isNotEmpty && mounted) {
        setState(() => _peerHandle = p['handle'] as String);
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final msgs = await widget.state.store.messagesFor(widget.peerId, limit: 300);
    if (!mounted) return;
    final changed = msgs.length != _msgs.length ||
        (msgs.isNotEmpty && _msgs.isNotEmpty && msgs.last['id'] != _msgs.last['id']);
    setState(() => _msgs = msgs);
    await widget.state.store.markRead(widget.peerId);
    if (changed && _scroll.hasClients) {
      await Future.delayed(Duration(milliseconds: 50));
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await widget.state.sendText(widget.peerId, text);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.peerName),
          if (_peerHandle.isNotEmpty)
            Text(_peerHandle, style: TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
        actions: [Icon(Icons.lock_outline, size: 18)],
      ),
      body: Column(children: [
        // E2EE banner
        Container(width: double.infinity, padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: Colors.green.shade50,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.lock, size: 14, color: Colors.green),
            SizedBox(width: 6),
            Text(S.of(context).encrypted, style: TextStyle(fontSize: 12, color: Colors.green)),
          ]),
        ),
        // Messages
        Expanded(child: _msgs.isEmpty
            ? Center(child: Text(S.of(context).noMessages, style: TextStyle(color: Colors.grey)))
            : ListView.builder(controller: _scroll, padding: EdgeInsets.all(12),
                itemCount: _msgs.length,
                itemBuilder: (_, i) => _bubble(_msgs[i]),
              )),
        // Input
        SafeArea(top: false, child: Padding(
          padding: EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Row(children: [
            Expanded(child: TextField(controller: _input, minLines: 1, maxLines: 4,
              textInputAction: TextInputAction.send, onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: S.of(context).typeMessage,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
            )),
            IconButton(onPressed: _send, icon: Icon(Icons.send)),
          ]),
        )),
      ]),
    );
  }

  Widget _bubble(Map<String, dynamic> m) {
    final outgoing = m['outgoing'] == 1;
    final bg = outgoing
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.symmetric(vertical: 4),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(m['text'] ?? '', style: TextStyle(fontSize: 15)),
          SizedBox(height: 2),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_time(m['ts'] as int), style: TextStyle(fontSize: 10, color: Colors.grey)),
            if (outgoing) ...[
              SizedBox(width: 4),
              Icon(m['delivered'] == 1 ? Icons.done_all : Icons.done, size: 12,
                  color: m['delivered'] == 1 ? Colors.blue : Colors.grey),
            ],
          ]),
        ]),
      ),
    );
  }

  String _time(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
