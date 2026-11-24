import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_toast.dart';
import '../widgets/app_update_dialog.dart';

/// Coordinates app version lookup as well as automatic and manual update checks.
class LibraryUpdateController {
  LibraryUpdateController({
    required this.updateChecker,
    required this.contextProvider,
    required this.isMounted,
    required this.isAutomaticEnabled,
    required this.canPromptAutomaticUpdate,
    required this.colorsProvider,
    required this.onMessage,
    required this.onError,
    required this.onVersionUpdated,
  });

  static const _updateCheckInterval = Duration(hours: 24);
  static const _updateRetryDelay = Duration(hours: 1);
  static const _updateCheckedAtKey = 'update_last_checked_at';

  final UpdateChecker updateChecker;
  final BuildContext? Function() contextProvider;
  final bool Function() isMounted;
  final bool Function() isAutomaticEnabled;
  final bool Function() canPromptAutomaticUpdate;
  final ReaderThemeColors Function() colorsProvider;
  final void Function(String message) onMessage;
  final void Function(String message) onError;
  final VoidCallback onVersionUpdated;

  Timer? _automaticUpdateTimer;
  bool _automaticUpdateRunning = false;
  DateTime? _automaticUpdateRetryAt;
  bool _manualUpdateChecking = false;
  bool _updateDialogVisible = false;
  String _applicationVersion = '—';

  String get applicationVersion => _applicationVersion;
  bool get manualUpdateChecking => _manualUpdateChecking;
  bool get updateDialogVisible => _updateDialogVisible;

  Future<void> loadApplicationVersion() async {
    try {
      final version = await updateChecker.currentVersion();
      if (isMounted() && version.trim().isNotEmpty) {
        _applicationVersion = version.trim();
        onVersionUpdated();
      }
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to read application version: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void syncAutomaticUpdateCheck() {
    _automaticUpdateTimer?.cancel();
    _automaticUpdateTimer = null;
    if (!isAutomaticEnabled()) return;
    unawaited(runAutomaticUpdateCheck());
  }

  void _scheduleAutomaticUpdateCheck(Duration delay) {
    _automaticUpdateTimer?.cancel();
    _automaticUpdateTimer = null;
    if (!isMounted() || !isAutomaticEnabled()) return;
    _automaticUpdateTimer = Timer(delay, () {
      _automaticUpdateTimer = null;
      unawaited(runAutomaticUpdateCheck());
    });
  }

  bool get _canRunPrompt =>
      isMounted() &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      !_manualUpdateChecking &&
      !_updateDialogVisible &&
      canPromptAutomaticUpdate();

  Future<void> runAutomaticUpdateCheck() async {
    if (_automaticUpdateRunning || !isAutomaticEnabled() || !_canRunPrompt) {
      return;
    }
    _automaticUpdateRunning = true;
    try {
      final now = DateTime.now();
      final retryAt = _automaticUpdateRetryAt;
      if (retryAt != null && now.isBefore(retryAt)) {
        _scheduleAutomaticUpdateCheck(retryAt.difference(now));
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      final checkedAt = DateTime.fromMillisecondsSinceEpoch(
        prefs.getInt(_updateCheckedAtKey) ?? 0,
      );
      final due = checkedAt.add(_updateCheckInterval);
      if (now.isBefore(due) && !checkedAt.isAfter(now)) {
        _scheduleAutomaticUpdateCheck(due.difference(now));
        return;
      }

      final result = await updateChecker.checkForUpdate();
      if (!isMounted() || !isAutomaticEnabled()) return;
      if (result.failed) {
        _automaticUpdateRetryAt = DateTime.now().add(_updateRetryDelay);
        _scheduleAutomaticUpdateCheck(_updateRetryDelay);
        return;
      }
      _automaticUpdateRetryAt = null;
      final info = result.info;
      if (info != null && !_canRunPrompt) return;
      await prefs.setInt(
        _updateCheckedAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      _scheduleAutomaticUpdateCheck(_updateCheckInterval);
      if (info != null) await showUpdateDialog(info);
    } on Object catch (error, stackTrace) {
      debugPrint('Automatic update check failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      _automaticUpdateRunning = false;
    }
  }

  Future<void> checkUpdateManually() async {
    final context = contextProvider();
    if (context == null ||
        !context.mounted ||
        _manualUpdateChecking ||
        _updateDialogVisible) {
      return;
    }
    _manualUpdateChecking = true;
    try {
      AppToast.loading(context, '正在检查更新…', colors: colorsProvider());
      final result = await updateChecker.checkForUpdate();
      final currentContext = contextProvider();
      if (!isMounted() || currentContext == null || !currentContext.mounted) {
        return;
      }
      AppToast.hide(currentContext);
      final info = result.info;
      if (info != null) {
        await showUpdateDialog(info);
        return;
      }
      if (result.failed) {
        onError('更新线路暂时不可用，请检查网络后重试');
        return;
      }
      onMessage('当前已是最新版本');
    } on Object {
      final currentContext = contextProvider();
      if (isMounted() && currentContext != null && currentContext.mounted) {
        AppToast.hide(currentContext);
        onError('检查更新失败，请稍后重试');
      }
    } finally {
      _manualUpdateChecking = false;
    }
  }

  Future<void> showUpdateDialog(AppUpdateInfo info) async {
    final context = contextProvider();
    if (_updateDialogVisible || context == null || !context.mounted) return;
    _updateDialogVisible = true;
    try {
      final colors = colorsProvider();
      await showAppDialog<void>(
        context: context,
        colors: colors,
        barrierDismissible: false,
        builder: (_) => AppUpdateDialog(info: info, colors: colors),
      );
    } finally {
      _updateDialogVisible = false;
    }
  }

  void dispose() {
    _automaticUpdateTimer?.cancel();
    _automaticUpdateTimer = null;
  }
}
