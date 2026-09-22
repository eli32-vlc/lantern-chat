import 'dart:async';
import 'package:flutter/material.dart';
import '../core/app_state.dart';
import 'l10n.dart';

class GroupChatPage extends StatefulWidget {
  final AppState state;
  final String groupId;
  final String groupName;
  const GroupChatPage({super.key, required this.state, required this.groupId, required this.groupName});
  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _msgs = [];
  Timer? _poll;
  List<String> _memberIds = [];

  @override
  void initState() {
    super.initState();
    widget.state.store.markRead(widget.groupId);
    _reload();
    _poll = Timer.periodic(Duration(milliseconds: 800), (_) => _reload());
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    final ids = await widget.state.store.memberIds(widget.groupId);
    if (mounted) setState(() => _memberIds = ids);
  }

  @override
  void dispose() { _poll?.cancel(); _input.dispose(); _scroll.dispose(); super.dispose(); }

  Future<void> _reload() async {
    final msgs = await widget.state.store.messagesFor(widget.groupId, limit: 300);
    if (!mounted) return;
    final changed = msgs.length != _msgs.length || (msgs.isNotEmpty && _msgs.isNotEmpty && msgs.last['id'] != _msgs.last['id']);
    setState(() => _msgs = msgs);
    await widget.state.store.markRead(widget.groupId);
    if (changed && _scroll.hasClients) {
      await Future.delayed(Duration(milliseconds: 50));
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await widget.state.sendGroupText(widget.groupId, text);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.groupName),
          Text('${_memberIds.length} ${S.of(context).members}', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
        actions: [
          PopupMenuButton<String>(onSelected: (v) async {
            if (v == 'leave') {
              final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
                title: Text(S.of(context).leaveGroup),
                content: Text(S.of(context).leaveGroupConfirm),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(d, false), child: Text(S.of(context).cancel)),
                  TextButton(onPressed: () => Navigator.pop(d, true), child: Text(S.of(context).leave, style: TextStyle(color: Colors.red))),
                ],
              ));
              if (ok == true) { await widget.state.groups?.leave(widget.groupId); if (context.mounted) Navigator.pop(context); }
            }
          }, itemBuilder: (_) => [PopupMenuItem(value: 'leave', child: Text(S.of(context).leaveGroup, style: TextStyle(color: Colors.red)))]),
        ],
      ),
      body: Column(children: [
        Container(width: double.infinity, padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: Colors.green.shade50,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.lock, size: 14, color: Colors.green), SizedBox(width: 6),
            Text(S.of(context).groupEncrypted, style: TextStyle(fontSize: 12, color: Colors.green)),
          ]),
        ),
        Expanded(child: _msgs.isEmpty
            ? Center(child: Text(S.of(context).noMessages, style: TextStyle(color: Colors.grey)))
            : ListView.builder(controller: _scroll, padding: EdgeInsets.all(12), itemCount: _msgs.length, itemBuilder: (_, i) => _bubble(_msgs[i]))),
        SafeArea(top: false, child: Padding(padding: EdgeInsets.fromLTRB(8, 4, 8, 8), child: Row(children: [
          Expanded(child: TextField(controller: _input, minLines: 1, maxLines: 4, textInputAction: TextInputAction.send, onSubmitted: (_) => _send(),
            decoration: InputDecoration(hintText: S.of(context).typeMessage, border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)), contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8)))),
          IconButton(onPressed: _send, icon: Icon(Icons.send)),
        ]))),
      ]),
    );
  }

  Widget _bubble(Map<String, dynamic> m) {
    final outgoing = m['outgoing'] == 1;
    final bg = outgoing ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerHighest;
    return Align(alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(margin: EdgeInsets.symmetric(vertical: 4), padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!outgoing) FutureBuilder<Map<String, dynamic>?>(
            future: widget.state.store.getPeer(m['sender_id'] as String),
            builder: (_, snap) {
              final name = snap.data?['name'] as String? ?? '';
              final handle = snap.data?['handle'] as String? ?? '';
              final label = handle.isNotEmpty ? '$name $handle'.trim() : name;
              return label.isNotEmpty
                  ? Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary))
                  : SizedBox.shrink();
            },
          ),
          SelectableText(m['text'] ?? '', style: TextStyle(fontSize: 15)),
          SizedBox(height: 2),
          Text(_time(m['ts'] as int), style: TextStyle(fontSize: 10, color: Colors.grey)),
        ]),
      ),
    );
  }

  String _time(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
