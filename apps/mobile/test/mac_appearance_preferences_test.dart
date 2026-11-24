import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/services/app_appearance.dart';

class ThemeSecrets extends FlutterSecureStorage {
  int reads = 0, writes = 0;
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    throw StateError('Mac appearance must not query Keychain');
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes++;
    throw StateError('Mac appearance must not write Keychain');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mentor-theme-test-');
    file = File('${directory.path}/theme.txt');
  });
  tearDown(() async => directory.delete(recursive: true));

  test('Mac keeps existing palette files without any Keychain call', () async {
    for (final palette in AppPalette.values) {
      await file.writeAsString(palette.name);
      final secrets = ThemeSecrets();
      final appearance = AppAppearance(
        storage: secrets,
        macPreferences: true,
        preferenceFile: () async => file,
      );
      await appearance.load();
      expect(appearance.palette, palette);
      expect(secrets.reads, 0);
      expect(secrets.writes, 0);
      appearance.dispose();
    }
  });

  test(
    'Missing preferences use warm across restarts without a legacy query',
    () async {
      final secrets = ThemeSecrets();
      for (var run = 0; run < 2; run++) {
        final appearance = AppAppearance(
          storage: secrets,
          macPreferences: true,
          preferenceFile: () async => file,
        );
        await appearance.load();
        expect(appearance.palette, AppPalette.warm);
        appearance.dispose();
      }
      expect(secrets.reads, 0);
      expect(secrets.writes, 0);
    },
  );

  test('Mac changes palette and restores it from the file only', () async {
    final secrets = ThemeSecrets();
    final first = AppAppearance(
      storage: secrets,
      macPreferences: true,
      preferenceFile: () async => file,
    );
    await first.load();
    await first.select(AppPalette.black);
    first.dispose();
    final next = AppAppearance(
      storage: secrets,
      macPreferences: true,
      preferenceFile: () async => file,
    );
    await next.load();
    expect(next.palette, AppPalette.black);
    expect(await file.readAsString(), 'black');
    expect(secrets.reads, 0);
    expect(secrets.writes, 0);
    next.dispose();
  });

  test('Malformed cosmetic file does not fall back to Keychain', () async {
    final secrets = ThemeSecrets();
    await file.writeAsString('not a palette');
    final appearance = AppAppearance(
      storage: secrets,
      macPreferences: true,
      preferenceFile: () async => file,
    );
    await appearance.load();
    expect(appearance.palette, AppPalette.warm);
    expect(secrets.reads, 0);
    appearance.dispose();
  });
}
