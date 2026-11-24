# Reaction protocol compatibility

This developer note describes the additive reaction extension introduced in
0.4.0. Everyday use is covered by the [user manual](../README.md#4-text-reactions-and-automatic-ids).

## Compatibility goal

The released 0.3.1 validator accepts only six emoji for a `set` action:
`👍`, `❤️`, `😂`, `😮`, `😢`, `🙏`. It accepts `remove` when the top-level `emoji`
value is absent or null, and ignores unrecognized fields. A new emoji sent as an
ordinary `set` would fail that validator. Mapping an unrelated emoji to one of
the six would give the old user a misleading reaction.

The extension therefore removes the old visible representation while carrying
the richer selection inside the authenticated payload. It does not change
message envelopes, encryption, signatures, group keys, participation checks,
or the service-wide minimum version.

## Wire format

The six original reactions retain their existing representation:

```json
{
  "type": "reaction",
  "targetMessageId": "message-123",
  "counter": 1,
  "createdAt": 1,
  "action": "set",
  "emoji": "👍"
}
```

A richer reaction uses a legacy remove action plus `reactionV2`:

```json
{
  "type": "reaction",
  "targetMessageId": "message-123",
  "counter": 2,
  "createdAt": 2,
  "action": "remove",
  "reactionV2": {"v": 1, "emoji": "🫠"}
}
```

Actual cancellation sends `action: "remove"` with no `reactionV2` and no
top-level `emoji`. Outgoing selections must be exact members of the bundled
catalog. `ReactionEmoji.payloadFields` selects the appropriate representation;
callers should not construct their own fallback emoji.

| Received event | 0.3.1 display | 0.4.0 display |
| --- | --- | --- |
| Original six, plain `set` | Selected emoji | Selected emoji |
| Supported rich emoji in v1 extension | Hidden | Selected emoji |
| Unknown emoji string in v1 extension | Hidden | Hidden |
| Bounded future extension version | Hidden | Hidden |
| Plain `remove` | Hidden | Hidden |

Hidden events still count as the sender's latest reaction state. They do not
delete the target message or insert an empty chat message.

## Validation and future versions

The existing reaction target, timestamp, counter, sender-name prohibition, and
legacy action rules still apply. A `reactionV2` field is valid only with outer
`action: "remove"` and no non-null top-level emoji. A contradictory legacy `set`
plus extension is rejected, preventing different clients from rendering two
different selected emoji from the same event.

The extension must be a JSON object with an integer `v` between 1 and
9,007,199,254,740,991. Its JSON UTF-8 representation must not exceed 512 bytes.
For `v: 1`, exactly `v` and `emoji` are permitted. `emoji` must be a nonempty
string no longer than 128 UTF-8 bytes. Known strings render only after exact
catalog membership validation. Unknown strings stay hidden; they are not
rendered as arbitrary text or used as asset paths or URLs.

Unknown versions greater than 1 remain opaque within the same 512-byte bound.
They are accepted as hidden states. The receiver does not interpret a future
version's `emoji` field even if it happens to contain a known emoji.

Unknown strings deliberately do not require the installed Unicode grapheme
tables to recognize one emoji. A later Unicode release may introduce a sequence
that an older grapheme implementation segments differently. Rejecting it would
break the forward-compatible hidden-state behavior.

## Ordering and sender isolation

Both versions keep one reaction event per target message and authenticated
envelope sender. Higher counters supersede lower counters. Equal counters use
the existing deterministic message-ID and signature ordering. A rich reaction,
unknown extension, or cancellation must retain its counter even when no emoji
can be displayed; otherwise replaying a lower-counter original reaction could
make an obsolete selection visible again.

For example, `👍 at 1 → 🫠 at 2 → replay 👍 at 1` leaves 0.3.1 with a hidden
reaction at counter 2 and 0.4.0 showing 🫠 at counter 2. Another member's reaction
is independent. A later plain cancellation at counter 3 clears both displays.

There is no server or group migration for this display extension. It adds no
claim that a peer runs an unmodified official binary and does not relax the
existing signed participation or group-key rules.

## Regression fixture

`apps/mobile/test/fixtures/legacy_0_3_1/` contains byte-for-byte copies of the
released crypto service, models, and temporary-ID helper from commit
`60048640d8efe8d9e72fc244ca0e93ea206fbf71`. The fixture README and manifest record
their origin and SHA-256 hashes. Do not format or update them alongside current
production code.

`reaction_legacy_compat_test.dart` encrypts and signs real envelopes, crosses the
JSON serialization boundary, then runs both actual decryptors, validators,
parsers, and reaction folds. Its 28 cases cover the original six in both
directions, rich selections, sender isolation, replacement/removal/replay,
unknown strings and versions, bounds, malformed extensions, and contradictory
actions. Fixture integrity is also checked.

From `apps/mobile`:

```sh
../../scripts/flutter.sh test test/reaction_legacy_compat_test.dart
```

The fixture uses the project's installed cryptography dependency. It verifies
released protocol source compatibility, not an archived app binary, native GUI,
live network path, or store migration.
