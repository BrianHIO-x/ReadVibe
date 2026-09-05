/// Persisted revisions are non-negative integers; old books start at zero.
int readContentRevision(Object? value) =>
    value is int && value >= 0 ? value : 0;

class BookEditConflict extends StateError {
  BookEditConflict() : super('书籍内容已更新，请保留当前修改并重新打开章节后再保存');
}
