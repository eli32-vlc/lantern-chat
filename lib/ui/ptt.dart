import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../core/app_state.dart';
import '../core/mesh.dart';
import '../core/protocol.dart';
import 'l10n.dart';

class PttScreen extends StatefulWidget {
  final AppState state;
  const PttScreen({super.key, required this.state});

  @override
  State<PttScreen> createState() => _PttScreenState();
}

class _PttScreenState extends State<PttScreen> {
  final _recorder = AudioRecorder();
  String _channel = P.pttDefaultChannel;
  String? _selectedPeerId;
  bool _transmitting = false;
  bool _receiving = false;
  String? _receivingFrom;
  final List<List<int>> _rxChunks = [];
  Timer? _presenceTimer;
  StreamSubscription? _eventSub; // H8: Track for cleanup

  // Channel presence: channel -> set of peer IDs
  final Map<String, Set<String>> _presence = {};

  static const _channels = ['general', 'emergency', 'info'];

  @override
  void initState() {
    super.initState();
    _setupCallbacks();
    _presenceTimer = Timer.periodic(Duration(seconds: 5), (_) => _sendPresence());
  }

  void _setupCallbacks() {
    final msgs = widget.state.msgs;
    if (msgs == null) return;
    // H8: Track subscription for cleanup
    _eventSub = msgs.events.listen((e) {
      if (!mounted) return;
      if (e.type == 'ptt_start') {
        setState(() { _receiving = true; _receivingFrom = e.peerId; _rxChunks.clear(); });
      } else if (e.type == 'ptt_data' && e.audioData != null) {
        _rxChunks.add(e.audioData!);
      } else if (e.type == 'ptt_stop') {
        setState(() { _receiving = false; _receivingFrom = null; });
        _playReceived();
      } else if (e.type == 'ptt_presence' && e.peerId != null && e.channel != null) {
        setState(() {
          _presence.putIfAbsent(e.channel!, () => {});
          _presence[e.channel!]!.add(e.peerId!);
        });
      }
    });
  }

  void _sendPresence() {
    final msgs = widget.state.msgs;
    if (msgs == null) return;
    for (final peer in widget.state.peers) {
      msgs.sendPttPresence(peer, _channel);
    }
    // Remove peers no longer in list
    for (final entry in _presence.entries) {
      entry.value.removeWhere((id) => !widget.state.peers.any((p) => p.id == id));
    }
  }

  void _playReceived() {
    if (_rxChunks.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Voice received (${_rxChunks.length} chunks)')));
    // TODO: play via audioplayers when streaming decoder is available
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    _eventSub?.cancel(); // H8: Cancel event subscription
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _startTransmit() async {
    final peerId = _selectedPeerId;
    if (peerId == null) return;
    final peer = widget.state.peers.where((p) => p.id == peerId).firstOrNull;
    if (peer == null) return;

    if (!await _recorder.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).micPermissionRequired)));
      }
      return;
    }

    setState(() => _transmitting = true);

    // Send PTT start
    widget.state.msgs?.sendPttStart(peer, _channel);

    // Record to temp file
    final path = '${Directory.systemTemp.path}/ptt_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 16000, numChannels: 1, bitRate: 16000),
      path: path,
    );

    // Stream recorded audio periodically
    _streamChunks(peer, path);
  }

  void _streamChunks(Peer peer, String path) async {
    int lastSize = 0;
    int chunkCount = 0;
    while (_transmitting) {
      await Future.delayed(Duration(milliseconds: 200)); // M6: Slower pace for 1Mbps links
      if (!_transmitting) break;
      try {
        final file = File(path);
        if (await file.exists()) {
          // H9: Only read new bytes, not entire file
          final size = await file.length();
          if (size > lastSize) {
            final raf = await file.open(mode: FileMode.read);
            await raf.setPosition(lastSize);
            final chunk = await raf.read(size - lastSize);
            await raf.close();
            lastSize = size;
            // Split into UDP-safe pieces
            widget.state.msgs?.sendPttData(peer, chunk);
            chunkCount++;
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _stopTransmit() async {
    if (!_transmitting) return;
    await _recorder.stop();
    setState(() => _transmitting = false);

    final peerId = _selectedPeerId;
    if (peerId == null) return;
    final peer = widget.state.peers.where((p) => p.id == peerId).firstOrNull;
    if (peer == null) return;

    widget.state.msgs?.sendPttStop(peer);
  }

  @override
  Widget build(BuildContext context) {
    final peers = widget.state.peers;
    final channelPeers = _presence[_channel] ?? {};

    return Scaffold(
      appBar: AppBar(title: Text(S.of(context).ptt)),
      body: Column(
        children: [
          // Channel selector
          Container(
            padding: EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.radio, size: 20),
                SizedBox(width: 8),
                Expanded(child: DropdownButton<String>(
                  isExpanded: true,
                  value: _channel,
                  items: _channels.map((c) {
                    final count = (_presence[c] ?? {}).length;
                    return DropdownMenuItem(value: c, child: Row(children: [
                      Text('#$c', style: TextStyle(fontWeight: FontWeight.w600)),
                      if (count > 0) ...[
                        SizedBox(width: 8),
                        Container(width: 8, height: 8,
                          decoration: BoxDecoration(color: Colors.green, shape: BoxShape.circle)),
                        SizedBox(width: 4),
                        Text('$count', style: TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ]));
                  }).toList(),
                  onChanged: (v) { if (v != null) setState(() => _channel = v); },
                )),
              ]),
              SizedBox(height: 8),
              // Peer selector
              Row(children: [
                Icon(Icons.person, size: 18),
                SizedBox(width: 8),
                Expanded(child: DropdownButton<String>(
                  isExpanded: true,
                  hint: Text(S.of(context).selectPeer),
                  value: _selectedPeerId,
                  items: peers.map((p) {
                    final onChannel = channelPeers.contains(p.id);
                    return DropdownMenuItem(value: p.id, child: Row(children: [
                      if (onChannel) ...[
                        Container(width: 8, height: 8,
                          decoration: BoxDecoration(color: Colors.green, shape: BoxShape.circle)),
                        SizedBox(width: 6),
                      ],
                      Text('${p.name} ${p.handle}'.trim()),
                    ]));
                  }).toList(),
                  onChanged: (v) => setState(() => _selectedPeerId = v),
                )),
              ]),
            ]),
          ),

          // Status area
          Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_receiving) ...[
              Icon(Icons.hearing, size: 64, color: Colors.green),
              SizedBox(height: 12),
              Text('${S.of(context).receivingFrom} ${_receivingFrom ?? ""}',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              SizedBox(height: 8),
              LinearProgressIndicator(),
            ] else if (_transmitting) ...[
              Icon(Icons.mic, size: 64, color: Colors.red),
              SizedBox(height: 12),
              Text(S.of(context).transmitting, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              SizedBox(height: 8),
              Text(S.of(context).releaseToStop, style: TextStyle(color: Colors.grey)),
            ] else ...[
              Icon(Icons.radio, size: 64, color: _selectedPeerId != null
                  ? Theme.of(context).colorScheme.primary : Colors.grey),
              SizedBox(height: 12),
              Text(_selectedPeerId != null ? S.of(context).holdToTalk : S.of(context).selectPeerAbove,
                  style: TextStyle(color: Colors.grey)),
            ],
          ]))),

          // PTT button
          SafeArea(child: Padding(
            padding: EdgeInsets.all(24),
            child: GestureDetector(
              onLongPressStart: (_) => _startTransmit(),
              onLongPressEnd: (_) => _stopTransmit(),
              child: Container(
                width: 120, height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _transmitting ? Colors.red
                      : _selectedPeerId != null ? Theme.of(context).colorScheme.primary : Colors.grey,
                  boxShadow: _transmitting ? [BoxShadow(color: Colors.red.withValues(alpha: 0.4), blurRadius: 20, spreadRadius: 5)] : null,
                ),
                child: Center(child: Icon(_transmitting ? Icons.mic : Icons.mic_none, size: 48, color: Colors.white)),
              ),
            ),
          )),
        ],
      ),
    );
  }
}
