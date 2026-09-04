import 'package:flutter/material.dart';

import '../models/reader_settings.dart';
import '../services/system_text_action_service.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_toast.dart';
import 'font_settings_section.dart';

class GlobalSettingsSheet extends StatelessWidget {
  final ReaderSettings settings;
  final ReaderThemeColors colors;
  final ValueChanged<ReaderSettings> onChange;
  final Future<void> Function() onImportFont;
  final Future<void> Function() onCheckUpdate;
  final String applicationVersion;

  const GlobalSettingsSheet({
    super.key,
    required this.settings,
    required this.colors,
    required this.onChange,
    required this.onImportFont,
    required this.onCheckUpdate,
    required this.applicationVersion,
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
                    const SizedBox(height: AppSpacing.xl),
                    Text(
                      '外部应用',
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      '翻译和搜索可以记住所选应用。清除后，下次操作会重新显示受控应用列表。',
                      style: TextStyle(
                        color: colors.secondary,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await SystemTextActionService.clearDefaults();
                        if (!context.mounted) return;
                        AppToast.success(
                          context,
                          '已清除翻译和搜索的默认应用',
                          colors: colors,
                        );
                      },
                      icon: const Icon(Icons.restart_alt_rounded, size: 18),
                      label: const Text('重新选择默认应用'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colors.accent,
                        side: BorderSide(color: colors.border),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Text(
                      '应用更新',
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        '自动检查更新',
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        '默认关闭；开启后，进入书架时会连接 GitHub Releases。',
                        style: TextStyle(
                          color: colors.secondary,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                      value: settings.automaticUpdateChecks,
                      onChanged: (enabled) => onChange(
                        settings.copyWith(automaticUpdateChecks: enabled),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    OutlinedButton.icon(
                      onPressed: onCheckUpdate,
                      icon: const Icon(
                        Icons.system_update_alt_rounded,
                        size: 18,
                      ),
                      label: const Text('检查更新'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colors.accent,
                        side: BorderSide(color: colors.border),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Text(
                      '关于',
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    OutlinedButton.icon(
                      onPressed: () => showLicensePage(
                        context: context,
                        applicationName: 'ReadVibe',
                        applicationVersion: applicationVersion,
                        applicationLegalese: '本地离线阅读器',
                      ),
                      icon: const Icon(Icons.balance_outlined, size: 18),
                      label: const Text('开源许可'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colors.accent,
                        side: BorderSide(color: colors.border),
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
