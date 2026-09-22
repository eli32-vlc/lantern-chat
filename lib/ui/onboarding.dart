import 'package:flutter/material.dart';
import '../core/app_state.dart';
import 'l10n.dart';
import 'qr_screens.dart';

class OnboardingPage extends StatefulWidget {
  final AppState state;
  const OnboardingPage({super.key, required this.state});
  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _name = TextEditingController();
  String _status = 'Available';
  bool _busy = false;
  String? _error;

  @override
  void dispose() { _name.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Lantern')),
      body: ListView(padding: EdgeInsets.all(24), children: [
        SizedBox(height: 16),
        Icon(Icons.lan_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
        SizedBox(height: 12),
        Text(S.of(context).localWifiChat, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        SizedBox(height: 20),
        TextField(controller: _name, maxLength: 24, textInputAction: TextInputAction.done,
          decoration: InputDecoration(labelText: S.of(context).displayName, hintText: S.of(context).nameHint, border: OutlineInputBorder(), counterText: '')),
        SizedBox(height: 12),
        DropdownButtonFormField<String>(value: _status,
          decoration: InputDecoration(labelText: S.of(context).status, border: OutlineInputBorder()),
          items: ['Available', 'Busy', 'At work', 'In a meeting', 'Sleeping'].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
          onChanged: (v) => setState(() => _status = v ?? _status)),
        if (_error != null) Padding(padding: EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Colors.red))),
        SizedBox(height: 20),
        FilledButton(onPressed: _busy ? null : () async {
          final name = _name.text.trim();
          if (name.isEmpty) { setState(() => _error = S.of(context).enterName); return; }
          setState(() { _busy = true; _error = null; });
          try { await widget.state.completeOnboarding(name, _status); } catch (e) { setState(() { _error = S.of(context).couldNotStart; _busy = false; }); }
        }, child: Text(_busy ? S.of(context).starting : S.of(context).start)),
        SizedBox(height: 16),
        Center(child: GestureDetector(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => QrImportScreen(state: widget.state))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.qr_code_scanner, size: 18), SizedBox(width: 6),
            Text(S.of(context).alreadyHaveAccount, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ]),
        )),
      ]),
    );
  }
}
