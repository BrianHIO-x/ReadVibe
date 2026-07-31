import 'package:flutter/services.dart';

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
}
