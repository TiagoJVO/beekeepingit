import 'dart:io';
import 'dart:typed_data';

/// The code points a TrueType face's `cmap` maps to a real glyph.
///
/// Extracted from `test/fonts_local_fallback_test.dart` (#620) when
/// `test/emoji_glyph_fallback_test.dart` (#673) grew the same need: both ask
/// the same question — "does this bundled face actually cover this character,
/// or would it render as the missing-glyph box?" — of different files.
///
/// Reads the Windows Unicode subtable (platform 3, encoding 1 or 10) in format
/// 4 or 12. That is enough for every TrueType face this app bundles, and far
/// cheaper than pulling in a font-parsing dependency for a handful of
/// assertions. Encoding 10 (format 12) is what carries the supplementary
/// planes, which is where every emoji lives.
///
/// Returns an empty set for a file with no `cmap` at all, so a caller's
/// `contains` assertion fails with the code point it wanted rather than an
/// exception about table offsets.
Set<int> codePointsCoveredBy(String fontPath) {
  final bytes = File(fontPath).readAsBytesSync();
  final data = ByteData.sublistView(Uint8List.fromList(bytes));

  int? cmapOffset;
  final tableCount = data.getUint16(4);
  for (var i = 0; i < tableCount; i++) {
    final record = 12 + i * 16;
    final tag = String.fromCharCodes(bytes.sublist(record, record + 4));
    if (tag == 'cmap') cmapOffset = data.getUint32(record + 8);
  }
  if (cmapOffset == null) return <int>{};

  int? subtable;
  final subtableCount = data.getUint16(cmapOffset + 2);
  for (var i = 0; i < subtableCount; i++) {
    final record = cmapOffset + 4 + i * 8;
    final platform = data.getUint16(record);
    final encoding = data.getUint16(record + 2);
    if (platform == 3 && (encoding == 1 || encoding == 10)) {
      subtable = cmapOffset + data.getUint32(record + 4);
    }
  }
  if (subtable == null) return <int>{};

  final covered = <int>{};
  switch (data.getUint16(subtable)) {
    case 4:
      final segmentBytes = data.getUint16(subtable + 6);
      final ends = subtable + 14;
      final starts = ends + segmentBytes + 2;
      final deltas = starts + segmentBytes;
      final rangeOffsets = deltas + segmentBytes;
      for (var i = 0; i < segmentBytes ~/ 2; i++) {
        final start = data.getUint16(starts + i * 2);
        final end = data.getUint16(ends + i * 2);
        if (start == 0xFFFF) continue;
        final delta = data.getInt16(deltas + i * 2);
        final rangeOffset = data.getUint16(rangeOffsets + i * 2);
        for (var c = start; c <= end; c++) {
          int glyph;
          if (rangeOffset == 0) {
            glyph = (c + delta) & 0xFFFF;
          } else {
            final index = rangeOffsets + i * 2 + rangeOffset + (c - start) * 2;
            if (index + 1 >= data.lengthInBytes) continue;
            glyph = data.getUint16(index);
            if (glyph != 0) glyph = (glyph + delta) & 0xFFFF;
          }
          if (glyph != 0) covered.add(c);
        }
      }
    case 12:
      final groups = data.getUint32(subtable + 12);
      for (var i = 0; i < groups; i++) {
        final group = subtable + 16 + i * 12;
        final start = data.getUint32(group);
        final end = data.getUint32(group + 4);
        for (var c = start; c <= end; c++) {
          covered.add(c);
        }
      }
  }
  return covered;
}
