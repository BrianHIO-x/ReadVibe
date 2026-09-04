import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'theme/app_theme.dart';
import 'theme/app_motion.dart';
import 'screens/library_screen.dart';
import 'screens/reader_screen.dart';
import 'screens/pdf_reader_screen.dart';
import 'models/book.dart';
import 'models/reader_launch_args.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ReadVibeApp());
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
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh')],
      locale: const Locale('zh'),
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
