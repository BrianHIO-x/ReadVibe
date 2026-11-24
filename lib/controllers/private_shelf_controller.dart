import 'dart:async';

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../repositories/reader_repositories.dart';
import '../services/private_shelf_lock.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialog.dart';
import '../widgets/private_shelf_sheets.dart';
import 'reader_window_controller.dart';

/// Owns private shelf lock state, foreground-resume biometric waits,
/// background auto-lock, and dynamic FLAG_SECURE protection.
class PrivateShelfController {
  PrivateShelfController({
    required this.lock,
    required this.storage,
    required this.contextProvider,
    required this.isMounted,
    required this.isOpeningBook,
    required this.allBooksProvider,
    required this.colorsProvider,
    required this.onPrivateModeChanged,
    required this.onConfigChanged,
    required this.onReloadLibrary,
    required this.onMessage,
    required this.onError,
    this.onAppResume,
  }) {
    _lifecycle = AppLifecycleListener(
      onInactive: _handleAppInactive,
      onHide: _handleAppHide,
      onPause: cancelPendingForegroundResume,
      onDetach: cancelPendingForegroundResume,
      onResume: _handleAppResume,
    );
  }

  static const _foregroundResumeTimeout = Duration(seconds: 3);

  final PrivateShelfLock lock;
  final LibraryRepository storage;
  final BuildContext? Function() contextProvider;
  final bool Function() isMounted;
  final bool Function() isOpeningBook;
  final List<Book> Function() allBooksProvider;
  final ReaderThemeColors Function() colorsProvider;
  final void Function(bool privateMode) onPrivateModeChanged;
  final VoidCallback onConfigChanged;
  final Future<void> Function() onReloadLibrary;
  final void Function(String message) onMessage;
  final void Function(String message) onError;
  final VoidCallback? onAppResume;

  late final AppLifecycleListener _lifecycle;
  PrivateShelfConfig _config = const PrivateShelfConfig();
  bool _isOpen = false;
  int _systemDialogDepth = 0;
  int _foregroundPromptDepth = 0;
  Completer<bool>? _pendingForegroundResume;
  Timer? _pendingForegroundTimer;
  bool _flowBusy = false;

  PrivateShelfConfig get config => _config;
  bool get configured => _config.configured;
  bool get isOpen => _isOpen;

  Future<T> runWithSystemDialog<T>(Future<T> Function() action) async {
    _systemDialogDepth++;
    try {
      return await action();
    } finally {
      if (_systemDialogDepth > 0) _systemDialogDepth--;
    }
  }

  Future<void> loadConfig() async {
    try {
      final config = await lock.load();
      if (isMounted()) {
        _config = config;
        onConfigChanged();
      }
    } on Object catch (error, stack) {
      debugPrint('Failed to load private shelf settings: $error');
      debugPrintStack(stackTrace: stack);
    }
  }

  void _handleAppResume() {
    _resolvePendingForegroundResume(true);
    onAppResume?.call();
  }

  void _handleAppHide() {
    _resolvePendingForegroundResume(false);
    lockOnLeave();
  }

  void _resolvePendingForegroundResume(bool resumed) {
    _pendingForegroundTimer?.cancel();
    _pendingForegroundTimer = null;
    final pending = _pendingForegroundResume;
    _pendingForegroundResume = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(resumed);
    }
  }

  void cancelPendingForegroundResume() => _resolvePendingForegroundResume(false);

  void _handleAppInactive() {
    if (_foregroundPromptDepth > 0) return;
    lockOnLeave();
  }

  void lockOnLeave() {
    final context = contextProvider();
    if (!_isOpen ||
        _systemDialogDepth > 0 ||
        !isMounted() ||
        context == null ||
        !context.mounted) {
      return;
    }
    if (!isOpeningBook()) {
      final shelfRoute = ModalRoute.of(context);
      Navigator.of(
        context,
      ).popUntil((route) => route == shelfRoute || route is! PopupRoute);
    }
    setPrivateMode(false);
  }

  void setPrivateMode(bool private) {
    if (!private) {
      cancelPendingForegroundResume();
    }
    unawaited(ReaderWindowController.setSecure(this, private));
    if (_isOpen == private || !isMounted()) return;
    _isOpen = private;
    onPrivateModeChanged(private);
  }

  Future<bool> awaitPrivateShelfForeground() async {
    if (!isMounted()) return false;
    switch (WidgetsBinding.instance.lifecycleState) {
      case null:
      case AppLifecycleState.resumed:
        return true;
      case AppLifecycleState.inactive:
        cancelPendingForegroundResume();
        final completer = Completer<bool>();
        _pendingForegroundResume = completer;
        _pendingForegroundTimer = Timer(_foregroundResumeTimeout, () {
          _resolvePendingForegroundResume(false);
        });
        final resumed = await completer.future;
        return resumed && isMounted();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        return false;
    }
  }

  Future<void> handlePrivateShelfEntry() async {
    if (_flowBusy) return;
    if (_config.configured && _isOpen) {
      setPrivateMode(false);
      return;
    }
    _flowBusy = true;
    try {
      if (!_config.configured) {
        if (await ensureConfigured() &&
            await awaitPrivateShelfForeground() &&
            _config.configured) {
          setPrivateMode(true);
        }
      } else {
        final result = await _unlock('进入隐私书架');
        if (result == PrivateShelfUnlock.unlocked &&
            await awaitPrivateShelfForeground() &&
            _config.configured) {
          setPrivateMode(true);
        }
      }
    } finally {
      _flowBusy = false;
    }
  }

  Future<bool> ensureUnlocked(String purpose) async {
    if (!_config.configured) return false;
    if (_isOpen) return true;
    final result = await _unlock(purpose);
    return result == PrivateShelfUnlock.unlocked &&
        await awaitPrivateShelfForeground() &&
        _config.configured;
  }

  Future<PrivateShelfUnlock> _unlock(String purpose) async {
    final context = contextProvider();
    if (context == null || !context.mounted) {
      return PrivateShelfUnlock.cancelled;
    }
    final result = await unlockPrivateShelf(
      context,
      lock: lock,
      colors: colorsProvider(),
      purpose: purpose,
      onClearShelf: clearPrivateShelf,
    );
    await loadConfig();
    return result;
  }

  Future<bool> ensureConfigured() async {
    final context = contextProvider();
    if (context == null || !context.mounted) return false;
    final saved = await showPrivateShelfPinSetup(
      context,
      lock: lock,
      colors: colorsProvider(),
    );
    final nextContext = contextProvider();
    if (!saved ||
        !isMounted() ||
        nextContext == null ||
        !nextContext.mounted) {
      return false;
    }
    await showPrivateShelfSettings(
      nextContext,
      lock: lock,
      colors: colorsProvider(),
      onDisable: disablePrivateShelf,
      justCreated: true,
    );
    await loadConfig();
    return _config.configured;
  }

  Future<void> managePrivateShelf() async {
    if (_flowBusy || !_config.configured) return;
    _flowBusy = true;
    try {
      if (!_isOpen) {
        final result = await _unlock('修改隐私书架设置');
        if (result != PrivateShelfUnlock.unlocked ||
            !await awaitPrivateShelfForeground() ||
            !_config.configured) {
          return;
        }
      }
      final context = contextProvider();
      if (!isMounted() || context == null || !context.mounted) return;
      _foregroundPromptDepth++;
      try {
        await showPrivateShelfSettings(
          context,
          lock: lock,
          colors: colorsProvider(),
          onDisable: disablePrivateShelf,
        );
      } finally {
        _foregroundPromptDepth--;
      }
      await loadConfig();
    } finally {
      _flowBusy = false;
    }
  }

  Future<bool> disablePrivateShelf() async {
    final context = contextProvider();
    if (context == null || !context.mounted) return false;
    final privateIds = <String>[
      for (final book in allBooksProvider())
        if (book.isPrivate) book.id,
    ];
    final confirmed = await showAppDialog<bool>(
      context: context,
      colors: colorsProvider(),
      builder: (dialogContext) => AppDialog(
        title: const Text('关闭隐私书架'),
        content: Text(
          '关闭之后，隐私书架里的 ${privateIds.length} 本书会移回普通书架。'
          '与此同时，密码和已开启的验证方式也会一并清除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (confirmed != true || !isMounted()) return false;
    try {
      await storage.setBooksPrivate(privateIds, private: false);
      await lock.clear();
    } on Object catch (error, stack) {
      debugPrint('Failed to turn off the private shelf: $error');
      debugPrintStack(stackTrace: stack);
      onError('关闭隐私书架失败，请稍后重试');
      return false;
    }
    setPrivateMode(false);
    await loadConfig();
    await onReloadLibrary();
    onMessage('隐私书架已关闭');
    return true;
  }

  Future<bool> clearPrivateShelf() async {
    final context = contextProvider();
    if (context == null || !context.mounted) return false;
    final privateBooks = <Book>[
      for (final book in allBooksProvider())
        if (book.isPrivate) book,
    ];
    final confirmed = await showAppDialog<bool>(
      context: context,
      colors: colorsProvider(),
      builder: (dialogContext) => AppDialog(
        title: const Text('清空隐私书架'),
        content: Text(
          '没有开启指纹或人脸验证时，只能清空隐私书架后重新设置。'
          '清空会删除其中的 ${privateBooks.length} 本书和阅读记录，并且无法恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          AppDestructiveButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !isMounted()) return false;
    try {
      await storage.deleteBooks(privateBooks.map((book) => book.id));
      await lock.clear();
    } on Object catch (error, stack) {
      debugPrint('Failed to clear the private shelf: $error');
      debugPrintStack(stackTrace: stack);
      onError('清空失败，请稍后重试');
      await onReloadLibrary();
      return false;
    }
    await onReloadLibrary();
    onMessage('隐私书架已清空');
    return true;
  }

  void dispose() {
    cancelPendingForegroundResume();
    _lifecycle.dispose();
    unawaited(ReaderWindowController.setSecure(this, false));
  }
}
