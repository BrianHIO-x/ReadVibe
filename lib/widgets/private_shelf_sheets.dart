import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/private_shelf_lock.dart';
import '../theme/app_motion.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_sheet.dart';
import 'app_toast.dart';

enum PrivateShelfUnlock { unlocked, cancelled, cleared }

enum _PinOutcome { unlocked, forgot }

/// Asks for a new six-digit PIN twice and saves it.
Future<bool> showPrivateShelfPinSetup(
  BuildContext context, {
  required PrivateShelfLock lock,
  required ReaderThemeColors colors,
  String title = '设置隐私书架密码',
}) async {
  final saved = await showAppSheet<bool>(
    context: context,
    colors: colors,
    builder: (_) => _PinSheet(lock: lock, colors: colors, title: title),
  );
  return saved == true;
}

/// Verifies the reader before a private shelf action.
///
/// The default biometric is tried first through the system prompt, and the
/// PIN pad follows when it is declined or fails. A forgotten PIN is reset
/// through that same biometric. Without one, [onClearShelf] is the only way
/// back, and the caller decides what clearing involves.
Future<PrivateShelfUnlock> unlockPrivateShelf(
  BuildContext context, {
  required PrivateShelfLock lock,
  required ReaderThemeColors colors,
  required String purpose,
  required Future<bool> Function() onClearShelf,
}) async {
  final config = await lock.load();
  if (!config.configured) return PrivateShelfUnlock.cancelled;
  final kind = config.unlockBiometric;
  PrivateShelfBiometric? usable;
  String? notice;
  if (kind != null) {
    final support = await lock.biometricSupport();
    if (support.canUse(kind)) {
      usable = kind;
      final outcome = await lock.authenticate(kind, purpose: purpose);
      if (outcome == BiometricOutcome.success) {
        return PrivateShelfUnlock.unlocked;
      }
      notice = _biometricNotice(kind, outcome);
    } else {
      notice = '${kind.label}验证暂时不可用，请输入密码';
    }
  }
  if (!context.mounted) return PrivateShelfUnlock.cancelled;
  final result = await showAppSheet<_PinOutcome>(
    context: context,
    colors: colors,
    builder: (_) => _PinSheet(
      lock: lock,
      colors: colors,
      title: '输入隐私书架密码',
      verifying: true,
      purpose: purpose,
      biometric: usable,
      notice: notice,
    ),
  );
  switch (result) {
    case _PinOutcome.unlocked:
      return PrivateShelfUnlock.unlocked;
    case null:
      return PrivateShelfUnlock.cancelled;
    case _PinOutcome.forgot:
      if (!context.mounted) return PrivateShelfUnlock.cancelled;
      if (usable == null) {
        return await onClearShelf()
            ? PrivateShelfUnlock.cleared
            : PrivateShelfUnlock.cancelled;
      }
      final outcome = await lock.authenticate(
        usable,
        purpose: '验证后重新设置密码',
        fallbackLabel: '取消',
      );
      if (outcome != BiometricOutcome.success) {
        final message = _biometricNotice(usable, outcome);
        if (message != null && context.mounted) {
          AppToast.error(context, message, colors: colors);
        }
        return PrivateShelfUnlock.cancelled;
      }
      if (!context.mounted) return PrivateShelfUnlock.cancelled;
      final saved = await showPrivateShelfPinSetup(
        context,
        lock: lock,
        colors: colors,
        title: '设置新密码',
      );
      return saved ? PrivateShelfUnlock.unlocked : PrivateShelfUnlock.cancelled;
  }
}

/// Lets the reader switch biometrics, pick the default, change the PIN or
/// turn the private shelf off. [onDisable] returns whether it went through.
Future<void> showPrivateShelfSettings(
  BuildContext context, {
  required PrivateShelfLock lock,
  required ReaderThemeColors colors,
  required Future<bool> Function() onDisable,
  bool justCreated = false,
}) => showAppSheet<void>(
  context: context,
  colors: colors,
  builder: (_) => _PrivateShelfSettingsSheet(
    lock: lock,
    colors: colors,
    onDisable: onDisable,
    justCreated: justCreated,
  ),
);

String? _biometricNotice(
  PrivateShelfBiometric kind,
  BiometricOutcome outcome,
) => switch (outcome) {
  BiometricOutcome.success ||
  BiometricOutcome.cancelled ||
  BiometricOutcome.fallback => null,
  BiometricOutcome.lockout => '${kind.label}验证次数过多，请输入密码',
  BiometricOutcome.notEnrolled => '系统里还没有可用的${kind.label}，请输入密码',
  BiometricOutcome.unavailable ||
  BiometricOutcome.error => '${kind.label}验证没有完成，请输入密码',
};

IconData _biometricIcon(PrivateShelfBiometric kind) => switch (kind) {
  PrivateShelfBiometric.fingerprint => Icons.fingerprint,
  PrivateShelfBiometric.face => Icons.face_outlined,
};

/// Six-digit pad used both to create and to verify a PIN.
///
/// Creating pops a bool once the PIN is saved. Verifying pops a
/// [_PinOutcome]. The pad draws its own keys so the system keyboard, and any
/// input method that learns from typing, never sees the PIN.
class _PinSheet extends StatefulWidget {
  const _PinSheet({
    required this.lock,
    required this.colors,
    required this.title,
    this.verifying = false,
    this.purpose,
    this.biometric,
    this.notice,
  });

  final PrivateShelfLock lock;
  final ReaderThemeColors colors;
  final String title;
  final bool verifying;
  final String? purpose;
  final PrivateShelfBiometric? biometric;
  final String? notice;

  @override
  State<_PinSheet> createState() => _PinSheetState();
}

class _PinSheetState extends State<_PinSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  String _digits = '';
  String? _firstEntry;
  String? _message;
  bool _error = false;
  bool _busy = false;
  DateTime? _lockedUntil;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _message = widget.notice;
    _error = widget.notice != null;
    if (widget.verifying) unawaited(_restoreLockout());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _shake.dispose();
    super.dispose();
  }

  Future<void> _restoreLockout() async {
    final until = await widget.lock.lockedUntil();
    if (until != null && mounted) _startLockout(until);
  }

  void _startLockout(DateTime until) {
    _ticker?.cancel();
    setState(() => _lockedUntil = until);
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (!DateTime.now().isBefore(until)) {
        timer.cancel();
        setState(() {
          _lockedUntil = null;
          _message = null;
          _error = false;
        });
      } else {
        setState(() {});
      }
    });
  }

  bool get _locked => _lockedUntil != null;

  void _press(int digit) {
    if (_busy || _locked || _digits.length >= PrivateShelfLock.pinLength) {
      return;
    }
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _digits += '$digit';
      if (_digits.length == 1 && _error) {
        _message = null;
        _error = false;
      }
    });
    if (_digits.length == PrivateShelfLock.pinLength) {
      unawaited(_complete(_digits));
    }
  }

  void _backspace() {
    if (_busy || _locked || _digits.isEmpty) return;
    setState(() => _digits = _digits.substring(0, _digits.length - 1));
  }

  Future<void> _complete(String pin) async {
    setState(() => _busy = true);
    // Let the last dot fill before the pad clears or closes.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    if (!widget.verifying) {
      await _completeCreation(pin);
      return;
    }
    final check = await widget.lock.verifyPin(pin);
    if (!mounted) return;
    if (check.accepted) {
      Navigator.of(context).pop(_PinOutcome.unlocked);
      return;
    }
    final until = check.lockedUntil;
    if (until != null) {
      _reject(null);
      _startLockout(until);
    } else {
      _reject('密码错误（剩余 ${check.remaining} 次机会）');
    }
  }

  Future<void> _completeCreation(String pin) async {
    final first = _firstEntry;
    if (first == null) {
      setState(() {
        _firstEntry = pin;
        _digits = '';
        _busy = false;
      });
      return;
    }
    if (first != pin) {
      _firstEntry = null;
      _reject('两次输入的密码不一致');
      return;
    }
    try {
      await widget.lock.setPin(pin);
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      debugPrint('Failed to save private shelf PIN: $error');
      _firstEntry = null;
      _reject('密码保存失败，请重新设置');
    }
  }

  void _reject(String? message) {
    if (!mounted) return;
    unawaited(HapticFeedback.heavyImpact());
    setState(() {
      _digits = '';
      _busy = false;
      _message = message;
      _error = true;
    });
    _shake.forward(from: 0);
  }

  Future<void> _useBiometric() async {
    final kind = widget.biometric;
    if (kind == null || _busy) return;
    setState(() => _busy = true);
    final outcome = await widget.lock.authenticate(
      kind,
      purpose: widget.purpose ?? '进入隐私书架',
    );
    if (!mounted) return;
    if (outcome == BiometricOutcome.success) {
      Navigator.of(context).pop(_PinOutcome.unlocked);
      return;
    }
    final notice = _biometricNotice(kind, outcome);
    setState(() {
      _busy = false;
      if (notice != null) {
        _message = notice;
        _error = true;
      }
    });
  }

  String get _statusText {
    final until = _lockedUntil;
    if (until != null) {
      final seconds = math.max(1, until.difference(DateTime.now()).inSeconds);
      return seconds >= 60
          ? '请在 ${seconds ~/ 60} 分 ${seconds % 60} 秒后重试'
          : '请在 $seconds 秒后重试';
    }
    if (_message != null) return _message!;
    if (widget.verifying) return widget.purpose ?? '';
    return _firstEntry == null ? '请输入 6 位数字密码' : '请再输入一次，确认新密码';
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final danger = AppOverlayTheme.danger(colors);
    return AppSheetSurface(
      colors: colors,
      // A landscape phone is shorter than the pad, so it scrolls there.
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.xl,
          AppSpacing.sm,
          AppSpacing.sm,
          AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close_rounded, color: colors.secondary),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.lg),
              child: Column(
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 34,
                    color: colors.accent,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    widget.title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: colors.text,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  SizedBox(
                    height: 40,
                    child: Text(
                      _statusText,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: _error || _locked ? danger : colors.secondary,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AnimatedBuilder(
                    animation: _shake,
                    builder: (context, child) {
                      final t = _shake.value;
                      return Transform.translate(
                        offset: Offset(
                          math.sin(t * math.pi * 6) * 10 * (1 - t),
                          0,
                        ),
                        child: child,
                      );
                    },
                    child: _buildDots(colors),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  _buildKeypad(colors),
                  if (widget.verifying)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(_PinOutcome.forgot),
                      child: const Text('忘记密码'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDots(ReaderThemeColors colors) {
    return Semantics(
      label: '已输入 ${_digits.length} 位，共 ${PrivateShelfLock.pinLength} 位',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < PrivateShelfLock.pinLength; i++)
            AnimatedContainer(
              duration: AppMotion.quick,
              width: 14,
              height: 14,
              margin: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < _digits.length ? colors.accent : Colors.transparent,
                border: Border.all(
                  color: i < _digits.length
                      ? colors.accent
                      : colors.secondary.withValues(alpha: 0.6),
                  width: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildKeypad(ReaderThemeColors colors) {
    final enabled = !_busy && !_locked;
    final biometric = widget.biometric;
    Widget key({required Widget child, String? label, VoidCallback? onTap}) {
      return Semantics(
        button: true,
        label: label,
        child: SizedBox(
          width: 76,
          height: 60,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Center(child: child),
          ),
        ),
      );
    }

    Widget digit(int value) => key(
      label: '$value',
      onTap: enabled ? () => _press(value) : null,
      child: Text(
        '$value',
        style: TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w500,
          color: enabled ? colors.text : colors.secondary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );

    Widget row(List<Widget> keys) => Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < keys.length; i++) ...[
            if (i > 0) const SizedBox(width: 20),
            keys[i],
          ],
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row([digit(1), digit(2), digit(3)]),
        row([digit(4), digit(5), digit(6)]),
        row([digit(7), digit(8), digit(9)]),
        row([
          biometric == null
              ? const SizedBox(width: 76, height: 60)
              : key(
                  label: '使用${biometric.label}验证',
                  onTap: _busy ? null : _useBiometric,
                  child: Icon(
                    _biometricIcon(biometric),
                    size: 28,
                    color: colors.accent,
                  ),
                ),
          digit(0),
          key(
            label: '删除',
            onTap: enabled && _digits.isNotEmpty ? _backspace : null,
            child: Icon(
              Icons.backspace_outlined,
              size: 24,
              color: colors.secondary,
            ),
          ),
        ]),
      ],
    );
  }
}

class _PrivateShelfSettingsSheet extends StatefulWidget {
  const _PrivateShelfSettingsSheet({
    required this.lock,
    required this.colors,
    required this.onDisable,
    required this.justCreated,
  });

  final PrivateShelfLock lock;
  final ReaderThemeColors colors;
  final Future<bool> Function() onDisable;
  final bool justCreated;

  @override
  State<_PrivateShelfSettingsSheet> createState() =>
      _PrivateShelfSettingsSheetState();
}

class _PrivateShelfSettingsSheetState
    extends State<_PrivateShelfSettingsSheet> {
  PrivateShelfConfig _config = const PrivateShelfConfig();
  BiometricSupport _support = const BiometricSupport();
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final results = await Future.wait<Object>([
      widget.lock.load(),
      widget.lock.biometricSupport(),
    ]);
    if (!mounted) return;
    setState(() {
      _config = results[0] as PrivateShelfConfig;
      _support = results[1] as BiometricSupport;
      _loaded = true;
    });
  }

  Future<void> _toggle(PrivateShelfBiometric kind, bool enable) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final enabled = Set<PrivateShelfBiometric>.of(_config.biometrics);
      if (enable) {
        // One successful check proves the sensor answers for this phone
        // before the shelf starts relying on it.
        final outcome = await widget.lock.authenticate(
          kind,
          purpose: '开启${kind.label}验证',
          fallbackLabel: '取消',
        );
        if (outcome != BiometricOutcome.success) {
          final message = switch (outcome) {
            BiometricOutcome.cancelled || BiometricOutcome.fallback => null,
            BiometricOutcome.lockout => '${kind.label}验证次数过多，请稍后再试',
            BiometricOutcome.notEnrolled => '请先在系统设置里录入${kind.label}',
            _ => '${kind.label}验证没有完成',
          };
          if (message != null && mounted) {
            AppToast.error(context, message, colors: widget.colors);
          }
          return;
        }
        enabled.add(kind);
      } else {
        enabled.remove(kind);
      }
      await widget.lock.saveBiometrics(
        enabled,
        enable && _config.biometrics.isEmpty ? kind : _config.unlockBiometric,
      );
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseDefault(PrivateShelfBiometric kind) async {
    await widget.lock.saveBiometrics(_config.biometrics, kind);
    await _reload();
  }

  Future<void> _changePin() async {
    final saved = await showPrivateShelfPinSetup(
      context,
      lock: widget.lock,
      colors: widget.colors,
      title: '设置新密码',
    );
    if (saved && mounted) {
      AppToast.success(context, '密码已修改', colors: widget.colors);
    }
  }

  Future<void> _disable() async {
    if (await widget.onDisable() && mounted) Navigator.of(context).pop();
  }

  String _hint(PrivateShelfBiometric kind) {
    final label = kind.label;
    if (_support.status == BiometricStatus.unsupported) {
      return '需要 Android 10 或更高版本';
    }
    if (!_support.hasHardware(kind)) return '这台设备没有向应用开放$label验证';
    if (_config.biometrics.contains(kind)) {
      return _config.unlockBiometric == kind ? '解锁时默认使用' : '已开启';
    }
    return switch (_support.status) {
      BiometricStatus.ready => '开启前需要验证一次$label',
      BiometricStatus.notEnrolled => '请先在系统设置里录入$label',
      _ => '$label验证暂时不可用',
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final danger = AppOverlayTheme.danger(colors);
    final enabled = _config.biometrics;
    return AppSheetSurface(
      colors: colors,
      child: SafeArea(
        top: false,
        bottom: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppSheetHeader(
                title: widget.justCreated ? '隐私书架已开启' : '隐私书架设置',
                subtitle: '除了 6 位数字密码，还可以开启指纹或人脸验证。',
              ),
              const Divider(),
              if (!_loaded)
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.xl),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final kind in PrivateShelfBiometric.values)
                        SwitchListTile.adaptive(
                          secondary: Icon(_biometricIcon(kind)),
                          title: Text('${kind.label}验证'),
                          subtitle: Text(_hint(kind)),
                          value: enabled.contains(kind),
                          onChanged:
                              !_busy &&
                                  (enabled.contains(kind) ||
                                      _support.canUse(kind))
                              ? (value) => _toggle(kind, value)
                              : null,
                        ),
                      if (enabled.length > 1)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '解锁时使用',
                                style: TextStyle(
                                  color: colors.text,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              Wrap(
                                spacing: AppSpacing.sm,
                                children: [
                                  for (final kind
                                      in PrivateShelfBiometric.values)
                                    ChoiceChip(
                                      avatar: Icon(
                                        _biometricIcon(kind),
                                        size: 18,
                                      ),
                                      label: Text(kind.label),
                                      selected: _config.unlockBiometric == kind,
                                      onSelected: (_) => _chooseDefault(kind),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ListTile(
                        leading: const Icon(Icons.password_rounded),
                        title: const Text('修改密码'),
                        onTap: _busy ? null : _changePin,
                      ),
                      ListTile(
                        leading: Icon(Icons.lock_open_rounded, color: danger),
                        title: Text('关闭隐私书架', style: TextStyle(color: danger)),
                        subtitle: const Text('书籍移回普通书架，并清除密码'),
                        onTap: _busy ? null : _disable,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Text(
                          '按照安卓系统的规则，验证框接受哪种生物信息由系统决定。'
                          '手机同时向应用开放指纹和人脸时，两种方式都可能通过验证。',
                          style: TextStyle(
                            color: colors.secondary,
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
