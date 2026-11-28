import 'dart:io';
import 'dart:isolate';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../models/book.dart';
import 'epub_parser.dart' show normalizeXhtmlSelfClosingTags;
import 'mobi/kindle_binary_reader.dart';
import 'txt_parser.dart';

const _maxKindleFileBytes = 256 * 1024 * 1024;

/// Parses `.mobi`, `.azw`, `.azw3` (KF8), and PalmDOC (`TEXtREAd`) locally
/// without external parser dependencies.
Future<Book> parseKindleBook(String filePath, String fileName) async {
  final file = File(filePath);
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
    throw const FormatException('Kindle 电子书为空或无法读取');
  }
  if (stat.size > _maxKindleFileBytes) {
    throw const FormatException('Kindle 电子书过大，请选择小于 256 MB 的文件');
  }
  return Isolate.run(() => _parseKindleBook(filePath, fileName, stat.size));
}

Book _parseKindleBook(String filePath, String fileName, int fileSize) {
  final rawBytes = File(filePath).readAsBytesSync();
  final decoded = KindleBinaryReader.parse(rawBytes);

  final bodyText = decoded.plainTextFallback
      ? decoded.htmlChunks.join('\n')
      : decoded.htmlChunks
            .map(_kindleHtmlToPlainText)
            .where((part) => part.isNotEmpty)
            .join('\n\n');

  final content = bodyText.trim();
  if (content.isEmpty) {
    throw const FormatException('Kindle 电子书不包含可阅读的文本内容');
  }

  return buildBookFromText(
    content: content,
    fileName: fileName,
    format: _formatFromFileName(fileName),
    fileSize: fileSize,
    title: decoded.title.isEmpty ? null : decoded.title,
    author: decoded.author.isEmpty ? null : decoded.author,
  );
}

BookFormat _formatFromFileName(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.azw3')) return BookFormat.azw3;
  if (lower.endsWith('.azw')) return BookFormat.azw;
  return BookFormat.mobi;
}

const _hiddenMarkupTags = <String>{
  'head',
  'title',
  'style',
  'script',
  'noscript',
  'template',
};

const _blockBreakTags = <String>{
  'p',
  'div',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'li',
  'dt',
  'dd',
  'tr',
  'blockquote',
  'pre',
  'section',
  'article',
  'header',
  'footer',
  'aside',
  'figcaption',
  'hr',
};

const _cellSeparatorTags = <String>{'td', 'th', 'dd', 'dt'};

String _kindleHtmlToPlainText(String rawMarkup) {
  if (rawMarkup.trim().isEmpty) return '';
  final normalized = normalizeXhtmlSelfClosingTags(
    rawMarkup.replaceAll(RegExp(r'<\?xml[^>]*\?>', caseSensitive: false), ''),
  );
  final document = html_parser.parse(normalized);
  final root = document.body ?? document.documentElement;
  if (root == null) return '';

  final out = StringBuffer();
  var needsNewline = false;
  var lastWasSpace = true;

  void appendBreak() {
    if (out.isEmpty) return;
    needsNewline = false;
    if (!out.toString().endsWith('\n')) {
      out.write('\n');
    }
    lastWasSpace = true;
  }

  void appendText(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[ \t\r\n]+'), ' ');
    for (var i = 0; i < cleaned.length; i++) {
      final ch = cleaned[i];
      if (ch == ' ') {
        if (!lastWasSpace && !needsNewline && out.isNotEmpty) {
          out.write(' ');
          lastWasSpace = true;
        }
      } else {
        if (needsNewline) {
          appendBreak();
        }
        out.write(ch);
        lastWasSpace = false;
      }
    }
  }

  void walk(Node node) {
    if (node is Text) {
      appendText(node.data);
      return;
    }
    if (node is! Element) return;
    final tag = (node.localName ?? '').toLowerCase();
    final fullName = node.localName?.toLowerCase() ?? '';
    if (_hiddenMarkupTags.contains(tag)) return;
    // Strip SVG `<title>` / `<desc>` inside vector graphics too.
    if (tag == 'desc') return;

    if (tag == 'br' || tag == 'pagebreak' || fullName.endsWith(':pagebreak')) {
      appendBreak();
      return;
    }

    final isBlock = _blockBreakTags.contains(tag);
    final isCell = _cellSeparatorTags.contains(tag);
    if (isBlock && out.isNotEmpty) {
      needsNewline = true;
    }

    for (final child in node.nodes) {
      walk(child);
    }

    if (isCell && !lastWasSpace && !needsNewline && out.isNotEmpty) {
      out.write('　');
      lastWasSpace = true;
    } else if (isBlock && out.isNotEmpty) {
      needsNewline = true;
    }
  }

  walk(root);
  return out
      .toString()
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}
