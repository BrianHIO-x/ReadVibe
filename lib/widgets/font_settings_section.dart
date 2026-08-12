import 'package:flutter/material.dart';

import '../models/reader_settings.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';

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

  @override
  Widget build(BuildContext context) {
    final importedFontName = settings.importedFontName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel('字体'),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Expanded(
              child: _FontChoice(
                label: '系统',
                selected: settings.usesSystemFont,
                colors: colors,
                onTap: () => onChange(
                  settings.copyWith(
                    fontFamily: ReaderSettings.systemFontFamily,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _FontChoice(
                label: '宋体',
                selected: settings.usesBuiltinSerif,
                colors: colors,
                onTap: () => onChange(
                  settings.copyWith(
                    fontFamily: ReaderSettings.builtinSerifFamily,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _FontChoice(
                label: '导入',
                subtitle: importedFontName,
                selected:
                    !settings.usesSystemFont && !settings.usesBuiltinSerif,
                enabled: settings.hasImportedFont,
                colors: colors,
                onTap: settings.hasImportedFont
                    ? () => onChange(
                        settings.copyWith(
                          fontFamily: settings.importedFontFamily,
                        ),
                      )
                    : null,
              ),
            ),
          ],
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
            style: OutlinedButton.styleFrom(
              foregroundColor: colors.secondary,
              overlayColor: Colors.transparent,
              side: BorderSide(color: colors.border),
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

class _FontChoice extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool selected;
  final bool enabled;
  final ReaderThemeColors colors;
  final VoidCallback? onTap;

  const _FontChoice({
    required this.label,
    this.subtitle,
    required this.selected,
    this.enabled = true,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = selected
        ? Colors.white
        : enabled
        ? colors.text
        : colors.secondary.withValues(alpha: 0.55);

    return AnimatedScale(
      scale: selected ? 1.02 : 1.0,
      duration: AppMotion.control,
      curve: AppMotion.controlCurve,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          overlayColor: WidgetStateProperty.all(Colors.transparent),
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: AppMotion.control,
            curve: AppMotion.controlCurve,
            constraints: const BoxConstraints(minHeight: 42),
            padding: const EdgeInsets.symmetric(
              vertical: AppSpacing.sm,
              horizontal: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: selected ? colors.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(
                color: selected ? colors.accent : colors.border,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: foreground,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: foreground.withValues(alpha: 0.78),
                      fontSize: 10,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
