import 'package:flutter/material.dart';

import '../services/ai_chapter_service.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';

/// DeepSeek API key editor. Returns true when a key is stored after the
/// dialog closes, false when the user cancelled or cleared the key.
class DeepSeekKeyDialog extends StatefulWidget {
  final ReaderThemeColors colors;

  const DeepSeekKeyDialog({super.key, required this.colors});

  static Future<bool> show(BuildContext context, ReaderThemeColors colors) {
    return showDialog<bool>(
      context: context,
      builder: (_) => DeepSeekKeyDialog(colors: colors),
    ).then((saved) => saved ?? false);
  }

  @override
  State<DeepSeekKeyDialog> createState() => _DeepSeekKeyDialogState();
}

class _DeepSeekKeyDialogState extends State<DeepSeekKeyDialog> {
  final _controller = TextEditingController();
  final _service = AiChapterService();
  bool _obscure = true;
  bool _hadKey = false;

  @override
  void initState() {
    super.initState();
    _service.getApiKey().then((key) {
      if (!mounted || key == null) return;
      setState(() {
        _controller.text = key;
        _hadKey = true;
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _controller.text.trim();
    if (key.isEmpty) return;
    await _service.setApiKey(key);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _clear() async {
    await _service.setApiKey('');
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return AlertDialog(
      backgroundColor: colors.headerBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      title: Text('DeepSeek API 密钥', style: TextStyle(color: colors.text)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '密钥只保存在本机，用于智能分章时调用 DeepSeek。可在 platform.deepseek.com 创建。',
            style: TextStyle(
              color: colors.secondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _controller,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            style: TextStyle(color: colors.text, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'sk-…',
              hintStyle: TextStyle(color: colors.secondary),
              filled: true,
              fillColor: colors.background,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.md,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide(color: colors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide(color: colors.accent, width: 1.5),
              ),
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示密钥' : '隐藏密钥',
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: colors.secondary,
                  size: 20,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        if (_hadKey)
          TextButton(
            onPressed: _clear,
            child: Text('清除密钥', style: TextStyle(color: colors.secondary)),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('取消', style: TextStyle(color: colors.secondary)),
        ),
        FilledButton(
          onPressed: _save,
          style: FilledButton.styleFrom(
            backgroundColor: colors.accent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
