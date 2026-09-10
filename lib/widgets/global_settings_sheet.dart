import 'dart:async';

import 'package:flutter/material.dart';

import '../models/reader_settings.dart';
import '../repositories/reader_repositories.dart';
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
  final Future<StorageUsageReport> Function() onMeasureStorage;
  final Future<int> Function() onClearCaches;
  final String applicationVersion;

  const GlobalSettingsSheet({
    super.key,
    required this.settings,
    required this.colors,
    required this.onChange,
    required this.onImportFont,
    required this.onCheckUpdate,
    required this.onMeasureStorage,
    required this.onClearCaches,
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
      // The trailing gap lives on the scroll view instead of the panel, so the
      // list keeps running underneath the gesture bar.
      padding: EdgeInsets.fromLTRB(
        AppSpacing.xl,
        MediaQuery.viewPaddingOf(context).top + AppSpacing.xl,
        AppSpacing.xl,
        0,
      ),
      child: SafeArea(
        top: false,
        right: false,
        bottom: false,
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
                padding: EdgeInsets.only(
                  bottom: AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
                ),
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
                        '默认关闭；开启后检查新版，连接失败时自动尝试备用线路。下载需手动确认。',
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
                    StorageUsageSection(
                      colors: colors,
                      onMeasure: onMeasureStorage,
                      onClearCaches: onClearCaches,
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


/// Shows what ReadVibe occupies and offers the one reclaim that is always safe.
///
/// Measuring walks the private directories, so the section loads its own data
/// and reports progress instead of blocking the panel that contains it.
class StorageUsageSection extends StatefulWidget {
  const StorageUsageSection({
    super.key,
    required this.colors,
    required this.onMeasure,
    required this.onClearCaches,
  });

  final ReaderThemeColors colors;
  final Future<StorageUsageReport> Function() onMeasure;
  final Future<int> Function() onClearCaches;

  @override
  State<StorageUsageSection> createState() => _StorageUsageSectionState();
}

class _StorageUsageSectionState extends State<StorageUsageSection> {
  StorageUsageReport? _report;
  bool _measuring = true;
  bool _clearing = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
  }

  Future<void> _measure() async {
    if (mounted) setState(() => _measuring = true);
    try {
      final report = await widget.onMeasure();
      if (!mounted) return;
      setState(() {
        _report = report;
        _failed = false;
      });
    } on Object catch (error, stack) {
      debugPrint('Failed to measure storage usage: $error');
      debugPrintStack(stackTrace: stack);
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _measuring = false);
    }
  }

  Future<void> _clear() async {
    if (_clearing) return;
    setState(() => _clearing = true);
    var freed = 0;
    var failed = false;
    try {
      freed = await widget.onClearCaches();
    } on Object catch (error, stack) {
      failed = true;
      debugPrint('Failed to clear caches: $error');
      debugPrintStack(stackTrace: stack);
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
    if (!mounted) return;
    if (failed) {
      AppToast.error(context, '清理缓存失败，请稍后重试', colors: widget.colors);
    } else {
      AppToast.success(
        context,
        freed > 0 ? '已释放 ${formatStorageBytes(freed)} 缓存' : '没有可清理的缓存',
        colors: widget.colors,
      );
    }
    await _measure();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final report = _report;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '存储空间',
          style: TextStyle(
            color: colors.text,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (report == null)
          Text(
            _failed ? '无法统计占用，请稍后重试' : '正在统计占用…',
            style: TextStyle(
              color: _failed ? colors.accent : colors.secondary,
              fontSize: 12,
              height: 1.5,
            ),
          )
        else ...[
          Text(
            '${report.bookCount} 本书共占用 '
            '${formatStorageBytes(report.totalBytes)}。'
            '缓存可以随时清理，重新打开 PDF 会自动重建。',
            style: TextStyle(
              color: colors.secondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _row('书籍正文', report.bookPayloadBytes),
          _row('EPUB 图片与字体', report.epubResourceBytes),
          _row('Word 图片', report.wordResourceBytes),
          _row('PDF 副本', report.pdfCopyBytes),
          _row('导入字体', report.fontBytes),
          _row('可清理缓存', report.cacheBytes, emphasized: true),
        ],
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _clearing || _measuring ? null : _clear,
              icon: _clearing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cleaning_services_outlined, size: 18),
              label: Text(_clearing ? '清理中…' : '清理缓存'),
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.accent,
                side: BorderSide(color: colors.border),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            TextButton(
              onPressed: _measuring || _clearing ? null : _measure,
              child: Text(_measuring ? '统计中…' : '重新统计'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _row(String label, int bytes, {bool emphasized = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: emphasized ? widget.colors.text : widget.colors.secondary,
              fontSize: 13,
              fontWeight: emphasized ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        Text(
          formatStorageBytes(bytes),
          style: TextStyle(
            color: emphasized ? widget.colors.accent : widget.colors.secondary,
            fontSize: 13,
            fontWeight: emphasized ? FontWeight.w600 : FontWeight.w400,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}

/// Formats a byte count the way a storage panel reads best: whole numbers for
/// small sizes, one decimal once the unit is large enough for it to matter.
String formatStorageBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
