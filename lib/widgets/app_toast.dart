import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../models/reader_settings.dart';
import '../theme/app_motion.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_theme.dart';

enum AppToastTone { info, success, error }

/// App-wide floating capsule notification toast rendered in the root [Overlay].
///
/// Key properties:
/// - **Zero heavy blur / saveLayer**: pure compositor `Transform` + `Opacity`
///   inside a [RepaintBoundary] so underlying reading pages never repaint.
/// - **Compact editorial capsule**: self-sizes to fit its message instead of
///   stretching across the entire bottom edge over reading text.
/// - **Live in-place morphing**: consecutive toasts glide smoothly in width,
///   crossfade text/icon, and deliver a gentle spring pulse without flickering.
/// - **Always on top & non-blocking**: floats cleanly above sheets and dialogs
///   while passing taps everywhere outside the capsule straight through.
class AppToast {
  AppToast._();

  static OverlayEntry? _activeEntry;
  static final GlobalKey<_ToastCapsuleOverlayState> _overlayKey =
      GlobalKey<_ToastCapsuleOverlayState>();
  static int _serial = 0;

  static void show(
    BuildContext context,
    String message, {
    AppToastTone tone = AppToastTone.info,
    Duration? duration,
    ReaderThemeColors? colors,
    IconData? icon,
    Color? accentColor,
    Color? swatchColor,
    double bottomOffset = 0,
  }) => _present(
    context,
    message,
    tone: tone,
    duration: duration,
    colors: colors,
    icon: icon,
    accentColor: accentColor,
    swatchColor: swatchColor,
    bottomOffset: bottomOffset,
  );

  static void info(
    BuildContext context,
    String message, {
    ReaderThemeColors? colors,
    IconData? icon,
    Color? accentColor,
    Color? swatchColor,
    Duration? duration,
    double bottomOffset = 0,
  }) => show(
    context,
    message,
    tone: AppToastTone.info,
    colors: colors,
    icon: icon,
    accentColor: accentColor,
    swatchColor: swatchColor,
    duration: duration,
    bottomOffset: bottomOffset,
  );

  static void success(
    BuildContext context,
    String message, {
    ReaderThemeColors? colors,
    IconData? icon,
    Duration? duration,
    double bottomOffset = 0,
  }) => show(
    context,
    message,
    tone: AppToastTone.success,
    colors: colors,
    icon: icon,
    duration: duration,
    bottomOffset: bottomOffset,
  );

  static void error(
    BuildContext context,
    String message, {
    ReaderThemeColors? colors,
    IconData? icon,
    Duration? duration,
    double bottomOffset = 0,
  }) => show(
    context,
    message,
    tone: AppToastTone.error,
    colors: colors,
    icon: icon,
    duration: duration,
    bottomOffset: bottomOffset,
  );

  static void loading(
    BuildContext context,
    String message, {
    ReaderThemeColors? colors,
    double bottomOffset = 0,
  }) => _present(
    context,
    message,
    colors: colors,
    loading: true,
    bottomOffset: bottomOffset,
  );

  static void hide(BuildContext context) {
    final state = _overlayKey.currentState;
    if (state != null && state.mounted) {
      state.dismiss();
    } else {
      _removeEntryImmediately();
    }
  }

  static void _removeEntryImmediately() {
    _activeEntry?.remove();
    _activeEntry = null;
  }

  static void _present(
    BuildContext context,
    String message, {
    AppToastTone tone = AppToastTone.info,
    Duration? duration,
    ReaderThemeColors? colors,
    bool loading = false,
    IconData? icon,
    Color? accentColor,
    Color? swatchColor,
    double bottomOffset = 0,
  }) {
    final overlay =
        Overlay.maybeOf(context, rootOverlay: true) ?? Overlay.maybeOf(context);
    if (overlay == null) return;

    final palette =
        colors ??
        AppTheme.getReaderTheme(
          ReaderThemeMode.system,
          systemBrightness: Theme.of(context).brightness,
        );
    final effectiveDuration =
        duration ??
        (loading
            ? const Duration(seconds: 30)
            : Duration(
                milliseconds: tone == AppToastTone.error ? 3200 : 2200,
              ));

    final payload = _ToastPayload(
      id: ++_serial,
      message: message,
      tone: tone,
      palette: palette,
      duration: effectiveDuration,
      loading: loading,
      icon: icon,
      accentColor: accentColor,
      swatchColor: swatchColor,
      bottomOffset: bottomOffset,
    );

    final activeState = _overlayKey.currentState;
    if (_activeEntry != null && activeState != null && activeState.mounted) {
      activeState.updatePayload(payload);
      return;
    }

    _removeEntryImmediately();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastCapsuleOverlay(
        key: _overlayKey,
        initialPayload: payload,
        onRemoved: () {
          if (_activeEntry == entry) {
            _activeEntry?.remove();
            _activeEntry = null;
          }
        },
      ),
    );
    _activeEntry = entry;
    overlay.insert(entry);
  }
}

class _ToastPayload {
  const _ToastPayload({
    required this.id,
    required this.message,
    required this.tone,
    required this.palette,
    required this.duration,
    required this.loading,
    this.icon,
    this.accentColor,
    this.swatchColor,
    this.bottomOffset = 0,
  });

  final int id;
  final String message;
  final AppToastTone tone;
  final ReaderThemeColors palette;
  final Duration duration;
  final bool loading;
  final IconData? icon;
  final Color? accentColor;
  final Color? swatchColor;
  final double bottomOffset;
}

class _ToastCapsuleOverlay extends StatefulWidget {
  const _ToastCapsuleOverlay({
    super.key,
    required this.initialPayload,
    required this.onRemoved,
  });

  final _ToastPayload initialPayload;
  final VoidCallback onRemoved;

  @override
  State<_ToastCapsuleOverlay> createState() => _ToastCapsuleOverlayState();
}

class _ToastCapsuleOverlayState extends State<_ToastCapsuleOverlay>
    with TickerProviderStateMixin {
  static const _enterSpring = SpringDescription(
    mass: 1.0,
    stiffness: 430.0,
    damping: 25.0,
  );
  static const _pulseSpring = SpringDescription(
    mass: 1.0,
    stiffness: 520.0,
    damping: 22.0,
  );

  late _ToastPayload _payload;
  late final AnimationController _entryController;
  late final AnimationController _pulseController;
  late final AnimationController _dragController;
  Timer? _dismissTimer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _payload = widget.initialPayload;
    _entryController = AnimationController.unbounded(vsync: this, value: 0.0);
    _pulseController = AnimationController.unbounded(vsync: this, value: 0.0);
    _dragController = AnimationController.unbounded(vsync: this, value: 0.0);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _animateIn();
    });
    _scheduleDismiss();
  }

  void _animateIn() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _entryController.value = 1.0;
      return;
    }
    _entryController.animateWith(
      SpringSimulation(_enterSpring, _entryController.value, 1.0, 0.0),
    );
  }

  void updatePayload(_ToastPayload next) {
    if (!mounted) return;
    _dismissTimer?.cancel();
    final wasDismissing = _dismissing;
    _dismissing = false;
    _dragController.value = 0.0;
    setState(() => _payload = next);
    _scheduleDismiss();

    if (MediaQuery.disableAnimationsOf(context)) {
      _entryController.value = 1.0;
      _pulseController.value = 0.0;
      return;
    }
    if (wasDismissing || _entryController.value < 0.85) {
      _entryController.animateWith(
        SpringSimulation(_enterSpring, _entryController.value, 1.0, 0.0),
      );
    } else {
      // Subtle buoyant pop to acknowledge in-place morph.
      _pulseController.value = 1.0;
      _pulseController.animateWith(
        SpringSimulation(_pulseSpring, 1.0, 0.0, 0.0),
      );
    }
  }

  void _scheduleDismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = Timer(_payload.duration, dismiss);
  }

  Future<void> dismiss() async {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    _dismissTimer?.cancel();
    if (MediaQuery.disableAnimationsOf(context)) {
      widget.onRemoved();
      return;
    }
    await _entryController.animateTo(
      0.0,
      duration: const Duration(milliseconds: 190),
      curve: Curves.easeInCubic,
    );
    if (mounted && _dismissing) {
      widget.onRemoved();
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_payload.loading || _dismissing) return;
    final delta = details.primaryDelta ?? 0;
    _dragController.value = (_dragController.value + delta).clamp(-6.0, 48.0);
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_payload.loading || _dismissing) return;
    final velocity = details.primaryVelocity ?? 0;
    if (_dragController.value > 18 || velocity > 240) {
      dismiss();
    } else {
      _dragController.animateWith(
        SpringSimulation(_pulseSpring, _dragController.value, 0.0, 0.0),
      );
    }
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _entryController.dispose();
    _pulseController.dispose();
    _dragController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bottomReserve =
        math.max(mq.viewInsets.bottom, mq.viewPadding.bottom) +
        20.0 +
        (mq.viewInsets.bottom > 20 ? 0.0 : _payload.bottomOffset);
    final maxWidth = math.min(mq.size.width - 44.0, 360.0);
    final reduced = mq.disableAnimations;

    final palette = _payload.palette;
    final isDarkPaper = AppOverlayTheme.isDark(palette);
    final isOledBlack = palette.background.computeLuminance() < 0.01;

    // Warm obsidian-espresso pill on light/warm pages for jewel-like contrast
    // without covering reading prose in a muddy beige rectangle; warm elevated
    // graphite on dark/OLED pages with delicate luminous rim.
    final Color bgTop;
    final Color bgBottom;
    final Color rimColor;
    final Color textColor;
    if (isOledBlack) {
      bgTop = const Color(0xFF25211F);
      bgBottom = const Color(0xFF1B1816);
      rimColor = Colors.white.withValues(alpha: 0.16);
      textColor = const Color(0xFFF0E9E0);
    } else if (isDarkPaper) {
      bgTop = const Color(0xFF352F2B);
      bgBottom = const Color(0xFF2B2622);
      rimColor = Colors.white.withValues(alpha: 0.14);
      textColor = const Color(0xFFF5EFE8);
    } else {
      bgTop = const Color(0xFF332B26);
      bgBottom = const Color(0xFF27211C);
      rimColor = Colors.white.withValues(alpha: 0.13);
      textColor = const Color(0xFFFAF6F0);
    }

    final Color badgeAccent =
        _payload.swatchColor ??
        _payload.accentColor ??
        switch (_payload.tone) {
          AppToastTone.info => const Color(0xFFEBA07C),
          AppToastTone.success => const Color(0xFF7BE0A3),
          AppToastTone.error => const Color(0xFFFF8C8C),
        };
    final IconData iconData =
        _payload.icon ??
        switch (_payload.tone) {
          AppToastTone.info => Icons.info_outline_rounded,
          AppToastTone.success => Icons.check_rounded,
          AppToastTone.error => Icons.priority_high_rounded,
        };
    final isCompactPill =
        _payload.message.length <= 22 && !_payload.message.contains('\n');
    final borderRadius = BorderRadius.circular(isCompactPill ? 999 : 20);

    return AnimatedPositioned(
      duration: reduced ? Duration.zero : AppMotion.fast,
      curve: AppMotion.controlCurve,
      left: 22,
      right: 22,
      bottom: bottomReserve,
      child: IgnorePointer(
        ignoring: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: Listenable.merge([
                _entryController,
                _pulseController,
                _dragController,
              ]),
              builder: (context, child) {
                final entry = _entryController.value;
                final clampedOpacity = (entry / 0.55).clamp(0.0, 1.0);
                final scale =
                    (0.88 + 0.12 * entry) +
                    0.038 * _pulseController.value.clamp(-0.2, 1.0);
                final dy = (1.0 - entry) * 20.0 + _dragController.value;
                return Opacity(
                  opacity: clampedOpacity,
                  child: Transform.translate(
                    offset: Offset(0, dy),
                    child: Transform.scale(
                      scale: scale.clamp(0.82, 1.08),
                      alignment: Alignment.bottomCenter,
                      child: child,
                    ),
                  ),
                );
              },
              child: Semantics(
                liveRegion: true,
                label: _payload.message,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _payload.loading ? null : dismiss,
                  onVerticalDragUpdate: _onVerticalDragUpdate,
                  onVerticalDragEnd: _onVerticalDragEnd,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: 42,
                      maxWidth: maxWidth,
                    ),
                    child: AnimatedContainer(
                      key: const ValueKey('app-toast-surface'),
                      duration: reduced ? Duration.zero : AppMotion.fast,
                      curve: AppMotion.controlCurve,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [bgTop, bgBottom],
                        ),
                        borderRadius: borderRadius,
                        border: Border.all(color: rimColor, width: 0.85),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: isDarkPaper ? 0.44 : 0.22,
                            ),
                            blurRadius: 24,
                            spreadRadius: -3,
                            offset: const Offset(0, 10),
                          ),
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: isDarkPaper ? 0.28 : 0.10,
                            ),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: AnimatedSize(
                        duration: reduced ? Duration.zero : AppMotion.normal,
                        curve: AppMotion.controlCurve,
                        alignment: Alignment.center,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            11,
                            isCompactPill ? 9 : 11,
                            16,
                            isCompactPill ? 9 : 11,
                          ),
                          child: AnimatedSwitcher(
                            duration: reduced
                                ? Duration.zero
                                : const Duration(milliseconds: 190),
                            switchInCurve: AppMotion.controlCurve,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: SlideTransition(
                                    position: Tween<Offset>(
                                      begin: const Offset(0, 0.14),
                                      end: Offset.zero,
                                    ).animate(animation),
                                    child: child,
                                  ),
                                ),
                            child: Row(
                              key: ValueKey<int>(_payload.id),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _ToastBadge(
                                  loading: _payload.loading,
                                  swatchColor: _payload.swatchColor,
                                  accent: badgeAccent,
                                  icon: iconData,
                                ),
                                const SizedBox(width: 9),
                                Flexible(
                                  child: Text(
                                    _payload.message,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: textColor,
                                      fontSize: 13.5,
                                      height: 1.38,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: 0.15,
                                      decoration: TextDecoration.none,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastBadge extends StatelessWidget {
  const _ToastBadge({
    required this.loading,
    required this.swatchColor,
    required this.accent,
    required this.icon,
  });

  final bool loading;
  final Color? swatchColor;
  final Color accent;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return SizedBox.square(
        dimension: 22,
        child: Center(
          child: SizedBox.square(
            dimension: 15,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: accent,
            ),
          ),
        ),
      );
    }

    if (swatchColor != null) {
      return Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: swatchColor!.withValues(alpha: 0.24),
        ),
        child: Center(
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: swatchColor,
              boxShadow: [
                BoxShadow(
                  color: swatchColor!.withValues(alpha: 0.55),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: accent.withValues(alpha: 0.18),
      ),
      child: Center(child: Icon(icon, size: 14.5, color: accent)),
    );
  }
}
