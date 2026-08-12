import 'package:flutter_test/flutter_test.dart';
import 'package:readvibe/services/update_service.dart';

void main() {
  group('update service version comparison', () {
    test('remote patch bump is newer', () {
      expect(UpdateService.isNewerVersion('0.6.3', '0.6.2'), isTrue);
    });

    test('remote minor bump is newer', () {
      expect(UpdateService.isNewerVersion('0.7.0', '0.6.2'), isTrue);
    });

    test('same version is not newer', () {
      expect(UpdateService.isNewerVersion('0.6.2', '0.6.2'), isFalse);
    });

    test('older remote is not newer', () {
      expect(UpdateService.isNewerVersion('0.5.6', '0.6.2'), isFalse);
      expect(UpdateService.isNewerVersion('0.6.1', '0.6.2'), isFalse);
    });

    test('malformed versions are rejected', () {
      expect(UpdateService.isNewerVersion('v0.7', '0.6.2'), isFalse);
      expect(UpdateService.isNewerVersion('0.7.0', 'beta'), isFalse);
      expect(UpdateService.isNewerVersion('', '0.6.2'), isFalse);
    });
  });

  group('update service release notes parsing', () {
    const hash =
        '13BAC9816BC6B08DB384CF881FC6100E10348D43C2E0F2083204787B6EDE415A';

    test('reads full-width colon format', () {
      expect(UpdateService.sha256FromNotes('SHA-256：$hash'), hash);
    });

    test('reads half-width colon format', () {
      expect(UpdateService.sha256FromNotes('SHA-256: $hash'), hash);
    });

    test('reads hash embedded in longer notes', () {
      final notes = '公开版本：v0.6.2\n最低系统：Android 8.0\nSHA-256：$hash\n';
      expect(UpdateService.sha256FromNotes(notes), hash);
    });

    test('returns null when no hash present', () {
      expect(UpdateService.sha256FromNotes('普通更新说明'), isNull);
      expect(
        UpdateService.sha256FromNotes('SHA-256：tooshort'),
        isNull,
      );
    });
  });
}
