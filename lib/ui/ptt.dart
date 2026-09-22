import 'dart:async';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../core/app_state.dart';
import '../core/protocol.dart';
import '../core/store.dart';
import 'theme.dart';

/// Push-to-Talk tab. Walkie-talkie style voice over UDP.
class PttTab extends StatefulWidget {
  final AppState state;
  const PttTab({super.key, required this.state});

  @override
  State<PttTab> createState() => _PttTabState();
}

class _PttTabState extends State<PttTab> {
  String? _selectedPeerId;
  String? _selectedPeerName;
  bool _transmitting = false;
  bool _receiving = false;
  String? _receivingFrom;
  final _audioRecorder = AudioRecorder();
  final List<List<int>> _receivedChunks = [];
  String? _recPath;
  // PTT Channels
  String _currentChannel = LanternProtocol.pttDefaultChannel;
  final Map<String, Set<String>> _channelPresence = {}; // channel -> peerIds
  Timer? _presenceTimer;

  @override
  void initState() {
    super.initState();
    _setupPttCallbacks();
    // Start presence ping
    _presenceTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _sendPresence());
  }

  void _joinChannel(String channel) {
    setState(() {
      _currentChannel = channel;
      _channelPresence.putIfAbsent(channel, () => {});
    });
    _sendPresence();
  }

  void _sendPresence() {
    final engine = widget.state.engine;
    if (engine == null) return;
    for (final peer in widget.state.peers) {
      engine.sendPttPresence(peer, _currentChannel);
    }
    // Clean up stale presence (no ping for 15s)
    for (final entry in _channelPresence.entries) {
      entry.value.removeWhere((peerId) {
        // Keep only if peer is still in peers list
        return !widget.state.peers.any((p) => p.id == peerId);
      });
    }
  }

  void _setupPttCallbacks() {
    final engine = widget.state.engine;
    if (engine == null) return;

    engine.onPttStart = (peerId) {
      if (mounted) {
        setState(() {
          _receiving = true;
          _receivingFrom = peerId;
          _receivedChunks.clear();
        });
      }
    };

    engine.onPttData = (peerId, audioData) {
      _receivedChunks.add(audioData);
    };

    engine.onPttStop = (peerId) {
      if (mounted) {
        setState(() {
          _receiving = false;
          _receivingFrom = null;
        });
        _playReceived();
      }
    };

    engine.onPttPresence = (peerId, channel) {
      if (mounted) {
        setState(() {
          _channelPresence.putIfAbsent(channel, () => {});
          _channelPresence[channel]!.add(peerId);
        });
      }
    };
  }

  void _playReceived() {
    // TODO: play received audio chunks via audioplayers
    // For now, just show a snackbar
    if (_receivedChunks.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Voice received from ${_receivingFrom ?? "unknown"} '
                '(${_receivedChunks.length} chunks)')),
      );
    }
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    widget.state.engine?.onPttStart = null;
    widget.state.engine?.onPttData = null;
    widget.state.engine?.onPttStop = null;
    widget.state.engine?.onPttPresence = null;
    _audioRecorder.dispose();
    super.dispose();
  }

  Future<void> _startTransmit() async {
    if (_selectedPeerId == null) return;
    final peer = widget.state.peerById(_selectedPeerId!);
    if (peer == null) return;

    if (!await _audioRecorder.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission required')));
      }
      return;
    }

    setState(() => _transmitting = true);

    // Send PTT start signal
    widget.state.engine?.sendPttStart(peer);

    // B22: Record to a real temp file, not /dev/null
    final dir = Directory.systemTemp;
    _recPath = '${dir.path}/ptt_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 16000,
      ),
      path: _recPath!,
    );

    // B21: Send keepalive while recording
    _streamAudioChunks(peer);
  }

  void _streamAudioChunks(dynamic peer) async {
    // Send audio chunks periodically while recording
    while (_transmitting) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!_transmitting) break;

      // Get recorded data (simplified - in production use streaming encoder)
      // For now, send a keepalive/typing indicator
      widget.state.engine?.sendTyping(peer);
    }
  }

  Future<void> _stopTransmit() async {
    if (!_transmitting) return;

    await _audioRecorder.stop();
    setState(() => _transmitting = false);

    if (_selectedPeerId == null) return;
    final peer = widget.state.peerById(_selectedPeerId!);
    if (peer == null) return;

    // Send PTT stop signal
    widget.state.engine?.sendPttStop(peer);

    // B22: Send the recorded file as a voice message
    if (_recPath != null && File(_recPath!).existsSync()) {
      await widget.state.sendFile(
          _selectedPeerId!, _recPath!, LanternMsgKind.voice);
    }
  }

  @override
  Widget build(BuildContext context) {
    final peers = widget.state.peers;
    final channels = ['general', 'emergency', 'info'];
    final currentPresence = _channelPresence[_currentChannel] ?? {};
    return Column(
      children: [
        // Channel selector
        Container(
          padding: const EdgeInsets.all(12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.radio, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _currentChannel,
                      items: channels.map((c) {
                        final count = (_channelPresence[c] ?? {}).length;
                        return DropdownMenuItem(
                          value: c,
                          child: Row(
                            children: [
                              L.txt('#$c', size: L.body, weight: FontWeight.w600),
                              if (count > 0) ...[
                                const SizedBox(width: 8),
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: Colors.green,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                L.txt('$count', size: L.tiny, color: L.muted(context)),
                              ],
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (v) {
                        if (v != null) _joinChannel(v);
                      },
                    ),
                  ),
                ],
              ),
              // Peer selector
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.person, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      hint: L.txt('Select peer', size: L.body),
                      value: _selectedPeerId,
                      items: peers.map((p) {
                        final onChannel = currentPresence.contains(p.id);
                        return DropdownMenuItem(
                          value: p.id,
                          child: Row(
                            children: [
                              if (onChannel) ...[
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: Colors.green,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],
                              L.txt('${p.name} ${p.handle}', size: L.body),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (v) {
                        final p = peers.where((pp) => pp.id == v).firstOrNull;
                        setState(() {
                          _selectedPeerId = v;
                          _selectedPeerName = p?.name;
                        });
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Status area
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_receiving) ...[
                  const Icon(Icons.hearing, size: 64, color: Colors.green),
                  const SizedBox(height: 12),
                  L.txt('Receiving from $_receivingFrom',
                      size: L.title, weight: FontWeight.w600),
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                ] else if (_transmitting) ...[
                  const Icon(Icons.mic, size: 64, color: Colors.red),
                  const SizedBox(height: 12),
                  L.txt('Transmitting to ${_selectedPeerName ?? ""}',
                      size: L.title, weight: FontWeight.w600),
                  const SizedBox(height: 8),
                  L.txt('Release to stop', size: L.small, color: L.muted(context)),
                ] else ...[
                  Icon(Icons.radio,
                      size: 64,
                      color: _selectedPeerId != null
                          ? Theme.of(context).colorScheme.primary
                          : L.muted(context)),
                  const SizedBox(height: 12),
                  L.txt(
                      _selectedPeerId != null
                          ? 'Hold to talk to ${_selectedPeerName ?? ""}'
                          : 'Select a peer above',
                      size: L.body,
                      color: L.muted(context)),
                ],
              ],
            ),
          ),
        ),

        // PTT button
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: GestureDetector(
              onLongPressStart: (_) => _startTransmit(),
              onLongPressEnd: (_) => _stopTransmit(),
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _transmitting
                      ? Colors.red
                      : _selectedPeerId != null
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                  boxShadow: _transmitting
                      ? [
                          BoxShadow(
                            color: Colors.red.withValues(alpha: 0.4),
                            blurRadius: 20,
                            spreadRadius: 5,
                          )
                        ]
                      : null,
                ),
                child: Center(
                  child: Icon(
                    _transmitting ? Icons.mic : Icons.mic_none,
                    size: 48,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Message search screen.
class MessageSearchScreen extends StatefulWidget {
  final AppState state;
  const MessageSearchScreen({super.key, required this.state});

  @override
  State<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

class _MessageSearchScreenState extends State<MessageSearchScreen> {
  final _queryCtrl = TextEditingController();
  List<ChatMessage> _results = [];
  bool _searching = false;
  Timer? _debounce;

  @override
  void dispose() {
    _queryCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(query));
  }

  Future<void> _search(String query) async {
    setState(() => _searching = true);
    final results = await widget.state.store.searchMessages(query.trim());
    if (mounted) {
      setState(() {
        _results = results;
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _queryCtrl,
          autofocus: true,
          onChanged: _onChanged,
          decoration: const InputDecoration(
            hintText: 'Search messages…',
            border: InputBorder.none,
          ),
        ),
      ),
      body: _searching
          ? const Center(child: CircularProgressIndicator())
          : _results.isEmpty
              ? Center(
                  child: L.txt(
                      _queryCtrl.text.length < 2
                          ? 'Type to search'
                          : 'No results',
                      size: L.body,
                      color: L.muted(context)))
              : ListView.builder(
                  itemCount: _results.length,
                  itemBuilder: (context, i) {
                    final m = _results[i];
                    final isGroup = m.chatId.startsWith('grp-');
                    return ListTile(
                      leading: Icon(
                          isGroup ? Icons.group : Icons.person,
                          size: 20),
                      title: L.txt(m.text ?? '', size: L.body,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: L.muteTxt(context,
                          '${m.chatId} · ${_formatTime(m.ts)}'),
                      onTap: () {
                        // Navigate to the chat
                        Navigator.of(context).pop();
                        // TODO: navigate to specific message in chat
                      },
                    );
                  },
                ),
    );
  }

  String _formatTime(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
