import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/private_shelf_controller.dart';
import '../services/storage_vault_channel.dart';
import '../theme/app_button_styles.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_choice_pill.dart';
import 'app_dialog.dart';
import 'app_segmented_control.dart';
import 'app_sheet.dart';
import 'app_toast.dart';
import 'pressable_scale.dart';

/// Shows an in-app themed folder browser backed by Android's optional
/// `MANAGE_EXTERNAL_STORAGE` permission, returning the selected canonical path.
Future<String?> showVaultDirectoryPickerSheet(
  BuildContext context, {
  required PrivateShelfController privateShelf,
  required ReaderThemeColors colors,
  String? initialPath,
}) {
  return showAppSheet<String>(
    context: context,
    colors: colors,
    isScrollControlled: true,
    builder: (_) => _VaultDirectoryPickerSheet(
      privateShelf: privateShelf,
      colors: colors,
      initialPath: initialPath,
    ),
  );
}

class _VaultDirectoryPickerSheet extends StatefulWidget {
  const _VaultDirectoryPickerSheet({
    required this.privateShelf,
    required this.colors,
    this.initialPath,
  });

  final PrivateShelfController privateShelf;
  final ReaderThemeColors colors;
  final String? initialPath;

  @override
  State<_VaultDirectoryPickerSheet> createState() =>
      _VaultDirectoryPickerSheetState();
}

class _VaultDirectoryPickerSheetState
    extends State<_VaultDirectoryPickerSheet> {
  VaultAllFilesStatus? _access;
  LocalDirectoryListing? _listing;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadInitial());
  }

  Future<void> _loadInitial({String? preferredPath}) async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final status = await StorageVaultChannel.allFilesAccessStatus();
      if (!mounted) return;
      _access = status;
      if (status.supported && status.granted) {
        final target = preferredPath ?? widget.initialPath ?? status.defaultPath;
        await _openDirectory(target, fallbackToRoot: true);
      }
    } on Object catch (error) {
      if (mounted) {
        _error = error is PlatformException
            ? (error.message ?? '无法读取目录权限状态')
            : '无法读取目录权限状态';
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openDirectory(
    String? path, {
    bool fallbackToRoot = false,
  }) async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      final listing = await StorageVaultChannel.listLocalDirectories(path: path);
      if (mounted) setState(() => _listing = listing);
    } on PlatformException catch (error) {
      if (fallbackToRoot && path != _access?.rootPath) {
        await _openDirectory(_access?.rootPath);
        return;
      }
      if (mounted) {
        _error = error.message ?? '无法打开该文件夹';
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestPermission() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final granted = await widget.privateShelf.runWithSystemDialog(
        StorageVaultChannel.requestAllFilesAccess,
      );
      if (!mounted) return;
      await _loadInitial();
      if (!mounted) return;
      if (!granted && !(_access?.granted ?? false)) {
        AppToast.info(
          context,
          '尚未开启“所有文件访问权限”，可在授予后返回重试',
          colors: widget.colors,
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          error.message ?? '无法打开系统权限设置',
          colors: widget.colors,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createSubfolder() async {
    final listing = _listing;
    if (_busy || listing == null) return;
    final controller = TextEditingController();
    final createdName = await showAppDialog<String>(
      context: context,
      colors: widget.colors,
      builder: (dialogContext) => AppDialog(
        title: const Text('新建文件夹'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '将在「${listing.displayName}」下创建目录：',
              style: TextStyle(fontSize: 13, color: widget.colors.secondary),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 60,
              decoration: const InputDecoration(
                hintText: '例如：ReadVibe_Backup',
                counterText: '',
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                final text = controller.text.trim();
                if (text.isNotEmpty) Navigator.pop(dialogContext, text);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isEmpty) {
                AppToast.info(dialogContext, '请输入文件夹名称', colors: widget.colors);
                return;
              }
              Navigator.pop(dialogContext, text);
            },
            child: const Text('创建并进入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (createdName == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final createdPath = await StorageVaultChannel.createLocalDirectory(
        parentPath: listing.currentPath,
        name: createdName,
      );
      if (!mounted) return;
      if (createdPath.isNotEmpty) {
        await _openDirectory(createdPath);
      } else {
        await _openDirectory(listing.currentPath);
      }
    } on PlatformException catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          error.message ?? '创建文件夹失败',
          colors: widget.colors,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final dark = AppOverlayTheme.isDark(colors);
    return AppSheetSurface(
      colors: colors,
      child: SafeArea(
        top: false,
        bottom: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.86,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppSheetHeader(
                title: '应用内自选守护目录',
                subtitle: '高级模式 · 可自由新建或直接选定备份目录',
                trailing: (_access?.granted ?? false) && _listing != null
                    ? IconButton(
                        tooltip: '新建文件夹',
                        onPressed: _busy ? null : _createSubfolder,
                        icon: const Icon(Icons.create_new_folder_outlined),
                      )
                    : null,
              ),
              Divider(height: 1, color: colors.border),
              Flexible(
                child: AppTabTransition(
                  index: _loading
                      ? 0
                      : !(_access?.supported ?? false)
                      ? 1
                      : !(_access?.granted ?? false)
                      ? 2
                      : 3,
                  animateSize: false,
                  child: _loading
                      ? const Padding(
                          key: ValueKey<int>(0),
                          padding: EdgeInsets.symmetric(vertical: 64),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : !(_access?.supported ?? false)
                      ? KeyedSubtree(
                          key: const ValueKey<int>(1),
                          child: _buildUnsupported(colors),
                        )
                      : !(_access?.granted ?? false)
                      ? KeyedSubtree(
                          key: const ValueKey<int>(2),
                          child: _buildPermissionGuide(colors, dark),
                        )
                      : KeyedSubtree(
                          key: const ValueKey<int>(3),
                          child: _buildDirectoryBrowser(colors, dark),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUnsupported(ReaderThemeColors colors) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_outlined, size: 42, color: colors.secondary),
          const SizedBox(height: AppSpacing.md),
          Text(
            '当前系统版本不支持“管理所有文件”权限，请直接返回使用默认的系统目录选择器。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: colors.secondary, height: 1.5),
          ),
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionGuide(ReaderThemeColors colors, bool dark) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.lg,
        AppSpacing.xl,
        AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                colors.accent.withValues(alpha: dark ? 0.12 : 0.06),
                colors.headerBg,
              ),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: colors.accent.withValues(alpha: 0.35),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.verified_user_outlined,
                      size: 20,
                      color: colors.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '需要开启「管理所有文件」权限',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: colors.text,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '开启后即可绕过厂商自带文件选择器的目录限制，直接在应用内浏览手机目录、快速建夹或找回旧手机拷入的 ReadVibe_Vault 备份。',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: colors.text.withValues(alpha: 0.88),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '• 仅读写你主动绑定的守护目录（ReadVibe_Vault/）\n'
                  '• 全部数据保留在本地，绝不扫描或上传其他隐私文件\n'
                  '• 不需要时可随时在系统设置撤回或切回默认 SAF 模式',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.55,
                    color: colors.secondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton.icon(
            onPressed: _busy ? null : _requestPermission,
            icon: const Icon(Icons.admin_panel_settings_outlined, size: 18),
            label: const Text('前往系统设置开启'),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('改用默认系统目录选择器'),
          ),
        ],
      ),
    );
  }

  Widget _buildDirectoryBrowser(ReaderThemeColors colors, bool dark) {
    final access = _access!;
    final listing = _listing;
    final rootPath = access.rootPath;
    final docsPath = '$rootPath/Documents';
    final downloadPath = '$rootPath/Download';

    Widget quickChip(String label, String path) {
      final selected = listing?.currentPath == path;
      return AppChoicePill(
        label: label,
        selected: selected,
        enabled: !_busy,
        colors: colors,
        onTap: () => _openDirectory(path),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.xs,
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                quickChip('Documents', docsPath),
                const SizedBox(width: AppSpacing.xs),
                quickChip('Download', downloadPath),
                const SizedBox(width: AppSpacing.xs),
                quickChip('内部存储', rootPath),
              ],
            ),
          ),
        ),
        if (listing != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.xs,
              AppSpacing.sm,
              AppSpacing.xs,
            ),
            child: Row(
              children: [
                if (listing.parentPath != null)
                  IconButton(
                    tooltip: '返回上级目录',
                    onPressed: _busy
                        ? null
                        : () => _openDirectory(listing.parentPath),
                    style: AppButtonStyles.iconOverride(
                      colors,
                      minimumSize: const Size(38, 38),
                    ),
                    icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                  ),
                Icon(
                  Icons.folder_open_rounded,
                  size: 18,
                  color: colors.accent,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    listing.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: colors.text,
                    ),
                  ),
                ),
                if (listing.hasVault)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: colors.accent.withValues(alpha: dark ? 0.22 : 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      '含已有备份',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: colors.accent,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Divider(height: 1, color: colors.border),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Text(
              _error!,
              style: TextStyle(color: AppOverlayTheme.danger(colors), fontSize: 13),
            ),
          )
        else if (listing == null || listing.directories.isEmpty)
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xl,
                vertical: 36,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.folder_copy_outlined,
                    size: 36,
                    color: colors.secondary.withValues(alpha: 0.7),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '此目录下没有子文件夹，可直接点击下方按钮使用当前目录，或点右上角新建子文件夹。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: colors.secondary,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              itemCount: listing.directories.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                indent: 48,
                endIndent: 12,
                color: colors.border.withValues(alpha: 0.55),
              ),
              itemBuilder: (context, index) {
                final item = listing.directories[index];
                return PressableScale(
                  enabled: !_busy,
                  pressedScale: 0.985,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _busy ? null : () => _openDirectory(item.path),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      overlayColor: const WidgetStatePropertyAll(
                        Colors.transparent,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 11,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              item.hasVault
                                  ? Icons.folder_special_rounded
                                  : Icons.folder_rounded,
                              size: 22,
                              color: item.hasVault
                                  ? colors.accent
                                  : colors.secondary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: item.hasVault
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: colors.text,
                                ),
                              ),
                            ),
                            if (item.hasVault) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: colors.accent.withValues(
                                    alpha: dark ? 0.22 : 0.12,
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.sm,
                                  ),
                                ),
                                child: Text(
                                  '已有备份',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: colors.accent,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 18,
                              color: colors.secondary.withValues(alpha: 0.7),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        Divider(height: 1, color: colors.border),
        Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.md + MediaQuery.paddingOf(context).bottom,
          ),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_busy || listing == null)
                  ? null
                  : () => Navigator.of(context).pop(listing.currentPath),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: Text(
                listing == null ? '选择此目录' : '选择「${listing.displayName}」',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
