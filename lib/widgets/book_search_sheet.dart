import 'package:flutter/material.dart';

import '../models/search_match.dart';
import '../controllers/document_search_controller.dart';
import '../theme/app_spacing.dart';
import '../theme/app_theme.dart';
import 'app_sheet.dart';

class BookSearchSheet<T extends SearchMatch> extends StatefulWidget {
  final ReaderThemeColors colors;
  final Future<List<T>> Function(String query) onSearch;
  final ValueChanged<T> onSelect;

  const BookSearchSheet({
    super.key,
    required this.colors,
    required this.onSearch,
    required this.onSelect,
  });

  @override
  State<BookSearchSheet<T>> createState() => _BookSearchSheetState<T>();
}

class _BookSearchSheetState<T extends SearchMatch>
    extends State<BookSearchSheet<T>> {
  final _controller = TextEditingController();
  late final DocumentSearchController<T> _searchState;
  List<T> get _results => _searchState.results;
  bool get _searching => _searchState.searching;
  bool get _searched => _searchState.searched;
  String? get _errorMessage => _searchState.failed ? '搜索失败，请重新输入关键词后再试' : null;

  @override
  void initState() {
    super.initState();
    _searchState = DocumentSearchController<T>(
      search: (query) => widget.onSearch(query),
      onError: (error, stack) {
        debugPrint('Full-text search failed: $error');
        debugPrintStack(stackTrace: stack);
      },
    )..addListener(_onSearchStateChanged);
    _controller.addListener(_handleQueryChanged);
  }

  void _onSearchStateChanged() {
    if (mounted) setState(() {});
  }

  void _handleQueryChanged() => _searchState.setQuery(_controller.text);

  Future<void> _search() => _searchState.submit();

  @override
  void dispose() {
    _searchState.removeListener(_onSearchStateChanged);
    _searchState.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Uses the exact source range returned by the search worker. This remains
  /// correct when a match only exists after newlines, full-width spaces or
  /// repeated whitespace have been normalized.
  Widget _buildHighlightedSnippet(T result) {
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
    return AppSheetSurface(
      colors: widget.colors,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const AppSheetHeader(title: '全文搜索'),
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
                          _results.length == maxDocumentSearchResults
                              ? '已显示前 $maxDocumentSearchResults 条，请增加关键词缩小范围'
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
                                  result.title,
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
