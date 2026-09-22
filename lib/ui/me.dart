import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_state.dart';
import '../core/protocol.dart';
import 'l10n.dart';
import 'qr_screens.dart';

/// Me tab — profile, settings, export, about.
class MeTab extends StatelessWidget {
  final AppState state;
  const MeTab({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state;
    return Scaffold(
      appBar: AppBar(title: Text(S.of(context).me)),
      body: ListView(
        children: [
          // Profile header
          Container(
            padding: EdgeInsets.all(24),
            child: Column(
              children: [
                CircleAvatar(radius: 32,
                  child: Text(s.displayName.isNotEmpty ? s.displayName[0].toUpperCase() : '?',
                      style: TextStyle(fontSize: 24))),
                SizedBox(height: 8),
                Text(s.displayName, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                Text(s.status, style: TextStyle(color: Colors.grey)),
                FutureBuilder<String>(
                  future: s.account?.handle ?? Future.value(''),
                  builder: (_, snap) => snap.hasData && snap.data!.isNotEmpty
                      ? Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(snap.data!, style: TextStyle(color: Colors.grey, fontSize: 13)))
                      : SizedBox.shrink(),
                ),
              ],
            ),
          ),
          Divider(height: 1),

          // Profile
          ListTile(
            leading: Icon(Icons.edit_outlined),
            title: Text(S.of(context).editProfile),
            onTap: () => _editProfile(context),
          ),

          // Link device
          ListTile(
            leading: Icon(Icons.qr_code_2),
            title: Text(S.of(context).linkDevice),
            subtitle: Text(S.of(context).showQrToLink),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => QrExportScreen(state: s))),
          ),
          ListTile(
            leading: Icon(Icons.qr_code_scanner),
            title: Text(S.of(context).importAccount),
            subtitle: Text(S.of(context).scanQrFromOther),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => QrImportScreen(state: s))),
          ),

          // File export/import
          ListTile(
            leading: Icon(Icons.save_alt),
            title: Text(S.of(context).exportToFile),
            onTap: () async {
              try {
                final json = await s.exportToFile();
                final dir = Directory.systemTemp;
                final file = File('${dir.path}/lantern-backup.json');
                await file.writeAsString(json);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('${S.of(context).saved}: ${file.path}')));
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('${S.of(context).failed}: $e')));
                }
              }
            },
          ),
          ListTile(
            leading: Icon(Icons.file_upload),
            title: Text(S.of(context).importFromFile),
            onTap: () async {
              final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
              if (result.isEmpty || result.single.path == null) return;
              final json = await File(result.single.path!).readAsString();
              final res = await s.importFromFile(json);
              if (!context.mounted) return;
              if (res == 'confirm') {
                final ok = await showDialog<bool>(context: context,
                  builder: (d) => AlertDialog(
                    title: Text(S.of(context).replaceAccount),
                    content: Text(S.of(context).replaceAccountConfirm),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d, false), child: Text(S.of(context).cancel)),
                      TextButton(onPressed: () => Navigator.pop(d, true), child: Text(S.of(context).replace, style: TextStyle(color: Colors.red))),
                    ],
                  ),
                );
                if (ok == true) await s.importFromFile(json, force: true);
              }
            },
          ),

          Divider(height: 1),

          // Factory reset
          ListTile(
            leading: Icon(Icons.restore, color: Colors.red),
            title: Text(S.of(context).factoryReset, style: TextStyle(color: Colors.red)),
            onTap: () async {
              final ok = await showDialog<bool>(context: context,
                builder: (d) => AlertDialog(
                  title: Text(S.of(context).factoryReset),
                  content: Text(S.of(context).factoryResetConfirm),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(d, false), child: Text(S.of(context).cancel)),
                    TextButton(onPressed: () => Navigator.pop(d, true), child: Text(S.of(context).resetEverything, style: TextStyle(color: Colors.red))),
                  ],
                ),
              );
              if (ok == true) {
                await s.factoryReset();
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              }
            },
          ),

          // About
          ListTile(
            leading: Icon(Icons.info_outline),
            title: Text(S.of(context).about),
            subtitle: Text('${S.of(context).version} ${P.appVersion}'),
          ),
        ],
      ),
    );
  }

  void _editProfile(BuildContext context) {
    final name = TextEditingController(text: state.displayName);
    var status = state.status;
    showDialog(context: context, builder: (d) => AlertDialog(
      title: Text(S.of(context).profile),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, maxLength: 24,
            decoration: InputDecoration(labelText: S.of(context).displayName, counterText: '')),
        SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: status,
          items: ['Available', 'Busy', 'At work', 'In a meeting', 'Sleeping']
              .map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
          onChanged: (v) => status = v ?? status,
          decoration: InputDecoration(labelText: S.of(context).status),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(S.of(context).cancel)),
        FilledButton(onPressed: () async {
          if (name.text.trim().isEmpty) return;
          Navigator.pop(d);
          await state.updateProfile(name.text, status);
        }, child: Text(S.of(context).save)),
      ],
    ));
  }
}
