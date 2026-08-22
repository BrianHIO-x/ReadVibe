import 'package:flutter/material.dart';

import '../services/update_service.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';

/// Opens GitHub Releases in the browser so ReadVibe does not need Android's
/// package-installer permission.
class AppUpdateDialog extends StatefulWidget {
  final AppUpdateInfo info;
  final ReaderThemeColors colors;

  const AppUpdateDialog({super.key, required this.info, required this.colors});

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  final _service = UpdateService();

  bool _opening = false;
  String? _error;

  Future<void> _openReleasePage() async {
    setState(() {
      _opening = true;
      _error = null;
    });
    final opened = await _service.openReleasePage(widget.info);
    if (!mounted) return;
    setState(() {
      _opening = false;
      if (!opened) _error = '无法打开浏览器，请前往 GitHub Releases 下载';
    });
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
            if (widget.info.sha256 != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                'SHA-256：${widget.info.sha256}',
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
        if (!_opening)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('以后再说', style: TextStyle(color: colors.secondary)),
          ),
        FilledButton(
          onPressed: _opening ? null : _openReleasePage,
          style: FilledButton.styleFrom(
            backgroundColor: colors.accent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
          child: Text(_opening ? '正在打开…' : '前往 GitHub 下载'),
        ),
      ],
    );
  }
}
