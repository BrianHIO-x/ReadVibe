import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/theme/app_theme.dart';
import 'package:readvibe/widgets/chapter_editor_sheet.dart';

void main() {
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> mount(WidgetTester tester, ReaderThemeMode mode) async {
    tester.view.physicalSize = const Size(400, 880);
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = const FakeViewPadding(top: 54, bottom: 24);
    tester.view.padding = const FakeViewPadding(top: 54, bottom: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        theme: mode == ReaderThemeMode.dark
            ? AppTheme.darkTheme
            : AppTheme.theme,
        home: ChapterEditorSheet(
          initialTitle: '当前章节',
          initialContent: '正文 content line\n' * 100,
          hasRichContent: false,
          colors: AppTheme.getReaderTheme(mode),
          onSave: (_, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void keyboard(WidgetTester tester, double inset) {
    tester.view.viewInsets = FakeViewPadding(bottom: inset);
    tester.view.padding = FakeViewPadding(top: 54, bottom: inset > 0 ? 0 : 24);
  }

  for (final mode in [ReaderThemeMode.warm, ReaderThemeMode.dark]) {
    testWidgets('body viewport has no vertical gutter in ${mode.name}', (
      tester,
    ) async {
      await mount(tester, mode);
      final field = find.byType(TextField).at(1);
      final editable = tester.state<EditableTextState>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      final text = editable.widget.controller.text;
      final top = tester.getTopLeft(find.byTooltip('关闭编辑器')).dy;
      for (final inset in [0.0, 300.0, 180.0, 0.0]) {
        keyboard(tester, inset);
        await tester.pump(const Duration(milliseconds: 200));
        final fieldRect = tester.getRect(field);
        final render = editable.renderEditable;
        final viewport = render.localToGlobal(Offset.zero) & render.size;
        expect(viewport.top, closeTo(fieldRect.top, 0.1));
        expect(viewport.bottom, closeTo(fieldRect.bottom, 0.1));
        expect(viewport.left, greaterThan(fieldRect.left + 10));
        expect(viewport.right, lessThan(fieldRect.right - 10));
        expect(tester.getTopLeft(find.byTooltip('关闭编辑器')).dy, top);
        expect(editable.widget.controller.text, text);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('navigation backdrop and restored chrome match ${mode.name}', (
      tester,
    ) async {
      await mount(tester, mode);
      final colors = AppTheme.getReaderTheme(mode);
      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.descendant(
          of: find.byType(ChapterEditorSheet),
          matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
        ),
      );
      expect(region.value.systemNavigationBarColor, colors.background);
      expect(region.value.systemNavigationBarDividerColor, colors.background);
      expect(region.value.systemNavigationBarContrastEnforced, isFalse);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        colors.background,
      );
      expect(tester.getRect(find.byType(Scaffold)).bottom, 880);
      keyboard(tester, 300);
      await tester.pump();
      calls.clear();
      keyboard(tester, 0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(
        calls
            .where(
              (call) => call.method == 'SystemChrome.restoreSystemUIOverlays',
            )
            .length,
        greaterThanOrEqualTo(2),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      calls.clear();
      await tester.pump(const Duration(seconds: 2));
      expect(
        calls.where(
          (call) => call.method == 'SystemChrome.restoreSystemUIOverlays',
        ),
        isEmpty,
      );
    });
  }

  testWidgets(
    'deferred chrome refresh stops when IME reopens or editor closes',
    (tester) async {
      await mount(tester, ReaderThemeMode.warm);
      keyboard(tester, 300);
      await tester.pump();
      keyboard(tester, 0);
      await tester.pump();
      keyboard(tester, 300);
      await tester.pump();
      calls.clear();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(
        calls.where(
          (call) => call.method == 'SystemChrome.restoreSystemUIOverlays',
        ),
        isEmpty,
      );
      keyboard(tester, 0);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      calls.clear();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(
        calls.where(
          (call) => call.method == 'SystemChrome.restoreSystemUIOverlays',
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
