import 'dart:async';

import 'package:flutter/foundation.dart'
    show LicenseEntry, LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'theme/app_theme.dart';
import 'theme/app_motion.dart';
import 'screens/library_screen.dart';
import 'screens/reader_screen.dart';
import 'screens/pdf_reader_screen.dart';
import 'models/book.dart';
import 'models/reader_launch_args.dart';
import 'services/frame_activity_log.dart';
import 'services/motion_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw behind the status and navigation bars everywhere, so every screen can
  // run its own surface under the gesture bar instead of leaving a blank strip.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  unawaited(MotionService.start());
  FrameActivityLog.start();
  LicenseRegistry.addLicense(_bundledFontLicenses);
  runApp(const ReadVibeApp());
}

/// The Arphic Public License asks for its text to travel with the Kaiti
/// font, so it is listed beside the package licenses. It also asks modified
/// files to say what changed and when, which the second entry does.
Stream<LicenseEntry> _bundledFontLicenses() async* {
  const font = ['AR PL KaitiM GB（文鼎 PL 简中楷）'];
  yield LicenseEntryWithLineBreaks(
    font,
    await rootBundle.loadString('assets/licenses/arphic-public-license.txt'),
  );
  yield const LicenseEntryWithLineBreaks(
    font,
    'ReadVibe 随附的字库文件改动了 hhea 表里的行间距，把数值从 6 调整为 0。'
    '这样设置以后，每一行的行距都会与行框保持一致。'
    '字形和其他数据全部保持原样，没有做任何修改。\n\n'
    '改动完成的日期，是 2026 年 10 月 30 日。',
  );
}

class ReadVibeApp extends StatelessWidget {
  const ReadVibeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ReadVibe',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      // Every route's lists report their scrolling here, so the display runs
      // at its fastest rate only while something actually moves.
      builder: (context, child) => NotificationListener<ScrollNotification>(
        onNotification: MotionService.handleScroll,
        child: child ?? const SizedBox.shrink(),
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // ReadVibe ships a Chinese interface only. Naming the script and region
      // also settles Han glyph selection: without them a device set to
      // Japanese or Traditional Chinese can shape shared codepoints with the
      // wrong regional forms.
      supportedLocales: const [
        Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hans',
          countryCode: 'CN',
        ),
      ],
      locale: const Locale.fromSubtags(
        languageCode: 'zh',
        scriptCode: 'Hans',
        countryCode: 'CN',
      ),
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/':
            return MaterialPageRoute(builder: (_) => const LibraryScreen());
          case '/reader':
            final args = settings.arguments;
            if (args is! ReaderLaunchArgs && args is! Book) {
              return MaterialPageRoute(
                builder: (_) => const LibraryScreen(),
                settings: settings,
              );
            }
            final book = args is ReaderLaunchArgs ? args.book : args as Book;
            if (book.isPdf) {
              return MaterialPageRoute(
                builder: (_) => PdfReaderScreen(book: book),
                settings: settings,
              );
            }
            return buildFadeScaleRoute(
              (_) => ReaderScreen(book: book),
              settings: settings,
              sourceRect: args is ReaderLaunchArgs ? args.sourceRect : null,
              coverImage: args is ReaderLaunchArgs ? args.coverImage : null,
            );
          default:
            return MaterialPageRoute(builder: (_) => const LibraryScreen());
        }
      },
    );
  }
}
