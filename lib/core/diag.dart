import 'dart:async';

/// In-memory diagnostics ring buffer. Everything the LAN engine sees and
/// does gets a one-line entry here so users can paste real traffic back
/// (Settings → Diagnostics) instead of guessing at wire formats.
class DiagEntry {
  final DateTime at;
  final String tag;
  final String msg;
  DiagEntry(this.tag, this.msg) : at = DateTime.now();

  @override
  String toString() {
    final t =
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';
    return '[$t][$tag] $msg';
  }
}

class DiagLog {
  static const maxEntries = 300;
  static final List<DiagEntry> _entries = [];
  static final _ctrl = StreamController<void>.broadcast();

  static Stream<void> get ticks => _ctrl.stream;
  static List<DiagEntry> get entries => List.unmodifiable(_entries);

  static void add(String tag, String msg) {
    _entries.add(DiagEntry(tag, msg));
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    if (!_ctrl.isClosed) _ctrl.add(null);
  }

  static String dump() => _entries.map((e) => e.toString()).join('\n');

  static void clear() {
    _entries.clear();
    if (!_ctrl.isClosed) _ctrl.add(null);
  }

  /// Short printable preview of raw bytes: ascii where printable, . otherwise.
  static String preview(List<int> bytes, [int max = 220]) {
    final n = bytes.length > max ? max : bytes.length;
    final sb = StringBuffer();
    for (var i = 0; i < n; i++) {
      final b = bytes[i];
      sb.write(b >= 32 && b < 127 ? String.fromCharCode(b) : '.');
    }
    if (bytes.length > max) sb.write('…(+${bytes.length - max}B)');
    return sb.toString();
  }
}
