import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../theme/app_overlay_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required ReaderThemeColors colors,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<T>(
    context: context,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierDismissible: barrierDismissible,
    barrierColor: AppOverlayTheme.barrier(colors),
    animationStyle: AnimationStyle(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : AppMotion.normal,
      reverseDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : AppMotion.fast,
      curve: AppMotion.standard,
    ),
    builder: (_) => AppOverlayTheme(
      colors: colors,
      child: Builder(builder: builder),
    ),
  );
  final result = await navigator.push(route);
  // Text fields still use their controllers during the reverse transition.
  await route.completed;
  return result;
}

class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
  });
  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    constraints: const BoxConstraints(minWidth: 280, maxWidth: 440),
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    clipBehavior: Clip.antiAlias,
    titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
    contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
    actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    buttonPadding: const EdgeInsets.symmetric(horizontal: 4),
    actionsOverflowButtonSpacing: AppSpacing.sm,
    actionsOverflowAlignment: OverflowBarAlignment.end,
    title: title,
    content: content,
    actions: actions,
  );
}

class AppDestructiveButton extends StatelessWidget {
  const AppDestructiveButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.filled = true,
  });
  final VoidCallback? onPressed;
  final Widget child;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return filled
        ? FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: onPressed,
            child: child,
          )
        : TextButton(
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: onPressed,
            child: child,
          );
  }
}
