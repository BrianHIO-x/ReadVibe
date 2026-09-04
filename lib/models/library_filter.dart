enum ShelfFilter { all, recent, unread, txt, epub, kindle, word, pdf }

extension ShelfFilterInfo on ShelfFilter {
  String get label => switch (this) {
    ShelfFilter.all => '全部',
    ShelfFilter.recent => '最近阅读',
    ShelfFilter.unread => '未读',
    ShelfFilter.txt => 'TXT',
    ShelfFilter.epub => 'EPUB',
    ShelfFilter.kindle => 'MOBI/AZW',
    ShelfFilter.word => 'Word',
    ShelfFilter.pdf => 'PDF',
  };
}
