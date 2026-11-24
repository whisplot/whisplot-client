import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/chat_controller.dart';
import 'package:nearlink/core/crypto_service.dart';
import 'package:nearlink/core/default_connection.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/services/local_store.dart';
import 'package:nearlink/services/network_monitor.dart';

class LifecycleSecrets extends FlutterSecureStorage {
  final values = <String, String>{};
  final calls = <String>[];
  Completer<String?>? identityRead;
  bool denyIdentity = false, denyConnectionWrite = false;
  PlatformException get cancelled =>
      PlatformException(code: 'Unexpected security result code', details: -128);
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
    calls.add('read:$key');
    if (key == 'identity-seed') {
      if (denyIdentity) throw cancelled;
      final pending = identityRead;
      if (pending != null) return pending.future;
    }
    return values[key];
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
    calls.add('write:$key');
    if (key == ChatController.connectionSettingsKey && denyConnectionWrite) {
      throw cancelled;
    }
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls.add('delete:$key');
    values.remove(key);
  }
}

class LifecycleStore extends LocalStore {
  LifecycleStore(LifecycleSecrets secrets)
    : super(secrets: secrets, cacheSecrets: true);
  int opens = 0, historyReads = 0;
  String? alias;
  final state = <String, Map<String, dynamic>>{};
  @override
  Future<void> open() async {
    opens++;
  }

  @override
  Future<bool> hasChatData() async {
    historyReads++;
    return false;
  }

  @override
  Future<String?> readAliasState() async => alias;
  @override
  Future<void> updateAliasState(
    String? expected,
    String next, {
    required String ownDeviceId,
  }) async {
    expect(alias, expected);
    alias = next;
  }

  @override
  Future<void> anonymizeOwnMemberNames(String deviceId) async {}
  @override
  Future<Map<String, Map<String, dynamic>>> groupDepartures() async => {};
  @override
  Future<Map<String, dynamic>?> readState(String name) async => state[name];
  @override
  Future<void> writeState(String name, Map<String, dynamic> value) async {
    state[name] = value;
  }

  @override
  Future<List<Group>> groups(String server) async => [];
}

class CountingCrypto extends CryptoService {
  int identityCalls = 0, newIdentities = 0, encryptionCalls = 0;
  @override
  Future<Identity> identity([List<int>? seed]) {
    identityCalls++;
    if (seed == null) newIdentities++;
    return super.identity(seed);
  }

  @override
  Future<EncryptionIdentity> encryptionIdentity([List<int>? seed]) {
    encryptionCalls++;
    return super.encryptionIdentity(seed);
  }
}

class NoNetworkPaths implements NetworkMonitor {
  const NoNetworkPaths();
  @override
  Stream<NetworkPathChange> get changes => const Stream.empty();
}

class LifecycleController extends ChatController {
  LifecycleController({
    required LifecycleStore store,
    required CountingCrypto crypto,
    DefaultConnection connection = const DefaultConnection(),
  }) : super(
         store: store,
         crypto: crypto,
         defaultConnection: connection,
         networkMonitor: const NoNetworkPaths(),
       );
  int reconnects = 0;
  @override
  Future<void> reconnect() async {
    reconnects++;
  }
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(
    condition(),
    isTrue,
    reason: 'Lifecycle operation did not reach its controlled boundary',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'disposing during identity read stops initialization before further secret IO or new identity',
    () async {
      final pending = Completer<String?>();
      final secrets = LifecycleSecrets()..identityRead = pending;
      final store = LifecycleStore(secrets), crypto = CountingCrypto();
      final controller = LifecycleController(store: store, crypto: crypto);
      final initializing = controller.initialize();
      await until(() => secrets.calls.contains('read:identity-seed'));
      controller.dispose();
      pending.complete(null);
      await initializing;
      await controller.initialize();
      expect(secrets.calls, ['read:identity-seed']);
      expect(store.historyReads, 0);
      expect(crypto.identityCalls, 0);
      expect(crypto.newIdentities, 0);
      expect(crypto.encryptionCalls, 0);
      expect(controller.ready, isFalse);
      expect(controller.api, isNull);
      expect(secrets.values, isEmpty);
    },
  );
  test(
    'concurrent initialize calls share one startup and one identity creation',
    () async {
      final pending = Completer<String?>();
      final secrets = LifecycleSecrets()..identityRead = pending;
      final store = LifecycleStore(secrets), crypto = CountingCrypto();
      final controller = LifecycleController(store: store, crypto: crypto);
      addTearDown(controller.dispose);
      final attempts = List.generate(12, (_) => controller.initialize());
      await until(() => secrets.calls.contains('read:identity-seed'));
      expect(store.opens, 1);
      expect(secrets.calls, ['read:identity-seed']);
      secrets.identityRead = null;
      pending.complete(null);
      await Future.wait(attempts);
      expect(controller.ready, isTrue);
      expect(crypto.identityCalls, 1);
      expect(crypto.newIdentities, 1);
      expect(crypto.encryptionCalls, 1);
      expect(
        secrets.calls.where((call) => call == 'write:identity-seed'),
        hasLength(1),
      );
      final completedCalls = List<String>.from(secrets.calls);
      await controller.initialize();
      expect(secrets.calls, completedCalls);
      expect(store.opens, 1);
    },
  );
  test(
    'cancelled identity authorization stays paused until explicit retry and preserves the original seed',
    () async {
      final seed = List<int>.filled(32, 7),
          existing = await CryptoService().identity(List<int>.filled(32, 7));
      final secrets = LifecycleSecrets()
        ..denyIdentity = true
        ..values['identity-seed'] = b64(seed);
      final store = LifecycleStore(secrets), crypto = CountingCrypto();
      final controller = LifecycleController(store: store, crypto: crypto);
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.ready, isFalse);
      expect(controller.error, contains('钥匙串访问已暂停'));
      expect(store.secretAccessBlocked, isTrue);
      expect(crypto.identityCalls, 0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(secrets.calls, ['read:identity-seed']);
      secrets.denyIdentity = false;
      await controller.initialize();
      expect(secrets.calls, ['read:identity-seed']);
      expect(controller.ready, isFalse);
      await controller.retryInitialization();
      expect(controller.ready, isTrue);
      expect(store.secretAccessBlocked, isFalse);
      expect(controller.identity.id, existing.id);
      expect(crypto.newIdentities, 0);
      expect(secrets.values['identity-seed'], b64(seed));
      expect(
        secrets.calls.where((call) => call == 'write:identity-seed'),
        isEmpty,
      );
      expect(
        secrets.calls.where((call) => call == 'read:identity-seed'),
        hasLength(2),
      );
    },
  );
  test(
    'cancelled first connection save returns to initialization retry without replacing identity',
    () async {
      final secrets = LifecycleSecrets()..denyConnectionWrite = true;
      final store = LifecycleStore(secrets), crypto = CountingCrypto();
      final controller = LifecycleController(
        store: store,
        crypto: crypto,
        connection: const DefaultConnection(
          server: 'https://lifecycle.example',
          registrationCode: 'synthetic-test-code',
        ),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.ready, isFalse);
      expect(controller.error, contains('钥匙串访问已暂停'));
      expect(store.secretAccessBlocked, isTrue);
      final originalSeed = secrets.values['identity-seed'];
      expect(originalSeed, isNotNull);
      expect(controller.reconnects, 0);
      final callsAtCancel = List<String>.from(secrets.calls);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(secrets.calls, callsAtCancel);
      secrets.denyConnectionWrite = false;
      await controller.retryInitialization();
      expect(controller.ready, isTrue);
      expect(controller.configured, isTrue);
      expect(controller.server, 'https://lifecycle.example');
      expect(controller.reconnects, 1);
      expect(secrets.values['identity-seed'], originalSeed);
      expect(crypto.newIdentities, 1);
      expect(
        secrets.calls.where((call) => call == 'write:identity-seed'),
        hasLength(1),
      );
      expect(
        secrets.calls.where(
          (call) => call == 'write:${ChatController.connectionSettingsKey}',
        ),
        hasLength(2),
      );
    },
  );
}
