import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/screens/reader/reader_pagination_support.dart';
import 'package:readvibe/screens/reader/reader_selection_edge_scroller.dart';
import 'package:readvibe/screens/reader/reader_selection_support.dart';
import 'package:readvibe/theme/app_theme.dart';
import 'package:readvibe/screens/reader/reader_selectable_block.dart';

Future<void> _frames(WidgetTester tester, [int count = 60]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

class _ReaderHarness {
  _ReaderHarness({
    this.simulation = false,
    this.continuous = false,
    this.centered = false,
  }) {
    controller = SelectionAwareScrollController(
      selectionActive: active,
      selectionDragging: dragging,
      freezeSelectionViewport: () => simulation,
      paginateToFullViewports: simulation,
    );
  }

  final bool simulation;
  final bool continuous;
  final bool centered;
  final active = ValueNotifier(false);
  final dragging = ValueNotifier(false);
  final blocked = ValueNotifier(false);
  final enabled = ValueNotifier(true);
  late final ScrollController controller;

  Widget paragraph(int index) => ReaderSelectableBlock(
    child: SizedBox(
      height: 60,
      child: Text(
        'Line $index: words for selecting more text.',
        key: ValueKey('line-$index'),
        style: const TextStyle(fontSize: 18, height: 1.5),
      ),
    ),
  );

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (context, enabled, _) => ReaderSelectionArea(
              colors: AppTheme.getReaderTheme(ReaderThemeMode.light),
              selectionBlocked: blocked,
              selectionActive: active,
              selectionDragging: dragging,
              onReaderModalOpened: () {},
              onReaderModalClosed: () {},
              edgeScrollController: simulation ? null : controller,
              edgeScrollEnabled: enabled,
              child: continuous
                  ? CustomScrollView(
                      center: centered ? const ValueKey('chapter-2') : null,
                      controller: controller,
                      slivers: [
                        for (var chapter = 0; chapter < 4; chapter++)
                          SliverList.builder(
                            key: ValueKey('chapter-$chapter'),
                            itemCount: 10,
                            itemBuilder: (_, index) =>
                                paragraph(chapter * 10 + index),
                          ),
                      ],
                    )
                  : ListView.builder(
                      controller: controller,
                      physics: simulation
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      itemCount: 40,
                      itemBuilder: (_, index) => paragraph(index),
                    ),
            ),
          ),
        ),
      ),
    );
    await _frames(tester, 3);
  }

  SelectionContainer container(WidgetTester tester) =>
      tester.widget<SelectionContainer>(
        find
            .descendant(
              of: find.byType(ReaderSelectionEdgeScroller),
              matching: find.byType(SelectionContainer),
            )
            .first,
      );

  String selected(WidgetTester tester) =>
      container(tester).delegate!.getSelectedContent()?.plainText ?? '';

  Offset handle(WidgetTester tester, {required bool start}) {
    final finder = find
        .descendant(
          of: find.byType(ReaderSelectionEdgeScroller),
          matching: find.byType(SelectionContainer),
        )
        .first;
    final geometry = tester.widget<SelectionContainer>(finder).delegate!.value;
    final point = start
        ? geometry.startSelectionPoint!
        : geometry.endSelectionPoint!;
    final box = tester.renderObject<RenderBox>(finder);
    return box.localToGlobal(point.localPosition) + const Offset(0, 5);
  }

  Future<TestGesture> longPress(WidgetTester tester) async {
    final gesture = await tester.startGesture(const Offset(110, 192));
    await tester.pump(const Duration(milliseconds: 700));
    expect(active.value, isTrue);
    return gesture;
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
    active.dispose();
    dragging.dispose();
    blocked.dispose();
    enabled.dispose();
  }
}

void main() {
  testWidgets('retained selection can resume handle dragging after scrolling', (
    tester,
  ) async {
    final reader = _ReaderHarness();
    await reader.mount(tester);
    reader.controller.jumpTo(600);
    await _frames(tester, 3);
    final press = await reader.longPress(tester);
    await press.up();
    await _frames(tester, 10);
    final original = reader.selected(tester);
    final swipe = await tester.startGesture(const Offset(310, 400));
    await swipe.moveBy(const Offset(0, -50));
    await tester.pump(const Duration(milliseconds: 150));
    await swipe.moveBy(const Offset(0, -30));
    await tester.pump(const Duration(milliseconds: 150));
    await swipe.up();
    await tester.pumpAndSettle();
    expect(reader.selected(tester), original);
    final handle = await tester.startGesture(
      reader.handle(tester, start: false),
    );
    await handle.moveBy(const Offset(0, 65));
    await tester.pump();
    expect(reader.dragging.value, isTrue);
    final position =
        reader.controller.position as ScrollPositionWithSingleContext;
    final offset = position.pixels;
    position.applyUserOffset(-100);
    position.goBallistic(1000);
    await _frames(tester, 5);
    expect(position.pixels, offset);
    expect(reader.selected(tester), startsWith(original));
    expect(reader.selected(tester).length, greaterThan(original.length));
    await handle.up();
    await tester.pumpAndSettle();
    expect(reader.dragging.value, isFalse);
    expect(reader.active.value, isTrue);
    reader.enabled.value = false;
    await tester.pump();
    await reader.unmount(tester);
    expect(tester.takeException(), isNull);
  });
  for (final continuous in [false, true]) {
    testWidgets(
      'ordinary body swipe after selection tracks finger in $continuous',
      (tester) async {
        final reader = _ReaderHarness(continuous: continuous);
        await reader.mount(tester);
        reader.controller.jumpTo(600);
        await _frames(tester, 3);
        final selection = await reader.longPress(tester);
        await selection.up();
        await _frames(tester, 10);
        expect(reader.active.value, isTrue);
        final selected = reader.selected(tester);
        final offset = reader.controller.offset;
        final swipe = await tester.startGesture(const Offset(310, 420));
        await swipe.moveBy(const Offset(0, -50));
        await tester.pump(const Duration(milliseconds: 16));
        await swipe.moveBy(const Offset(0, -50));
        await tester.pump(const Duration(milliseconds: 16));
        expect(reader.controller.offset, greaterThan(offset + 40));
        expect(reader.active.value, isTrue);
        expect(reader.dragging.value, isFalse);
        expect(reader.selected(tester), selected);
        expect(find.text('复制'), findsNothing);
        await swipe.up();
        await tester.pumpAndSettle();
        expect(reader.selected(tester), selected);
        expect(find.text('复制').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await reader.unmount(tester);
      },
    );
  }

  testWidgets('entering selection cancels an existing ballistic scroll', (
    tester,
  ) async {
    final reader = _ReaderHarness();
    await reader.mount(tester);
    reader.controller.jumpTo(600);
    await _frames(tester, 3);
    await tester.flingFrom(const Offset(300, 420), const Offset(0, -150), 1200);
    await tester.pump(const Duration(milliseconds: 16));
    reader.active.value = true;
    final stopped = reader.controller.offset;
    await _frames(tester, 10);
    expect(reader.controller.offset, closeTo(stopped, 0.1));
    reader.active.value = false;
    await reader.unmount(tester);
  });
  testWidgets('long press edge scroll extends selection and stops on release', (
    tester,
  ) async {
    final reader = _ReaderHarness();
    await reader.mount(tester);
    final gesture = await reader.longPress(tester);
    await gesture.moveTo(const Offset(160, 575));
    await _frames(tester, 2);
    final initialSelection = reader.selected(tester);
    await _frames(tester);
    expect(reader.controller.offset, greaterThan(120));
    expect(
      reader.selected(tester).length,
      greaterThan(initialSelection.length),
    );
    expect(reader.selected(tester), startsWith(initialSelection));
    await gesture.up();
    await tester.pump();
    final stopped = reader.controller.offset;
    await _frames(tester, 20);
    expect(reader.controller.offset, stopped);
    expect(find.text('复制'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await reader.unmount(tester);
  });

  testWidgets('returning to center and pointer cancellation stop scrolling', (
    tester,
  ) async {
    final reader = _ReaderHarness();
    await reader.mount(tester);
    final gesture = await reader.longPress(tester);
    await gesture.moveTo(const Offset(160, 575));
    await _frames(tester, 20);
    expect(reader.controller.offset, greaterThan(0));
    await gesture.moveTo(const Offset(160, 300));
    await tester.pump();
    final stopped = reader.controller.offset;
    await _frames(tester, 20);
    expect(reader.controller.offset, stopped);
    await gesture.moveTo(const Offset(160, 575));
    await _frames(tester, 10);
    await gesture.cancel();
    await tester.pump();
    final cancelled = reader.controller.offset;
    await _frames(tester, 20);
    expect(reader.controller.offset, cancelled);
    await reader.unmount(tester);
  });

  testWidgets(
    'both selection handles can scroll and retain the opposite edge',
    (tester) async {
      final reader = _ReaderHarness();
      await reader.mount(tester);
      reader.controller.jumpTo(600);
      await _frames(tester, 3);
      final longPress = await reader.longPress(tester);
      await longPress.up();
      await _frames(tester, 15);
      final original = reader.selected(tester);
      final startDrag = await tester.startGesture(
        reader.handle(tester, start: true),
      );
      await startDrag.moveBy(const Offset(0, -30));
      await startDrag.moveTo(const Offset(100, 25));
      await _frames(tester, 40);
      expect(reader.controller.offset, lessThan(500));
      expect(reader.selected(tester), endsWith(original));
      await startDrag.up();
      await _frames(tester, 15);
      final startOffset = reader.controller.offset;
      final beforeEnd = reader.selected(tester);
      final endDrag = await tester.startGesture(
        reader.handle(tester, start: false),
      );
      await endDrag.moveBy(const Offset(0, 30));
      await endDrag.moveTo(const Offset(160, 580));
      await _frames(tester, 80);
      expect(reader.controller.offset, greaterThan(startOffset + 100));
      expect(reader.selected(tester), startsWith(beforeEnd));
      await endDrag.up();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await reader.unmount(tester);
    },
  );

  testWidgets('continuous selection crosses chapter slivers', (tester) async {
    final reader = _ReaderHarness(continuous: true);
    await reader.mount(tester);
    final gesture = await reader.longPress(tester);
    await gesture.moveTo(const Offset(160, 585));
    await _frames(tester, 100);
    expect(reader.controller.offset, greaterThan(400));
    expect(reader.selected(tester), contains('Line 10:'));
    await gesture.up();
    await reader.unmount(tester);
  });

  testWidgets('chapter boundaries stop without overscroll', (tester) async {
    final reader = _ReaderHarness();
    await reader.mount(tester);
    reader.controller.jumpTo(reader.controller.position.maxScrollExtent - 30);
    await _frames(tester, 3);
    final gesture = await reader.longPress(tester);
    await gesture.moveTo(const Offset(160, 585));
    await _frames(tester, 40);
    expect(
      reader.controller.offset,
      reader.controller.position.maxScrollExtent,
    );
    final stopped = reader.controller.offset;
    await _frames(tester, 20);
    expect(reader.controller.offset, stopped);
    await gesture.up();
    await reader.unmount(tester);
  });

  testWidgets('blocked or modal selection stops the edge scroller', (
    tester,
  ) async {
    final reader = _ReaderHarness();
    await reader.mount(tester);
    final gesture = await reader.longPress(tester);
    await gesture.moveTo(const Offset(160, 585));
    await _frames(tester, 20);
    reader.enabled.value = false;
    await tester.pump();
    final stopped = reader.controller.offset;
    await _frames(tester, 20);
    expect(reader.controller.offset, stopped);
    reader.blocked.value = true;
    await gesture.up();
    await tester.pump();
    expect(reader.active.value, isFalse);
    await reader.unmount(tester);
  });

  testWidgets(
    'continuous backward selection supports negative scroll offsets',
    (tester) async {
      final reader = _ReaderHarness(continuous: true, centered: true);
      await reader.mount(tester);
      expect(reader.controller.position.minScrollExtent, lessThan(0));
      final gesture = await reader.longPress(tester);
      await gesture.moveTo(const Offset(160, 15));
      await _frames(tester, 80);
      expect(reader.controller.offset, lessThan(-200));
      expect(reader.selected(tester), matches(RegExp(r'Line 1[0-9]:')));
      await gesture.up();
      await reader.unmount(tester);
    },
  );

  testWidgets(
    'a normal finger scroll does not start selection auto scrolling',
    (tester) async {
      final reader = _ReaderHarness();
      await reader.mount(tester);
      final gesture = await tester.startGesture(const Offset(160, 300));
      await gesture.moveTo(const Offset(160, 40));
      await tester.pump();
      expect(reader.active.value, isFalse);
      final offset = reader.controller.offset;
      await _frames(tester, 30);
      expect(reader.controller.offset, offset);
      await gesture.up();
      await reader.unmount(tester);
    },
  );

  testWidgets('leaving the reader during an edge drag stops pending work', (
    tester,
  ) async {
    final reader = _ReaderHarness();
    await reader.mount(tester);
    final gesture = await reader.longPress(tester);
    await gesture.moveTo(const Offset(160, 585));
    await _frames(tester, 10);
    await reader.unmount(tester);
    await gesture.up();
    await _frames(tester, 10);
    expect(tester.takeException(), isNull);
  });

  testWidgets('simulation selection keeps its page fixed', (tester) async {
    final reader = _ReaderHarness(simulation: true);
    await reader.mount(tester);
    expect(find.byType(ReaderSelectionEdgeScroller), findsNothing);
    final gesture = await reader.longPress(tester);
    await gesture.moveTo(const Offset(160, 585));
    await _frames(tester, 40);
    expect(reader.controller.offset, 0);
    await gesture.up();
    await reader.unmount(tester);
  });
}
