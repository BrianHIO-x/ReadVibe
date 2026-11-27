import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/private_shelf_controller.dart';
import '../services/data_safety_vault_service.dart';
import '../services/library_backup_service.dart';
import '../theme/app_button_styles.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_choice_pill.dart';
import 'app_dialog.dart';
import 'app_segmented_control.dart';
import 'app_sheet.dart';
import 'app_switch.dart';
import 'app_toast.dart';
import 'library_backup_sheet.dart';
import 'vault_directory_picker_sheet.dart';

Future<void> showDataSafetySheet(
  BuildContext context, {
  required DataSafetyVaultService vaultService,
  required LibraryBackupService backupService,
  required PrivateShelfController privateShelf,
  required ReaderThemeColors colors,
  required Future<void> Function() onRestored,
}) {
  return showAppSheet<void>(
    context: context,
    colors: colors,
    isScrollControlled: true,
    builder: (_) => _DataSafetySheet(
      vaultService: vaultService,
      backupService: backupService,
      privateShelf: privateShelf,
      colors: colors,
      onRestored: onRestored,
    ),
  );
}

class _DataSafetySheet extends StatefulWidget {
  const _DataSafetySheet({
    required this.vaultService,
    required this.backupService,
    required this.privateShelf,
    required this.colors,
    required this.onRestored,
  });

  final DataSafetyVaultService vaultService;
  final LibraryBackupService backupService;
  final PrivateShelfController privateShelf;
  final ReaderThemeColors colors;
  final Future<void> Function() onRestored;

  @override
  State<_DataSafetySheet> createState() => _DataSafetySheetState();
}

class _DataSafetySheetState extends State<_DataSafetySheet> {
  int _tab = 0;
  VaultStatus? _status;
  int? _optimisticQuotaBytes;
  bool? _optimisticAutoSync;
  bool _loading = true;
  bool _busy = false;
  String? _busyMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    try {
      final next = await widget.vaultService.loadStatus();
      if (mounted) {
        setState(() {
          _status = next;
          _optimisticQuotaBytes = null;
          _optimisticAutoSync = null;
          _loading = false;
        });
      }
    } on Object {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickSafFolder() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyMessage = '正在授权守护目录...';
    });
    try {
      final status = await widget.privateShelf.runWithSystemDialog(
        widget.vaultService.bindFolder,
      );
      if (!mounted) return;
      if (status == null) return;
      setState(() => _status = status);
      AppToast.success(
        context,
        '已绑定「${status.config.displayName ?? '守护目录'}」',
        colors: widget.colors,
      );
      // Kick off an immediate first sync so the bound folder is populated right away.
      unawaited(_syncNow(silentIfEmpty: true));
    } on PlatformException catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          error.message ?? '选择目录失败',
          colors: widget.colors,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = null;
        });
      }
    }
  }

  Future<void> _pickDirectFolder() async {
    if (_busy) return;
    final selectedPath = await showVaultDirectoryPickerSheet(
      context,
      privateShelf: widget.privateShelf,
      colors: widget.colors,
    );
    if (selectedPath == null || !mounted) return;
    setState(() {
      _busy = true;
      _busyMessage = '正在绑定守护目录...';
    });
    try {
      final status = await widget.vaultService.bindDirectFolder(selectedPath);
      if (!mounted || status == null) return;
      setState(() => _status = status);
      AppToast.success(
        context,
        '已绑定「${status.config.displayName ?? '守护目录'}」',
        colors: widget.colors,
      );
      unawaited(_syncNow(silentIfEmpty: true));
    } on PlatformException catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          error.message ?? '绑定目录失败',
          colors: widget.colors,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = null;
        });
      }
    }
  }

  Future<void> _chooseFolderMode() async {
    if (_busy) return;
    final mode = await showAppSheet<String>(
      context: context,
      colors: widget.colors,
      builder: (sheetContext) => AppActionSheet(
        colors: widget.colors,
        title: '更换守护目录方式',
        subtitle: '可按需选用系统目录授权或高级目录模式',
        children: [
          ListTile(
            leading: Icon(Icons.security_rounded, color: widget.colors.accent),
            title: const Text('系统目录选择器（SAF）'),
            subtitle: const Text('零敏感存储权限，默认定位 Documents'),
            onTap: () => Navigator.pop(sheetContext, 'saf'),
          ),
          ListTile(
            leading: Icon(Icons.folder_copy_outlined, color: widget.colors.accent),
            title: const Text('应用内自选目录（高级）'),
            subtitle: const Text('支持应用内浏览目录与自由建夹，需管理所有文件权限'),
            onTap: () => Navigator.pop(sheetContext, 'direct'),
          ),
        ],
      ),
    );
    if (!mounted || mode == null) return;
    if (mode == 'direct') {
      await _pickDirectFolder();
    } else {
      await _pickSafFolder();
    }
  }

  Future<void> _syncNow({bool silentIfEmpty = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyMessage = '正在增量同步至守护目录...';
    });
    try {
      final report = await widget.vaultService.syncNow();
      await _refreshStatus();
      if (!mounted) return;
      if (!report.ok) {
        AppToast.error(
          context,
          report.errorMessage ?? '同步未完整完成',
          colors: widget.colors,
        );
        return;
      }
      if (silentIfEmpty && report.uploadedBooks == 0 && report.skippedBooks == 0) {
        return;
      }
      AppToast.success(
        context,
        report.uploadedBooks > 0
            ? '已同步 ${report.uploadedBooks} 本，跳过未变 ${report.skippedBooks} 本'
            : '守护目录已是最新（${report.skippedBooks} 本未变）',
        colors: widget.colors,
      );
    } on Object catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          error is FormatException ? error.message : '同步失败，请稍后重试',
          colors: widget.colors,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = null;
        });
      }
    }
  }

  Future<void> _restoreFromVault() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyMessage = '正在扫描守护目录索引...';
    });
    try {
      final preview = await widget.vaultService.inspectVault();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyMessage = null;
      });
      if (preview == null || preview.bookCount == 0 && !preview.hasSettings) {
        AppToast.info(
          context,
          '守护目录中暂无可恢复的同步数据',
          colors: widget.colors,
        );
        return;
      }

      var includePrivate = preview.privateBookCount > 0;
      var restoreSettings = preview.hasSettings;
      final confirmed = await showAppDialog<bool>(
        context: context,
        colors: widget.colors,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AppDialog(
            title: const Text('从守护目录恢复'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '检测到 ${preview.bookCount} 本书'
                  '${preview.privateBookCount > 0 ? '（含 ${preview.privateBookCount} 本隐私书）' : ''}'
                  '、${preview.noteCount} 条笔记与 ${preview.bookmarkCount} 个书签。恢复采用合并策略，不会删除本地已有内容。',
                ),
                const SizedBox(height: AppSpacing.md),
                if (preview.privateBookCount > 0)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: includePrivate,
                    title: Text('一并恢复隐私书籍 (${preview.privateBookCount} 本)'),
                    onChanged: (v) =>
                        setDialogState(() => includePrivate = v ?? false),
                  ),
                if (preview.hasSettings)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: restoreSettings,
                    title: const Text('恢复阅读偏好与字号/主题设置'),
                    onChanged: (v) =>
                        setDialogState(() => restoreSettings = v ?? true),
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
                child: const Text('开始恢复'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true || !mounted) return;

      if (includePrivate &&
          preview.privateBookCount > 0 &&
          widget.privateShelf.configured &&
          !widget.privateShelf.isOpen) {
        final verified = await widget.privateShelf.ensureUnlocked(
          '验证以恢复守护目录中的隐私书籍',
        );
        if (!verified) includePrivate = false;
      }
      if (!mounted) return;

      setState(() {
        _busy = true;
        _busyMessage = '正在校验并流式恢复守护数据...';
      });
      final report = await widget.vaultService.restoreFromVault(
        includePrivate: includePrivate,
        restoreSettings: restoreSettings,
      );
      await widget.onRestored();
      await _refreshStatus();
      if (!mounted) return;
      AppToast.success(
        context,
        '已恢复 ${report.restoredBooks} 本新书、合并 ${report.updatedBooks} 本与 ${report.mergedNotes} 条笔记',
        colors: widget.colors,
      );
    } on Object catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          error is FormatException ? error.message : '恢复失败，请检查守护目录文件完整性',
          colors: widget.colors,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = null;
        });
      }
    }
  }

  Future<void> _verifyAndClean() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyMessage = '正在核验完整性并清理冗余缓存...';
    });
    try {
      final report = await widget.vaultService.verifyAndCleanVault();
      await _refreshStatus();
      if (!mounted) return;
      final freed = _formatBytes(report.freedBytes);
      AppToast.success(
        context,
        '核验完成：有效书籍 ${report.validBooks} 本，清理 ${report.removedOrphans} 个孤立包与 ${report.removedTmpFiles} 个残留临时文件（释放 $freed）',
        colors: widget.colors,
      );
    } on Object catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          error is FormatException ? error.message : '核验失败，请稍后重试',
          colors: widget.colors,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = null;
        });
      }
    }
  }

  Future<void> _unbindOnly() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyMessage = '正在解除守护目录绑定...';
    });
    try {
      await widget.vaultService.unbindFolder();
      await _refreshStatus();
      if (mounted) {
        AppToast.success(
          context,
          '已解绑守护目录（外部文件夹内的备份文件已保留）',
          colors: widget.colors,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = null;
        });
      }
    }
  }

  Future<void> _purgeAndUnbind() async {
    if (_busy) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      colors: widget.colors,
      builder: (dialogContext) => AppDialog(
        title: const Text('清空守护目录并解绑'),
        content: const Text(
          '将删除所选文件夹内 ReadVibe_Vault 中的全部备份书籍与配置，并解除授权绑定（不会删除应用当前书架）。此操作不可撤销，确定继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          AppDestructiveButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('彻底清空并解绑'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _busyMessage = '正在清空守护目录并释放空间...';
    });
    try {
      final result = await widget.vaultService.purgeVaultData();
      await _refreshStatus();
      if (mounted) {
        AppToast.success(
          context,
          '已清理 ${result.deletedCount} 个守护文件并释放 ${_formatBytes(result.freedBytes)}',
          colors: widget.colors,
        );
      }
    } on Object {
      if (mounted) {
        AppToast.error(context, '清空失败，请检查目录授权状态', colors: widget.colors);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final danger = AppOverlayTheme.danger(colors);
    return AppSheetSurface(
      colors: colors,
      child: SafeArea(
        top: false,
        bottom: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.88,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppSheetHeader(
                title: '数据安全与备份',
                subtitle: '防卸载本地守护与跨设备迁移',
              ),
              Divider(height: 1, color: colors.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: AppSegmentedControl<int>(
                  options: const [
                    AppSegmentOption(
                      value: 0,
                      icon: Icons.shield_outlined,
                      label: '防卸载守护目录',
                    ),
                    AppSegmentOption(
                      value: 1,
                      icon: Icons.inventory_2_outlined,
                      label: '便携压缩包 (.zip)',
                    ),
                  ],
                  value: _tab,
                  colors: colors,
                  enabled: !_busy,
                  onChanged: (next) => setState(() => _tab = next),
                ),
              ),
              if (_busy && _busyMessage != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.xs,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.accent,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          _busyMessage!,
                          style: TextStyle(fontSize: 12, color: colors.accent),
                        ),
                      ),
                    ],
                  ),
                ),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.sm,
                    AppSpacing.lg,
                    AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: AppTabTransition(
                    index: _tab,
                    child: _tab == 0
                        ? KeyedSubtree(
                            key: const ValueKey<int>(0),
                            child: _buildVaultTab(colors, danger),
                          )
                        : KeyedSubtree(
                            key: const ValueKey<int>(1),
                            child: _buildZipTab(colors),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVaultTab(ReaderThemeColors colors, Color danger) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final status = _status;
    final config = status?.config ?? const VaultConfig();
    final isBound = config.isBound;
    final valid = status?.permissionValid ?? false;
    final quotaBytes = _optimisticQuotaBytes ?? config.quotaBytes;
    final autoSync = _optimisticAutoSync ?? config.autoSync;
    final usedBytes = status?.usedBytes ?? 0;
    final quotaRatio = quotaBytes > 0
        ? (usedBytes / quotaBytes).clamp(0.0, 1.0)
        : 0.0;

    final badgeColor = !isBound
        ? colors.secondary
        : valid
        ? colors.accent
        : danger;
    final badgeText = !isBound
        ? '未开启守护'
        : valid
        ? '防卸载守护中'
        : '目录授权失效';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: colors.background.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      badgeText,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: badgeColor,
                      ),
                    ),
                  ),
                  if (isBound) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: colors.headerBg,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(color: colors.border),
                      ),
                      child: Text(
                        config.isDirectMode ? '应用内直连' : '系统 SAF',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                          color: colors.secondary,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (status != null && status.freeDeviceBytes > 0)
                    Text(
                      '设备可用 ${_formatBytes(status.freeDeviceBytes)}',
                      style: TextStyle(fontSize: 12, color: colors.secondary),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                isBound
                    ? '${config.displayName ?? '守护目录'}/ReadVibe_Vault'
                    : '选择如 Download 或 Documents 下的文件夹作为本地守护目录。卸载重装 ReadVibe 后，重新授权该目录即可一键找回书籍、划线笔记与阅读进度。',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: isBound ? colors.text : colors.secondary,
                  fontWeight: isBound ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              if (isBound) ...[
                const SizedBox(height: AppSpacing.sm),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '已备份 ${status?.bookCount ?? 0} 本书'
                      '${(status?.privateBookCount ?? 0) > 0 ? '（含隐私 ${status!.privateBookCount} 本）' : ''}',
                      style: TextStyle(fontSize: 12, color: colors.secondary),
                    ),
                    Text(
                      quotaBytes > 0
                          ? '${_formatBytes(usedBytes)} / ${_formatBytes(quotaBytes)}'
                          : '已用 ${_formatBytes(usedBytes)}（不限配额）',
                      style: TextStyle(fontSize: 12, color: colors.secondary),
                    ),
                  ],
                ),
                if (quotaBytes > 0) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: quotaRatio,
                      minHeight: 6,
                      backgroundColor: colors.border.withValues(alpha: 0.45),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        quotaRatio > 0.9 ? danger : colors.accent,
                      ),
                    ),
                  ),
                ],
                if (config.lastSyncAt != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '上次同步：${_formatTimestamp(config.lastSyncAt!)}',
                    style: TextStyle(fontSize: 11, color: colors.secondary),
                  ),
                ],
              ],
              if (config.lastError != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: danger.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline_rounded, size: 16, color: danger),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          config.lastError!,
                          style: TextStyle(fontSize: 12, color: danger),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (!isBound || !valid) ...[
          FilledButton.icon(
            onPressed: _busy ? null : _pickSafFolder,
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: Text(!isBound ? '选择外部守护目录' : '重新授权守护目录'),
          ),
          const SizedBox(height: AppSpacing.xs),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickDirectFolder,
            icon: const Icon(Icons.folder_copy_outlined, size: 18),
            label: const Text('应用内自选目录（高级）'),
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _syncNow(),
                  icon: const Icon(Icons.sync_rounded, size: 18),
                  label: const Text('立即增量同步'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: _busy ? null : _chooseFolderMode,
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('更换'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _restoreFromVault,
                  icon: const Icon(Icons.restore_rounded, size: 18),
                  label: const Text('从守护目录恢复'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _verifyAndClean,
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: const Text('核验与清理'),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        Text(
          '守护空间上限（保留手机至少 256 MB 安全余量）',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colors.secondary,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in kVaultQuotaPresets)
              AppChoicePill(
                label: preset.label,
                selected: quotaBytes == preset.bytes,
                enabled: !_busy,
                colors: colors,
                onTap: () async {
                  if (quotaBytes == preset.bytes) return;
                  setState(() => _optimisticQuotaBytes = preset.bytes);
                  await widget.vaultService.setQuotaBytes(preset.bytes);
                  await _refreshStatus();
                },
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Material(
          color: colors.headerBg,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            side: BorderSide(color: colors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              AppSwitchTile(
                colors: colors,
                value: autoSync,
                title: const Text('自动增量同步'),
                subtitle: const Text('导入书籍、阅读退出、记笔记或调整书架后自动后台更新'),
                onChanged: _busy
                    ? null
                    : (value) async {
                        setState(() => _optimisticAutoSync = value);
                        await widget.vaultService.setAutoSync(value);
                        await _refreshStatus();
                      },
              ),
              Divider(height: 1, color: colors.border),
              AppSwitchTile(
                colors: colors,
                value: config.includePrivate,
                title: const Text('同步隐私书架'),
                subtitle: const Text('默认关闭；关闭时会立即删除守护目录中的隐私书籍备份'),
                onChanged: _busy
                    ? null
                    : (value) async {
                        setState(() {
                          _busy = true;
                          _busyMessage = value
                              ? '正在保存设置...'
                              : '正在清理守护目录中的隐私书籍备份...';
                        });
                        try {
                          await widget.vaultService.setIncludePrivate(value);
                          await _refreshStatus();
                          if (mounted && !value) {
                            AppToast.info(
                              context,
                              '已停止同步并清理守护目录中的隐私书籍',
                              colors: widget.colors,
                            );
                          }
                        } finally {
                          if (mounted) {
                            setState(() {
                              _busy = false;
                              _busyMessage = null;
                            });
                          }
                        }
                      },
              ),
            ],
          ),
        ),
        if (isBound) ...[
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: _busy ? null : _unbindOnly,
                  icon: const Icon(Icons.link_off_rounded, size: 17),
                  label: const Text('仅解绑目录'),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: _busy ? null : _purgeAndUnbind,
                  style: AppButtonStyles.textOverride(
                    colors,
                    foregroundColor: danger,
                  ),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 17),
                  label: const Text('清空守护目录并解绑'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildZipTab(ReaderThemeColors colors) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.folder_zip_outlined, color: colors.accent, size: 22),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '单文件全量快照 (.zip)',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: colors.text,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '适合跨手机换机迁移或单独留档分享：将书籍正文、划线笔记、金句分类、书签、阅读进度、书架分组、自定义字体与阅读偏好打包为单个 .zip 文件，或从已保存的 .zip 文件无损合并恢复。',
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: colors.secondary,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    await showLibraryBackupSheet(
                      context,
                      backupService: widget.backupService,
                      privateShelf: widget.privateShelf,
                      colors: widget.colors,
                      onRestored: () async {
                        await widget.onRestored();
                        await _refreshStatus();
                      },
                    );
                  },
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('打开 .zip 导出与恢复'),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var idx = 0;
  while (value >= 1024 && idx < units.length - 1) {
    value /= 1024;
    idx++;
  }
  return idx <= 1
      ? '${value.round()} ${units[idx]}'
      : '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[idx]}';
}

String _formatTimestamp(DateTime dt) {
  final l = dt.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}
