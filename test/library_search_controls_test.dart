import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/library_filter.dart';
import 'package:readvibe/models/reader_settings.dart';
import 'package:readvibe/theme/app_theme.dart';
import 'package:readvibe/widgets/library_search_controls.dart';

void main() {
  for (final mode in [ReaderThemeMode.warm, ReaderThemeMode.dark]) {
    testWidgets('all filters keep the input width and theme in ${mode.name}', (
      tester,
    ) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      final colors = AppTheme.getReaderTheme(mode);
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      double? width;
      for (final filter in ShelfFilter.values) {
        var cleared = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: LibrarySearchControls(
                  controller: controller,
                  focusNode: focus,
                  filter: filter,
                  colors: colors,
                  onChanged: () {},
                  onClearFilter: () => cleared = true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(find.byType(TextField));
        width ??= tester.getSize(find.byType(TextField)).width;
        expect(tester.getSize(find.byType(TextField)).width, width);
        expect(
          find.descendant(
            of: find.byType(TextField),
            matching: find.byType(InputChip),
          ),
          findsNothing,
        );
        expect(field.decoration!.fillColor, colors.headerBg);
        expect(
          field.decoration!.enabledBorder!.borderSide.width,
          field.decoration!.focusedBorder!.borderSide.width,
        );
        if (filter != ShelfFilter.all) {
          final chip = tester.widget<InputChip>(find.byType(InputChip));
          expect(chip.labelStyle!.color, colors.accent);
          expect(chip.shape, isA<StadiumBorder>());
          chip.onDeleted!();
          expect(cleared, isTrue);
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('filter menu has themed rounded surface in ${mode.name}', (
      tester,
    ) async {
      final colors = AppTheme.getReaderTheme(mode);
      ShelfFilter? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeArea(
              child: LibraryFilterButton(
                filter: ShelfFilter.kindle,
                colors: colors,
                onSelected: (value) => selected = value,
              ),
            ),
          ),
        ),
      );
      final button = tester.widget<PopupMenuButton<ShelfFilter>>(
        find.byType(PopupMenuButton<ShelfFilter>),
      );
      expect(button.color, colors.headerBg);
      expect(button.surfaceTintColor, Colors.transparent);
      expect(
        (button.shape as RoundedRectangleBorder).side.color,
        colors.border,
      );
      await tester.tap(find.byTooltip('筛选书架'));
      await tester.pumpAndSettle();
      expect(
        find.byType(PopupMenuItem<ShelfFilter>),
        findsNWidgets(ShelfFilter.values.length),
      );
      await tester.tap(find.text('TXT'));
      await tester.pumpAndSettle();
      expect(selected, ShelfFilter.txt);
      expect(tester.takeException(), isNull);
    });
  }
}
