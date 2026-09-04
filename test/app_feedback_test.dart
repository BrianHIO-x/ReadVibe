import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/services/update_service.dart';
import 'package:readvibe/theme/app_overlay_theme.dart';
import 'package:readvibe/theme/app_theme.dart';
import 'package:readvibe/widgets/app_dialog.dart';
import 'package:readvibe/widgets/app_sheet.dart';
import 'package:readvibe/widgets/app_toast.dart';
import 'package:readvibe/widgets/app_update_dialog.dart';

const _captureKey = ValueKey('feedback-preview');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('FEEDBACK_PREVIEWS')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/feedback-previews')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void _phone(WidgetTester tester, {Size size = const Size(390, 844)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
  tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewPadding);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewInsets);
}

Future<BuildContext> _host(WidgetTester tester, {double scale = 1}) async {
  late BuildContext host;
  await tester.pumpWidget(
    MaterialApp(
      theme: const bool.fromEnvironment('FEEDBACK_PREVIEWS')
          ? AppTheme.theme.copyWith(
              textTheme: AppTheme.theme.textTheme.apply(
                fontFamily: 'FeedbackPreview',
              ),
            )
          : AppTheme.theme,
      builder: (context, child) => RepaintBoundary(
        key: _captureKey,
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
      home: Builder(
        builder: (context) {
          host = context;
          return const Scaffold(body: Center(child: Text('ReadVibe')));
        },
      ),
    ),
  );
  return host;
}

double _contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance(), b = background.computeLuminance();
  return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
}

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('FEEDBACK_PREVIEWS')) return;
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader('FeedbackPreview')..addFont(
          rootBundle.load('assets/fonts/SourceHanSerifSC-Regular.ttf'),
        ))
        .load();
  });
  for (final mode in [
    ReaderThemeMode.light,
    ReaderThemeMode.warm,
    ReaderThemeMode.dark,
  ]) {
    testWidgets('dialog respects $mode rather than the host brightness', (
      tester,
    ) async {
      _phone(tester);
      final context = await _host(tester);
      final colors = AppTheme.getReaderTheme(mode);
      final controller = TextEditingController(text: '本地阅读笔记');
      var finished = false;
      final result =
          showAppDialog<bool>(
            context: context,
            colors: colors,
            builder: (dialogContext) => AppDialog(
              title: const Text('保存阅读笔记'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('笔记仅保存在本机。你可以随时修改或导出书籍。'),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(labelText: '笔记'),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('保存'),
                ),
              ],
            ),
          ).then((value) {
            finished = true;
            controller.dispose();
            return value;
          });
      await tester.pumpAndSettle();
      final themed = Theme.of(tester.element(find.byType(AppDialog)));
      expect(themed.dialogTheme.backgroundColor, colors.headerBg);
      expect(themed.dialogTheme.surfaceTintColor, Colors.transparent);
      final shape = themed.dialogTheme.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(24));
      expect(shape.side.color, colors.border);
      expect(themed.dialogTheme.titleTextStyle!.fontSize, 18);
      expect(themed.dialogTheme.contentTextStyle!.color, colors.text);
      final input = themed.inputDecorationTheme;
      expect(
        input.enabledBorder!.borderSide.width,
        input.focusedBorder!.borderSide.width,
      );
      expect(input.hintStyle!.color, colors.secondary);
      final button = themed.filledButtonTheme.style!;
      expect(
        _contrast(
          button.foregroundColor!.resolve({})!,
          button.backgroundColor!.resolve({})!,
        ),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        tester.getSize(find.byType(FilledButton)).height,
        greaterThanOrEqualTo(48),
      );
      await _capture(tester, 'dialog-${mode.name}');
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(finished, isFalse);
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'destructive prompts and toasts share the $mode paper surface',
      (tester) async {
        _phone(tester);
        final context = await _host(tester);
        final colors = AppTheme.getReaderTheme(mode);
        final result = showAppDialog<bool>(
          context: context,
          colors: colors,
          builder: (ctx) => AppDialog(
            title: const Text('删除书籍'),
            content: const Text('确定要删除「阅读中的故事」吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              AppDestructiveButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        final button = tester.widget<FilledButton>(find.byType(FilledButton));
        expect(
          button.style!.backgroundColor!.resolve({}),
          AppOverlayTheme.danger(colors),
        );
        expect(
          _contrast(
            button.style!.foregroundColor!.resolve({})!,
            button.style!.backgroundColor!.resolve({})!,
          ),
          greaterThanOrEqualTo(4.5),
        );
        await _capture(tester, 'delete-${mode.name}');
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(await result, isNull);
        for (final tone in AppToastTone.values) {
          AppToast.show(
            context,
            '操作提示：${tone.name}',
            tone: tone,
            colors: colors,
          );
          await tester.pumpAndSettle();
          final material = tester.widget<Material>(
            find.byKey(const ValueKey('app-toast-surface')),
          );
          expect(material.color, colors.headerBg);
          expect(
            (material.shape! as RoundedRectangleBorder).borderRadius,
            BorderRadius.circular(16),
          );
          expect(tester.takeException(), isNull);
        }
        await _capture(tester, 'toast-${mode.name}');
        AppToast.hide(context);
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'narrow keyboard dialog scrolls content without hiding actions or crossing cutouts',
    (tester) async {
      _phone(tester, size: const Size(320, 720));
      final context = await _host(tester, scale: 1.6);
      final result = showAppDialog<void>(
        context: context,
        colors: AppTheme.getReaderTheme(ReaderThemeMode.warm),
        builder: (ctx) => AppDialog(
          title: const Text('修改书籍信息'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('这是一段较长的说明文字，用来确认大字体和键盘同时出现时仍能正常操作。'),
              const SizedBox(height: 16),
              const TextField(
                autofocus: true,
                decoration: InputDecoration(labelText: '书名'),
              ),
              const SizedBox(height: 16),
              const TextField(decoration: InputDecoration(labelText: '作者')),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('保存修改'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      tester.view.padding = const FakeViewPadding(top: 44);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('保存修改').hitTestable(), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(AlertDialog)).dy,
        greaterThanOrEqualTo(44),
      );
      expect(tester.getBottomRight(find.text('保存修改')).dy, lessThan(440));
      await _capture(tester, 'keyboard-large-text');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await result;
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'action sheet is scrollable in short landscape space and closes before completing',
    (tester) async {
      _phone(tester, size: const Size(560, 360));
      final context = await _host(tester, scale: 1.4);
      final colors = AppTheme.getReaderTheme(ReaderThemeMode.dark);
      final result = showAppSheet<int>(
        context: context,
        colors: colors,
        builder: (ctx) => AppActionSheet(
          colors: colors,
          title: '选择操作',
          subtitle: '面板内容较多时可上下滚动。',
          children: [
            for (var i = 0; i < 12; i++)
              ListTile(
                title: Text('操作 $i'),
                onTap: () => Navigator.pop(ctx, i),
              ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('操作 11'));
      await tester.pumpAndSettle();
      expect(find.text('操作 11').hitTestable(), findsOneWidget);
      await _capture(tester, 'sheet-landscape');
      await tester.tap(find.text('操作 11'));
      await tester.pumpAndSettle();
      expect(await result, 11);
      expect(find.byType(AppActionSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a burst of brief messages retains only the newest pending message',
    (tester) async {
      final context = await _host(tester);
      AppToast.info(context, '旧提示一');
      await tester.pumpAndSettle();
      AppToast.info(context, '旧提示二');
      AppToast.success(context, '最新提示');
      await tester.pumpAndSettle();
      expect(find.text('最新提示'), findsOneWidget);
      expect(find.text('旧提示一'), findsNothing);
      expect(find.text('旧提示二'), findsNothing);
      AppToast.hide(context);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(SnackBar), findsNothing);
    },
  );
  testWidgets(
    'update notes and long download action remain usable on a narrow display',
    (tester) async {
      _phone(tester, size: const Size(320, 720));
      final context = await _host(tester, scale: 1.4);
      final colors = AppTheme.getReaderTheme(ReaderThemeMode.warm);
      final info = AppUpdateInfo(
        version: '0.6.14',
        notes: '更新说明：改善阅读体验。\n' * 60,
        apkUrl: 'https://example.invalid/app.apk',
        apkName: 'app.apk',
        apkSize: 1,
        sha256: 'a' * 64,
        releasePageUrl: 'https://example.invalid/release',
      );
      final result = showAppDialog<void>(
        context: context,
        colors: colors,
        builder: (_) => AppUpdateDialog(info: info, colors: colors),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('前往 GitHub 下载').hitTestable(), findsOneWidget);
      await _capture(tester, 'update-narrow');
      await tester.tap(find.text('以后再说'));
      await tester.pumpAndSettle();
      await result;
      expect(tester.takeException(), isNull);
    },
  );
}
