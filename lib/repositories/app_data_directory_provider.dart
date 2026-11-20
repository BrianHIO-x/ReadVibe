import 'dart:io';

/// Narrow resource boundary shared by importers that only need the private
/// app-data directory.
///
/// Kept apart from the reader repository interfaces so format parsers do not
/// pull Flutter models into a worker isolate or a standalone tool.
abstract interface class AppDataDirectoryProvider {
  Future<Directory> getAppDataDirectory();
}
