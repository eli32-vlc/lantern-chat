import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'protocol.dart';

/// Result of accepting one incoming file chunk.
class IncomingChunkResult {
  final bool transportAccepted;
  final bool complete;
  final bool success;
  final String? finalPath;
  final String? fileName;
  final int? fileBytes;
  final int? durationMs;
  final int? timestamp;
  final String? text;

  const IncomingChunkResult({
    required this.transportAccepted,
    required this.complete,
    required this.success,
    this.finalPath,
    this.fileName,
    this.fileBytes,
    this.durationMs,
    this.timestamp,
    this.text,
  });
}

/// Disk-backed receiver for Lantern's chunked file protocol.
///
/// Each accepted chunk is written to its own file and flushed before the
/// application ACKs it. Once all chunks exist, they are concatenated in order,
/// byte count and SHA-256 are verified, and the result is atomically renamed
/// into the inbox.
class IncomingFileTransfer {
  /// Final files are written below [root]; partial transfers live in
  /// [root]/.transfers so a process restart never exposes a partial file.
  final Directory root;

  IncomingFileTransfer(this.root);

  Directory get _transferRoot => Directory('${root.path}/.transfers');

  Future<IncomingChunkResult> accept({
    required String peerId,
    required String msgId,
    required int index,
    required int total,
    required List<int> bytes,
    required Map<String, dynamic> metadata,
  }) async {
    final peerKey = _safeSegment(peerId, fallback: 'peer');
    final messageKey = _safeSegment(msgId, fallback: 'message');
    final transferDir = Directory(
      '${_transferRoot.path}/$peerKey/$messageKey',
    );
    final metadataFile = File('${transferDir.path}/metadata.json');

    final declaredBytes = _asInt(metadata['bytes']);
    final declaredHash = _asString(metadata['sha256'])?.toLowerCase();
    if (declaredBytes == null ||
        declaredBytes < 0 ||
        declaredBytes > LanternProtocol.maxFileBytes) {
      return const IncomingChunkResult(
        transportAccepted: false,
        complete: false,
        success: false,
      );
    }
    if (declaredHash == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(declaredHash)) {
      return const IncomingChunkResult(
        transportAccepted: false,
        complete: false,
        success: false,
      );
    }

    final expectedChunkBytes = index == total - 1
        ? declaredBytes - index * LanternProtocol.fileChunkSize
        : LanternProtocol.fileChunkSize;
    if (bytes.length != expectedChunkBytes) {
      return const IncomingChunkResult(
        transportAccepted: false,
        complete: false,
        success: false,
      );
    }

    try {
      await transferDir.create(recursive: true);
      if (await metadataFile.exists()) {
        final decoded = jsonDecode(await metadataFile.readAsString());
        if (decoded is! Map<String, dynamic> ||
            _asInt(decoded['bytes']) != declaredBytes ||
            _asString(decoded['sha256'])?.toLowerCase() != declaredHash ||
            _asInt(decoded['chunks']) != total) {
          return const IncomingChunkResult(
            transportAccepted: false,
            complete: false,
            success: false,
          );
        }
      } else {
        await _atomicWrite(
          metadataFile,
          utf8.encode(jsonEncode({
            ...metadata,
            'bytes': declaredBytes,
            'sha256': declaredHash,
            'chunks': total,
            'created_at': DateTime.now().millisecondsSinceEpoch,
          })),
        );
      }

      // Always replace the part. A retransmission repairs a damaged part of
      // the same length instead of silently retaining corrupt bytes.
      await _atomicWrite(
        File('${transferDir.path}/${_partName(index)}'),
        bytes,
      );

      for (var i = 0; i < total; i++) {
        if (!await File('${transferDir.path}/${_partName(i)}').exists()) {
          return const IncomingChunkResult(
            transportAccepted: true,
            complete: false,
            success: true,
          );
        }
      }

      final rawName = _asString(metadata['name']) ?? msgId;
      final safeName = _safeSegment(rawName, fallback: 'file');
      final inbox = Directory('${root.path}/$peerKey');
      await inbox.create(recursive: true);
      final finalFile = File('${inbox.path}/$messageKey-$safeName');
      final assembled = File('${transferDir.path}/assembled.bin');

      final hashSink = Sha256().newHashSink();
      final output = assembled.openWrite(mode: FileMode.writeOnly);
      var actualBytes = 0;
      try {
        for (var i = 0; i < total; i++) {
          await for (final partBytes
              in File('${transferDir.path}/${_partName(i)}').openRead()) {
            actualBytes += partBytes.length;
            hashSink.add(partBytes);
            output.add(partBytes);
          }
        }
        await output.flush();
      } finally {
        await output.close();
        hashSink.close();
      }

      final digest = await hashSink.hash();
      final actualHash = digest.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      if (actualBytes != declaredBytes || actualHash != declaredHash) {
        if (await assembled.exists()) await assembled.delete();
        return const IncomingChunkResult(
          transportAccepted: true,
          complete: true,
          success: false,
        );
      }

      if (await finalFile.exists()) await finalFile.delete();
      await assembled.rename(finalFile.path);
      return IncomingChunkResult(
        transportAccepted: true,
        complete: true,
        success: true,
        finalPath: finalFile.path,
        fileName: rawName,
        fileBytes: actualBytes,
        durationMs: _asInt(metadata['dur']),
        timestamp: _asInt(metadata['ts']),
        text: _asString(metadata['text']),
      );
    } catch (_) {
      return const IncomingChunkResult(
        transportAccepted: false,
        complete: false,
        success: false,
      );
    }
  }

  /// Remove a completed transfer's temporary parts after the database insert.
  Future<void> discardTransfer({
    required String peerId,
    required String msgId,
  }) async {
    final dir = Directory(
      '${_transferRoot.path}/${_safeSegment(peerId, fallback: 'peer')}/'
      '${_safeSegment(msgId, fallback: 'message')}',
    );
    if (await dir.exists()) {
      try { await dir.delete(recursive: true); } catch (_) {}
    }
  }

  /// Remove partial transfers older than [maxAge].
  Future<void> cleanupStale({
    Duration maxAge = const Duration(hours: 24),
  }) async {
    final transferRoot = _transferRoot;
    if (!await transferRoot.exists()) return;
    final cutoff = DateTime.now().subtract(maxAge);
    try {
      await for (final peerDir in transferRoot.list(followLinks: false)) {
        if (peerDir is! Directory) continue;
        try {
          if ((await peerDir.stat()).modified.isBefore(cutoff)) {
            await peerDir.delete(recursive: true);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _atomicWrite(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final temp = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
  }

  static String _partName(int index) =>
      'part-${index.toString().padLeft(6, '0')}.bin';

  static String _safeSegment(String value, {required String fallback}) {
    var safe = value.replaceAll(RegExp(r'[/\\:\r\n]'), '_').trim();
    if (safe.isEmpty) safe = fallback;
    if (safe.length > 160) safe = safe.substring(0, 160);
    return safe;
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static String? _asString(dynamic value) =>
      value is String && value.isNotEmpty ? value : null;
}

/// Copy [source] to [target] while calculating SHA-256.
Future<({String hash, int bytes})> copyAndHash(
  File source,
  File target,
) async {
  await target.parent.create(recursive: true);
  final temp = File(
    '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  final hashSink = Sha256().newHashSink();
  final output = temp.openWrite(mode: FileMode.writeOnly);
  var length = 0;
  try {
    await for (final chunk in source.openRead()) {
      length += chunk.length;
      hashSink.add(chunk);
      output.add(chunk);
    }
    await output.flush();
  } finally {
    await output.close();
    hashSink.close();
  }
  final hash = await hashSink.hash();
  if (await target.exists()) await target.delete();
  await temp.rename(target.path);
  return (
    hash: hash.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(),
    bytes: length,
  );
}
