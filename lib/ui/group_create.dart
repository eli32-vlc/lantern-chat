import 'package:flutter/material.dart';
import '../core/app_state.dart';
import '../core/store.dart';
import 'l10n.dart';

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
  void dispose() { _nameCtrl.dispose(); super.dispose(); }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).enterGroupName))); return; }
    if (_selected.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).selectMembers))); return; }
    setState(() => _creating = true);
    final gid = await widget.state.createGroup(name, _selected.toList());
    if (!mounted) return;
    if (gid != null) Navigator.pop(context, gid);
    else { setState(() => _creating = false); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).failed))); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(S.of(context).newGroup), actions: [
        TextButton(onPressed: _creating ? null : _create,
            child: _creating ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(S.of(context).create)),
      ]),
      body: ListView(children: [
        Padding(padding: EdgeInsets.all(16), child: TextField(controller: _nameCtrl, maxLength: 32,
            decoration: InputDecoration(labelText: S.of(context).groupName, border: OutlineInputBorder(), counterText: ''))),
        Divider(height: 1),
        Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text(S.of(context).members.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey))),
        ...widget.state.peers.map((p) => FutureBuilder<Map<String, dynamic>?>(
          future: widget.state.store.getPeer(p.id),
          builder: (context, snap) {
            if (snap.data?['trusted'] != 1) return SizedBox.shrink();
            return CheckboxListTile(
              value: _selected.contains(p.id),
              onChanged: (v) => setState(() { v == true ? _selected.add(p.id) : _selected.remove(p.id); }),
              title: Text('${p.name} ${p.handle}'.trim()),
              subtitle: Text(p.status.isEmpty ? S.of(context).nearby : p.status),
            );
          },
        )),
      ]),
    );
  }
}
