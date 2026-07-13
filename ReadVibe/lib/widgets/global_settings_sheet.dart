import 'package:flutter/material.dart';

import '../models/reader_settings.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'font_settings_section.dart';

class GlobalSettingsSheet extends StatelessWidget {
  final ReaderSettings settings;
  final ReaderThemeColors colors;
  final ValueChanged<ReaderSettings> onChange;
  final Future<void> Function() onImportFont;

  const GlobalSettingsSheet({
    super.key,
    required this.settings,
    required this.colors,
    required this.onChange,
    required this.onImportFont,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.headerBg,
        borderRadius: const BorderRadius.horizontal(
          right: Radius.circular(AppRadius.pill),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        AppSpacing.xl,
        MediaQuery.viewPaddingOf(context).top + AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.xl,
      ),
      child: SafeArea(
        top: false,
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '设置',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: colors.text,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(Icons.close, color: colors.secondary),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xl),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FontSettingsSection(
                      settings: settings,
                      colors: colors,
                      onChange: onChange,
                      onImportFont: onImportFont,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      '可选择系统字体、内置宋体或自定义导入字体。这里的字体设置会作为全局阅读字体使用。',
                      style: TextStyle(
                        color: colors.secondary,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
