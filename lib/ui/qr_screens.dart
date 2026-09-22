import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../core/app_state.dart';
import 'l10n.dart';

class QrExportScreen extends StatefulWidget {
  final AppState state;
  const QrExportScreen({super.key, required this.state});
  @override
  State<QrExportScreen> createState() => _QrExportScreenState();
}

class _QrExportScreenState extends State<QrExportScreen> {
  String? _qrData, _passcode, _error;

  @override
  void initState() { super.initState(); _generate(); }

  Future<void> _generate() async {
    try {
      final (qr, pass) = await widget.state.exportQr();
      if (mounted) setState(() { _qrData = qr; _passcode = pass; });
    } catch (e) { if (mounted) setState(() => _error = S.of(context).failed); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(S.of(context).linkDevice)),
      body: Center(child: _error != null
          ? Text(_error!)
          : _qrData == null ? CircularProgressIndicator() : SingleChildScrollView(padding: EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(S.of(context).scanThisQr, style: TextStyle(fontSize: 15)), SizedBox(height: 16),
              Container(padding: EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                child: QrImageView(data: _qrData!, size: 260, backgroundColor: Colors.white)),
              SizedBox(height: 20),
              Text(S.of(context).passcode, style: TextStyle(fontSize: 12, color: Colors.grey)), SizedBox(height: 4),
              GestureDetector(onTap: () { Clipboard.setData(ClipboardData(text: _passcode!)); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).copied))); },
                child: Container(padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                  child: Text(_passcode!, style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: 8, fontFamily: 'monospace')))),
              SizedBox(height: 12),
              Text(S.of(context).enterPasscodeOnNew, style: TextStyle(color: Colors.grey, fontSize: 13), textAlign: TextAlign.center),
            ]))));
  }
}

class QrImportScreen extends StatefulWidget {
  final AppState state;
  const QrImportScreen({super.key, required this.state});
  @override
  State<QrImportScreen> createState() => _QrImportScreenState();
}

class _QrImportScreenState extends State<QrImportScreen> {
  String? _scannedData;
  final _passCtrl = TextEditingController();
  bool _importing = false, _scanned = false;
  String? _error;

  @override
  void dispose() { _passCtrl.dispose(); super.dispose(); }

  void _onDetect(BarcodeCapture cap) {
    if (_scanned || cap.barcodes.isEmpty) return;
    final v = cap.barcodes.first.rawValue;
    if (v == null || v.isEmpty) return;
    _scanned = true;
    setState(() => _scannedData = v);
  }

  Future<void> _import({bool force = false}) async {
    final pass = _passCtrl.text.trim();
    if (pass.length != 8) { setState(() => _error = S.of(context).enterPasscode8); return; }
    setState(() { _importing = true; _error = null; });
    final result = await widget.state.importQr(_scannedData!, pass, force: force);
    if (!mounted) return;
    if (result == 'confirm') {
      setState(() => _importing = false);
      final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
        title: Text(S.of(context).replaceAccount), content: Text(S.of(context).replaceAccountConfirm),
        actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: Text(S.of(context).cancel)),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text(S.of(context).replace, style: TextStyle(color: Colors.red)))]));
      if (ok == true) _import(force: true);
    } else if (result == 'true') {
      Navigator.popUntil(context, (r) => r.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(S.of(context).accountImported)));
    } else {
      setState(() { _importing = false; _error = S.of(context).wrongPasscode; _scanned = false; _scannedData = null; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: Text(S.of(context).importAccount)),
      body: _scannedData == null ? _scanner() : _passcode());
  }

  Widget _scanner() => Column(children: [
    Expanded(child: MobileScanner(
      onDetect: _onDetect,
      onScannerStarted: (_) {},
    )),
    Padding(padding: EdgeInsets.all(16), child: Text(S.of(context).pointCamera, style: TextStyle(color: Colors.grey))),
  ]);

  Widget _passcode() => Padding(padding: EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
    Icon(Icons.check_circle, size: 48, color: Colors.green), SizedBox(height: 12),
    Text(S.of(context).qrScanned, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)), SizedBox(height: 8),
    Text(S.of(context).enterPasscodeOnNew, style: TextStyle(color: Colors.grey), textAlign: TextAlign.center), SizedBox(height: 24),
    TextField(controller: _passCtrl, keyboardType: TextInputType.number, maxLength: 8, textAlign: TextAlign.center,
      style: TextStyle(fontSize: 28, letterSpacing: 12, fontFamily: 'monospace'),
      decoration: InputDecoration(labelText: S.of(context).passcode, border: OutlineInputBorder(), counterText: ''), autofocus: true),
    if (_error != null) Padding(padding: EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Colors.red))),
    SizedBox(height: 20),
    SizedBox(width: double.infinity, child: FilledButton(onPressed: _importing ? null : () => _import(),
      child: _importing ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(S.of(context).linkDevice))),
    SizedBox(height: 8),
    TextButton(onPressed: () => setState(() { _scanned = false; _scannedData = null; }), child: Text(S.of(context).scanAgain)),
  ]));
}
