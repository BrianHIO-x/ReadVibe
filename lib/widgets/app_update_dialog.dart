import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/update_download_service.dart';
import '../services/update_service.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_dialog.dart';

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

  bool _busy = false;
  File? _downloaded;
  UpdateDownloadProgress? _progress;
  String? _status;
  String? _error;

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

  @override
  void dispose() {
    _service.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
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
              if (widget.info.notes.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: SingleChildScrollView(
                    child: Text(
                      widget.info.notes,
                      style: TextStyle(
                        color: colors.secondary,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              if (_progress != null && _busy && _downloaded == null) ...[
                const SizedBox(height: AppSpacing.md),
                LinearProgressIndicator(value: _progress!.fraction),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '${(_progress!.fraction * 100).toStringAsFixed(0)}% · ${(_progress!.received / (1024 * 1024)).toStringAsFixed(1)} / ${(widget.info.apkSize / (1024 * 1024)).toStringAsFixed(1)} MB',
                ),
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
