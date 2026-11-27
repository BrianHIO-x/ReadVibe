import 'package:flutter/material.dart';

import '../models/reader_settings.dart';
import '../theme/app_button_styles.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_segmented_control.dart';

enum _FontChoiceSlot { system, serif, kaiti, imported }

class FontSettingsSection extends StatelessWidget {
  final ReaderSettings settings;
  final ReaderThemeColors colors;
  final ValueChanged<ReaderSettings> onChange;
  final Future<void> Function() onImportFont;

  const FontSettingsSection({
    super.key,
    required this.settings,
    required this.colors,
    required this.onChange,
    required this.onImportFont,
  });

  _FontChoiceSlot get _activeSlot {
    if (settings.usesSystemFont) return _FontChoiceSlot.system;
    if (settings.usesBuiltinSerif) return _FontChoiceSlot.serif;
    if (settings.usesBuiltinKaiti) return _FontChoiceSlot.kaiti;
    return _FontChoiceSlot.imported;
  }

  @override
  Widget build(BuildContext context) {
    final importedFontName = settings.importedFontName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel('字体'),
        const SizedBox(height: AppSpacing.xs),
        AppSegmentedControl<_FontChoiceSlot>(
          options: [
            const AppSegmentOption(
              value: _FontChoiceSlot.system,
              label: '系统',
            ),
            const AppSegmentOption(
              value: _FontChoiceSlot.serif,
              label: '宋体',
            ),
            const AppSegmentOption(
              value: _FontChoiceSlot.kaiti,
              label: '楷体',
            ),
            AppSegmentOption(
              value: _FontChoiceSlot.imported,
              label: '导入',
              subtitle: importedFontName,
              enabled: settings.hasImportedFont,
            ),
          ],
          value: _activeSlot,
          colors: colors,
          variant: AppSegmentedVariant.accent,
          height: importedFontName != null ? 48 : 42,
          fontSize: 13,
          onChanged: (slot) {
            final nextFamily = switch (slot) {
              _FontChoiceSlot.system => ReaderSettings.systemFontFamily,
              _FontChoiceSlot.serif => ReaderSettings.builtinSerifFamily,
              _FontChoiceSlot.kaiti => ReaderSettings.builtinKaitiFamily,
              _FontChoiceSlot.imported => settings.importedFontFamily,
            };
            onChange(settings.copyWith(fontFamily: nextFamily));
          },
        ),
        const SizedBox(height: AppSpacing.xs),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: onImportFont,
            icon: const Icon(Icons.upload_file, size: 18),
            label: Text(
              importedFontName == null ? '导入 .ttf / .otf 字体' : '重新导入字体',
            ),
            style: AppButtonStyles.outlinedOverride(
              colors,
              foregroundColor: colors.secondary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              padding: const EdgeInsets.symmetric(
                vertical: AppSpacing.sm,
                horizontal: AppSpacing.md,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: colors.secondary,
        letterSpacing: 0.5,
      ),
    );
  }
}
