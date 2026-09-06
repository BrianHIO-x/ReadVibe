import 'package:flutter/material.dart';
import '../theme/app_motion.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';

Future<T?> showAppSheet<T>({
  required BuildContext context,
  required ReaderThemeColors colors,
  required WidgetBuilder builder,
  AnimationStyle? sheetAnimationStyle,
}) async {
  final navigator = Navigator.of(context);
  final route = ModalBottomSheetRoute<T>(
    isScrollControlled: true,
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
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : sheetAnimationStyle ??
              AnimationStyle(
                duration: AppMotion.sheet,
                reverseDuration: AppMotion.normal,
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

/// Attached panels share the reader's 24 dp upper corners and paper surface.
class AppSheetSurface extends StatelessWidget {
  const AppSheetSurface({super.key, required this.colors, required this.child});
  final ReaderThemeColors colors;
  final Widget child;

  @override
  Widget build(BuildContext context) => AppOverlayTheme(
    colors: colors,
    child: Material(
      color: colors.headerBg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.pill),
        ),
        side: BorderSide(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );
}

class AppSheetHeader extends StatelessWidget {
  const AppSheetHeader({super.key, required this.title, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
  );
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
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
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
