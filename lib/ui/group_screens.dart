import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/store.dart';
import 'theme.dart';

/// Screen for creating a new group: name + select members.
class GroupCreateScreen extends StatefulWidget {
  final AppState state;
  const GroupCreateScreen({super.key, required this.state});

  @override
  State<GroupCreateScreen> createState() => _GroupCreateScreenState();
}

class _GroupCreateScreenState extends State<GroupCreateScreen> {
  final _nameCtrl = TextEditingController();
  final _selected = <String>{};
  bool _creating = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a group name.')));
      return;
    }
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select at least one member.')));
      return;
    }
    setState(() => _creating = true);
    final gid = await widget.state.createGroup(name, _selected.toList());
    if (!mounted) return;
    if (gid != null) {
      Navigator.of(context).pop(gid);
    } else {
      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create group.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: L.txt('New group', size: L.title),
        actions: [
          TextButton(
            onPressed: _creating ? null : _create,
            child: _creating
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : L.txt('Create', size: L.body, weight: FontWeight.w600),
          ),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _nameCtrl,
              maxLength: 32,
              decoration: const InputDecoration(
                labelText: 'Group name',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: L.txt('MEMBERS', size: L.tiny,
                weight: FontWeight.w600, color: L.muted(context)),
          ),
          ...widget.state.peers.map((p) {
            // Only show trusted peers
            return FutureBuilder<KnownPeer?>(
              future: widget.state.store.getPeer(p.id),
              builder: (context, snap) {
                if (snap.data?.trusted != true) {
                  return const SizedBox.shrink();
                }
                final selected = _selected.contains(p.id);
                return CheckboxListTile(
                  value: selected,
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _selected.add(p.id);
                      } else {
                        _selected.remove(p.id);
                      }
                    });
                  },
                  title: L.txt('${p.name} ${p.handle}',
                      size: L.body, weight: FontWeight.w500),
                  subtitle: L.muteTxt(context, p.status.isEmpty ? 'Nearby' : p.status),
                  secondary: CircleAvatar(
                    radius: 16,
                    child: L.txt(p.name.isEmpty ? '?' : p.name[0].toUpperCase(),
                        size: L.body),
                  ),
                );
              },
            );
          }),
        ],
      ),
    );
  }
}

/// Group chat screen.
class GroupChatPage extends StatefulWidget {
  final AppState state;
  final String groupId;
  final String groupName;
  const GroupChatPage({
    super.key,
    required this.state,
    required this.groupId,
    required this.groupName,
  });

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage> _msgs = [];
  Timer? _poll;
  bool _sending = false;
  List<String> _memberIds = [];
  final _senderNames = <String, String>{}; // cache sender names

  @override
  void initState() {
    super.initState();
    widget.state.store.markRead(widget.groupId);
    _reload();
    _poll = Timer.periodic(const Duration(milliseconds: 800), (_) => _reload());
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    final ids = await widget.state.store.groupMemberIds(widget.groupId);
    if (mounted) setState(() => _memberIds = ids);
  }

  Future<String?> _resolveName(String senderId) async {
    if (_senderNames.containsKey(senderId)) return _senderNames[senderId];
    // Check live peers
    for (final p in widget.state.peers) {
      if (p.id == senderId) {
        _senderNames[senderId] = p.name;
        return p.name;
      }
    }
    // Fallback: query store
    final known = await widget.state.store.getPeer(senderId);
    final name = known?.name;
    if (name != null && name.isNotEmpty) {
      _senderNames[senderId] = name;
    }
    return name;
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final msgs =
        await widget.state.store.messagesFor(widget.groupId, limit: 300);
    if (!mounted) return;
    final changed = msgs.length != _msgs.length ||
        (msgs.isNotEmpty &&
            _msgs.isNotEmpty &&
            msgs.last.id != _msgs.last.id);
    setState(() => _msgs = msgs);
    await widget.state.store.markRead(widget.groupId);
    if (changed) {
      await Future.delayed(const Duration(milliseconds: 50));
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _input.clear();
    await widget.state.sendGroupText(widget.groupId, text);
    if (!mounted) return;
    setState(() => _sending = false);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            L.txt(widget.groupName, size: L.title, weight: FontWeight.w600),
            L.txt('${_memberIds.length} members',
                size: L.small, color: L.muted(context)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add, size: 20),
            tooltip: 'Add members',
            onPressed: () {
              // TODO: add members flow
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Add members coming soon')));
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'leave') {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: L.txt('Leave group?', size: L.title),
                    content: L.txt('You will no longer receive messages from this group.',
                        size: L.body),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(d, false),
                          child: L.txt('Cancel', size: L.body)),
                      TextButton(
                          onPressed: () => Navigator.pop(d, true),
                          child: L.txt('Leave',
                              size: L.body, color: Colors.red)),
                    ],
                  ),
                );
                if (confirm == true) {
                  await widget.state.leaveGroup(widget.groupId);
                  if (context.mounted) Navigator.of(context).pop();
                }
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'leave',
                child: L.txt('Leave group', size: L.body, color: Colors.red),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Colors.green.shade50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock, size: 14, color: Colors.green),
                const SizedBox(width: 6),
                L.txt('Group encrypted', size: L.small, color: Colors.green),
              ],
            ),
          ),
          Expanded(
            child: _msgs.isEmpty
                ? const LEmpty(
                    icon: Icons.forum_outlined,
                    title: 'No messages',
                    hint: 'Say hello to the group.',
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _msgs.length,
                    itemBuilder: (context, i) => _bubble(_msgs[i]),
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
                        hintText: 'Type a message…',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(20)),
                        ),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
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

  Widget _bubble(ChatMessage m) {
    final isMe = m.outgoing;
    final bg = isMe
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isMe && m.senderId != widget.state.identity?.id)
              FutureBuilder<String?>(
                future: _resolveName(m.senderId),
                builder: (context, snap) {
                  final name = snap.data;
                  if (name == null) return const SizedBox.shrink();
                  return L.txt(name,
                      size: L.tiny,
                      weight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary);
                },
              ),
            SelectableText(m.text ?? '',
                style: TextStyle(
                    fontSize: L.body,
                    color: Theme.of(context).colorScheme.onSurface,
                    decoration: TextDecoration.none)),
            const SizedBox(height: 2),
            L.txt(_time(m.ts), size: 10, color: L.muted(context)),
          ],
        ),
      ),
    );
  }

  String _time(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
