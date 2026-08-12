import 'dart:ui' as ui;

import 'book.dart';

class ReaderLaunchArgs {
  final Book book;
  final ui.Rect? sourceRect;
  final ui.Image? coverImage;

  const ReaderLaunchArgs({
    required this.book,
    this.sourceRect,
    this.coverImage,
  });
}
