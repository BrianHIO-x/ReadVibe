import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/services/ai_chapter_service.dart';

void main() {
  group('AI chapter regex sanitizing', () {
    test('accepts a plain anchored pattern', () {
      expect(
        AiChapterService.sanitizeChapterRegex(r'^第[0-9]+章.*$'),
        r'^第[0-9]+章.*$',
      );
    });

    test('rejects lookaround constructs', () {
      expect(
        () => AiChapterService.sanitizeChapterRegex(r'^第(?=1)'),
        throwsFormatException,
      );
    });

    test('rejects backreferences', () {
      expect(
        () => AiChapterService.sanitizeChapterRegex(r'(章)\1'),
        throwsFormatException,
      );
    });

    test('rejects uncompilable expressions', () {
      expect(
        () => AiChapterService.sanitizeChapterRegex('[未闭合'),
        throwsFormatException,
      );
    });

    test('rejects overlong expressions', () {
      expect(
        () => AiChapterService.sanitizeChapterRegex('a' * 301),
        throwsFormatException,
      );
    });
  });

  group('AI chapter match plausibility', () {
    test('ordinary novel counts pass', () {
      expect(AiChapterService.isPlausibleMatchCount(500, 80000), isTrue);
      expect(AiChapterService.isPlausibleMatchCount(2, 100), isTrue);
    });

    test('too few or too many matches fail', () {
      expect(AiChapterService.isPlausibleMatchCount(1, 80000), isFalse);
      expect(AiChapterService.isPlausibleMatchCount(0, 80000), isFalse);
    });

    test('matching a third of all lines is prose, not headings', () {
      expect(AiChapterService.isPlausibleMatchCount(30000, 80000), isFalse);
    });
  });

  group('AI chapter candidate sampling', () {
    test('short and hinted lines are collected, prose is skipped', () {
      final lines = [
        '第1章 起始',
        '这是一句普通正文，长度明显超过候选行的限制，不应该被收进样本里面去。',
        '【第二卷】',
        '',
      ];
      final sample = AiChapterService.collectCandidateLines(lines);
      expect(sample, contains('第1章 起始'));
      expect(sample, contains('【第二卷】'));
      expect(sample.length, 2);
    });

    test('large books are capped at three hundred candidates', () {
      final lines = [for (var i = 0; i < 5000; i++) '第$i 章'];
      final sample = AiChapterService.collectCandidateLines(lines);
      expect(sample.length, 300);
      expect(sample.first, '第0 章');
    });
  });

  group('AI chapter heading match counting', () {
    test('counts anchored matches on trimmed short lines only', () {
      final pattern = RegExp(r'^第[0-9]+章');
      final lines = [
        '第1章 标题',
        '  第2章 缩进标题  ',
        '正文里提到第3章不算',
        '　',
      ];
      expect(AiChapterService.countHeadingMatches(lines, pattern), 2);
    });
  });
}
