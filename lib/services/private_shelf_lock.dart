import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PrivateShelfBiometric {
  fingerprint('指纹'),
  face('人脸');

  const PrivateShelfBiometric(this.label);

  final String label;
}

/// What the private shelf is protected with. The PIN always exists once the
/// shelf is configured; biometrics are optional shortcuts on top of it.
@immutable
class PrivateShelfConfig {
  const PrivateShelfConfig({
    this.configured = false,
    this.biometrics = const <PrivateShelfBiometric>{},
    this.defaultBiometric,
  });

  final bool configured;
  final Set<PrivateShelfBiometric> biometrics;
  final PrivateShelfBiometric? defaultBiometric;

  /// The one biometric offered when unlocking. A stale default that is no
  /// longer enabled falls back to whichever kind still is.
  PrivateShelfBiometric? get unlockBiometric {
    if (biometrics.isEmpty) return null;
    final preferred = defaultBiometric;
    return preferred != null && biometrics.contains(preferred)
        ? preferred
        : biometrics.first;
  }
}

enum BiometricStatus {
  ready,
  notEnrolled,
  noHardware,
  unavailable,
  unsupported,
}

/// What the device opens to apps. Android exposes the hardware kinds, not
/// which of them has been enrolled, so [status] covers biometrics as a whole.
@immutable
class BiometricSupport {
  const BiometricSupport({
    this.fingerprint = false,
    this.face = false,
    this.status = BiometricStatus.unsupported,
  });

  final bool fingerprint;
  final bool face;
  final BiometricStatus status;

  bool hasHardware(PrivateShelfBiometric kind) => switch (kind) {
    PrivateShelfBiometric.fingerprint => fingerprint,
    PrivateShelfBiometric.face => face,
  };

  bool canUse(PrivateShelfBiometric kind) =>
      hasHardware(kind) && status == BiometricStatus.ready;
}

enum BiometricOutcome {
  success,
  cancelled,
  fallback,
  lockout,
  notEnrolled,
  unavailable,
  error,
}

@immutable
class PinCheck {
  const PinCheck.accepted()
    : accepted = true,
      remaining = 0,
      lockedUntil = null;

  const PinCheck.rejected(this.remaining)
    : accepted = false,
      lockedUntil = null;

  const PinCheck.locked(DateTime this.lockedUntil)
    : accepted = false,
      remaining = 0;

  final bool accepted;

  /// Wrong entries left before the next lockout.
  final int remaining;
  final DateTime? lockedUntil;
}

/// Stores the private shelf PIN and verification choices on this device.
///
/// The PIN is kept only as a salted PBKDF2 digest. Repeated wrong entries
/// lock the pad for a growing interval, and the counter is persisted so
/// restarting the app does not reset it.
class PrivateShelfLock {
  PrivateShelfLock({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.readvibe.app/biometric');

  static const pinLength = 6;

  final MethodChannel _channel;

  static const _iterations = 60000;
  static const _freeAttempts = 5;
  static const _firstLockout = Duration(seconds: 30);
  static const _longestLockout = Duration(minutes: 15);

  static const _kSalt = 'private_shelf_salt';
  static const _kDigest = 'private_shelf_digest';
  static const _kIterations = 'private_shelf_iterations';
  static const _kBiometrics = 'private_shelf_biometrics';
  static const _kDefaultBiometric = 'private_shelf_default_biometric';
  static const _kFailures = 'private_shelf_failures';
  static const _kLockedUntil = 'private_shelf_locked_until';

  Future<PrivateShelfConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final configured =
        prefs.getString(_kDigest) != null && prefs.getString(_kSalt) != null;
    if (!configured) return const PrivateShelfConfig();
    final biometrics = <PrivateShelfBiometric>{
      for (final name in prefs.getStringList(_kBiometrics) ?? const <String>[])
        ?PrivateShelfBiometric.values.asNameMap()[name],
    };
    return PrivateShelfConfig(
      configured: true,
      biometrics: Set.unmodifiable(biometrics),
      defaultBiometric: PrivateShelfBiometric.values
          .asNameMap()[prefs.getString(_kDefaultBiometric)],
    );
  }

  static bool isValidPin(String pin) =>
      pin.length == pinLength && pin.codeUnits.every((c) => c >= 48 && c <= 57);

  /// Sets or replaces the PIN. Biometric choices stay as they were.
  Future<void> setPin(String pin) async {
    if (!isValidPin(pin)) {
      throw const FormatException('密码必须是 6 位数字');
    }
    final random = math.Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final digest = await Isolate.run(() => _derive(pin, salt, _iterations));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSalt, base64Encode(salt));
    await prefs.setString(_kDigest, base64Encode(digest));
    await prefs.setInt(_kIterations, _iterations);
    await _clearFailures(prefs);
  }

  Future<PinCheck> verifyPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final lockedUntil = _lockedUntil(prefs);
    if (lockedUntil != null) return PinCheck.locked(lockedUntil);
    final salt = prefs.getString(_kSalt);
    final stored = prefs.getString(_kDigest);
    if (salt == null || stored == null) return const PinCheck.rejected(0);
    final iterations = prefs.getInt(_kIterations) ?? _iterations;
    final saltBytes = base64Decode(salt);
    final digest = isValidPin(pin)
        ? await Isolate.run(() => _derive(pin, saltBytes, iterations))
        : const <int>[];
    if (_sameBytes(digest, base64Decode(stored))) {
      await _clearFailures(prefs);
      return const PinCheck.accepted();
    }
    final failures = (prefs.getInt(_kFailures) ?? 0) + 1;
    await prefs.setInt(_kFailures, failures);
    if (failures < _freeAttempts) {
      return PinCheck.rejected(_freeAttempts - failures);
    }
    // Each lockout past the free attempts doubles, up to the cap.
    final doublings = math.min(failures - _freeAttempts, 5);
    final lockout = Duration(
      seconds: math.min(
        _firstLockout.inSeconds << doublings,
        _longestLockout.inSeconds,
      ),
    );
    final until = DateTime.now().add(lockout);
    await prefs.setInt(_kLockedUntil, until.millisecondsSinceEpoch);
    return PinCheck.locked(until);
  }

  /// The end of the current lockout, or null when the pad is open.
  Future<DateTime?> lockedUntil() async =>
      _lockedUntil(await SharedPreferences.getInstance());

  Future<void> saveBiometrics(
    Set<PrivateShelfBiometric> enabled,
    PrivateShelfBiometric? preferred,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kBiometrics, [
      for (final kind in PrivateShelfBiometric.values)
        if (enabled.contains(kind)) kind.name,
    ]);
    final effective = preferred != null && enabled.contains(preferred)
        ? preferred
        : enabled.firstOrNull;
    if (effective == null) {
      await prefs.remove(_kDefaultBiometric);
    } else {
      await prefs.setString(_kDefaultBiometric, effective.name);
    }
  }

  /// Forgets the PIN and every verification choice.
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in const [
      _kSalt,
      _kDigest,
      _kIterations,
      _kBiometrics,
      _kDefaultBiometric,
      _kFailures,
      _kLockedUntil,
    ]) {
      await prefs.remove(key);
    }
  }

  Future<BiometricSupport> biometricSupport() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'capabilities',
      );
      if (raw == null || raw['supported'] != true) {
        return const BiometricSupport();
      }
      return BiometricSupport(
        fingerprint: raw['fingerprint'] == true,
        face: raw['face'] == true,
        status: switch (raw['status']) {
          'ready' => BiometricStatus.ready,
          'notEnrolled' => BiometricStatus.notEnrolled,
          'noHardware' => BiometricStatus.noHardware,
          _ => BiometricStatus.unavailable,
        },
      );
    } on Object catch (error) {
      debugPrint('Biometric capability query failed: $error');
      return const BiometricSupport();
    }
  }

  /// Shows the system biometric prompt. A success also clears the PIN
  /// failure count, since the reader has proved who they are.
  Future<BiometricOutcome> authenticate(
    PrivateShelfBiometric kind, {
    required String purpose,
    String fallbackLabel = '使用密码',
  }) async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'authenticate',
        {
          'title': '验证${kind.label}',
          'subtitle': purpose,
          'negative': fallbackLabel,
        },
      );
      final outcome = switch (raw?['outcome']) {
        'success' => BiometricOutcome.success,
        'cancelled' || 'busy' => BiometricOutcome.cancelled,
        'fallback' => BiometricOutcome.fallback,
        'lockout' => BiometricOutcome.lockout,
        'notEnrolled' => BiometricOutcome.notEnrolled,
        'unavailable' => BiometricOutcome.unavailable,
        _ => BiometricOutcome.error,
      };
      if (outcome == BiometricOutcome.success) {
        await _clearFailures(await SharedPreferences.getInstance());
      }
      return outcome;
    } on Object catch (error) {
      debugPrint('Biometric prompt failed: $error');
      return BiometricOutcome.error;
    }
  }

  DateTime? _lockedUntil(SharedPreferences prefs) {
    final millis = prefs.getInt(_kLockedUntil);
    if (millis == null) return null;
    final until = DateTime.fromMillisecondsSinceEpoch(millis);
    return until.isAfter(DateTime.now()) ? until : null;
  }

  Future<void> _clearFailures(SharedPreferences prefs) async {
    await prefs.remove(_kFailures);
    await prefs.remove(_kLockedUntil);
  }

  static bool _sameBytes(List<int> first, List<int> second) {
    if (first.length != second.length || first.isEmpty) return false;
    var difference = 0;
    for (var i = 0; i < first.length; i++) {
      difference |= first[i] ^ second[i];
    }
    return difference == 0;
  }

  /// PBKDF2-HMAC-SHA256 with a single 32-byte block.
  static List<int> _derive(String pin, List<int> salt, int iterations) {
    final hmac = Hmac(sha256, utf8.encode(pin));
    var block = hmac.convert(<int>[...salt, 0, 0, 0, 1]).bytes;
    final output = List<int>.of(block);
    for (var round = 1; round < iterations; round++) {
      block = hmac.convert(block).bytes;
      for (var i = 0; i < output.length; i++) {
        output[i] ^= block[i];
      }
    }
    return output;
  }
}
