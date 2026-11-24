import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import '../core/models.dart';
import 'secure_storage.dart';
import 'secret_session_cache.dart';
import 'mac_secret_vault.dart';
import 'mac_secret_vault_platform.dart';

class LocalStore {
  LocalStore({
    FlutterSecureStorage? secrets,
    Database? database,
    bool? cacheSecrets,
    bool? useMacSecretVault,
  }) : _secrets = secrets ?? appSecureStorage,
       _cacheSecrets =
           cacheSecrets ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS),
       _useMacSecretVault =
           useMacSecretVault ??
           (secrets == null &&
               !kIsWeb &&
               defaultTargetPlatform == TargetPlatform.macOS),
       _db = database;
  final FlutterSecureStorage _secrets;
  final bool _cacheSecrets;
  final bool _useMacSecretVault;
  static const _vaultStateKey = 'mac-secret-vault-v1';
  static const _vaultInitializedKey = 'mac-secret-vault-initialized-v1';
  VoidCallback? onSecretMigrationProgress;
  MacVaultMigrationProgress? secretMigrationProgress;
  late final _macVault = MacSecretVault(
    loadEncrypted: () async {
      final stored = await readState(_vaultStateKey);
      if (stored == null) return null;
      if (stored.length != 1 || stored['sealed'] is! String) {
        throw const FormatException('本机密钥库格式异常，原记录已保留');
      }
      return stored['sealed'] as String;
    },
    saveEncrypted: (sealed) => db.transaction((tx) async {
      await tx.insert('local_state', {
        'name': _vaultStateKey,
        'value': jsonEncode({'sealed': sealed}),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await tx.insert('local_state', {
        'name': _vaultInitializedKey,
        'value': jsonEncode({'v': 1}),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }),
    canInitialize: () async => await readState(_vaultInitializedKey) == null,
    readMaster: MacSecretVaultPlatform.readMaster,
    createMaster: MacSecretVaultPlatform.createMaster,
    listLegacyKeys: () async {
      final keys = await MacSecretVaultPlatform.listLegacyKeys();
      if (!keys.contains('identity-seed') &&
          (await hasChatData() || await readAliasState() != null)) {
        throw const FormatException('找不到原身份密钥，已停止迁移并保留聊天记录');
      }
      return keys;
    },
    readLegacy: (key) => _secrets.read(key: key),
    onProgress: (progress) {
      secretMigrationProgress = progress;
      onSecretMigrationProgress?.call();
    },
  );
  late final _secretSession = SecretSessionCache(
    enabled: _cacheSecrets,
    read: (key) =>
        _useMacSecretVault ? _macVault.read(key) : _secrets.read(key: key),
    write: (key, value) => _useMacSecretVault
        ? _macVault.write(key, value)
        : _secrets.write(key: key, value: value),
    delete: (key) =>
        _useMacSecretVault ? _macVault.delete(key) : _secrets.delete(key: key),
  );
  Database? _db;
  Database get db => _db!;
  Future<void> open() async {
    _db ??= await _openDatabase();
    if (_useMacSecretVault) await _macVault.open();
  }

  Future<Database> _openDatabase() async {
    final isWindows = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    if (isWindows) sqfliteFfiInit();
    final factory = isWindows ? databaseFactoryFfi : databaseFactory;
    final directory = isWindows
        ? (await getApplicationSupportDirectory()).path
        : await factory.getDatabasesPath();
    return factory.openDatabase(
      p.join(directory, 'nearlink-v1.db'),
      options: OpenDatabaseOptions(
        // Older Mac builds must not reopen the database and write obsolete
        // per-item Keychain values after the vault has become authoritative.
        version: 6,
        onCreate: (database, _) => createSchema(database),
        onUpgrade: (database, old, _) async {
          if (old < 2) await createStateSchema(database);
          if (old < 3) await _upgradeSecuritySchema(database);
          if (old < 4) await _upgradeMembershipSchema(database);
          if (old < 6) await _upgradeHistorySchema(database);
        },
      ),
    );
  }

  static Future<void> createSchema(Database database) async {
    await createStateSchema(database);
    await database.execute(
      'CREATE TABLE groups (storageId TEXT PRIMARY KEY, groupId TEXT NOT NULL, server TEXT NOT NULL, name TEXT NOT NULL, ownerId TEXT NOT NULL, createdAt INTEGER NOT NULL, lastSeq INTEGER NOT NULL DEFAULT 0, cursor INTEGER NOT NULL DEFAULT 0, keyEpoch INTEGER NOT NULL DEFAULT 0, protocolVersion INTEGER NOT NULL DEFAULT 1, privacyEpoch INTEGER NOT NULL DEFAULT 1, minClientBuild INTEGER NOT NULL DEFAULT 0, rekeyRequired INTEGER NOT NULL DEFAULT 0, membershipRevision INTEGER NOT NULL DEFAULT 0, joinedAt INTEGER NOT NULL DEFAULT 0, historySince INTEGER NOT NULL DEFAULT 0)',
    );
    await database.execute(
      'CREATE TABLE messages (storageId TEXT NOT NULL, messageId TEXT NOT NULL, envelope TEXT NOT NULL, seq INTEGER, storedAt INTEGER, state TEXT NOT NULL, PRIMARY KEY(storageId,messageId))',
    );
    await database.execute(
      'CREATE UNIQUE INDEX message_sequence ON messages(storageId,seq) WHERE seq IS NOT NULL',
    );
    await database.execute(
      'CREATE TABLE invitations (storageId TEXT NOT NULL, inviteId TEXT NOT NULL, expiresAt INTEGER NOT NULL, PRIMARY KEY(storageId,inviteId))',
    );
    await database.execute(
      'CREATE TABLE members (storageId TEXT NOT NULL, deviceId TEXT NOT NULL, publicKey TEXT NOT NULL, displayName TEXT NOT NULL, encryptionPublicKey TEXT, clientBuild INTEGER NOT NULL DEFAULT 0, protocolVersion INTEGER NOT NULL DEFAULT 1, privacyEpoch INTEGER NOT NULL DEFAULT 1, grantedKeyEpoch INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(storageId,deviceId))',
    );
  }

  static Future<void> _upgradeSecuritySchema(Database database) async {
    for (final entry in {
      'groups': [
        'keyEpoch INTEGER NOT NULL DEFAULT 0',
        'protocolVersion INTEGER NOT NULL DEFAULT 1',
        'privacyEpoch INTEGER NOT NULL DEFAULT 1',
        'minClientBuild INTEGER NOT NULL DEFAULT 0',
      ],
      'members': [
        'encryptionPublicKey TEXT',
        'clientBuild INTEGER NOT NULL DEFAULT 0',
        'protocolVersion INTEGER NOT NULL DEFAULT 1',
        'privacyEpoch INTEGER NOT NULL DEFAULT 1',
        'grantedKeyEpoch INTEGER NOT NULL DEFAULT 0',
      ],
    }.entries) {
      for (final column in entry.value) {
        await database.execute('ALTER TABLE ${entry.key} ADD COLUMN $column');
      }
    }
  }

  static Future<void> _upgradeMembershipSchema(Database database) async {
    await database.execute(
      'ALTER TABLE groups ADD COLUMN rekeyRequired INTEGER NOT NULL DEFAULT 0',
    );
    await database.execute(
      'ALTER TABLE groups ADD COLUMN membershipRevision INTEGER NOT NULL DEFAULT 0',
    );
  }

  static Future<void> _upgradeHistorySchema(Database database) async {
    final columns = (await database.rawQuery(
      'PRAGMA table_info(groups)',
    )).map((r) => r['name']).toSet();
    for (final name in ['joinedAt', 'historySince']) {
      if (!columns.contains(name)) {
        await database.execute(
          'ALTER TABLE groups ADD COLUMN $name INTEGER NOT NULL DEFAULT 0',
        );
      }
    }
  }

  Future<Map<String, dynamic>?> readState(String name) async {
    final rows = await db.query(
      'local_state',
      columns: ['value'],
      where: 'name=?',
      whereArgs: [name],
    );
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(
      jsonDecode(rows.single['value'] as String) as Map,
    );
  }

  Future<void> writeState(String name, Map<String, dynamic> value) async {
    await db.insert('local_state', {
      'name': name,
      'value': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteState(String name) async {
    await db.delete('local_state', where: 'name=?', whereArgs: [name]);
  }

  static const _departurePrefix = 'group-leave:';
  Future<Map<String, Map<String, dynamic>>> groupDepartures() async {
    final rows = await db.query(
      'local_state',
      columns: ['name', 'value'],
      where: 'name LIKE ?',
      whereArgs: ['$_departurePrefix%'],
    );
    return {
      for (final row in rows)
        (row['name'] as String).substring(
          _departurePrefix.length,
        ): Map<String, dynamic>.from(
          jsonDecode(row['value'] as String) as Map,
        ),
    };
  }

  Future<void> markGroupLeft(Group group, String leaveId) =>
      db.transaction((tx) async {
        await tx.insert('local_state', {
          'name': '$_departurePrefix${group.storageId}',
          'value': jsonEncode({
            'leaveId': leaveId,
            'groupId': group.id,
            'server': group.server,
            'pending': true,
          }),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await tx.update(
          'messages',
          {'state': 'retired'},
          where: 'storageId=? AND state=?',
          whereArgs: [group.storageId, 'pending'],
        );
      });

  Future<void> confirmGroupLeft(Group group, String leaveId) =>
      db.transaction((tx) async {
        final name = '$_departurePrefix${group.storageId}';
        final rows = await tx.query(
          'local_state',
          columns: ['value'],
          where: 'name=?',
          whereArgs: [name],
        );
        if (rows.isEmpty) return;
        final state = Map<String, dynamic>.from(
          jsonDecode(rows.single['value'] as String) as Map,
        );
        if (state['leaveId'] != leaveId) return;
        state['pending'] = false;
        await tx.update(
          'local_state',
          {'value': jsonEncode(state)},
          where: 'name=?',
          whereArgs: [name],
        );
      });

  /// Keep only the durable leave operation; no chat metadata is retained here.
  Future<void> markGroupDeleted(Group group, String leaveId) => db.transaction((
    tx,
  ) async {
    final rows = await tx.query(
      'local_state',
      columns: ['value'],
      where: 'name=?',
      whereArgs: ['$_departurePrefix${group.storageId}'],
    );
    final old = rows.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(rows.single['value'] as String));
    final state = <String, dynamic>{
      'leaveId': old['leaveId'] ?? leaveId,
      'groupId': group.id,
      'server': group.server,
      'pending': old['pending'] ?? true,
      'deleted': true,
      'cleanupPending': true,
    };
    await tx.insert('local_state', {
      'name': '$_departurePrefix${group.storageId}',
      'value': jsonEncode(state),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    for (final table in ['messages', 'members', 'invitations', 'groups']) {
      await tx.delete(
        table,
        where: 'storageId=?',
        whereArgs: [group.storageId],
      );
    }
    for (final prefix in [
      'pending-rejoin:',
      'pending-rekey:',
      'pending-admission:',
    ]) {
      await tx.delete(
        'local_state',
        where: 'name=?',
        whereArgs: ['$prefix${group.storageId}'],
      );
    }
  });

  Future<void> finishGroupDeletion(Group group) => db.transaction((tx) async {
    final name = '$_departurePrefix${group.storageId}';
    final rows = await tx.query(
      'local_state',
      columns: ['value'],
      where: 'name=?',
      whereArgs: [name],
    );
    if (rows.isEmpty) return;
    final state = Map<String, dynamic>.from(
      jsonDecode(rows.single['value'] as String),
    );
    if (state['deleted'] != true) return;
    state['cleanupPending'] = false;
    await tx.update(
      'local_state',
      {'value': jsonEncode(state)},
      where: 'name=?',
      whereArgs: [name],
    );
  });

  /// Override together with read/writeSecret in in-memory test stores.
  Future<List<String>> listSecretKeys() async => _useMacSecretVault
      ? _macVault.keys()
      : (await _secrets.readAll()).keys.toList();

  Future<void> _groupSecretsTail = Future.value();
  Future<T> _groupSecrets<T>(Future<T> Function() operation) {
    final pending = _groupSecretsTail.then((_) => operation());
    _groupSecretsTail = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return pending;
  }

  Future<void> deleteGroupKeys(Group group) => _groupSecrets(() async {
    final base = _keyName(group, 0);
    bool matches(String key) =>
        key == base ||
        key.startsWith('$base:epoch:') ||
        key == 'pending:$base' ||
        key.startsWith('pending:$base:epoch:');
    for (final key in (await listSecretKeys()).where(matches)) {
      await deleteSecret(key);
    }
  });

  Future<bool> _isDeleted(
    DatabaseExecutor executor,
    Group group, {
    bool allowRejoin = false,
  }) async {
    final rows = await executor.query(
      'local_state',
      columns: ['value'],
      where: 'name=?',
      whereArgs: ['$_departurePrefix${group.storageId}'],
    );
    if (rows.isEmpty) return false;
    final departure = jsonDecode(rows.single['value'] as String) as Map;
    if (departure['deleted'] != true) return false;
    if (allowRejoin &&
        departure['pending'] != true &&
        departure['cleanupPending'] != true) {
      final intents = await executor.query(
        'local_state',
        columns: ['value'],
        where: 'name=?',
        whereArgs: ['pending-rejoin:${group.storageId}'],
      );
      if (intents.isNotEmpty &&
          (jsonDecode(intents.single['value'] as String) as Map)['leaveId'] ==
              departure['leaveId']) {
        return false;
      }
    }
    return true;
  }

  Future<void> writeGroupState(
    Group group,
    String name,
    Map<String, dynamic> value,
  ) => db.transaction((tx) async {
    await _requireCurrentMembership(tx, group);
    await tx.insert('local_state', {
      'name': name,
      'value': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  });

  Future<void> prepareGroupJoin(
    Group group,
    String? expectedLeaveId,
    int startedAt, {
    required bool newAdmission,
  }) => db.transaction((tx) async {
    final rows = await tx.query(
      'local_state',
      columns: ['value'],
      where: 'name=?',
      whereArgs: ['$_departurePrefix${group.storageId}'],
    );
    final departure = rows.isEmpty
        ? null
        : jsonDecode(rows.single['value'] as String) as Map;
    if (departure?['leaveId'] != expectedLeaveId ||
        departure?['pending'] == true ||
        departure?['cleanupPending'] == true) {
      throw StateError('群成员状态已变化，请重试入群');
    }
    if (expectedLeaveId != null) {
      await tx.insert('local_state', {
        'name': 'pending-rejoin:${group.storageId}',
        'value': jsonEncode({
          'leaveId': expectedLeaveId,
          'keyEpoch': group.keyEpoch,
        }),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (newAdmission) {
      await tx.insert('local_state', {
        'name': 'pending-admission:${group.storageId}',
        'value': jsonEncode({
          'joinedAt': startedAt,
          'historySince': startedAt - const Duration(hours: 24).inMilliseconds,
        }),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  });

  Future<void> finishGroupJoin(Group group, String? expectedLeaveId) =>
      db.transaction((tx) async {
        final name = '$_departurePrefix${group.storageId}';
        final rows = await tx.query(
          'local_state',
          columns: ['value'],
          where: 'name=?',
          whereArgs: [name],
        );
        final departure = rows.isEmpty
            ? null
            : jsonDecode(rows.single['value'] as String) as Map;
        if (departure?['leaveId'] != expectedLeaveId ||
            departure?['pending'] == true ||
            departure?['cleanupPending'] == true) {
          throw StateError('群成员状态已变化，请重新入群');
        }
        if (departure != null) {
          final intent = await tx.query(
            'local_state',
            columns: ['value'],
            where: 'name=?',
            whereArgs: ['pending-rejoin:${group.storageId}'],
          );
          if (intent.isEmpty ||
              (jsonDecode(intent.single['value'] as String)
                      as Map)['leaveId'] !=
                  expectedLeaveId) {
            throw StateError('入群操作已失效');
          }
        }
        await tx.delete('local_state', where: 'name=?', whereArgs: [name]);
        for (final prefix in ['pending-rejoin:', 'pending-admission:']) {
          await tx.delete(
            'local_state',
            where: 'name=?',
            whereArgs: ['$prefix${group.storageId}'],
          );
        }
      });

  Future<void> clearGroupDeparture(Group group) =>
      deleteState('$_departurePrefix${group.storageId}');

  Future<void> _requireCurrentMembership(Transaction tx, Group group) async {
    final rows = await tx.query(
      'local_state',
      columns: ['name'],
      where: 'name=?',
      whereArgs: ['$_departurePrefix${group.storageId}'],
      limit: 1,
    );
    if (rows.isNotEmpty) throw StateError('你已退出此群，无法继续发送消息');
  }

  Future<Map<String, dynamic>> mergePolicyFloor(
    String name,
    Map<String, dynamic> observed,
  ) => db.transaction((tx) async {
    final rows = await tx.query(
      'local_state',
      columns: ['value'],
      where: 'name=?',
      whereArgs: [name],
    );
    final current = rows.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(
            jsonDecode(rows.single['value'] as String) as Map,
          );
    for (final field in [
      'policyRevision',
      'minClientBuild',
      'protocolVersion',
      'privacyEpoch',
    ]) {
      final next = observed[field] as int,
          previous = current[field] as int? ?? 0;
      current[field] = next > previous ? next : previous;
    }
    await tx.insert('local_state', {
      'name': name,
      'value': jsonEncode(current),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return current;
  });

  static Future<void> createStateSchema(Database database) => database.execute(
    'CREATE TABLE local_state (name TEXT PRIMARY KEY, value TEXT NOT NULL)',
  );
  static const aliasStateName = 'alias-rotation-v1';
  Future<String?> readAliasState() async {
    final rows = await db.query(
      'local_state',
      columns: ['value'],
      where: 'name=?',
      whereArgs: [aliasStateName],
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  Future<void> updateAliasState(
    String? expected,
    String next, {
    required String ownDeviceId,
  }) => db.transaction((tx) async {
    await _replaceAliasState(tx, expected, next);
    await tx.update(
      'members',
      {'displayName': '匿名成员'},
      where: 'deviceId=?',
      whereArgs: [ownDeviceId],
    );
  });

  Future<void> queueWithAliasState(
    Group group,
    Envelope envelope, {
    required String expectedState,
    required String nextState,
    required String ownDeviceId,
  }) => db.transaction((tx) async {
    await _requireCurrentMembership(tx, group);
    await _replaceAliasState(tx, expectedState, nextState);
    // A duplicate event must fail the entire transaction, not consume budget.
    await tx.insert('messages', {
      'storageId': group.storageId,
      'messageId': envelope.messageId,
      'envelope': jsonEncode(envelope.toJson()),
      'state': 'pending',
    });
    await tx.update(
      'members',
      {'displayName': '匿名成员'},
      where: 'deviceId=?',
      whereArgs: [ownDeviceId],
    );
  });

  Future<void> _replaceAliasState(
    Transaction tx,
    String? expected,
    String next,
  ) async {
    final rows = await tx.query(
      'local_state',
      columns: ['value'],
      where: 'name=?',
      whereArgs: [aliasStateName],
    );
    final actual = rows.isEmpty ? null : rows.single['value'] as String;
    if (actual != expected) throw StateError('临时ID状态已变化，请重试发送');
    await tx.insert('local_state', {
      'name': aliasStateName,
      'value': next,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> anonymizeOwnMemberNames(String deviceId) => db
      .update(
        'members',
        {'displayName': '匿名成员'},
        where: 'deviceId=?',
        whereArgs: [deviceId],
      )
      .then((_) {});

  bool get secretAccessBlocked =>
      _secretSession.accessBlocked ||
      (_useMacSecretVault && _macVault.accessBlocked);
  void retrySecretAccess() {
    _secretSession.retryAccess();
    if (_useMacSecretVault) _macVault.retryAccess();
  }

  Future<String?> readSecret(String key) => _secretSession.read(key);
  Future<bool> hasChatData() async {
    final rows = await db.rawQuery(
      'SELECT EXISTS(SELECT 1 FROM groups) OR EXISTS(SELECT 1 FROM messages) AS present',
    );
    return rows.single['present'] == 1;
  }

  Future<void> writeSecret(String key, String value) =>
      _secretSession.write(key, value);
  Future<void> deleteSecret(String key) => _secretSession.delete(key);
  String _keyName(Group group, [int? epoch]) {
    final version = epoch ?? group.keyEpoch;
    final base = 'group-key:${b64(utf8.encode(group.storageId))}';
    return version == 0 ? base : '$base:epoch:$version';
  }

  Future<void> saveKey(Group group, List<int> key, {int? epoch}) =>
      _groupSecrets(() async {
        if (await _isDeleted(db, group, allowRejoin: true)) {
          throw StateError('此聊天空间已删除');
        }
        await writeSecret(_keyName(group, epoch), b64(key));
      });
  Future<void> savePendingKey(Group group, List<int> key) =>
      _groupSecrets(() async {
        if (await _isDeleted(db, group, allowRejoin: true)) {
          throw StateError('此聊天空间已删除');
        }
        await writeSecret('pending:${_keyName(group)}', b64(key));
      });
  Future<void> discardPendingKey(Group group) =>
      deleteSecret('pending:${_keyName(group)}');
  Future<void> recoverPendingKey(Group group) async {
    final pending = await readSecret('pending:${_keyName(group)}');
    if (pending != null && await groupKey(group) == null) {
      await saveKey(group, unb64(pending));
    }
    if (pending != null) await discardPendingKey(group);
  }

  Future<List<int>?> groupKey(Group group, {int? epoch}) async {
    final key = await readSecret(_keyName(group, epoch));
    return key == null ? null : unb64(key);
  }

  Future<void> saveGroup(Group group) => db.transaction((tx) async {
    if (await _isDeleted(tx, group, allowRejoin: true)) return;
    const fresh =
        'excluded.keyEpoch>=groups.keyEpoch AND excluded.membershipRevision>=groups.membershipRevision';
    await tx.rawInsert(
      'INSERT INTO groups(storageId,groupId,server,name,ownerId,createdAt,lastSeq,cursor,keyEpoch,protocolVersion,privacyEpoch,minClientBuild,rekeyRequired,membershipRevision,joinedAt,historySince) VALUES (?,?,?,?,?,?,?,0,?,?,?,?,?,?,?,?) ON CONFLICT(storageId) DO UPDATE SET '
      'name=CASE WHEN $fresh THEN excluded.name ELSE groups.name END,'
      'ownerId=CASE WHEN $fresh THEN excluded.ownerId ELSE groups.ownerId END,'
      'lastSeq=MAX(groups.lastSeq,excluded.lastSeq),'
      'keyEpoch=CASE WHEN $fresh THEN excluded.keyEpoch ELSE groups.keyEpoch END,'
      'rekeyRequired=CASE WHEN $fresh THEN excluded.rekeyRequired ELSE groups.rekeyRequired END,'
      'membershipRevision=CASE WHEN $fresh THEN excluded.membershipRevision ELSE groups.membershipRevision END,'
      'joinedAt=MAX(groups.joinedAt,excluded.joinedAt),historySince=MAX(groups.historySince,excluded.historySince),'
      'protocolVersion=MAX(groups.protocolVersion,excluded.protocolVersion),privacyEpoch=MAX(groups.privacyEpoch,excluded.privacyEpoch),minClientBuild=MAX(groups.minClientBuild,excluded.minClientBuild)',
      [
        group.storageId,
        group.id,
        group.server,
        group.name,
        group.ownerId,
        group.createdAt,
        group.lastSeq,
        group.keyEpoch,
        group.protocolVersion,
        group.privacyEpoch,
        group.minClientBuild,
        group.rekeyRequired ? 1 : 0,
        group.membershipRevision,
        group.joinedAt,
        group.historySince,
      ],
    );
  });

  Future<List<Group>> groups(String server) async => (await db.query(
    'groups',
    where: 'server=?',
    whereArgs: [server],
    orderBy: 'createdAt DESC',
  )).map((j) => Group.fromJson(j, server)).toList();
  Future<int> cursor(Group group) async =>
      (await db.query(
            'groups',
            columns: ['cursor'],
            where: 'storageId=?',
            whereArgs: [group.storageId],
          )).first['cursor']
          as int;
  Future<void> queue(Group group, Envelope envelope) =>
      db.transaction((tx) async {
        await _requireCurrentMembership(tx, group);
        await tx.insert('messages', {
          'storageId': group.storageId,
          'messageId': envelope.messageId,
          'envelope': jsonEncode(envelope.toJson()),
          'state': 'pending',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      });

  Future<void> saveP2p(Group group, Envelope envelope) =>
      db.transaction((tx) async {
        await _requireCurrentMembership(tx, group);
        await tx.insert('messages', {
          'storageId': group.storageId,
          'messageId': envelope.messageId,
          'envelope': jsonEncode(envelope.toJson()),
          'state': 'p2p',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      });

  Future<void> markStored(Group group, String id, int seq, int storedAt) async {
    await db.update(
      'messages',
      {'seq': seq, 'storedAt': storedAt, 'state': 'stored'},
      where: 'storageId=? AND messageId=?',
      whereArgs: [group.storageId, id],
    );
  }

  Future<void> markRetired(Group group, String id) async {
    await db.update(
      'messages',
      {'state': 'retired'},
      where: 'storageId=? AND messageId=? AND state=?',
      whereArgs: [group.storageId, id, 'pending'],
    );
  }

  Future<void> quarantine(Group group, String id) async {
    await db.update(
      'messages',
      {'state': 'invalid'},
      where: 'storageId=? AND messageId=?',
      whereArgs: [group.storageId, id],
    );
  }

  /// Failed envelopes are retained separately, allowing later valid messages to sync.
  /// Return conflicting P2P copies replaced by the verified mailbox copy.
  Future<int> ingestPage(
    Group group,
    List<Map<String, dynamic>> messages,
    int cursor, {
    Set<String> invalidIds = const {},
    Set<String> lockedIds = const {},
  }) async {
    var conflicts = 0;
    await db.transaction((tx) async {
      await _requireCurrentMembership(tx, group);
      final rows = await tx.query(
        'groups',
        columns: ['historySince'],
        where: 'storageId=?',
        whereArgs: [group.storageId],
      );
      final floor = rows.isEmpty
          ? group.historySince
          : rows.single['historySince'] as int;
      for (final message in messages) {
        if (floor > 0 &&
            (message['storedAt'] is! num ||
                (message['storedAt'] as num) < floor)) {
          continue;
        }
        final id = message['messageId'] as String;
        final invalid = invalidIds.contains(id);
        final encoded = jsonEncode(
          invalid ? message : Envelope.fromJson(message).toJson(),
        );
        final previous = await tx.query(
          'messages',
          columns: ['envelope'],
          where: 'storageId=? AND messageId=?',
          whereArgs: [group.storageId, id],
        );
        if (previous.isNotEmpty && previous.first['envelope'] != encoded) {
          conflicts++;
        }
        await tx.rawInsert(
          'INSERT INTO messages(storageId,messageId,envelope,seq,storedAt,state) VALUES (?,?,?,?,?,?) ON CONFLICT(storageId,messageId) DO UPDATE SET seq=excluded.seq,storedAt=excluded.storedAt,state=excluded.state',
          [
            group.storageId,
            id,
            encoded,
            message['seq'],
            message['storedAt'],
            invalid
                ? 'invalid'
                : lockedIds.contains(id)
                ? 'locked'
                : 'stored',
          ],
        );
        await tx.update(
          'messages',
          {'envelope': encoded},
          where: 'storageId=? AND messageId=?',
          whereArgs: [group.storageId, id],
        );
      }
      await tx.update(
        'groups',
        {'cursor': cursor},
        where: 'storageId=? AND cursor<=?',
        whereArgs: [group.storageId, cursor],
      );
    });
    return conflicts;
  }

  Future<Map<String, Object?>?> messageRecord(Group group, String id) async {
    final records = await db.query(
      'messages',
      where: 'storageId=? AND messageId=? AND state!=?',
      whereArgs: [group.storageId, id, 'invalid'],
      limit: 1,
    );
    return records.firstOrNull;
  }

  Future<List<Map<String, Object?>>> messages(Group group) => db.query(
    'messages',
    where: 'storageId=? AND state!=?',
    whereArgs: [group.storageId, 'invalid'],
    orderBy: 'CASE WHEN seq IS NULL THEN 1 ELSE 0 END, seq, rowid',
  );
  Future<int> quarantinedCount(Group group) async =>
      Sqflite.firstIntValue(
        await db.rawQuery(
          'SELECT COUNT(*) FROM messages WHERE storageId=? AND state=?',
          [group.storageId, 'invalid'],
        ),
      ) ??
      0;
  Future<List<Envelope>> outbox(Group group) async =>
      (await db.query(
            'messages',
            where: 'storageId=? AND state=?',
            whereArgs: [group.storageId, 'pending'],
            orderBy: 'rowid',
          ))
          .map((j) => Envelope.fromJson(jsonDecode(j['envelope'] as String)))
          .toList();
  Future<void> saveMembers(
    Group group,
    List<Member> members, {
    String? ownDeviceId,
  }) async {
    await db.transaction((tx) async {
      if (await _isDeleted(tx, group)) return;
      for (final member in members) {
        await tx.insert('members', {
          'storageId': group.storageId,
          'deviceId': member.id,
          'publicKey': member.publicKey,
          'displayName': member.id == ownDeviceId ? '匿名成员' : member.name,
          'encryptionPublicKey': member.encryptionPublicKey,
          'clientBuild': member.clientBuild,
          'protocolVersion': member.protocolVersion,
          'privacyEpoch': member.privacyEpoch,
          'grantedKeyEpoch': member.grantedKeyEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<List<Member>> members(Group group) async => (await db.query(
    'members',
    where: 'storageId=?',
    whereArgs: [group.storageId],
  )).map((m) => Member.fromJson(Map<String, dynamic>.from(m))).toList();
  Future<void> addInvite(Group group, String id, int expiresAt) =>
      db.transaction((tx) async {
        await _requireCurrentMembership(tx, group);
        await tx.insert('invitations', {
          'storageId': group.storageId,
          'inviteId': id,
          'expiresAt': expiresAt,
        });
      });
  Future<List<Map<String, Object?>>> invitations(Group group) => db.query(
    'invitations',
    where: 'storageId=?',
    whereArgs: [group.storageId],
    orderBy: 'expiresAt DESC',
  );
  Future<void> deleteInvite(Group group, String id) => db
      .delete(
        'invitations',
        where: 'storageId=? AND inviteId=?',
        whereArgs: [group.storageId, id],
      )
      .then((_) {});
  Future<void> close() async {
    onSecretMigrationProgress = null;
    _secretSession.close();
    if (_useMacSecretVault) _macVault.close();
    await _db?.close();
  }
}
