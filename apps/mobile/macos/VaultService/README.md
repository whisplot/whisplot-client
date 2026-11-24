# Local macOS vault service

This optional private XPC service makes the Keychain reader independent of
Flutter app rebuilds. macOS file-based Keychain partitions can identify a
self-signed app by its code hash even when its designated requirement stays
the same. Reuse the **same signed service bytes** across app updates.

The service has no network entitlement, global Mach service, listener socket,
secret file, generic Keychain API, or background login registration. It is an
application-scoped XPC service launched by macOS. It reads or creates only the
32-byte vault master and a fixed non-secret migration marker. Existing items
and their access controls are never overwritten or deleted. The client retains
its existing per-run cache.

## Existing-key migration

The legacy account `mac-vault-master-v1` can retain old permission metadata even
after interactive approval. The service copies its **exact same32 bytes** to
its own `mac-vault-master-v2` account, verifies them with a noninteractive read,
then creates and verifies `mac-vault-master-v2-initialized`. This last item has
the fixed non-secret data `hello-mentor-vault:v2:committed`. The old account is
retained; no identity, group key, encrypted vault or history is regenerated.

Every read checks the marker first. A malformed or inaccessible marker fails
closed. With a valid marker, a missing, malformed or inaccessible v2 key also
fails closed; it never falls back to v1 or reports a fresh installation. Only
when both v2 and the marker are absent may the service request permission for
one legacy read. All v2 and marker operations are noninteractive.

If the process stopped after writing v2 but before writing the marker, a later
read verifies the v2 key and completes the marker. The marker records a verified
Keychain copy, not successful decryption of the encrypted application database.
The client must still authenticate that database and refuse identity reset on
failure. A new random key can only be created when all three accounts are
absent. Duplicate writes must match the saved bytes and never overwrite them.

## Build and signing

- Compile `main.c` for macOS12 or later with blocks and the Security and
  CoreFoundation frameworks. Set `HM_VAULT_CLIENT_REQUIREMENT` to a requirement
  pinning both the client bundle identifier and its signing certificate.
- Bundle it using `Info.plist`, with the executable named
  `HelloMentorVaultService`. `JoinExistingSession` permits access to the user's
  Keychain session. Sign it with hardened runtime and only the sandbox
  entitlement in `Service.entitlements`.
- Preserve that signed bundle in a private build cache. Copy it unchanged into
  the app at `Contents/XPCServices/HelloMentorVaultService.xpc` **before** signing
  the app. Do not re-sign nested code using `codesign --deep`. A changed helper
  needs a separately reviewed update and may require new Keychain permission.
- Set `HMUsesStableVaultService` to `true` in the enclosing app's signed
  `Info.plist`, together with `HMVaultServiceSigningRequirement` pinning the
  service identifier and certificate. A configured client must fail closed
  if the service is absent, unreachable, malformed, or not trusted.

Unconfigured developer builds retain the original direct Keychain bridge.
The local machine's build cache and private signing material are not part of
this repository.

## Wire contract

Use `xpc_connection_create("com.nearlink.chat.VaultService", queue)` to reach the
bundled service. Both peers set
`xpc_connection_set_peer_code_signing_requirement` before resuming their
connection. This public macOS12 API verifies **incoming** messages. Requests
therefore contain only an operation, never a secret; the service sends a key
only as a reply to a request that passed the client's exact signing requirement.

Requests contain exactly two fields:

```text
version: XPC_INT64 = 1
operation: XPC_STRING = "readMaster" | "createMaster"
```

Replies contain `version: XPC_INT64 = 1` and `status: XPC_INT64 = OSStatus`.
A successful read/create also has `master: XPC_DATA`, exactly32 bytes.
`errSecItemNotFound` means a read found no key. A duplicate create, Keychain
denial, transport failure or malformed reply must not trigger replacement,
an alternate read, or a new identity. The protocol cannot modify or delete a
production key. A request without a reply channel does no Keychain work.

`HM_VAULT_SYNTHETIC_TEST` is for isolated test binaries only. Such builds
require a different fixed service and a `probe-` legacy account. The new and
marker accounts append `-v2` and `-committed` to that exact account. Test builds
disable Keychain UI globally and use known non-secret bytes: `0x4c` for legacy
fixtures and `0x42` for fresh creation. Additional fixed-item operations support
migration, partial-write recovery, corruption, deletion and exact cleanup tests.
Production builds exclude those operations and reject Keychain-name overrides.

## Relevant platform documentation

- [Creating XPC services](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)
- [Apple's guidance on validating XPC peers](https://developer.apple.com/forums/thread/681053)
- [Apple's Keychain partition implementation](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp)
