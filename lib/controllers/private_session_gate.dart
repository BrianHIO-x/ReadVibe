import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/reader_settings.dart';
import '../services/private_shelf_lock.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import '../widgets/private_shelf_sheets.dart';
import 'reader_window_controller.dart';

/// Shared navigator key used by [PrivateSessionGate] when returning directly
/// to the normal bookshelf from a locked private reader route.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Coordinates the full-screen privacy veil mounted above the app Navigator.
///
/// Instead of resetting the shelf underneath an open private book when leaving
/// the app, ReadVibe preserves the private shelf/reader route stack in memory
/// and covers it with an opaque lock gate until re-authenticated.
class PrivateSessionGate extends ChangeNotifier {
  PrivateSessionGate._();

  static final PrivateSessionGate instance = PrivateSessionGate._();

  bool _locked = false;
  String _purpose = '验证后继续访问隐私空间';
  bool _hasPendingBook = false;
  ReaderThemeColors? _colors;
  PrivateShelfLock? _lock;
  PrivateShelfBiometric? _usableBiometric;
  String? _notice;
  bool _busy = false;
  bool _authenticating = false;
  bool _autoBiometricRequested = false;
  bool _resettingPin = false;
  bool _confirmingClearShelf = false;
  int _lockGeneration = 0;
  bool _backObserverInstalled = false;

  Future<void> Function()? _onUnlocked;
  Future<void> Function()? _onReturnToNormalShelf;
  Future<bool> Function({bool requireConfirm})? _onClearShelf;

  bool get locked => _locked;
  bool get authenticating => _authenticating;
  String get purpose => _purpose;
  bool get hasPendingBook => _hasPendingBook;
  ReaderThemeColors? get colors => _colors;

  /// Registers the Back-interception observer before [runApp] so it sits ahead
  /// of MaterialApp/WidgetsApp in `WidgetsBinding` observer dispatch order.
  void installBackObserver() {
    if (_backObserverInstalled) return;
    _backObserverInstalled = true;
    WidgetsBinding.instance.addObserver(_PrivateGateBackObserver(this));
  }

  void attach({
    required PrivateShelfLock lock,
    required Future<void> Function() onUnlocked,
    required Future<void> Function() onReturnToNormalShelf,
    required Future<bool> Function({bool requireConfirm}) onClearShelf,
  }) {
    _lock = lock;
    _onUnlocked = onUnlocked;
    _onReturnToNormalShelf = onReturnToNormalShelf;
    _onClearShelf = onClearShelf;
  }

  void updateColors(ReaderThemeColors colors) {
    if (_colors?.background == colors.background &&
        _colors?.text == colors.text &&
        _colors?.accent == colors.accent) {
      return;
    }
    _colors = colors;
    if (_locked) notifyListeners();
  }

  void lock({
    required String purpose,
    bool hasPendingBook = false,
  }) {
    if (_locked &&
        _purpose == purpose &&
        _hasPendingBook == hasPendingBook) {
      return;
    }
    _lockGeneration++;
    _locked = true;
    _purpose = purpose;
    _hasPendingBook = hasPendingBook;
    _notice = null;
    _busy = false;
    _resettingPin = false;
    _confirmingClearShelf = false;
    _autoBiometricAttempted();
    unawaited(ReaderWindowController.setSecure(this, true));
    notifyListeners();
    unawaited(
      _prepareBiometrics(
        generation: _lockGeneration,
        autoTriggerIfResumed: true,
      ),
    );
  }

  void _autoBiometricAttempted() {
    _autoBiometricRequested = false;
  }

  void onAppResumed() {
    if (!_locked || _authenticating || _autoBiometricRequested) return;
    unawaited(
      _prepareBiometrics(
        generation: _lockGeneration,
        autoTriggerIfResumed: true,
      ),
    );
  }

  Future<void> _prepareBiometrics({
    required int generation,
    required bool autoTriggerIfResumed,
  }) async {
    final lock = _lock;
    if (lock == null || !_locked) return;
    final config = await lock.load();
    if (!_locked || generation != _lockGeneration) return;
    if (!config.configured) {
      await unlockNow();
      return;
    }
    PrivateShelfBiometric? usable;
    final preferred = config.unlockBiometric;
    if (preferred != null) {
      final support = await lock.biometricSupport();
      if (!_locked || generation != _lockGeneration) return;
      if (support.canUse(preferred)) {
        usable = preferred;
      } else {
        _notice ??= '${preferred.label}验证暂时不可用，请输入密码';
      }
    }
    _usableBiometric = usable;
    notifyListeners();

    if (autoTriggerIfResumed &&
        usable != null &&
        !_autoBiometricRequested &&
        !_authenticating &&
        !_resettingPin &&
        !_confirmingClearShelf &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _autoBiometricRequested = true;
      await triggerBiometric();
    }
  }

  Future<void> triggerBiometric() async {
    final lock = _lock;
    final kind = _usableBiometric;
    if (!_locked || _authenticating || lock == null || kind == null) return;
    _autoBiometricRequested = true;
    _authenticating = true;
    _busy = true;
    notifyListeners();
    try {
      final outcome = await lock.authenticate(kind, purpose: _purpose);
      if (!_locked) return;
      if (outcome == BiometricOutcome.success) {
        await completeUnlock();
        return;
      }
      final notice = biometricNotice(kind, outcome);
      if (notice != null) _notice = notice;
    } finally {
      _authenticating = false;
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> handleForgotPin() async {
    final lock = _lock;
    if (!_locked || _busy || lock == null) return;
    final kind = _usableBiometric;
    if (kind == null) {
      _confirmingClearShelf = true;
      _notice = null;
      notifyListeners();
      return;
    }
    _authenticating = true;
    _busy = true;
    notifyListeners();
    try {
      final outcome = await lock.authenticate(
        kind,
        purpose: '验证后重新设置密码',
        fallbackLabel: '取消',
      );
      if (!_locked) return;
      if (outcome == BiometricOutcome.success) {
        _resettingPin = true;
        _notice = null;
      } else {
        final msg = biometricNotice(kind, outcome);
        if (msg != null) _notice = msg;
      }
    } finally {
      _authenticating = false;
      _busy = false;
      notifyListeners();
    }
  }

  void cancelResetOrClear() {
    if (!_locked) return;
    _resettingPin = false;
    _confirmingClearShelf = false;
    notifyListeners();
  }

  Future<void> confirmClearShelf() async {
    final handler = _onClearShelf;
    if (!_locked || _busy || handler == null) return;
    _busy = true;
    notifyListeners();
    try {
      final cleared = await handler(requireConfirm: false);
      if (cleared) {
        await returnToNormalShelf();
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> completeUnlock() async {
    if (!_locked) return;
    _busy = true;
    notifyListeners();
    try {
      await _onUnlocked?.call();
      await unlockNow();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> unlockNow() async {
    _lockGeneration++;
    _locked = false;
    _notice = null;
    _resettingPin = false;
    _confirmingClearShelf = false;
    _autoBiometricRequested = false;
    _busy = false;
    unawaited(ReaderWindowController.setSecure(this, false));
    notifyListeners();
  }

  Future<void> returnToNormalShelf() async {
    _lockGeneration++;
    _busy = true;
    notifyListeners();
    try {
      await _onReturnToNormalShelf?.call();
      _locked = false;
      _notice = null;
      _resettingPin = false;
      _confirmingClearShelf = false;
      _autoBiometricRequested = false;
    } finally {
      _busy = false;
      unawaited(ReaderWindowController.setSecure(this, false));
      notifyListeners();
    }
  }
}

class _PrivateGateBackObserver with WidgetsBindingObserver {
  _PrivateGateBackObserver(this._gate);

  final PrivateSessionGate _gate;

  @override
  Future<bool> didPopRoute() async {
    if (!_gate.locked) return false;
    if (_gate._resettingPin || _gate._confirmingClearShelf) {
      _gate.cancelResetOrClear();
    }
    return true;
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) => _gate.locked;

  @override
  void handleCommitBackGesture() {
    if (_gate.locked && (_gate._resettingPin || _gate._confirmingClearShelf)) {
      _gate.cancelResetOrClear();
    }
  }
}

/// Root overlay blocking access to private shelf/reader views when locked.
class PrivateLockOverlay extends StatelessWidget {
  const PrivateLockOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final gate = PrivateSessionGate.instance;
    return ListenableBuilder(
      listenable: gate,
      builder: (context, _) {
        if (!gate.locked) return child;
        final colors =
            gate.colors ??
            AppTheme.getReaderTheme(
              ReaderThemeMode.system,
              systemBrightness: MediaQuery.platformBrightnessOf(context),
            );
        final lock = gate._lock ?? PrivateShelfLock();
        final danger = AppOverlayTheme.danger(colors);
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned.fill(
              child: PopScope<void>(
                canPop: false,
                child: AnnotatedRegion<SystemUiOverlayStyle>(
                  value: AppTheme.systemUiOverlayStyle(colors),
                  child: Material(
                    color: colors.background,
                    child: SafeArea(
                      child: Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xl,
                            vertical: AppSpacing.xl,
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 400),
                            child: gate._confirmingClearShelf
                                ? _buildClearConfirm(gate, colors, danger)
                                : gate._resettingPin
                                ? _buildResetPin(gate, lock, colors)
                                : _buildPinLock(gate, lock, colors),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPinLock(
    PrivateSessionGate gate,
    PrivateShelfLock lock,
    ReaderThemeColors colors,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PrivateShelfPinPad(
          lock: lock,
          colors: colors,
          title: '隐私空间已锁定',
          verifying: true,
          purpose: gate.purpose,
          biometric: gate._usableBiometric,
          notice: gate._notice,
          busy: gate._busy,
          onUnlocked: () => unawaited(gate.completeUnlock()),
          onForgot: () => unawaited(gate.handleForgotPin()),
          onBiometricPressed: gate.triggerBiometric,
        ),
        const SizedBox(height: AppSpacing.md),
        OutlinedButton.icon(
          onPressed: gate._busy
              ? null
              : () => unawaited(gate.returnToNormalShelf()),
          icon: const Icon(Icons.home_outlined, size: 18),
          label: const Text('返回普通书架'),
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.secondary,
            side: BorderSide(color: colors.border),
          ),
        ),
      ],
    );
  }

  Widget _buildResetPin(
    PrivateSessionGate gate,
    PrivateShelfLock lock,
    ReaderThemeColors colors,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PrivateShelfPinPad(
          lock: lock,
          colors: colors,
          title: '设置新密码',
          verifying: false,
          busy: gate._busy,
          onCreated: () => unawaited(gate.completeUnlock()),
        ),
        const SizedBox(height: AppSpacing.md),
        TextButton(
          onPressed: gate._busy ? null : gate.cancelResetOrClear,
          child: const Text('取消重设'),
        ),
      ],
    );
  }

  Widget _buildClearConfirm(
    PrivateSessionGate gate,
    ReaderThemeColors colors,
    Color danger,
  ) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: colors.headerBg,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 40, color: danger),
          const SizedBox(height: AppSpacing.md),
          Text(
            '清空隐私书架',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: colors.text,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '未开启生物识别验证时，只能清空隐私书架中的书籍与密码后重新设置，且无法恢复。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: colors.secondary,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: gate._busy ? null : gate.cancelResetOrClear,
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: FilledButton(
                  onPressed: gate._busy
                      ? null
                      : () => unawaited(gate.confirmClearShelf()),
                  style: FilledButton.styleFrom(
                    backgroundColor: danger,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('确认清空'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
