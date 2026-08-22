import 'package:flutter/services.dart';

class PdfPasswordRequiredException extends FormatException {
  const PdfPasswordRequiredException() : super('PDF 受密码保护，请输入打开密码');
}

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

class PdfTextAnnotation {
  final int pageIndex;
  final String annotationId;
  final String contents;

  const PdfTextAnnotation({
    required this.pageIndex,
    required this.annotationId,
    required this.contents,
  });
}

class PdfRendererService {
  static const _channel = MethodChannel('com.readvibe.app/pdf_renderer');

  static Future<int> getPageCount(String filePath) async {
    late final int? count;
    try {
      count = await _channel.invokeMethod<int>('getPageCount', {
        'filePath': filePath,
      });
    } on PlatformException catch (error) {
      if (error.code == 'PDF_PASSWORD_REQUIRED' ||
          await isPasswordProtected(filePath)) {
        throw const PdfPasswordRequiredException();
      }
      rethrow;
    }
    if (count == null || count <= 0) {
      throw const FormatException('PDF 不包含可显示页面');
    }
    return count;
  }

  static Future<bool> isPasswordProtected(String filePath) async {
    try {
      return await _channel.invokeMethod<bool>('isPasswordProtected', {
            'filePath': filePath,
          }) ??
          false;
    } on PlatformException catch (error) {
      return error.code == 'PDF_PASSWORD_REQUIRED';
    }
  }

  static Future<int> unlockPdf({
    required String filePath,
    required String password,
  }) async {
    try {
      final count = await _channel.invokeMethod<int>('unlockPdf', {
        'filePath': filePath,
        'password': password,
      });
      if (count == null || count <= 0) {
        throw const FormatException('PDF 解锁后没有可显示页面');
      }
      return count;
    } on PlatformException catch (error) {
      if (error.code == 'PDF_PASSWORD_REQUIRED') {
        throw const PdfPasswordRequiredException();
      }
      rethrow;
    }
  }

  static Future<void> syncTextNote({
    required String filePath,
    required int pageIndex,
    required String noteId,
    required String contents,
  }) async {
    await _channel.invokeMethod<void>('syncTextNote', {
      'filePath': filePath,
      'pageIndex': pageIndex,
      'noteId': noteId,
      'contents': contents,
    });
  }

  static Future<String> recognizePageText({
    required String filePath,
    required int pageIndex,
  }) async {
    return await _channel.invokeMethod<String>('recognizePageText', {
          'filePath': filePath,
          'pageIndex': pageIndex,
        }) ??
        '';
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

  static Future<List<PdfTextAnnotation>> getTextAnnotations(
    String filePath,
  ) async {
    final raw = await _channel.invokeListMethod<Object?>('getTextAnnotations', {
      'filePath': filePath,
    });
    if (raw == null) return const <PdfTextAnnotation>[];
    return raw
        .whereType<Map>()
        .map((value) {
          final map = Map<Object?, Object?>.from(value);
          return PdfTextAnnotation(
            pageIndex: (map['pageIndex'] as num?)?.toInt() ?? -1,
            annotationId: map['annotationId'] as String? ?? '',
            contents: map['contents'] as String? ?? '',
          );
        })
        .where(
          (annotation) =>
              annotation.pageIndex >= 0 && annotation.contents.isNotEmpty,
        )
        .toList(growable: false);
  }
}
