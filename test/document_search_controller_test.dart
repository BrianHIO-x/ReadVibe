import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/controllers/document_search_controller.dart';
import 'package:readvibe/models/search_match.dart';

PdfTextSearchResult _hit(int page) => PdfTextSearchResult(
  pageIndex: page,
  snippet: '结果',
  matchedText: '结果',
  snippetMatchStart: 0,
  snippetMatchEnd: 2,
);

void main() {
  test(
    'typing a new query discards both displayed and in-flight old results',
    () async {
      final reply = Completer<List<PdfTextSearchResult>>();
      final controller = DocumentSearchController<PdfTextSearchResult>(
        search: (_) => reply.future,
      );
      controller.setQuery('旧词');
      final pending = controller.submit();
      controller.setQuery('新词');
      reply.complete([_hit(1)]);
      await pending;
      expect(controller.results, isEmpty);
      expect(controller.searched, isFalse);
      expect(controller.searching, isFalse);
      controller.dispose();
    },
  );

  test('only the latest submitted query follows active work', () async {
    final first = Completer<List<PdfTextSearchResult>>();
    final last = Completer<List<PdfTextSearchResult>>();
    final queries = <String>[];
    final controller = DocumentSearchController<PdfTextSearchResult>(
      search: (query) {
        queries.add(query);
        return queries.length == 1 ? first.future : last.future;
      },
    );
    controller.setQuery('甲');
    final pending = controller.submit();
    unawaited(controller.submit());
    controller.setQuery('乙');
    unawaited(controller.submit());
    controller.setQuery('丙');
    unawaited(controller.submit());
    expect(queries, ['甲']);
    first.complete([_hit(1)]);
    await Future<void>.delayed(Duration.zero);
    expect(queries, ['甲', '丙']);
    expect(controller.results, isEmpty);
    last.complete([_hit(3)]);
    await pending;
    expect(controller.results.single.pageIndex, 3);
    expect(controller.searched, isTrue);
    controller.setQuery('丁');
    expect(controller.results, isEmpty);
    controller.dispose();
  });

  test('obsolete errors and callbacks after disposal stay invisible', () async {
    final reply = Completer<List<PdfTextSearchResult>>();
    var notifications = 0;
    var errors = 0;
    final controller = DocumentSearchController<PdfTextSearchResult>(
      search: (_) => reply.future,
      onError: (_, _) => errors++,
    )..addListener(() => notifications++);
    controller.setQuery('甲');
    final pending = controller.submit();
    controller.dispose();
    final count = notifications;
    reply.completeError(StateError('obsolete'));
    await pending;
    expect(notifications, count);
    expect(errors, 0);
  });

  test('a failed current search can be retried', () async {
    var attempts = 0;
    final controller = DocumentSearchController<PdfTextSearchResult>(
      search: (_) async {
        if (attempts++ == 0) throw StateError('temporary');
        return [_hit(2)];
      },
    );
    controller.setQuery('正文');
    await controller.submit();
    expect(controller.failed, isTrue);
    await controller.submit();
    expect(controller.failed, isFalse);
    expect(controller.results.single.pageIndex, 2);
    controller.dispose();
  });
}
