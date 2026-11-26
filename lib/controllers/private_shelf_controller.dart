import 'dart:async';

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../repositories/reader_repositories.dart';
import '../services/private_shelf_lock.dart';
import '../services/reading_session_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialog.dart';
import '../widgets/private_shelf_sheets.dart';
import 'private_session_gate.dart';
import 'reader_window_controller.dart';

/// Owns private shelf lock state, monotonic lock-delay checks, cold/warm
/// in-place lock-gate protection, and dynamic FLAG_SECURE protection.
class PrivateShelfController {
  PrivateShelfController({
    required this.lock,
    required this.storage,
    required this.sessionStore,
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
    this.onRestorePrivateBook,
    this.onAppResume,
    PrivateSessionGate? gate,
  }) : gate = gate ?? PrivateSessionGate.instance {
    this.gate.attach(
      lock: lock,
      onUnlocked: _handleGateUnlocked,
      onReturnToNormalShelf: _handleGateReturnToNormalShelf,
      onClearShelf: clearPrivateShelf,
    );
    _lifecycle = AppLifecycleListener(
      onHide: _handleAppLeave,
      onPause: _handleAppLeave,
      onDetach: cancelPendingForegroundResume,
      onResume: _handleAppResume,
    );
  }

  static const _foregroundResumeTimeout = Duration(seconds: 3);

  final PrivateShelfLock lock;
  final LibraryRepository storage;
  final ReadingSessionStore sessionStore;
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
  final Future<void> Function(String bookId)? onRestorePrivateBook;
  final VoidCallback? onAppResume;
  final PrivateSessionGate gate;

  late final AppLifecycleListener _lifecycle;
  PrivateShelfConfig _config = const PrivateShelfConfig();
  bool _isOpen = false;
  int _systemDialogDepth = 0;
  int _foregroundPromptDepth = 0;
  Completer<bool>? _pendingForegroundResume;
  Timer? _pendingForegroundTimer;
  bool _flowBusy = false;

  ({int elapsedRealtimeMs, int bootCount, int wallTimeMs})?
  _backgroundLeftClock;
  bool _awaitingTimedUnlockCheck = false;
  bool _pendingColdStartRestore = false;
  String? _pendingColdStartBookId;

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

  void syncThemeColors(ReaderThemeColors colors) {
    gate.updateColors(colors);
  }

  void _handleAppResume() {
    _resolvePendingForegroundResume(true);
    if (gate.locked) {
      gate.onAppResumed();
    } else if (_awaitingTimedUnlockCheck) {
      unawaited(_evaluateTimedBackgroundLock());
    }
    onAppResume?.call();
  }

  void _handleAppLeave() {
    _resolvePendingForegroundResume(false);
    unawaited(_handleLeaveImpl());
  }

  Future<void> _handleLeaveImpl() async {
    if (!_isOpen ||
        _systemDialogDepth > 0 ||
        _foregroundPromptDepth > 0 ||
        gate.authenticating ||
        !_config.configured ||
        !isMounted()) {
      return;
    }
    if (gate.locked) return;
    syncThemeColors(colorsProvider());
    if (_config.lockDelay == PrivateShelfLockDelay.immediate) {
      _awaitingTimedUnlockCheck = false;
      _backgroundLeftClock = null;
      gate.lock(
        purpose: '验证以继续隐私空间',
        hasPendingBook: false,
      );
      return;
    }
    if (_awaitingTimedUnlockCheck) return;
    _awaitingTimedUnlockCheck = true;
    _backgroundLeftClock = await lock.readMonotonicClock();
  }

  Future<void> _evaluateTimedBackgroundLock() async {
    _awaitingTimedUnlockCheck = false;
    final left = _backgroundLeftClock;
    _backgroundLeftClock = null;
    if (!_isOpen || !_config.configured || gate.locked || !isMounted()) return;
    final now = await lock.readMonotonicClock();
    var expired = false;
    if (left == null || now == null) {
      expired = true;
    } else if (left.bootCount >= 0 && now.bootCount != left.bootCount) {
      expired = true;
    } else if (now.elapsedRealtimeMs < left.elapsedRealtimeMs) {
      expired = true;
    } else {
      final elapsedMs = now.elapsedRealtimeMs - left.elapsedRealtimeMs;
      expired = elapsedMs >= _config.lockDelay.duration.inMilliseconds;
    }
    if (expired && isMounted()) {
      syncThemeColors(colorsProvider());
      gate.lock(purpose: '已超过自动锁定时长，请验证后继续');
      gate.onAppResumed();
    }
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

  /// Locks immediately into an opaque full-screen gate on cold start when the
  /// previous session was inside the private shelf or reading a private book.
  void requestColdStartRestore({String? bookId}) {
    if (!_config.configured) {
      unawaited(sessionStore.clearPrivateSession());
      return;
    }
    _pendingColdStartRestore = true;
    _pendingColdStartBookId = bookId;
    syncThemeColors(colorsProvider());
    gate.lock(
      purpose: bookId != null ? '验证后回到上次阅读的隐私书籍' : '验证后回到隐私书架',
      hasPendingBook: bookId != null,
    );
  }

  Future<void> _handleGateUnlocked() async {
    await loadConfig();
    if (!isMounted()) return;
    if (_pendingColdStartRestore) {
      final bookId = _pendingColdStartBookId;
      _pendingColdStartRestore = false;
      _pendingColdStartBookId = null;
      setPrivateMode(true, updateSession: bookId == null);
      if (bookId != null) {
        unawaited(onRestorePrivateBook?.call(bookId));
      } else {
        unawaited(sessionStore.markPrivateShelf());
      }
      return;
    }
    if (_isOpen) {
      unawaited(ReaderWindowController.setSecure(this, true));
    }
  }

  Future<void> _handleGateReturnToNormalShelf() async {
    _pendingColdStartRestore = false;
    _pendingColdStartBookId = null;
    _awaitingTimedUnlockCheck = false;
    _backgroundLeftClock = null;
    appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
    setPrivateMode(false);
    await sessionStore.markLibrary();
  }

  void setPrivateMode(bool private, {bool updateSession = true}) {
    if (!private) {
      cancelPendingForegroundResume();
      _awaitingTimedUnlockCheck = false;
      _backgroundLeftClock = null;
    }
    unawaited(ReaderWindowController.setSecure(this, private));
    if (!isMounted()) return;
    if (updateSession && _isOpen != private) {
      unawaited(
        private ? sessionStore.markPrivateShelf() : sessionStore.markLibrary(),
      );
    }
    if (_isOpen == private) return;
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
    if (_isOpen && !gate.locked) return true;
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
      onClearShelf: () => clearPrivateShelf(requireConfirm: true),
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
      await sessionStore.clearPrivateSession();
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

  Future<bool> clearPrivateShelf({bool requireConfirm = true}) async {
    final privateBooks = <Book>[
      for (final book in allBooksProvider())
        if (book.isPrivate) book,
    ];
    if (requireConfirm) {
      final context = contextProvider();
      if (context == null || !context.mounted) return false;
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
    }
    try {
      await storage.deleteBooks(privateBooks.map((book) => book.id));
      await lock.clear();
      await sessionStore.clearPrivateSession();
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
