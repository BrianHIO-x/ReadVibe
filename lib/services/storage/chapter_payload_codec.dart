import '../../models/book.dart';

Chapter decodeChapterPayload(Object? value, int index) {
  if (value is! Map) throw const FormatException('章节数据格式错误');
  final map = Map<String, dynamic>.from(value);
  final title = map['title'];
  final content = map['content'];
  if (title is! String || content is! String) {
    throw const FormatException('章节数据格式错误');
  }
  final rawVolumeTitle = map['volumeTitle'];
  final volumeTitle =
      rawVolumeTitle is String && rawVolumeTitle.trim().isNotEmpty
      ? rawVolumeTitle.trim()
      : null;
  final epubBlocks = _epubBlocksFromJson(map['epubBlocks']);
  final restoredContent = content.isNotEmpty || epubBlocks.isEmpty
      ? content
      : _plainContentFromEpubBlocks(epubBlocks);
  return Chapter(
    index: index,
    title: title,
    content: restoredContent,
    volumeTitle: volumeTitle,
    epubBlocks: epubBlocks,
  );
}

Map<String, dynamic> encodeChapterPayload(Chapter chapter) => <String, dynamic>{
  'index': chapter.index,
  'title': chapter.title,
  // Rich EPUB blocks already contain the complete visible text. Avoid writing
  // a second full copy; plain text is rebuilt when the chapter is loaded.
  'content': chapter.epubBlocks.isEmpty ? chapter.content : '',
  if (chapter.volumeTitle != null) 'volumeTitle': chapter.volumeTitle,
  if (chapter.epubBlocks.isNotEmpty)
    'epubBlocks': chapter.epubBlocks.map(_epubBlockToJson).toList(),
};

String _plainContentFromEpubBlocks(List<EpubContentBlock> blocks) {
  var body = blocks.where(
    (block) => block.isText && !block.isHeading && block.text.trim().isNotEmpty,
  );
  if (body.isEmpty) {
    body = blocks.where(
      (block) => block.isText && block.text.trim().isNotEmpty,
    );
  }
  return body.map((block) => block.text.trim()).join('\n');
}

List<EpubContentBlock> _epubBlocksFromJson(Object? raw) {
  if (raw is! List) return const <EpubContentBlock>[];
  final blocks = <EpubContentBlock>[];
  for (final value in raw) {
    if (value is! Map) continue;
    final map = Map<String, dynamic>.from(value);
    final kindName = map['kind'];
    final kind = EpubContentBlockKind.values
        .where((candidate) => candidate.name == kindName)
        .firstOrNull;
    if (kind == null) continue;
    final style = _epubStyleFromJson(map['style']);
    final runs = <EpubTextRun>[];
    final rawRuns = map['runs'];
    if (rawRuns is List) {
      for (final rawRun in rawRuns) {
        if (rawRun is! Map) continue;
        final run = Map<String, dynamic>.from(rawRun);
        final text = run['text'];
        if (text is! String || text.isEmpty) continue;
        runs.add(
          EpubTextRun(text: text, style: _epubStyleFromJson(run['style'])),
        );
      }
    }
    blocks.add(
      EpubContentBlock(
        kind: kind,
        text: map['text'] is String ? map['text'] as String : '',
        runs: List<EpubTextRun>.unmodifiable(runs),
        isHeading: map['isHeading'] == true,
        imagePath: map['imagePath'] is String
            ? map['imagePath'] as String
            : null,
        altText: map['altText'] is String ? map['altText'] as String : null,
        imageWidth: _jsonDouble(map['imageWidth']),
        imageHeight: _jsonDouble(map['imageHeight']),
        style: style,
      ),
    );
  }
  return List<EpubContentBlock>.unmodifiable(blocks);
}

Map<String, dynamic> _epubBlockToJson(EpubContentBlock block) => {
  'kind': block.kind.name,
  if (block.text.isNotEmpty) 'text': block.text,
  if (block.runs.isNotEmpty)
    'runs': block.runs
        .map((run) => {'text': run.text, 'style': _epubStyleToJson(run.style)})
        .toList(),
  if (block.isHeading) 'isHeading': true,
  if (block.imagePath != null) 'imagePath': block.imagePath,
  if (block.altText != null && block.altText!.isNotEmpty)
    'altText': block.altText,
  if (block.imageWidth != null) 'imageWidth': block.imageWidth,
  if (block.imageHeight != null) 'imageHeight': block.imageHeight,
  'style': _epubStyleToJson(block.style),
};

EpubContentStyle _epubStyleFromJson(Object? raw) {
  if (raw is! Map) return const EpubContentStyle();
  final map = Map<String, dynamic>.from(raw);
  return EpubContentStyle(
    fontFamily:
        map['fontFamily'] is String &&
            (map['fontFamily'] as String).trim().isNotEmpty
        ? (map['fontFamily'] as String).trim()
        : null,
    fontScale: _jsonDouble(map['fontScale']) ?? 1,
    fontWeight: map['fontWeight'] is num
        ? (map['fontWeight'] as num).toInt().clamp(100, 900)
        : 400,
    italic: map['italic'] == true,
    underline: map['underline'] == true,
    textAlign: map['textAlign'] is String
        ? map['textAlign'] as String
        : 'start',
    lineHeightScale: _jsonDouble(map['lineHeightScale']) ?? 1,
    letterSpacingEm: _jsonDouble(map['letterSpacingEm']) ?? 0,
    textIndentEm: _jsonDouble(map['textIndentEm']) ?? 2,
    marginTopEm: _jsonDouble(map['marginTopEm']) ?? 0,
    marginBottomEm: _jsonDouble(map['marginBottomEm']) ?? 0,
    colorArgb: map['colorArgb'] is num
        ? (map['colorArgb'] as num).toInt()
        : null,
    backgroundColorArgb: map['backgroundColorArgb'] is num
        ? (map['backgroundColorArgb'] as num).toInt()
        : null,
    backgroundImagePath: map['backgroundImagePath'] is String
        ? map['backgroundImagePath'] as String
        : null,
  );
}

Map<String, dynamic> _epubStyleToJson(EpubContentStyle style) => {
  if (style.fontFamily != null && style.fontFamily!.isNotEmpty)
    'fontFamily': style.fontFamily,
  if (style.fontScale != 1) 'fontScale': style.fontScale,
  if (style.fontWeight != 400) 'fontWeight': style.fontWeight,
  if (style.italic) 'italic': true,
  if (style.underline) 'underline': true,
  if (style.textAlign != 'start') 'textAlign': style.textAlign,
  if (style.lineHeightScale != 1) 'lineHeightScale': style.lineHeightScale,
  if (style.letterSpacingEm != 0) 'letterSpacingEm': style.letterSpacingEm,
  if (style.textIndentEm != 2) 'textIndentEm': style.textIndentEm,
  if (style.marginTopEm != 0) 'marginTopEm': style.marginTopEm,
  if (style.marginBottomEm != 0) 'marginBottomEm': style.marginBottomEm,
  if (style.colorArgb != null) 'colorArgb': style.colorArgb,
  if (style.backgroundColorArgb != null)
    'backgroundColorArgb': style.backgroundColorArgb,
  if (style.backgroundImagePath != null)
    'backgroundImagePath': style.backgroundImagePath,
};

double? _jsonDouble(Object? value) {
  if (value is! num || !value.isFinite) return null;
  return value.toDouble();
}
