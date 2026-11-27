import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'pressable_scale.dart';

Future<T?> showAppSheet<T>({
  required BuildContext context,
  required ReaderThemeColors colors,
  required WidgetBuilder builder,
  AnimationStyle? sheetAnimationStyle,
  bool isScrollControlled = true,
}) async {
  final navigator = Navigator.of(context);
  final reduced = MediaQuery.disableAnimationsOf(context);
  final route = _AppSheetRoute<T>(
    isScrollControlled: isScrollControlled,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    constraints: const BoxConstraints(maxWidth: 640),
    modalBarrierColor: _sheetBarrierColor(colors),
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    capturedThemes: InheritedTheme.capture(
      from: context,
      to: navigator.context,
    ),
    sheetAnimationStyle: reduced
        ? AnimationStyle.noAnimation
        : _withSheetCurves(
            sheetAnimationStyle ??
                AnimationStyle(
                  duration: AppMotion.sheet,
                  reverseDuration: AppMotion.sheetClose,
                ),
          ),
    builder: (_) => AppOverlayTheme(
      colors: colors,
      child: Builder(builder: builder),
    ),
  );
  final result = await navigator.push(route);
  await route.completed;
  return result;
}

Color _sheetBarrierColor(ReaderThemeColors colors) =>
    AppOverlayTheme.isDark(colors)
    ? Colors.black.withValues(alpha: 0.56)
    : const Color(0xFF1F1A16).withValues(alpha: 0.34);

/// Fills in the edge-sheet curves a caller left out. Flutter's default
/// plays the same decelerating curve backwards to close, so a sheet used to
/// leave slowly and then speed off. Closing on the flipped curve makes it
/// leave at once.
AnimationStyle _withSheetCurves(AnimationStyle style) => style.copyWith(
  curve: style.curve ?? AppMotion.sheetCurve,
  reverseCurve: style.reverseCurve ?? AppMotion.exitOf(AppMotion.sheetCurve),
);

/// Enhanced [ModalBottomSheetRoute] adding a finger-tracked frosted glass
/// backdrop blur and a subtle bottom-anchored scale-lift entrance while keeping
/// Flutter's native vertical drag-to-dismiss gesture intact.
class _AppSheetRoute<T> extends ModalBottomSheetRoute<T> {
  _AppSheetRoute({
    required super.builder,
    required super.isScrollControlled,
    super.capturedThemes,
    super.barrierLabel,
    super.backgroundColor,
    super.elevation,
    super.modalBarrierColor,
    super.constraints,
    super.useSafeArea,
    super.sheetAnimationStyle,
  });

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) return child;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, sheetChild) {
        final raw = animation.value.clamp(0.0, 1.0);
        final blur = 7.0 * Curves.easeOut.transform(raw);
        final lift = AppMotion.sheetCurve.transform(raw);
        final scale = ui.lerpDouble(0.955, 1.0, lift) ?? 1.0;
        final fade = (raw / 0.38).clamp(0.0, 1.0);
        return Stack(
          fit: StackFit.expand,
          children: [
            if (blur > 0.08)
              IgnorePointer(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                  child: const SizedBox.expand(),
                ),
              ),
            Transform.scale(
              scale: scale,
              alignment: Alignment.bottomCenter,
              child: Opacity(opacity: fade, child: sheetChild),
            ),
          ],
        );
      },
    );
  }
}

/// Sculpted floating bottom-sheet card with 28 dp rounded corners, soft
/// multi-layer elevation shadow, subtle vellum sheen, centered drag handle, and
/// smooth [AnimatedSize] height morphing.
///
/// Automatically docks cleanly onto the soft keyboard whenever
/// `viewInsets.bottom > 20`, and strips duplicated bottom safe-area padding
/// inside floating cards so nested content stays balanced.
class AppSheetSurface extends StatelessWidget {
  const AppSheetSurface({
    super.key,
    required this.colors,
    required this.child,
    this.floating = true,
    this.showDragHandle = true,
    this.animateSize = true,
  });

  final ReaderThemeColors colors;
  final Widget child;
  final bool floating;
  final bool showDragHandle;
  final bool animateSize;

  @override
  Widget build(BuildContext context) {
    final dark = AppOverlayTheme.isDark(colors);
    final mq = MediaQuery.of(context);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final keyboardOpen = mq.viewInsets.bottom > 20;
    final isFloating = floating && !keyboardOpen;

    final outerPadding = isFloating
        ? EdgeInsets.fromLTRB(
            10,
            0,
            10,
            math.max(10.0, mq.padding.bottom),
          )
        : EdgeInsets.zero;
    final radius = isFloating
        ? BorderRadius.circular(AppRadius.sheet)
        : const BorderRadius.vertical(top: Radius.circular(AppRadius.sheet));

    final topSheen = Color.alphaBlend(
      (dark ? Colors.white : Colors.white).withValues(
        alpha: dark ? 0.055 : 0.42,
      ),
      colors.headerBg,
    );
    final rimColor = dark
        ? Colors.white.withValues(alpha: 0.11)
        : Color.alphaBlend(
            Colors.white.withValues(alpha: 0.45),
            colors.border,
          );
    final handleColor = colors.secondary.withValues(alpha: dark ? 0.42 : 0.28);

    final innerChild = isFloating
        ? MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: child,
          )
        : child;

    Widget content = showDragHandle
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: handleColor,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
              Flexible(child: innerChild),
            ],
          )
        : innerChild;

    if (animateSize && !reduced) {
      content = AnimatedSize(
        duration: AppMotion.tabSwitch,
        curve: AppMotion.controlCurve,
        alignment: Alignment.topCenter,
        child: content,
      );
    }

    return AppOverlayTheme(
      colors: colors,
      child: AnimatedPadding(
        duration: reduced ? Duration.zero : AppMotion.fast,
        curve: AppMotion.controlCurve,
        padding: outerPadding,
        child: AnimatedContainer(
          duration: reduced ? Duration.zero : AppMotion.fast,
          curve: AppMotion.controlCurve,
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.48 : 0.14),
                blurRadius: isFloating ? 34 : 24,
                spreadRadius: isFloating ? -2 : 0,
                offset: Offset(0, isFloating ? 14 : -4),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.28 : 0.06),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Material(
              color: colors.headerBg,
              surfaceTintColor: Colors.transparent,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [topSheen, colors.headerBg],
                    stops: const [0.0, 0.24],
                  ),
                  borderRadius: radius,
                  border: Border.all(color: rimColor, width: 0.9),
                ),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppSheetHeader extends StatelessWidget {
  const AppSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final closeBg = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.10 : 0.06,
    );
    final closeFg = theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 14, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          ?trailing,
          const SizedBox(width: 4),
          Semantics(
            button: true,
            label: '关闭',
            child: Tooltip(
              message: '关闭',
              child: PressableScale(
                pressedScale: 0.88,
                child: Material(
                  color: closeBg,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    customBorder: const CircleBorder(),
                    overlayColor: const WidgetStatePropertyAll(
                      Colors.transparent,
                    ),
                    child: SizedBox(
                      width: 34,
                      height: 34,
                      child: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: closeFg,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AppActionSheet extends StatelessWidget {
  const AppActionSheet({
    super.key,
    required this.colors,
    required this.title,
    this.subtitle,
    required this.children,
  });
  final ReaderThemeColors colors;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => AppSheetSurface(
    colors: colors,
    child: SafeArea(
      top: false,
      bottom: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          bottom: 14 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSheetHeader(title: title, subtitle: subtitle),
            Divider(
              height: 1,
              color: colors.border.withValues(alpha: 0.7),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
