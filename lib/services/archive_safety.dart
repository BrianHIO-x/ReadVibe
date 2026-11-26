import 'package:archive/archive_io.dart';

const kMaxManifestBytes = 32 * 1024 * 1024;
const kMaxSingleArchiveEntryBytes = 1024 * 1024 * 1024;
const kMaxArchiveEntries = 20000;
const kMinDeviceFreeBytesMargin = 256 * 1024 * 1024;
const kMaxArchiveTotalBytes = 4 * 1024 * 1024 * 1024;

/// Validates an archive entry path before touching disk or inflating bytes.
void assertSafeArchiveEntry(ArchiveFile entry) {
  if (entry.isSymbolicLink) {
    throw const FormatException('压缩包内包含不受支持的符号链接条目');
  }
  final name = entry.name;
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.startsWith('\\') ||
      name.contains('\\') ||
      name.codeUnits.any((c) => c < 0x20 || c == 0x7f) ||
      RegExp(r'^[A-Za-z]:').hasMatch(name)) {
    throw const FormatException('压缩包内包含不安全的文件路径');
  }
  final cleaned = entry.isDirectory && name.endsWith('/')
      ? name.substring(0, name.length - 1)
      : name;
  if (cleaned.isEmpty) return;
  final segments = cleaned.split('/');
  if (segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
    throw const FormatException('压缩包内包含非法路径片段');
  }
}

/// Tracks entry counts and decompressed byte budgets to block zip-bomb payloads.
class ArchiveExtractionBudget {
  ArchiveExtractionBudget({this.maxTotalBytes = kMaxArchiveTotalBytes});

  final int maxTotalBytes;
  int _entries = 0;
  int _totalBytes = 0;
  int _extractedBytes = 0;

  void recordHeader(ArchiveFile entry) {
    _entries++;
    if (_entries > kMaxArchiveEntries) {
      throw const FormatException('压缩包条目数量异常（超出安全上限）');
    }
    if (entry.isDirectory) return;
    final declaredSize = entry.size;
    if (declaredSize < 0 || declaredSize > kMaxSingleArchiveEntryBytes) {
      throw const FormatException('压缩包单文件体积超出安全上限');
    }
    _totalBytes += declaredSize;
    if (_totalBytes > maxTotalBytes) {
      throw const FormatException('压缩包解压总大小超出安全上限');
    }
  }

  /// Enforces byte limits against actual inflated bytes, even when archive
  /// directory headers under-declare uncompressed entry sizes.
  void recordExtractedBytes(int byteCount) {
    if (byteCount < 0 || byteCount > kMaxSingleArchiveEntryBytes) {
      throw const FormatException('压缩包单文件解压体积超出安全上限');
    }
    _extractedBytes += byteCount;
    if (_extractedBytes > maxTotalBytes) {
      throw const FormatException('压缩包解压总大小超出安全上限');
    }
  }
}
