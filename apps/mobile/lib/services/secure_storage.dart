import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The Mac app uses its own legacy Keychain namespace, without a shared-keychain
/// entitlement or a machine-specific provisioning profile. Mobile options keep
/// their existing defaults so this does not move existing phone identities.
const appSecureStorage = FlutterSecureStorage(
  mOptions: MacOsOptions(
    accountName: 'com.nearlink.chat',
    usesDataProtectionKeychain: false,
  ),
);
