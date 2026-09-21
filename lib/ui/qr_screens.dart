import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/app_state.dart';
import 'theme.dart';

/// Screen that shows a QR code for exporting the account to another device.
/// The QR data is AES-GCM encrypted; a 6-digit passphrase is shown on screen.
class QrExportScreen extends StatefulWidget {
  final AppState state;
  const QrExportScreen({super.key, required this.state});

  @override
  State<QrExportScreen> createState() => _QrExportScreenState();
}

class _QrExportScreenState extends State<QrExportScreen> {
  String? _qrData;
  String? _passcode;
  String? _error;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    try {
      final (qr, pass) = await widget.state.exportAccountQr();
      if (mounted) setState(() { _qrData = qr; _passcode = pass; });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not generate QR code.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: L.txt('Link another device', size: L.title)),
      body: Center(
        child: _error != null
            ? L.txt(_error!, size: L.body)
            : _qrData == null
                ? const CircularProgressIndicator()
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        L.txt('Scan this QR code on your new device',
                            size: L.body, align: TextAlign.center),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: QrImageView(
                            data: _qrData!,
                            size: 260,
                            backgroundColor: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 20),
                        L.txt('Passcode', size: L.small, color: L.muted(context)),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: _passcode!));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied')));
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 12),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _passcode!,
                              style: TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 8,
                                fontFamily: 'monospace',
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        LMute('Enter this passcode on the new device after scanning.',
                            align: TextAlign.center),
                        const SizedBox(height: 24),
                        L.txt('The QR code contains your account key, encrypted.',
                            size: L.tiny, color: L.muted(context),
                            align: TextAlign.center),
                      ],
                    ),
                  ),
      ),
    );
  }
}

/// Screen for scanning a QR code to import an account from another device.
class QrImportScreen extends StatefulWidget {
  final AppState state;
  const QrImportScreen({super.key, required this.state});

  @override
  State<QrImportScreen> createState() => _QrImportScreenState();
}

class _QrImportScreenState extends State<QrImportScreen> {
  String? _scannedData;
  final _passCtrl = TextEditingController();
  bool _importing = false;
  String? _error;
  bool _scanned = false;

  @override
  void dispose() {
    _passCtrl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final value = barcodes.first.rawValue;
    if (value == null || value.isEmpty) return;
    _scanned = true;
    setState(() => _scannedData = value);
  }

  Future<void> _import() async {
    final passcode = _passCtrl.text.trim();
    if (passcode.length != 6) {
      setState(() => _error = 'Enter the 6-digit passcode.');
      return;
    }
    setState(() { _importing = true; _error = null; });
    final ok = await widget.state.importAccountFromQr(_scannedData!, passcode);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account imported! Device linked.')));
    } else {
      setState(() {
        _importing = false;
        _error = 'Wrong passcode or corrupted QR code.';
        _scanned = false;
        _scannedData = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: L.txt('Import account', size: L.title)),
      body: _scannedData == null ? _scannerView() : _passcodeView(),
    );
  }

  Widget _scannerView() {
    return Column(
      children: [
        Expanded(
          child: MobileScanner(
            onDetect: _onDetect,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: LMute('Point your camera at the QR code on your other device.',
              align: TextAlign.center),
        ),
      ],
    );
  }

  Widget _passcodeView() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, size: 48, color: Colors.green),
          const SizedBox(height: 12),
          L.txt('QR code scanned', size: L.title, weight: FontWeight.w600),
          const SizedBox(height: 8),
          LMute('Enter the 6-digit passcode shown on your other device.',
              align: TextAlign.center),
          const SizedBox(height: 24),
          TextField(
            controller: _passCtrl,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 28, letterSpacing: 12, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              labelText: 'Passcode',
              border: OutlineInputBorder(),
              counterText: '',
            ),
            autofocus: true,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            L.txt(_error!, size: L.small,
                color: Theme.of(context).colorScheme.error),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _importing ? null : _import,
              child: _importing
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : L.txt('Link device', size: L.body, weight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => setState(() {
              _scanned = false;
              _scannedData = null;
              _error = null;
            }),
            child: L.txt('Scan again', size: L.body),
          ),
        ],
      ),
    );
  }
}
