import 'package:flutter/services.dart';

class PdfTextSearchResult {
  final int pageIndex;
  final String snippet;
  final String matchedText;
  final int snippetMatchStart;
  final int snippetMatchEnd;

  const PdfTextSearchResult({
    required this.pageIndex,
    required this.snippet,
    required this.matchedText,
    required this.snippetMatchStart,
    required this.snippetMatchEnd,
  });
}

class PdfOutlineEntry {
  final String title;
  final int pageIndex;
  final int depth;

  const PdfOutlineEntry({
    required this.title,
    required this.pageIndex,
    required this.depth,
  });
}

class PdfRendererService {
  static const _channel = MethodChannel('com.readvibe.app/pdf_renderer');

  static Future<int> getPageCount(String filePath) async {
    final count = await _channel.invokeMethod<int>('getPageCount', {
      'filePath': filePath,
    });
    if (count == null || count <= 0) {
      throw const FormatException('PDF 不包含可显示页面');
    }
    return count;
  }

  static Future<String> renderPage({
    required String filePath,
    required int pageIndex,
    required int widthPx,
  }) async {
    final path = await _channel.invokeMethod<String>('renderPage', {
      'filePath': filePath,
      'pageIndex': pageIndex,
      'widthPx': widthPx,
    });
    if (path == null || path.isEmpty) {
      throw const FormatException('PDF 页面渲染失败');
    }
    return path;
  }

  static Future<void> clearFileCache(String filePath) async {
    await _channel.invokeMethod<void>('clearFileCache', {'filePath': filePath});
  }

  static Future<List<PdfTextSearchResult>> searchText({
    required String filePath,
    required String query,
  }) async {
    final raw = await _channel.invokeListMethod<Object?>('searchText', {
      'filePath': filePath,
      'query': query,
    });
    if (raw == null) return const <PdfTextSearchResult>[];
    return raw
        .whereType<Map>()
        .map((value) {
          final map = Map<Object?, Object?>.from(value);
          return PdfTextSearchResult(
            pageIndex: (map['pageIndex'] as num?)?.toInt() ?? 0,
            snippet: map['snippet'] as String? ?? '',
            matchedText: map['matchedText'] as String? ?? '',
            snippetMatchStart: (map['snippetMatchStart'] as num?)?.toInt() ?? 0,
            snippetMatchEnd: (map['snippetMatchEnd'] as num?)?.toInt() ?? 0,
          );
        })
        .toList(growable: false);
  }

  static Future<List<PdfOutlineEntry>> getOutline(String filePath) async {
    final raw = await _channel.invokeListMethod<Object?>('getOutline', {
      'filePath': filePath,
    });
    if (raw == null) return const <PdfOutlineEntry>[];
    return raw
        .whereType<Map>()
        .map((value) {
          final map = Map<Object?, Object?>.from(value);
          return PdfOutlineEntry(
            title: map['title'] as String? ?? '',
            pageIndex: (map['pageIndex'] as num?)?.toInt() ?? 0,
            depth: (map['depth'] as num?)?.toInt() ?? 0,
          );
        })
        .where((entry) => entry.title.isNotEmpty)
        .toList(growable: false);
  }
}
