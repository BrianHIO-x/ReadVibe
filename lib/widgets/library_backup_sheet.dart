import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/private_shelf_controller.dart';
import '../services/android_book_picker.dart';
import '../services/library_backup_service.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_segmented_control.dart';
import 'app_sheet.dart';
import 'app_toast.dart';

Future<void> showLibraryBackupSheet(
  BuildContext context, {
  required LibraryBackupService backupService,
  required PrivateShelfController privateShelf,
  required ReaderThemeColors colors,
  required Future<void> Function() onRestored,
}) {
  return showAppSheet<void>(
    context: context,
    colors: colors,
    builder: (_) => _LibraryBackupSheet(
      backupService: backupService,
      privateShelf: privateShelf,
      colors: colors,
      onRestored: onRestored,
    ),
  );
}

enum _BackupSheetMode { exportBackup, restoreBackup }

class _LibraryBackupSheet extends StatefulWidget {
  const _LibraryBackupSheet({
    required this.backupService,
    required this.privateShelf,
    required this.colors,
    required this.onRestored,
  });

  final LibraryBackupService backupService;
  final PrivateShelfController privateShelf;
  final ReaderThemeColors colors;
  final Future<void> Function() onRestored;

  @override
  State<_LibraryBackupSheet> createState() => _LibraryBackupSheetState();
}

class _LibraryBackupSheetState extends State<_LibraryBackupSheet> {
  _BackupSheetMode _mode = _BackupSheetMode.exportBackup;

  bool _includeBookFiles = true;
  bool _includeSettings = true;
  bool _includePrivate = false;
  bool _exporting = false;
  BackupExportResult? _exportResult;

  String? _pickedBackupPath;
  bool _pickedBackupDeleteAfter = false;
  String? _pickedBackupName;
  BackupPreview? _preview;
  bool _inspecting = false;
  bool _restoreSettings = true;
  bool _restorePrivateAsNormal = false;
  bool _restoring = false;
  BackupRestoreResult? _restoreResult;

  @override
  void dispose() {
    if (_pickedBackupDeleteAfter) {
      _deletePickedBackup(_pickedBackupPath);
    }
    super.dispose();
  }

  void _deletePickedBackup(String? path) {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Best-effort cleanup of staged picked backup.
    }
  }

  Future<void> _runExport() async {
    if (_exporting || _restoring) return;
    if (_includePrivate && widget.privateShelf.configured) {
      final verified = await widget.privateShelf.ensureUnlocked('导出隐私书架备份');
      if (!verified || !mounted) return;
    }
    setState(() {
      _exporting = true;
      _exportResult = null;
    });
    try {
      final result = await widget.privateShelf.runWithSystemDialog(
        () => widget.backupService.exportBackup(
          BackupOptions(
            includeBookFiles: _includeBookFiles,
            includePrivate: _includePrivate && widget.privateShelf.configured,
            includeSettings: _includeSettings,
          ),
        ),
      );
      if (!mounted) return;
      if (result == null) {
        AppToast.show(context, '已取消保存备份', colors: widget.colors);
        return;
      }
      setState(() => _exportResult = result);
      AppToast.success(context, '备份已保存：${result.fileName}', colors: widget.colors);
    } on FormatException catch (error) {
      if (mounted) {
        AppToast.error(context, error.message, colors: widget.colors);
      }
    } on PlatformException catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          error.message ?? '保存备份文件失败，请检查存储空间',
          colors: widget.colors,
        );
      }
    } on Object {
      if (mounted) {
        AppToast.error(context, '导出备份失败，请稍后重试', colors: widget.colors);
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _pickAndInspectBackup() async {
    if (_inspecting || _restoring || _exporting) return;
    PickedImportFile? picked;
    try {
      picked = await widget.privateShelf.runWithSystemDialog(
        AndroidBookPicker.pickBackup,
      );
    } on PlatformException catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          error.message ?? '无法读取所选备份文件',
          colors: widget.colors,
        );
      }
      return;
    } on Object {
      if (mounted) {
        AppToast.error(context, '无法打开文件选择器', colors: widget.colors);
      }
      return;
    }
    if (picked == null || !mounted) return;

    final previousPath = _pickedBackupPath;
    final previousDeleteAfter = _pickedBackupDeleteAfter;
    _pickedBackupPath = picked.path;
    _pickedBackupDeleteAfter = picked.deleteAfterImport;
    if (previousDeleteAfter) _deletePickedBackup(previousPath);

    setState(() {
      _pickedBackupName = picked!.name;
      _preview = null;
      _restoreResult = null;
      _inspecting = true;
    });

    try {
      final preview = await widget.backupService.inspectBackup(picked.path);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _restoreSettings = preview.hasSettings;
        _restorePrivateAsNormal = !widget.privateShelf.configured;
      });
    } on FormatException catch (error) {
      if (_pickedBackupDeleteAfter) _deletePickedBackup(_pickedBackupPath);
      _pickedBackupPath = null;
      _pickedBackupDeleteAfter = false;
      if (mounted) {
        setState(() => _pickedBackupName = null);
        AppToast.error(context, error.message, colors: widget.colors);
      }
    } on Object {
      if (_pickedBackupDeleteAfter) _deletePickedBackup(_pickedBackupPath);
      _pickedBackupPath = null;
      _pickedBackupDeleteAfter = false;
      if (mounted) {
        setState(() => _pickedBackupName = null);
        AppToast.error(context, '无法解析备份包，请确认选择 .zip 备份文件', colors: widget.colors);
      }
    } finally {
      if (mounted) setState(() => _inspecting = false);
    }
  }

  Future<void> _runRestore() async {
    final backupPath = _pickedBackupPath;
    final preview = _preview;
    if (backupPath == null || preview == null || _restoring || _exporting) {
      return;
    }

    var allowPrivate = false;
    var restorePrivateAsNormal = _restorePrivateAsNormal;
    if (preview.privateBookCount > 0) {
      if (restorePrivateAsNormal) {
        allowPrivate = false;
      } else if (!widget.privateShelf.configured) {
        final configured = await widget.privateShelf.ensureConfigured();
        if (!configured || !mounted) return;
        allowPrivate = true;
      } else {
        final unlocked = await widget.privateShelf.ensureUnlocked(
          '恢复备份中的隐私书架数据',
        );
        if (!unlocked || !mounted) return;
        allowPrivate = true;
      }
    }

    setState(() {
      _restoring = true;
      _restoreResult = null;
    });
    try {
      final result = await widget.backupService.restoreBackup(
        backupPath,
        allowPrivateRestore: allowPrivate,
        restorePrivateAsNormal: restorePrivateAsNormal,
        restoreSettings: preview.hasSettings && _restoreSettings,
      );
      await widget.onRestored();
      if (!mounted) return;
      setState(() => _restoreResult = result);
      AppToast.success(context, '备份恢复完成', colors: widget.colors);
    } on FormatException catch (error) {
      if (mounted) {
        AppToast.error(context, error.message, colors: widget.colors);
      }
    } on Object {
      if (mounted) {
        AppToast.error(context, '恢复备份失败，请确认备份包完整', colors: widget.colors);
      }
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '未知时间';
    final local = date.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: AppSheetSurface(
        colors: widget.colors,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppSheetHeader(
              title: '本地备份与恢复',
              subtitle: '导出/恢复书签、笔记、阅读进度、分组与阅读设置',
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  0,
                  AppSpacing.xl,
                  AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppSegmentedControl<_BackupSheetMode>(
                      options: const [
                        AppSegmentOption(
                          value: _BackupSheetMode.exportBackup,
                          icon: Icons.upload_file_rounded,
                          label: '导出备份',
                        ),
                        AppSegmentOption(
                          value: _BackupSheetMode.restoreBackup,
                          icon: Icons.download_rounded,
                          label: '从备份恢复',
                        ),
                      ],
                      value: _mode,
                      colors: widget.colors,
                      enabled: !(_exporting || _restoring),
                      onChanged: (selected) => setState(() => _mode = selected),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    if (_mode == _BackupSheetMode.exportBackup)
                      _buildExportView()
                    else
                      _buildRestoreView(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExportView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text('包含完整书籍文件', style: TextStyle(color: widget.colors.text)),
          subtitle: Text(
            '包含已导入的章节正文、PDF、EPUB 图片与内置资源，换机可直接阅读',
            style: TextStyle(color: widget.colors.secondary, fontSize: 12),
          ),
          value: _includeBookFiles,
          onChanged: _exporting
              ? null
              : (v) => setState(() => _includeBookFiles = v),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text('包含全局设置与字体', style: TextStyle(color: widget.colors.text)),
          subtitle: Text(
            '保存主题、字号排版设置与已导入的自定义字体文件',
            style: TextStyle(color: widget.colors.secondary, fontSize: 12),
          ),
          value: _includeSettings,
          onChanged: _exporting
              ? null
              : (v) => setState(() => _includeSettings = v),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text('包含隐私书架内容', style: TextStyle(color: widget.colors.text)),
          subtitle: Text(
            widget.privateShelf.configured
                ? '导出前需验证锁密码；备份包内不会保存您的解锁密码与生物特征'
                : '当前尚未配置隐私书架',
            style: TextStyle(color: widget.colors.secondary, fontSize: 12),
          ),
          value: _includePrivate && widget.privateShelf.configured,
          onChanged: _exporting || !widget.privateShelf.configured
              ? null
              : (v) => setState(() => _includePrivate = v),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_exportResult != null) ...[
          _SummaryBox(
            colors: widget.colors,
            lines: [
              '已保存文件：${_exportResult!.fileName}',
              '包含书籍：${_exportResult!.bookCount} 本'
                  '${_exportResult!.privateBookCount > 0 ? '（含隐私 ${_exportResult!.privateBookCount} 本）' : ''}',
              '备份包大小：${_formatSize(_exportResult!.sizeBytes)}',
            ],
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _exporting ? null : _runExport,
            icon: _exporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.archive_outlined, size: 18),
            label: Text(_exporting ? '正在打包备份…' : '导出本地备份 (.zip)'),
          ),
        ),
      ],
    );
  }

  Widget _buildRestoreView() {
    final preview = _preview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: _inspecting || _restoring ? null : _pickAndInspectBackup,
          icon: const Icon(Icons.folder_open_rounded, size: 18),
          label: Text(
            _pickedBackupName == null
                ? '选择备份文件 (.zip)'
                : '重新选择（$_pickedBackupName）',
          ),
        ),
        if (_inspecting) ...[
          const SizedBox(height: AppSpacing.md),
          const LinearProgressIndicator(),
        ],
        if (preview != null) ...[
          const SizedBox(height: AppSpacing.md),
          _SummaryBox(
            colors: widget.colors,
            lines: [
              '创建时间：${_formatDate(preview.createdAt)}'
                  '${preview.appVersion.isNotEmpty ? ' · v${preview.appVersion}' : ''}',
              '内容类型：${preview.includeBookFiles ? '完整备份（含书籍文件）' : '仅记录与设置'}',
              '包含数据：${preview.bookCount} 本书'
                  '${preview.privateBookCount > 0 ? '（含隐私 ${preview.privateBookCount} 本）' : ''} · '
                  '${preview.groupCount} 个分组',
              '阅读积累：${preview.bookmarkCount} 条书签 · ${preview.noteCount} 条笔记',
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (preview.hasSettings)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '恢复全局设置与导入字体',
                style: TextStyle(color: widget.colors.text),
              ),
              value: _restoreSettings,
              onChanged: _restoring
                  ? null
                  : (v) => setState(() => _restoreSettings = v),
            ),
          if (preview.privateBookCount > 0) ...[
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '将备份中的隐私书籍放入普通书架',
                style: TextStyle(color: widget.colors.text),
              ),
              subtitle: Text(
                widget.privateShelf.configured
                    ? '关闭此项则在恢复前先验证当前隐私密码'
                    : '当前尚未设置隐私书架；关闭此项将在恢复前引导设置 6 位密码',
                style: TextStyle(color: widget.colors.secondary, fontSize: 12),
              ),
              value: _restorePrivateAsNormal,
              onChanged: _restoring
                  ? null
                  : (v) => setState(() => _restorePrivateAsNormal = v),
            ),
          ],
          if (_restoreResult != null) ...[
            const SizedBox(height: AppSpacing.sm),
            _SummaryBox(
              colors: widget.colors,
              lines: [
                '新恢复书籍：${_restoreResult!.restoredBooks} 本',
                '与本地合并：${_restoreResult!.mergedBooks} 本 · 新增分组：${_restoreResult!.restoredGroups} 个',
                if (_restoreResult!.skippedMissingFiles > 0)
                  '已跳过 ${_restoreResult!.skippedMissingFiles} 本本地无正文的记录',
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _restoring ? null : _runRestore,
              icon: _restoring
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.restore_rounded, size: 18),
              label: Text(_restoring ? '正在合并恢复…' : '合并恢复到本地书架'),
            ),
          ),
        ] else if (!_inspecting) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            '恢复采用非破坏式合并：本地已有书籍会保留最新阅读进度并合并新增书签、笔记与分组。',
            style: TextStyle(
              color: widget.colors.secondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }
}

class _SummaryBox extends StatelessWidget {
  const _SummaryBox({required this.colors, required this.lines});

  final ReaderThemeColors colors;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                line,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
