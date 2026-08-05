import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import 'storage_service.dart';
import 'txt_parser.dart';

/// DeepSeek-backed chapter format analysis.
///
/// Text-based books (TXT/DOCX/DOC) rely on built-in heading patterns. When a
/// book uses a marker shape the patterns miss, this service samples candidate
/// lines, asks DeepSeek for one regular expression describing the book's
/// chapter headings, and validates that expression locally before the caller
/// re-splits anything. Only the sampled lines leave the device, never the
/// full text.
class AiChapterService {
  static const _apiKeyPref = 'deepseek_api_key';
  static const _endpoint = 'https://api.deepseek.com/chat/completions';
  static const _timeout = Duration(seconds: 45);

  Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_apiKeyPref)?.trim();
    return key == null || key.isEmpty ? null : key;
  }

  Future<void> setApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(_apiKeyPref);
    } else {
      await prefs.setString(_apiKeyPref, trimmed);
    }
  }

  Future<bool> hasApiKey() async => await getApiKey() != null;

  /// Asks DeepSeek for a chapter-heading regex based on [sampleLines].
  /// Throws [FormatException] with a user-facing message on failure.
  Future<String> inferChapterPattern(List<String> sampleLines) async {
    final apiKey = await getApiKey();
    if (apiKey == null) {
      throw const FormatException('请先在设置中填写 DeepSeek API 密钥');
    }

    final sample = sampleLines.take(300).toList();
    final numbered = [
      for (var i = 0; i < sample.length; i++) '$i: ${sample[i]}',
    ].join('\n');

    final client = HttpClient();
    try {
      final request = await client
          .postUrl(Uri.parse(_endpoint))
          .timeout(_timeout);
      request.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.write(
        jsonEncode({
          'model': 'deepseek-chat',
          'temperature': 0.1,
          'max_tokens': 600,
          'response_format': {'type': 'json_object'},
          'messages': [
            {
              'role': 'system',
              'content':
                  '你是小说文本格式分析助手。用户会给出从一本小说中抽取的候选行（每行带编号）。'
                  '其中混有真正的章节标题行和普通正文行。请找出章节标题行的共同格式，'
                  '返回一个匹配章节标题行的正则表达式。要求：'
                  '1) 兼容 Dart RegExp，不使用环视、反向引用和命名捕获组；'
                  '2) 只匹配标题行，不匹配正文句子；'
                  '3) 用 ^ 和 \$ 锚定整行；'
                  '4) 如果样本中没有可识别的章节标题格式，regex 返回空字符串。'
                  '只返回 JSON：{"regex": "...", "reason": "一句话说明"}',
            },
            {'role': 'user', 'content': numbered},
          ],
        }),
      );
      final response = await request.close().timeout(_timeout);
      final body = await utf8.decoder.bind(response).join().timeout(_timeout);
      if (response.statusCode == 401) {
        throw const FormatException('DeepSeek 密钥无效，请检查后重试');
      }
      if (response.statusCode == 402) {
        throw const FormatException('DeepSeek 账户余额不足');
      }
      if (response.statusCode == 429) {
        throw const FormatException('DeepSeek 请求过于频繁，请稍后再试');
      }
      if (response.statusCode != 200) {
        throw FormatException('DeepSeek 服务异常（HTTP ${response.statusCode}）');
      }

      final payload = jsonDecode(body);
      if (payload is! Map<String, dynamic>) {
        throw const FormatException('DeepSeek 返回内容无法解析');
      }
      final choices = payload['choices'];
      if (choices is! List || choices.isEmpty) {
        throw const FormatException('DeepSeek 没有返回结果');
      }
      final message = (choices.first as Map<String, dynamic>)['message'];
      final content = (message as Map<String, dynamic>)['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        throw const FormatException('DeepSeek 返回内容为空');
      }
      final parsed = jsonDecode(content);
      if (parsed is! Map<String, dynamic>) {
        throw const FormatException('DeepSeek 返回格式不符合预期');
      }
      final regex = (parsed['regex'] as String? ?? '').trim();
      if (regex.isEmpty) {
        throw const FormatException('DeepSeek 未能从样本中识别出章节格式');
      }
      return sanitizeChapterRegex(regex);
    } on TimeoutException {
      throw const FormatException('DeepSeek 请求超时，请检查网络后重试');
    } on SocketException {
      throw const FormatException('无法连接 DeepSeek，请检查网络');
    } finally {
      client.close();
    }
  }

  /// Rejects expressions the local engine cannot run safely. Dart RegExp has
  /// no lookaround support anyway, and backreferences invite pathological
  /// backtracking on a whole novel.
  static String sanitizeChapterRegex(String regex) {
    if (regex.length > 300) {
      throw const FormatException('DeepSeek 返回的表达式过长');
    }
    if (regex.contains('(?') || RegExp(r'\\[1-9]').hasMatch(regex)) {
      throw const FormatException('DeepSeek 返回的表达式不受支持');
    }
    try {
      RegExp(regex);
    } on Object {
      throw const FormatException('DeepSeek 返回的表达式无法编译');
    }
    return regex;
  }

  /// Counts how many lines the pattern would turn into headings. A plausible
  /// chapter pattern matches at least twice, never short prose lines in bulk,
  /// and never a large share of the whole book.
  static int countHeadingMatches(List<String> lines, RegExp pattern) {
    var matches = 0;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.length > 120) continue;
      if (pattern.hasMatch(trimmed)) matches++;
    }
    return matches;
  }

  static bool isPlausibleMatchCount(int matches, int totalLines) {
    if (matches < 2 || matches > 100000) return false;
    if (totalLines > 0 && matches > totalLines * 0.3) return false;
    return true;
  }

  /// Candidate lines sent to DeepSeek: short lines plus anything carrying a
  /// chapter-ish hint, taken from the whole book so volume markers and late
  /// format changes are visible. Indices keep the original line order.
  static List<String> collectCandidateLines(List<String> lines) {
    final hint = RegExp('[章节卷回部篇集]|^[0-9０-９]|^[【\\[（(]|^第|^Chapter',
        caseSensitive: false);
    final candidates = <({int index, String text})>[];
    for (var i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trim();
      if (trimmed.isEmpty || trimmed.length > 60) continue;
      if (trimmed.length <= 24 || hint.hasMatch(trimmed)) {
        candidates.add((index: i, text: trimmed));
      }
    }
    if (candidates.length <= 300) {
      return candidates.map((c) => c.text).toList();
    }
    // Keep the opening (where format examples cluster) and an even spread of
    // the rest, so the sample stays within the token budget.
    final head = candidates.take(100).toList();
    final tail = candidates.skip(100).toList();
    final step = tail.length / 200;
    final spread = [
      for (var i = 0; i < 200; i++) tail[(i * step).floor()],
    ];
    return [...head, ...spread].map((c) => c.text).toList();
  }

  // Same prose guard as the built-in parser: an AI pattern that ends up
  // matching ordinary sentences would flood the directory with fake chapters.
  static final _proseEndingPattern = RegExp(r'[。，；,;][”’」』）)]*$');

  /// Full smart re-split flow: rebuild source lines from the stored book,
  /// sample candidates, ask DeepSeek for the heading pattern, validate it
  /// against the whole book, then persist the new chapter split with a
  /// backup of the old one. Returns the new chapter count.
  Future<int> resplitBookWithAi(
    Book book,
    StorageService storage, {
    void Function(String status)? onStatus,
  }) async {
    if (book.isPdf || book.chapters.isEmpty) {
      throw const FormatException('这本书不支持智能分章');
    }

    onStatus?.call('正在整理候选行…');
    final lines = <String>[];
    for (final chapter in book.chapters) {
      final title = chapter.title.trim();
      if (title.isNotEmpty && title != '全文' && title != '开篇') {
        lines.add(title);
      }
      lines.addAll(splitTxtLines(chapter.content));
    }
    if (lines.isEmpty) {
      throw const FormatException('书籍内容为空，无法分章');
    }

    final sample = collectCandidateLines(lines);
    if (sample.length < 2) {
      throw const FormatException('书中没有足够的候选标题行');
    }

    onStatus?.call('正在请求 DeepSeek 分析章节格式…');
    final regexSource = await inferChapterPattern(sample);

    onStatus?.call('正在校验并应用新分章…');
    final result = await Isolate.run(() {
      final pattern = RegExp(regexSource);
      final matches = countHeadingMatches(lines, pattern);
      if (!isPlausibleMatchCount(matches, lines.length)) {
        return (chapters: <Chapter>[], matches: matches);
      }
      final chapters = extractChaptersWithHeadingTest(lines, (line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.length > 120) return null;
        if (_proseEndingPattern.hasMatch(trimmed)) return null;
        return pattern.hasMatch(trimmed) ? trimmed : null;
      });
      return (chapters: chapters, matches: matches);
    });

    if (result.chapters.length < 2) {
      throw FormatException(
        result.matches < 2 ? '识别的章节数量过少，已放弃本次分章' : '按该格式分章后内容为空，已放弃',
      );
    }

    onStatus?.call('正在保存…');
    await storage.resplitBookChapters(book, result.chapters);
    return result.chapters.length;
  }
}
