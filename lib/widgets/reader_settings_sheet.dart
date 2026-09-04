import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'app_sheet.dart';
import '../theme/app_spacing.dart';
import '../theme/app_motion.dart';
import '../models/reader_settings.dart';
import 'font_settings_section.dart';

/// Bottom sheet panel for adjusting reader settings
class ReaderSettingsSheet extends StatelessWidget {
  final ReaderSettings settings;
  final ValueChanged<ReaderSettings> onChange;
  final ReaderThemeColors colors;
  final Future<void> Function() onImportFont;

  const ReaderSettingsSheet({
    super.key,
    required this.settings,
    required this.onChange,
    required this.colors,
    required this.onImportFont,
  });

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.62;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return AppSheetSurface(
      colors: colors,
      child: SafeArea(
        top: false,
        bottom: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.lg + bottomInset,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.secondary.withValues(alpha: 0.30),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Font Size ──────────────────────────────
                _buildLabel('字号'),
                const SizedBox(height: AppSpacing.xs),
                _buildSegmentedControl<double>(
                  options: _fontSizes,
                  selectedValue: settings.fontSize,
                  labelBuilder: (size) => '${size.toInt()}',
                  onSelect: (size) =>
                      onChange(settings.copyWith(fontSize: size)),
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Line Height ────────────────────────────
                _buildLabel('行距'),
                const SizedBox(height: AppSpacing.xs),
                _buildSegmentedControl<double>(
                  options: _lineHeights,
                  selectedValue: settings.lineHeight,
                  labelBuilder: (lh) => lh.toStringAsFixed(1),
                  onSelect: (lh) => onChange(settings.copyWith(lineHeight: lh)),
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Font Family ───────────────────────────
                FontSettingsSection(
                  settings: settings,
                  colors: colors,
                  onChange: onChange,
                  onImportFont: onImportFont,
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Font Weight ───────────────────────────
                _buildLabel('字体粗细'),
                const SizedBox(height: AppSpacing.xs),
                _buildSegmentedControl<ReaderFontWeight>(
                  options: ReaderFontWeight.values,
                  selectedValue: settings.fontWeight,
                  labelBuilder: (weight) => weight.label,
                  onSelect: (weight) =>
                      onChange(settings.copyWith(fontWeight: weight)),
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Page Margin ───────────────────────────
                _buildLabel('页边距'),
                const SizedBox(height: AppSpacing.xs),
                _buildSegmentedControl<ReaderPageMargin>(
                  options: ReaderPageMargin.values,
                  selectedValue: settings.pageMargin,
                  labelBuilder: (margin) => margin.label,
                  onSelect: (margin) =>
                      onChange(settings.copyWith(pageMargin: margin)),
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Paragraph Spacing ─────────────────────
                _buildLabel('段落空行'),
                const SizedBox(height: AppSpacing.xs),
                _buildSegmentedControl<ReaderParagraphSpacing>(
                  options: const [
                    ReaderParagraphSpacing.none,
                    ReaderParagraphSpacing.blankLine,
                  ],
                  selectedValue: settings.paragraphSpacing,
                  labelBuilder: (spacing) => spacing.label,
                  onSelect: (spacing) =>
                      onChange(settings.copyWith(paragraphSpacing: spacing)),
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Reading Mode ──────────────────────────
                _buildLabel('阅读模式'),
                const SizedBox(height: AppSpacing.xs),
                _buildSegmentedControl<ReaderReadingMode>(
                  options: _readingModes,
                  selectedValue: settings.readingMode,
                  labelBuilder: (mode) => mode.label,
                  onSelect: (mode) =>
                      onChange(settings.copyWith(readingMode: mode)),
                ),
                const SizedBox(height: AppSpacing.xs),
                _RollingModeDescription(
                  mode: settings.readingMode,
                  color: colors.secondary,
                ),
                AnimatedSize(
                  duration: AppMotion.control,
                  curve: AppMotion.controlCurve,
                  alignment: Alignment.topCenter,
                  child: settings.readingMode == ReaderReadingMode.simulation
                      ? Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.md),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('翻页效果'),
                              const SizedBox(height: AppSpacing.xs),
                              _buildSegmentedControl<SimulationPageTurnEffect>(
                                options: SimulationPageTurnEffect.values,
                                selectedValue:
                                    settings.simulationPageTurnEffect,
                                labelBuilder: (effect) => effect.label,
                                onSelect: (effect) => onChange(
                                  settings.copyWith(
                                    simulationPageTurnEffect: effect,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(height: AppSpacing.md),

                // ── Theme ──────────────────────────────────
                _buildLabel('主题'),
                const SizedBox(height: AppSpacing.xs),
                _buildSegmentedControl<ReaderThemeMode>(
                  options: ReaderThemeMode.values,
                  selectedValue: settings.theme,
                  labelBuilder: (theme) => theme.label,
                  onSelect: (theme) =>
                      onChange(settings.copyWith(theme: theme)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: colors.secondary,
        letterSpacing: 0.5,
      ),
    );
  }

  /// A segmented-control style selector: a single highlight block slides
  /// between equally-sized slots as the selection changes, instead of each
  /// option independently flipping its own background colour.
  Widget _buildSegmentedControl<T>({
    required List<T> options,
    required T selectedValue,
    required String Function(T) labelBuilder,
    required ValueChanged<T> onSelect,
  }) {
    // Fall back to the first slot if the current value isn't one of the
    // options (e.g. a value restored from a future settings format) rather
    // than letting the highlight block land off-screen at index -1.
    final selectedIndex = options
        .indexOf(selectedValue)
        .clamp(0, options.length - 1);

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemCount = options.length;
        final slotWidth = constraints.maxWidth / itemCount;
        return SizedBox(
          height: 36,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.border.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
              ),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(
                  begin: selectedIndex.toDouble(),
                  end: selectedIndex.toDouble(),
                ),
                duration: AppMotion.control,
                curve: AppMotion.controlCurve,
                builder: (context, animatedIndex, child) {
                  return Transform.translate(
                    offset: Offset(animatedIndex * slotWidth, 0),
                    child: child,
                  );
                },
                child: SizedBox(
                  width: slotWidth,
                  height: 36,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                      vertical: 2,
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.accent,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        boxShadow: [
                          BoxShadow(
                            color: colors.accent.withValues(alpha: 0.24),
                            blurRadius: 14,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                children: List.generate(itemCount, (i) {
                  final isActive = i == selectedIndex;
                  final option = options[i];
                  return SizedBox(
                    width: slotWidth,
                    height: 36,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        overlayColor: WidgetStateProperty.all(
                          Colors.transparent,
                        ),
                        onTap: () => onSelect(option),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: AppMotion.control,
                            curve: AppMotion.controlCurve,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              color: isActive ? Colors.white : colors.text,
                            ),
                            child: Text(labelBuilder(option)),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        );
      },
    );
  }

  static const _fontSizes = [16.0, 18.0, 20.0, 22.0, 24.0];
  static const _lineHeights = [1.4, 1.6, 1.8, 2.0, 2.2];
  static const _readingModes = [
    ReaderReadingMode.chapter,
    ReaderReadingMode.simulation,
    ReaderReadingMode.continuous,
  ];
}

/// Rolls the old mode hint out and the new hint in as one continuous strip.
/// Opacity stays constant throughout, avoiding the washed-out midpoint of a
/// cross-fade while the segmented highlight is moving to its new slot.
class _RollingModeDescription extends StatefulWidget {
  final ReaderReadingMode mode;
  final Color color;

  const _RollingModeDescription({required this.mode, required this.color});

  @override
  State<_RollingModeDescription> createState() =>
      _RollingModeDescriptionState();
}

class _RollingModeDescriptionState extends State<_RollingModeDescription>
    with SingleTickerProviderStateMixin {
  static const _lineHeight = 18.0;
  late final AnimationController _controller;
  late ReaderReadingMode _currentMode;
  ReaderReadingMode? _previousMode;
  int _direction = 1;

  @override
  void initState() {
    super.initState();
    _currentMode = widget.mode;
    _controller = AnimationController(
      vsync: this,
      duration: AppMotion.control,
      value: 1,
    )..addStatusListener(_handleStatus);
  }

  @override
  void didUpdateWidget(covariant _RollingModeDescription oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.mode == _currentMode) return;
    final oldIndex = ReaderSettingsSheet._readingModes.indexOf(_currentMode);
    final newIndex = ReaderSettingsSheet._readingModes.indexOf(widget.mode);
    _previousMode = _currentMode;
    _currentMode = widget.mode;
    _direction = newIndex >= oldIndex ? 1 : -1;
    _controller.forward(from: 0);
  }

  void _handleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _previousMode == null) return;
    setState(() => _previousMode = null);
  }

  @override
  void dispose() {
    _controller
      ..removeStatusListener(_handleStatus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _lineHeight,
      width: double.infinity,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final progress = AppMotion.controlCurve.transform(
              _controller.value,
            );
            return Stack(
              fit: StackFit.expand,
              children: [
                if (_previousMode case final previous?)
                  Transform.translate(
                    offset: Offset(0, -_direction * _lineHeight * progress),
                    child: _buildText(previous),
                  ),
                Transform.translate(
                  offset: Offset(0, _direction * _lineHeight * (1 - progress)),
                  child: _buildText(_currentMode),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildText(ReaderReadingMode mode) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        mode.description,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, height: 1.25, color: widget.color),
      ),
    );
  }
}
