import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/controllers/reader_pagination_controller.dart';
import 'package:readvibe/controllers/reader_progress_controller.dart';
import 'package:readvibe/controllers/reader_selection_controller.dart';

void main() {
  test('simulation scroll extent always ends on a full viewport', () {
    expect(
      ReaderPaginationController.fullViewportMaxScrollExtent(601, 300),
      900,
    );
    expect(
      ReaderPaginationController.fullViewportMaxScrollExtent(600.005, 300),
      600,
    );
  });

  test('progress controller keeps writes in submission order', () async {
    final controller = ReaderProgressController();
    final releaseFirst = Completer<void>();
    final events = <String>[];
    final first = controller.enqueue(() async {
      events.add('first-start');
      await releaseFirst.future;
      events.add('first-end');
    }, onError: (_, _) {});
    final second = controller.enqueue(() async {
      events.add('second');
    }, onError: (_, _) {});

    await Future<void>.delayed(Duration.zero);
    expect(events, <String>['first-start']);
    releaseFirst.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(events, <String>['first-start', 'first-end', 'second']);
  });

  test('selection controller updates shared notifiers together', () {
    final controller = ReaderSelectionController();
    controller.active.value = true;
    controller.setBlocked(true);
    expect(controller.active.value, isTrue);
    expect(controller.blocked.value, isTrue);
    controller.dispose();
  });
}
