import 'dart:io';
import 'dart:typed_data';
import 'dart:math'; // ignore: unused_import
import 'dart:convert'; // ignore: unused_import

/// Generates a simple lantern icon as a PNG file.
/// Run: dart run tool/generate_icon.dart
void main() {
  final size = 1024;
  final pixels = Uint8List(size * size * 4); // RGBA

  // Background gradient: warm amber (#FF8C00 to #CC5500)
  for (int y = 0; y < size; y++) {
    final t = y / size;
    final r = (255 * (1.0 - t * 0.2)).round();
    final g = (140 * (1.0 - t * 0.4)).round();
    final b = (0 + t * 30).round();
    for (int x = 0; x < size; x++) {
      final i = (y * size + x) * 4;
      pixels[i] = r;
      pixels[i + 1] = g;
      pixels[i + 2] = b;
      pixels[i + 3] = 255;
    }
  }

  // Draw a simple lantern shape (rounded rectangle body + top/bottom caps)
  final cx = size ~/ 2;
  final cy = size ~/ 2;

  // Lantern body (rounded rectangle)
  _fillRRect(pixels, size,
      cx - 180, cy - 250, cx + 180, cy + 200, 40,
      [255, 230, 180, 255]); // warm cream

  // Top cap
  _fillRRect(pixels, size,
      cx - 120, cy - 300, cx + 120, cy - 240, 15,
      [200, 120, 40, 255]); // dark amber

  // Top hook
  _fillRRect(pixels, size,
      cx - 40, cy - 360, cx + 40, cy - 290, 20,
      [200, 120, 40, 255]);

  // Bottom cap
  _fillRRect(pixels, size,
      cx - 120, cy + 200, cx + 120, cy + 250, 15,
      [200, 120, 40, 255]);

  // Flame (yellow ellipse in center)
  _fillEllipse(pixels, size,
      cx, cy - 40, 70, 120,
      [255, 220, 80, 255]); // bright yellow
  _fillEllipse(pixels, size,
      cx, cy - 40, 40, 80,
      [255, 255, 200, 255]); // white-hot center

  // Lantern bars (vertical lines)
  for (int bar in [-140, -70, 0, 70, 140]) {
    _fillRRect(pixels, size,
        cx + bar - 8, cy - 240, cx + bar + 8, cy + 190, 4,
        [180, 110, 30, 255]);
  }

  // Horizontal bars
  _fillRRect(pixels, size,
      cx - 170, cy - 100, cx + 170, cy - 85, 4,
      [180, 110, 30, 255]);
  _fillRRect(pixels, size,
      cx - 170, cy + 60, cx + 170, cy + 75, 4,
      [180, 110, 30, 255]);

  // Encode as PNG
  final png = _encodePng(size, size, pixels);
  File('assets/icon/app_icon.png').createSync(recursive: true);
  File('assets/icon/app_icon.png').writeAsBytesSync(png);
  print('Generated assets/icon/app_icon.png (${png.length} bytes)');
}

void _fillRRect(Uint8List pixels, int imgSize,
    int x0, int y0, int x1, int y1, int radius, List<int> color) {
  for (int y = y0.clamp(0, imgSize - 1); y <= y1.clamp(0, imgSize - 1); y++) {
    for (int x = x0.clamp(0, imgSize - 1); x <= x1.clamp(0, imgSize - 1); x++) {
      // Check rounded corners
      final dx = x < x0 + radius ? x0 + radius - x : (x > x1 - radius ? x - (x1 - radius) : 0);
      final dy = y < y0 + radius ? y0 + radius - y : (y > y1 - radius ? y - (y1 - radius) : 0);
      if (dx * dx + dy * dy <= radius * radius) {
        final i = (y * imgSize + x) * 4;
        pixels[i] = color[0];
        pixels[i + 1] = color[1];
        pixels[i + 2] = color[2];
        pixels[i + 3] = color[3];
      }
    }
  }
}

void _fillEllipse(Uint8List pixels, int imgSize,
    int cx, int cy, int rx, int ry, List<int> color) {
  for (int y = (cy - ry).clamp(0, imgSize - 1); y <= (cy + ry).clamp(0, imgSize - 1); y++) {
    for (int x = (cx - rx).clamp(0, imgSize - 1); x <= (cx + rx).clamp(0, imgSize - 1); x++) {
      final dx = (x - cx) / rx;
      final dy = (y - cy) / ry;
      if (dx * dx + dy * dy <= 1.0) {
        final i = (y * imgSize + x) * 4;
        pixels[i] = color[0];
        pixels[i + 1] = color[1];
        pixels[i + 2] = color[2];
        pixels[i + 3] = color[3];
      }
    }
  }
}

Uint8List _encodePng(int width, int height, Uint8List rgba) {
  final buf = <int>[];

  // PNG signature
  buf.addAll([137, 80, 78, 71, 13, 10, 26, 10]);

  // IHDR
  final ihdr = BytesBuilder();
  _writeInt32(ihdr, width);
  _writeInt32(ihdr, height);
  ihdr.add([8, 6, 0, 0, 0]); // 8-bit RGBA
  _writeChunk(buf, 'IHDR', ihdr.toBytes());

  // IDAT
  final rawData = BytesBuilder();
  for (int y = 0; y < height; y++) {
    rawData.add([0]); // filter: none
    for (int x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      rawData.add([rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]]);
    }
  }
  final compressed = zlib.encode(rawData.toBytes());
  _writeChunk(buf, 'IDAT', Uint8List.fromList(compressed));

  // IEND
  _writeChunk(buf, 'IEND', Uint8List(0));

  return Uint8List.fromList(buf);
}

void _writeChunk(List<int> buf, String type, Uint8List data) {
  _writeInt32To(buf, data.length);
  buf.addAll(type.codeUnits);
  buf.addAll(data);
  final crcData = BytesBuilder();
  crcData.add(type.codeUnits);
  crcData.add(data);
  _writeInt32To(buf, _crc32(crcData.toBytes()));
}

void _writeInt32(BytesBuilder buf, int value) {
  buf.add([(value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]);
}

void _writeInt32To(List<int> buf, int value) {
  buf.addAll([(value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]);
}

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (int i = 0; i < 8; i++) {
      crc = (crc >> 1) ^ (crc & 1) == 1 ? 0xEDB88320 : 0;
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
