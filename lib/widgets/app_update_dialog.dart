import 'dart:io';

import 'package:flutter/material.dart';

import '../services/update_service.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';

/// Update dialog driven by [AppUpdateInfo]. Handles the full flow in place:
/// notes → downloading with progress → verified → install hand-off.
class AppUpdateDialog extends StatefulWidget {
  final AppUpdateInfo info;
  final ReaderThemeColors colors;

  const AppUpdateDialog({super.key, required this.info, required this.colors});

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  final _service = UpdateService();

  bool _downloading = false;
  int _received = 0;
  int _total = 0;
  File? _apkFile;
  String? _error;

  Future<void> _startDownload() async {
    setState(() {
      _downloading = true;
      _received = 0;
      _total = widget.info.apkSize;
      _error = null;
    });
    try {
      final file = await _service.downloadApk(
        widget.info,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            if (total > 0) _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _apkFile = file;
      });
    } on Object catch (error) {
      if (!mounted) return;
      final message = switch (error) {
        FormatException e => e.message,
        HttpException e => e.message,
        _ => '下载失败，请检查网络后重试',
      };
      setState(() {
        _downloading = false;
        _error = message;
      });
    }
  }

  Future<void> _install() async {
    final file = _apkFile;
    if (file == null) return;
    if (!await _service.canRequestInstalls()) {
      await _service.openInstallSettings();
      return;
    }
    final started = await _service.installApk(file.path);
    if (!started && mounted) {
      setState(() => _error = '无法打开系统安装器');
    }
  }

  String get _progressText {
    final receivedMb = _received / 1024 / 1024;
    if (_total <= 0) return '已下载 ${receivedMb.toStringAsFixed(1)} MB';
    final totalMb = _total / 1024 / 1024;
    final percent = (_received / _total * 100).clamp(0, 100).toStringAsFixed(0);
    return '${receivedMb.toStringAsFixed(1)} / ${totalMb.toStringAsFixed(1)} MB（$percent%）';
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return AlertDialog(
      backgroundColor: colors.headerBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      title: Text(
        '发现新版本 v${widget.info.version}',
        style: TextStyle(color: colors.text, fontSize: 17),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.info.notes.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: Text(
                    widget.info.notes,
                    style: TextStyle(
                      color: colors.secondary,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            if (_downloading) ...[
              const SizedBox(height: AppSpacing.md),
              LinearProgressIndicator(
                value: _total > 0 ? _received / _total : null,
                color: colors.accent,
                backgroundColor: colors.border,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                _progressText,
                style: TextStyle(color: colors.secondary, fontSize: 12),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                _error!,
                style: TextStyle(color: colors.accent, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!_downloading)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('以后再说', style: TextStyle(color: colors.secondary)),
          ),
        if (_apkFile == null)
          FilledButton(
            onPressed: _downloading ? null : _startDownload,
            style: FilledButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
            child: Text(_error == null ? '立即下载' : '重试'),
          )
        else
          FilledButton(
            onPressed: _install,
            style: FilledButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
            child: const Text('安装'),
          ),
      ],
    );
  }
}
