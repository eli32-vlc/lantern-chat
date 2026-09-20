import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

import '../core/app_state.dart';
import '../core/protocol.dart';
import '../core/store.dart';
import 'adaptive.dart';

class ChatPage extends StatefulWidget {
  final AppState state;
  final String peerId;
  final String peerName;
  const ChatPage(
      {super.key,
      required this.state,
      required this.peerId,
      required this.peerName});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage> _msgs = [];
  Timer? _poll;
  bool _sending = false;
  bool _recording = false;
  final _rec = AudioRecorder();
  String? _recPath;
  DateTime? _recStart;

  @override
  void initState() {
    super.initState();
    widget.state.store.markRead(widget.peerId);
    _reload();
    _poll = Timer.periodic(const Duration(milliseconds: 800), (_) => _reload());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    _rec.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final msgs =
        await widget.state.store.messagesFor(widget.peerId, limit: 300);
    if (!mounted) return;
    final changed = msgs.length != _msgs.length ||
        (msgs.isNotEmpty &&
            _msgs.isNotEmpty &&
            msgs.last.id != _msgs.last.id);
    setState(() => _msgs = msgs);
    await widget.state.store.markRead(widget.peerId);
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
    final ok = await widget.state.sendText(widget.peerId, text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Peer not verified or offline — message saved, not delivered.')));
    }
    _reload();
  }

  Future<void> _attach() async {
    final peer = widget.state.peerById(widget.peerId);
    if (peer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Peer is offline right now.')));
      return;
    }
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo),
              title: const Text('Photo or video'),
              onTap: () async {
                Navigator.pop(context);
                final f = await ImagePicker()
                    .pickImage(source: ImageSource.gallery);
                if (f != null) {
                  await widget.state.sendFile(widget.peerId, f.path,
                      LanternMsgKind.image);
                  _reload();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Camera'),
              onTap: () async {
                Navigator.pop(context);
                final f =
                    await ImagePicker().pickImage(source: ImageSource.camera);
                if (f != null) {
                  await widget.state.sendFile(widget.peerId, f.path,
                      LanternMsgKind.image);
                  _reload();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('File'),
              onTap: () async {
                Navigator.pop(context);
                final r = await FilePicker.pickFiles();
                if (r.isNotEmpty && r.single.path != null) {
                  await widget.state.sendFile(
                      widget.peerId, r.single.path!, LanternMsgKind.file);
                  _reload();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      final path = await _rec.stop();
      final start = _recStart;
      setState(() => _recording = false);
      if (path != null && start != null) {
        final dur =
            DateTime.now().difference(start).inMilliseconds.clamp(500, 1 << 31);
        await widget.state.sendFile(widget.peerId, path, LanternMsgKind.voice,
            durationMs: dur);
        _reload();
      }
      return;
    }
    if (!await _rec.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission denied.')));
      }
      return;
    }
    final dir = Directory(
        '${Directory.systemTemp.path}/lantern_voice');
    await dir.create(recursive: true);
    _recPath =
        '${dir.path}/v_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc),
        path: _recPath!);
    setState(() {
      _recording = true;
      _recStart = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    return LanternScaffold(
      title: widget.peerName,
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Colors.green.shade50,
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock, size: 14, color: Colors.green),
                SizedBox(width: 6),
                Text('End-to-end encrypted',
                    style: TextStyle(fontSize: 12, color: Colors.green)),
              ],
            ),
          ),
          Expanded(
            child: _msgs.isEmpty
                ? const Center(
                    child: Text('Start the conversation 👋\n'
                        'Messages stay on this WiFi only.'))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _msgs.length,
                    itemBuilder: (_, i) => _bubble(_msgs[i]),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  IconButton(
                      onPressed: _attach,
                      icon: const Icon(Icons.add_circle_outline),
                      tooltip: 'Attach'),
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
                          borderRadius:
                              BorderRadius.all(Radius.circular(20)),
                        ),
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _toggleRecord,
                    icon: Icon(_recording ? Icons.stop : Icons.mic),
                    color: _recording ? Colors.red : null,
                    tooltip: 'Voice message',
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
    final me = m.outgoing;
    final bg = me
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    return Align(
      alignment: me ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _msgMenu(m),
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
              _content(m),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_time(m.ts),
                      style:
                          const TextStyle(fontSize: 10, color: Colors.grey)),
                  if (me) ...[
                    const SizedBox(width: 4),
                    Icon(
                      m.delivered ? Icons.done_all : Icons.done,
                      size: 12,
                      color: m.delivered ? Colors.blue : Colors.grey,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(ChatMessage m) {
    switch (m.kind) {
      case LanternMsgKind.text:
        return SelectableText(m.text ?? '');
      case LanternMsgKind.image:
        final p = m.filePath;
        if (p != null && File(p).existsSync()) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(File(p), width: 220),
              ),
              if (m.text != null) Text(m.text!),
            ],
          );
        }
        return Text('📷 Photo (${m.fileName ?? 'unavailable'})');
      case LanternMsgKind.voice:
        return _VoiceBubble(m);
      case LanternMsgKind.video:
        return _VideoBubble(m);
      case LanternMsgKind.file:
        return _FileTile(m);
      case LanternMsgKind.callEvent:
        return Text('📞 ${m.text ?? 'Call'}');
      case LanternMsgKind.system:
        return Text(m.text ?? '',
            style: const TextStyle(fontStyle: FontStyle.italic));
    }
  }

  String _time(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  void _msgMenu(ChatMessage m) {
    showModalBottomSheet(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m.text != null)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy'),
                onTap: () => Navigator.pop(sheetCtx),
              ),
            if (m.kind == LanternMsgKind.file ||
                m.kind == LanternMsgKind.image ||
                m.kind == LanternMsgKind.video ||
                m.kind == LanternMsgKind.voice)
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('Open file'),
                subtitle: Text(m.filePath ?? m.fileName ?? ''),
                onTap: () => Navigator.pop(sheetCtx),
              ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title:
                  const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () async {
                Navigator.pop(sheetCtx);
                await widget.state.store.db.delete('messages',
                    where: 'id = ?', whereArgs: [m.id]);
                _reload();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Playable voice message bubble (file must exist locally).
class _VoiceBubble extends StatefulWidget {
  final ChatMessage m;
  const _VoiceBubble(this.m);

  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble> {
  final _player = AudioPlayer();
  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((s) {
      if (mounted) {
        setState(() {
          _playing = (s == PlayerState.playing);
        });
      }
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) {
        setState(() => _dur = d);
      }
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) {
        setState(() => _pos = p);
      }
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _pos = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final p = widget.m.filePath;
    if (p == null || !File(p).existsSync()) return;
    if (_playing) {
      await _player.pause();
    } else {
      if (_pos > Duration.zero) {
        await _player.resume();
      } else {
        await _player.play(DeviceFileSource(p));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.m.filePath;
    final exists = p != null && File(p).existsSync();
    final label = widget.m.durationMs != null
        ? '${(widget.m.durationMs! / 1000).round()}s'
        : (widget.m.fileName ?? 'Voice');
    final progress = _dur.inMilliseconds > 0
        ? (_pos.inMilliseconds / _dur.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    return SizedBox(
      width: 210,
      child: Row(
        children: [
          IconButton(
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
            onPressed: exists ? _toggle : null,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 4),
                Text(exists ? '🎙️ $label' : '🎙️ Voice unavailable',
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline video bubble with tap-to-play/pause.
class _VideoBubble extends StatefulWidget {
  final ChatMessage m;
  const _VideoBubble(this.m);

  @override
  State<_VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<_VideoBubble> {
  VideoPlayerController? _ctrl;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    final p = widget.m.filePath;
    if (p != null && File(p).existsSync()) {
      _ctrl = VideoPlayerController.file(File(p))
        ..initialize().then((_) {
          if (mounted) setState(() => _ready = true);
        });
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ctrl == null) {
      return Text('🎬 Video: ${widget.m.fileName ?? ''} (unavailable)');
    }
    if (!_ready) {
      return const SizedBox(
        width: 220,
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return GestureDetector(
      onTap: () {
        setState(() {
          if (_ctrl!.value.isPlaying) {
            _ctrl!.pause();
          } else {
            _ctrl!.play();
          }
        });
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 220,
              child: AspectRatio(
                aspectRatio: _ctrl!.value.aspectRatio == 0
                    ? 16 / 9
                    : _ctrl!.value.aspectRatio,
                child: VideoPlayer(_ctrl!),
              ),
            ),
          ),
          if (!_ctrl!.value.isPlaying) ...[
            const Icon(Icons.play_circle_fill,
                size: 48, color: Colors.white70),
          ],
        ],
      ),
    );
  }
}

/// File attachment tile with size + open hint.
class _FileTile extends StatelessWidget {
  final ChatMessage m;
  const _FileTile(this.m);

  String _kb(int b) =>
      b < 1024 * 1024 ? '${(b / 1024).toStringAsFixed(1)} KB' : '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final exists =
        m.filePath != null && File(m.filePath!).existsSync();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(exists ? Icons.insert_drive_file : Icons.file_download_off,
            size: 28),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(m.fileName ?? 'File',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                '${m.fileBytes != null ? _kb(m.fileBytes!) : ''}${exists ? '' : ' • not on this device'}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
