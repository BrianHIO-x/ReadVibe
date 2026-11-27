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
  final route = ModalBottomSheetRoute<T>(
    isScrollControlled: isScrollControlled,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    constraints: const BoxConstraints(maxWidth: 640),
    modalBarrierColor: AppOverlayTheme.barrier(colors),
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

/// Fills in the edge-sheet curves a caller left out. Flutter's default
/// plays the same decelerating curve backwards to close, so a sheet used to
/// leave slowly and then speed off. Closing on the flipped curve makes it
/// leave at once.
AnimationStyle _withSheetCurves(AnimationStyle style) => style.copyWith(
  curve: style.curve ?? AppMotion.sheetCurve,
  reverseCurve: style.reverseCurve ?? AppMotion.exitOf(AppMotion.sheetCurve),
);

/// Centered capsule drag indicator rendered cleanly inside sheet headers or
/// scrollable sheet tops so it never forms an opaque clipping bar over content.
class AppSheetDragHandle extends StatelessWidget {
  const AppSheetDragHandle({
    super.key,
    this.colors,
    this.padding = const EdgeInsets.only(top: 10, bottom: 4),
  });

  final ReaderThemeColors? colors;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final color = colors != null
        ? colors!.secondary.withValues(
            alpha: AppOverlayTheme.isDark(colors!) ? 0.42 : 0.28,
          )
        : Theme.of(context).colorScheme.onSurfaceVariant.withValues(
            alpha: Theme.of(context).brightness == Brightness.dark ? 0.42 : 0.28,
          );
    return Padding(
      padding: padding,
      child: Center(
        child: Container(
          width: 38,
          height: 4,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
    );
  }
}

/// Edge-to-edge bottom sheet surface extending seamlessly down to the screen
/// bottom underneath the gesture bar, with 28 dp upper corners, subtle top
/// hairline rim, soft elevation shadow, and smooth [AnimatedSize] height morph.
class AppSheetSurface extends StatelessWidget {
  const AppSheetSurface({
    super.key,
    required this.colors,
    required this.child,
    this.animateSize = true,
  });

  final ReaderThemeColors colors;
  final Widget child;
  final bool animateSize;

  @override
  Widget build(BuildContext context) {
    final dark = AppOverlayTheme.isDark(colors);
    final reduced = MediaQuery.disableAnimationsOf(context);
    const radius = BorderRadius.vertical(top: Radius.circular(AppRadius.sheet));
    final rimColor = dark
        ? Colors.white.withValues(alpha: 0.10)
        : colors.border.withValues(alpha: 0.85);

    Widget content = child;
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.36 : 0.10),
              blurRadius: 24,
              offset: const Offset(0, -6),
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
                borderRadius: radius,
                border: Border(
                  top: BorderSide(color: rimColor, width: 0.9),
                  left: BorderSide(color: rimColor, width: 0.6),
                  right: BorderSide(color: rimColor, width: 0.6),
                ),
              ),
              child: content,
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
    this.showDragHandle = true,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool showDragHandle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final closeBg = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.10 : 0.06,
    );
    final closeFg = theme.colorScheme.onSurfaceVariant;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showDragHandle) const AppSheetDragHandle(),
        Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            showDragHandle ? 8 : 16,
            14,
            14,
          ),
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
        ),
      ],
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
          bottom: 16 + MediaQuery.paddingOf(context).bottom,
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
