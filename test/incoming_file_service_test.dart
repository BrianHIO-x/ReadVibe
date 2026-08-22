import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/services/incoming_file_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.readvibe.app/incoming_file');

  tearDown(() async {
    IncomingFileService.stop();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('pending ACTION_VIEW files are consumed serially', () async {
    final pending = <Map<String, String>>[
      <String, String>{
        'path': '/cache/first.txt',
        'name': 'first.txt',
        'mimeType': 'text/plain',
      },
      <String, String>{
        'path': '/cache/second.epub',
        'name': 'second.epub',
        'mimeType': 'application/epub+zip',
      },
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'consumeNext');
          return pending.isEmpty ? null : pending.removeAt(0);
        });
    final received = <IncomingBookFile>[];

    await IncomingFileService.start((file) async => received.add(file));

    expect(received.map((file) => file.name), <String>[
      'first.txt',
      'second.epub',
    ]);
    expect(received.last.mimeType, 'application/epub+zip');
  });
}
