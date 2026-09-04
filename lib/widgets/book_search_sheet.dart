import 'package:flutter/material.dart';

import '../services/book_search_service.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';

class BookSearchSheet extends StatefulWidget {
  final ReaderThemeColors colors;
  final Future<List<BookSearchResult>> Function(String query) onSearch;
  final ValueChanged<BookSearchResult> onSelect;

  const BookSearchSheet({
    super.key,
    required this.colors,
    required this.onSearch,
    required this.onSelect,
  });

  @override
  State<BookSearchSheet> createState() => _BookSearchSheetState();
}

class _BookSearchSheetState extends State<BookSearchSheet> {
  final _controller = TextEditingController();
  List<BookSearchResult> _results = const <BookSearchResult>[];
  bool _searching = false;
  bool _searched = false;
  String? _errorMessage;
  int _serial = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleQueryChanged);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleQueryChanged() {
    // Typing a new keyword makes the previous "no matches" verdict stale.
    if (!_searched && _errorMessage == null) return;
    setState(() {
      _searched = false;
      _errorMessage = null;
    });
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    // A hardware keyboard can submit more than once while the previous isolate
    // scan is still running.  Do not queue duplicate whole-book scans for the
    // same visible search panel.
    if (query.isEmpty || _searching) return;
    final serial = ++_serial;
    setState(() {
      _searching = true;
      _errorMessage = null;
    });
    try {
      final results = await widget.onSearch(query);
      if (!mounted || serial != _serial) return;
      setState(() {
        _results = results;
        _searching = false;
        _searched = true;
      });
    } on Object catch (error, stackTrace) {
      debugPrint('Full-text search failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted || serial != _serial) return;
      setState(() {
        _results = const <BookSearchResult>[];
        _searching = false;
        _searched = true;
        _errorMessage = '搜索失败，请重新输入关键词后再试';
      });
    }
  }

  /// Uses the exact source range returned by the search worker. This remains
  /// correct when a match only exists after newlines, full-width spaces or
  /// repeated whitespace have been normalized.
  Widget _buildHighlightedSnippet(BookSearchResult result) {
    final snippet = result.snippet;
    final baseStyle = TextStyle(color: widget.colors.secondary);
    final matchStart = result.snippetMatchStart.clamp(0, snippet.length);
    final matchEnd = result.snippetMatchEnd.clamp(matchStart, snippet.length);
    if (matchStart == matchEnd) {
      return Text(
        snippet,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: baseStyle,
      );
    }
    final highlightStyle = TextStyle(
      color: widget.colors.accent,
      fontWeight: FontWeight.w700,
    );
    final spans = <TextSpan>[
      if (matchStart > 0) TextSpan(text: snippet.substring(0, matchStart)),
      TextSpan(
        text: snippet.substring(matchStart, matchEnd),
        style: highlightStyle,
      ),
      if (matchEnd < snippet.length)
        TextSpan(text: snippet.substring(matchEnd)),
    ];
    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(style: baseStyle, children: spans),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: widget.colors.background,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(AppRadius.pill),
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '全文搜索',
                      style: TextStyle(
                        color: widget.colors.text,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(
                      Icons.close_rounded,
                      color: widget.colors.secondary,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                style: TextStyle(color: widget.colors.text),
                decoration: InputDecoration(
                  hintText: '输入正文关键词',
                  hintStyle: TextStyle(color: widget.colors.secondary),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: widget.colors.secondary,
                  ),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          onPressed: _search,
                          icon: const Icon(Icons.arrow_forward_rounded),
                        ),
                  filled: true,
                  fillColor: widget.colors.headerBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    borderSide: BorderSide(color: widget.colors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    borderSide: BorderSide(color: widget.colors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    borderSide: BorderSide(
                      color: widget.colors.accent,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Divider(height: 1, color: widget.colors.border),
            Expanded(
              child: Column(
                children: [
                  if (_results.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _results.length == BookSearchService.maxResults
                              ? '已显示前 ${BookSearchService.maxResults} 条，请增加关键词缩小范围'
                              : '找到 ${_results.length} 条结果',
                          style: TextStyle(
                            color: widget.colors.secondary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: _results.isEmpty
                        ? Center(
                            child: Text(
                              _errorMessage ??
                                  (_searched ? '没有找到匹配内容' : '输入关键词即可搜索本书全部正文'),
                              style: TextStyle(
                                color: _errorMessage == null
                                    ? widget.colors.secondary
                                    : widget.colors.accent,
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: _results.length,
                            separatorBuilder: (_, _) => Divider(
                              height: 1,
                              indent: 20,
                              endIndent: 20,
                              color: widget.colors.border,
                            ),
                            itemBuilder: (context, index) {
                              final result = _results[index];
                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 6,
                                ),
                                title: Text(
                                  result.chapterTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: widget.colors.text,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 5),
                                  child: _buildHighlightedSnippet(result),
                                ),
                                trailing: Icon(
                                  Icons.chevron_right_rounded,
                                  color: widget.colors.secondary,
                                ),
                                enabled: !_searching,
                                onTap: _searching
                                    ? null
                                    : () => widget.onSelect(result),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
