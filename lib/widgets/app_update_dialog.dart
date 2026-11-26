import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/release_notes_markdown.dart';
import '../services/update_download_service.dart';
import '../services/update_service.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_dialog.dart';
import 'release_notes_view.dart';

/// Keeps download, retry and installation in one user-controlled flow.
class AppUpdateDialog extends StatefulWidget {
  final AppUpdateInfo info;
  final ReaderThemeColors colors;
  final UpdateDownloader? downloader;

  const AppUpdateDialog({
    super.key,
    required this.info,
    required this.colors,
    this.downloader,
  });

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  late final _service = widget.downloader ?? UpdateDownloadService();
  final ScrollController _notesScrollController = ScrollController();

  late List<ReleaseNotesBlock> _noteBlocks;
  bool _busy = false;
  File? _downloaded;
  UpdateDownloadProgress? _progress;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _noteBlocks = parseReleaseNotesMarkdown(widget.info.notes);
  }

  @override
  void didUpdateWidget(covariant AppUpdateDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.info.notes != widget.info.notes) {
      _noteBlocks = parseReleaseNotesMarkdown(widget.info.notes);
    }
  }

  Future<void> _downloadAndInstall() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = _downloaded == null ? '正在连接下载线路…' : '正在检查安装包…';
    });
    try {
      _downloaded ??= await _service.download(widget.info, (progress) {
        if (!mounted) return;
        setState(() {
          _progress = progress;
          _status = progress.received == progress.total
              ? '正在校验安装包…'
              : progress.source;
        });
      });
      if (!mounted) return;
      setState(() => _status = '正在检查安装包并打开系统安装程序…');
      final result = await _service.install(_downloaded!, widget.info);
      if (!mounted) return;
      setState(() {
        _status = result == UpdateInstallResult.permissionRequired
            ? '请在系统设置中允许 ReadVibe 安装应用，返回后点击“安装更新”。无需重新下载。'
            : '已打开系统安装程序。若取消了安装，可点击“安装更新”重试。';
      });
    } on UpdateDownloadCancelled {
      if (mounted) setState(() => _status = '已取消下载');
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message ?? '无法打开系统安装程序';
          if (error.code == 'UPDATE_INVALID') _downloaded = null;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = error is UpdateDownloadException
              ? error.message
              : '更新失败，请检查网络和剩余存储空间后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Percentage, megabytes and the live rate, so a line that has slowed to a
  /// crawl is visible instead of only being felt.
  String _progressLabel(UpdateDownloadProgress progress) {
    final received = (progress.received / (1024 * 1024)).toStringAsFixed(1);
    final total = (widget.info.apkSize / (1024 * 1024)).toStringAsFixed(1);
    final percent = (progress.fraction * 100).toStringAsFixed(0);
    final rate = progress.bytesPerSecond;
    final speed = rate > 0
        ? ' · ${(rate / (1024 * 1024)).toStringAsFixed(2)} MB/s'
        : '';
    return '$percent% · $received / $total MB$speed';
  }

  @override
  void dispose() {
    _notesScrollController.dispose();
    _service.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final dark = AppOverlayTheme.isDark(colors);
    final maxNotesHeight = (MediaQuery.sizeOf(context).height * 0.42).clamp(
      200.0,
      320.0,
    );
    return PopScope(
      canPop: !_busy,
      child: AppDialog(
        title: Text('发现新版本 v${widget.info.version}'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '安装包 ${(widget.info.apkSize / (1024 * 1024)).toStringAsFixed(1)} MB',
                style: TextStyle(color: colors.secondary, fontSize: 13),
              ),
              const SizedBox(height: AppSpacing.md),
              if (_noteBlocks.isNotEmpty)
                Container(
                  width: double.infinity,
                  constraints: BoxConstraints(maxHeight: maxNotesHeight),
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(
                      colors.text.withValues(alpha: dark ? 0.05 : 0.025),
                      colors.headerBg,
                    ),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(color: colors.border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: RawScrollbar(
                    controller: _notesScrollController,
                    thumbVisibility: true,
                    thickness: 3.5,
                    radius: const Radius.circular(999),
                    thumbColor: colors.secondary.withValues(
                      alpha: dark ? 0.45 : 0.35,
                    ),
                    padding: const EdgeInsets.only(right: 3, top: 8, bottom: 8),
                    child: SingleChildScrollView(
                      controller: _notesScrollController,
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: ReleaseNotesView(
                        blocks: _noteBlocks,
                        colors: colors,
                      ),
                    ),
                  ),
                ),
              if (_progress != null && _busy && _downloaded == null) ...[
                const SizedBox(height: AppSpacing.md),
                // Backup probing keeps no committed progress bar state yet, so
                // an indeterminate bar is shown until a line resumes downloading.
                LinearProgressIndicator(
                  value: _progress!.probing ? null : _progress!.fraction,
                ),
                if (!_progress!.probing) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(_progressLabel(_progress!)),
                ],
              ],
              if (_status != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  _status!,
                  style: TextStyle(color: colors.secondary, fontSize: 13),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 14,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy
                ? (_downloaded == null ? _service.cancel : null)
                : () => Navigator.of(context).pop(),
            child: Text(
              _busy ? '取消下载' : '关闭',
              style: TextStyle(color: colors.secondary),
            ),
          ),
          FilledButton(
            onPressed: _busy ? null : _downloadAndInstall,
            child: Text(
              _busy
                  ? '正在处理…'
                  : _downloaded != null
                  ? '安装更新'
                  : _error != null
                  ? '重新下载'
                  : '下载并安装',
            ),
          ),
        ],
      ),
    );
  }
}
