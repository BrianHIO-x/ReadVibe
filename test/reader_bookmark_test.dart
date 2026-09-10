import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/models/reader_bookmark.dart';
import 'package:readvibe/services/reader_preferences_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

ReaderBookmark _mark({
  required String id,
  int chapter = 0,
  int paragraph = 0,
  int offset = 0,
  String note = '',
  DateTime? createdAt,
}) => ReaderBookmark(
  id: id,
  chapterIndex: chapter,
  chapterTitle: '第 ${chapter + 1} 章',
  paragraphIndex: paragraph,
  characterOffset: offset,
  excerpt: '正文片段',
  note: note,
  chapterProgress: 0.25,
  createdAt: createdAt ?? DateTime(2026, 1, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ReaderPreferencesStore store({Set<String> deleted = const {}}) =>
      ReaderPreferencesStore(deleted.contains, (_) async {});

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('bookmarks round-trip through storage in reading order', () async {
    final marks = store();
    await marks.saveBookmarks('book', [
      _mark(id: 'c', chapter: 2, paragraph: 0),
      _mark(id: 'a', chapter: 0, paragraph: 5, note: '这里要回头看'),
      _mark(id: 'b', chapter: 0, paragraph: 9),
    ]);

    final restored = await marks.getBookmarks('book');
    expect(restored.map((mark) => mark.id), ['a', 'b', 'c']);
    expect(restored.first.note, '这里要回头看');
    expect(restored.first.hasNote, isTrue);
    expect(restored.last.hasNote, isFalse);
    expect(restored.first.chapterProgress, 0.25);
  });

  test('a damaged record is dropped instead of jumping somewhere else', () {
    expect(ReaderBookmark.fromJson('not a map'), isNull);
    expect(ReaderBookmark.fromJson({'chapterIndex': 1}), isNull);
    expect(
      ReaderBookmark.fromJson({
        'chapterIndex': 1,
        'paragraphIndex': -3,
        'characterOffset': 0,
      }),
      isNull,
    );
    final recovered = ReaderBookmark.fromJson({
      'chapterIndex': 1,
      'paragraphIndex': 2,
      'characterOffset': 3,
    });
    expect(recovered, isNotNull);
    expect(recovered!.id, isNotEmpty);
    expect(recovered.note, isEmpty);
  });

  test('the newest marks survive when a book runs past the cap', () async {
    final marks = store();
    await marks.saveBookmarks('book', [
      for (var index = 0; index < maxReaderBookmarksPerBook + 20; index++)
        _mark(
          id: 'mark-$index',
          chapter: index,
          createdAt: DateTime(2026, 1, 1).add(Duration(minutes: index)),
        ),
    ]);

    final restored = await marks.getBookmarks('book');
    expect(restored, hasLength(maxReaderBookmarksPerBook));
    expect(restored.first.id, 'mark-20');
    expect(restored.last.id, 'mark-${maxReaderBookmarksPerBook + 19}');
  });

  test('a deleted book neither reads nor writes marks', () async {
    final live = store();
    await live.saveBookmarks('book', [_mark(id: 'a')]);

    final gone = store(deleted: {'book'});
    expect(await gone.getBookmarks('book'), isEmpty);
    await gone.saveBookmarks('book', [_mark(id: 'b')]);
    expect((await live.getBookmarks('book')).single.id, 'a');
  });

  test('clearing book state also removes its marks', () async {
    final marks = store();
    await marks.saveBookmarks('book', [_mark(id: 'a')]);
    await marks.clearBookState('book');
    expect(await marks.getBookmarks('book'), isEmpty);
  });

  test('excerpt clamping never leaves an unpaired surrogate', () {
    final emoji = '📚' * 200;
    final clamped = clampBookmarkText(emoji, 101);
    expect(clamped.length.isEven, isTrue);
    expect(clamped.runes.every((rune) => rune == 0x1F4DA), isTrue);
  });
}
