# Released 0.3.1 reaction compatibility fixture

The three Dart files here are byte-for-byte exports from client commit
`60048640d8efe8d9e72fc244ca0e93ea206fbf71` (release 0.3.1):

- `apps/mobile/lib/core/crypto_service.dart`
- `apps/mobile/lib/core/models.dart`
- `apps/mobile/lib/core/temporary_id.dart`

Their original relative imports already resolve inside this directory. No source
edits, import rewrites, or formatter changes were applied. `source-manifest.json`
records the original paths, byte lengths, and SHA-256 hashes; the compatibility
test verifies those hashes against fixed expected values. Do not update these
fixtures when changing the current implementation.

`reaction_legacy_compat_test.dart` encrypts and signs real messages with the current
and released crypto services, crosses the serialized envelope boundary, and runs
both actual decryptors, payload validators, event parsers, and reaction folds.
This catches a new reaction causing the old validator to reject the entire event
or resurrect a stale reaction. Unsupported rich reactions intentionally appear as
no reaction in 0.3.1; the current client displays catalog-supported selections.

This verifies the released Dart protocol source using the project's installed
cryptography dependency. It is not a test of an archived binary, network service,
native platform, or UI. These files are test-only and are not bundled app assets.
They retain the provenance and ownership of the original project source.
