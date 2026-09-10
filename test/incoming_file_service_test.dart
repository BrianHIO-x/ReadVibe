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

  test('one unreadable file does not strand the rest of the queue', () async {
    final pending = <Map<String, String>>[
      <String, String>{'path': '/cache/a.txt', 'name': 'a.txt'},
      <String, String>{'path': '/cache/broken.epub', 'name': 'broken.epub'},
      <String, String>{'path': '/cache/c.pdf', 'name': 'c.pdf'},
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => pending.isEmpty ? null : pending.removeAt(0),
        );
    final received = <String>[];
    final errors = <String>[];

    await IncomingFileService.start(
      (file) async {
        if (file.name == 'broken.epub') {
          throw const FormatException('EPUB 已损坏');
        }
        received.add(file.name);
      },
      onError: errors.add,
    );

    expect(received, <String>['a.txt', 'c.pdf']);
    expect(errors, hasLength(1));
  });

  test('a channel failure stops draining without losing the handler', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          if (calls == 1) throw PlatformException(code: 'QUEUE_UNAVAILABLE');
          return null;
        });
    final errors = <String>[];

    await IncomingFileService.start((file) async {}, onError: errors.add);

    expect(errors, hasLength(1));
    expect(errors.single, '无法读取外部文件');
    // A later notification must still be able to drain the queue.
    expect(calls, 1);
  });
}
