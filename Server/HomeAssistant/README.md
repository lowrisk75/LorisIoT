# LorisIoT scheduling for Home Assistant

Local implementation and isolated qualification candidate. No installation on a user's Home
Assistant is performed by this repository or its tests. Production deployment, device execution,
upgrade/backup recovery and a sustained final-candidate run remain separate qualification gates.

## Contract

### Optional sunrise session (component 0.3.1)

`GET /health` advertises `sunriseAutoOffVersion: 1`. The SDK's `HASunriseClient`
requires this capability before sending an immutable `HASunriseRequest` with an
`autoOffAt` UTC timestamp. The existing schedule API and explicit target allowlist
are reused; no component is installed automatically. Generic schedule readback
rejects an unexpected `autoOffAt` obligation.

- One light, a 1–30 minute native ramp (or explicitly enabled HA steps), then OFF 1–180 minutes after the end of
  the ramp (the wake time). The full session is persisted before acknowledgement.
- OFF becomes eligible only after a fresh, context-matching ON confirmation.
  The receipt moves `armed → executing → holding → offExecuting → completed`.
- A foreign or missing context, unknown/unavailable state, or observed foreign
  power command permanently relinquishes ownership (`overridden`). Returning to
  a matching brightness does not restore it. Some integrations do not preserve
  command context; these conservatively forgo automatic OFF. Physical changes
  not reported by HA cannot be detected: device qualification is still required.
- Overlapping sunrise sessions for the same light are refused across owners.
  Cancellation in `holding` removes OFF without commanding the light. In-flight
  or uncertain effects never claim successful cancellation.
- Pending sessions survive restart. **Already-started sessions become uncertain
  and do not turn the lamp off after restart**, because manual interventions during
  downtime are unobservable. Late OFF (>5 seconds) is missed, never replayed.
- SQLite schema 2 migrates transactionally to 3, retaining existing rows. An older
  component refuses schema 3. Back up and review before a separately authorized
  deployment; do not downgrade against the migrated journal.

The client must persist the nonce and complete request before `arm`, bind that
journal to the exact endpoint, and retain unknown/cancellation-pending receipts.
No timer on the iPhone, credentials in the journal, or guessed server capability.

The custom component persists one-shot intents in a bounded SQLite journal. A timer runs
inside Home Assistant independently of an app connection. Supported targets are explicit
`switch`, `light`, `fan` and `input_boolean` entity IDs; only `turn_on` and `turn_off` are accepted.
There are no area, floor, label, device-group, arbitrary service or webhook selectors. Scenes and
recurring wall-clock schedules are not implemented.

A `light` target may additionally carry a `level` (0 to 1) and a `transition` (0 to 3600 seconds).
A native ramp is one command: the luminaire performs the transition itself. Generic schedules
still require native transition capability and are never silently converted into software steps.

For a brightness-capable light without native transitions, a separately provisioned sunrise
session (`autoOffAt`) can opt into server-side steps. The target must appear in both lists:

```yaml
lorisiot_schedule:
  allowed_targets:
    - light.selected_lamp
  stepped_sunrise_targets:
    - light.selected_lamp
```

The initial brightness is a nonzero 1% when off; an already-on lamp starts near its reported
brightness bounded by the desired target. HA increases it every 15 seconds using integer-percent
steps, up to the requested wake level. Commands use the ceiling of the corresponding 0..255 value
so a percentage-based adapter does not truncate the first step to zero.
Polling delays coalesce steps rather than replaying a burst. A final step over five seconds late
abandons the session. Every step requires a fresh report and retained context. For an explicitly opted-in stepped
light, the report must fall between the floor and ceiling of that exact percentage in 0..255
space (fractional reports are accepted). Zero, non-numeric and out-of-bucket reports are rejected;
this is not a general brightness tolerance. Native transitions retain their existing contract.
The journal enters `executing` before each service call, serializing the step with cancellation;
`holding` is restored only after confirmation. A cancellation during a step is unconfirmed.

A foreign state report or command, including a same-value report with a foreign event context,
revokes steps and automatic OFF. A timeout keeps its concurrency slot until the service actually
finishes. The executor allows eight outstanding steps; it never retries an uncertain step.
Started software ramps are not reconstructed after restart; the journal becomes uncertain and
neither later steps nor OFF are replayed. Pending future sessions still survive a restart.

`POST /retire` accepts a complete sunrise request only after its OFF deadline and lateness
allowance have passed. If its nonce is absent, the server durably writes a `removed` tombstone.
It never replaces an existing live, uncertain, or mismatching receipt. The Swift client requires
exact acknowledgement and GET readback before accepting this as cancellation; a bare 404 is
still insufficient. This allows a never-created, elapsed session to be reconciled after installing
the previously missing component, while retaining the original request and its history.

Both read and write endpoints require a currently active HA administrator. At execution time,
the user and exact target are checked again. The owner app/installation identifies intent
ownership within that HA account; it is not a security boundary against the HA administrator.

The SDK opts in with `HASchedulingConfiguration(owner:store:)`. It probes the server before
exposing schedule capabilities, binds the local journal namespace to the endpoint, persists an
operation nonce before POST, and requires exact readback before confirming a schedule or removal.
An `input_datetime` helper name alone does not enable scheduling.

Protocol endpoints beneath `/api/lorisiot_schedule/v1`:

| Method/path | Meaning |
| --- | --- |
| `GET /health` | Version, readiness, UTC server clock, allowlist and timing policy |
| `POST /records` | Owned intent, with `expectedRevision` for an existing revision |
| `GET /records/{uuid}` | Exact receipt visible only to its HA user |
| `DELETE /records/{uuid}` | Owner and revision checked cancellation, followed by readback |

An intent has `remoteID` (UUID), `owner` (`appID`, `installationID` UUID), `providerID`,
`scheduleID`, `deviceID`, boolean `on`, UTC epoch seconds `start`, and boolean `enabled`, plus
optional `level` and `transition` for a light, and an optional `expiresAt` lease. Records written
before these fields existed omit them and still read back. Responses add positive `revision`,
UTC `updatedAt` and state: `armed`, `disabled`, `executing`, `applied`, `uncertain`, `missed`,
`expired`, or `removed`.

An intent may carry an optional `expiresAt` lease, from now to 366 days ahead, which the owner
renews on each push. A due intent whose lease has lapsed becomes `expired` and reaches no service.
The lease bounds a **zombie** intent — an owner that stops renewing stops arming the home, so an
uninstalled app cannot leave a wake armed forever. It does **not** bound a **cancellation**: an
owner whose cancellation failed to reach the server is alive and its lease is still fresh, so the
client-side pending-clear retry remains necessary. The two mechanisms are complementary.

## Failure and timing semantics

- A new or changed intent must be 15 seconds to 366 days ahead on the server; the SDK requires
  20 seconds of lead and at most 5 seconds of clock difference. No time or recurrence is rounded.
- The server polls every second only after HA has fully started. At most 32 due intents are
  claimed per poll, with 8 concurrent service calls. The maximum lateness is 5 seconds, checked
  again before sending; a clock that has stepped backwards cannot cause early execution.
- The SQLite `executing` transition commits before dispatch. Only one poller can claim an intent.
  Startup converts interrupted execution to `uncertain`. It is never automatically replayed.
- The execution policy is **at most once per claimed intent**. A crash between commit and dispatch
  can lose the action. A missing response can leave its outcome unknown. This deliberately makes
  no exactly-once or guaranteed-wake promise. An administrator must investigate uncertainty.
- `applied` means HA reported the expected state after service dispatch. An optimistic device
  integration may report that state without physical feedback; physical acceptance is separate.
- With a `transition`, `applied` confirms only that the ramp **started**: a fresh report after the
  send, and `on` for a turn-on. The terminal level, and a fade-out's final `off`, land long after the
  five-second command deadline and belong to the luminaire. Without a transition, a requested `level`
  must be reported back before the intent is confirmed.
- A lapsed lease is checked when the intent is claimed, before any dispatch, so an expired intent
  never reaches a service. Expiry can only prevent a firing, never cause one; the SDK therefore
  keeps `expiresAt` out of its exact-readback comparison, since a renewal shifts it on every push.
- Cancellation cannot claim success once execution is underway or uncertain. Removed intent
  tombstones prevent a delayed old creation from undoing cancellation. New work uses a new nonce
  after removal. Expired tombstones may be purged only when both their start and removal are over
  30 days old; an old creation then fails the new-intent time check.
- Request bodies are at most 16 KiB including chunked requests; allowlists hold at most 256
  entities, journals at most 1,024 records and 16 MiB. Full or corrupt journals fail closed;
  existing intents are not silently discarded or recreated.
- SQLite uses transactions with `synchronous=FULL`. Durability still depends on the host filesystem
  and storage. Restoring an older HA backup can restore an earlier armed intent: backup restoration
  must be qualified with scheduling disabled and reviewed before enabling it. No backup rollback
  detection or cross-host failover is claimed by this version.

## Isolated verification

Pure Python journal/runtime tests need no HA installation and no network:

```sh
python3 -B -m unittest discover -s Server/HomeAssistant/tests -v
```

The HTTP/auth integration lane uses the real HA 2026.9.1 package, an empty temporary configuration,
real authentication middleware, and a localhost-only HTTP server. Device services are synthetic.
No `default_config`, discovery, real device integration or home configuration is loaded.

```sh
uv venv --python python3.14 /private/tmp/lorisiot-ha-qualification
uv pip install --python /private/tmp/lorisiot-ha-qualification/bin/python -r Server/HomeAssistant/requirements-qualification.txt
/private/tmp/lorisiot-ha-qualification/bin/python -B -m unittest discover -s Server/HomeAssistant/integration_tests -v
```

These commands are for test preparation, not deployment. The integration's manifest is version
0.3.1 and the internal SQLite schema is version 3 (with additive migration from 2). Other existing journal versions are rejected,
never reset. Enabling this component on a real home requires separate deployment authorization
and device-specific acceptance. Existing television, plug and home schedules must be preserved.

## Implementation sources

- [HA HTTP view contract, 2026.9.1](https://github.com/home-assistant/core/blob/2026.9.1/homeassistant/helpers/http.py)
- [HA authentication models, 2026.9.1](https://github.com/home-assistant/core/blob/2026.9.1/homeassistant/auth/models.py)
- [HA core lifecycle and reported states, 2026.9.1](https://github.com/home-assistant/core/blob/2026.9.1/homeassistant/core.py)
- [HA async and executor guidance](https://developers.home-assistant.io/docs/asyncio_working_with_async/)
- [SQLite atomic commit](https://www.sqlite.org/atomiccommit.html)
- [SQLite synchronous policy](https://www.sqlite.org/pragma.html#pragma_synchronous)

## Qualification 2026-09-23

The stepped-sunrise suite was run with real Home Assistant **2026.9.0b2**, matching the target
server, using synthetic services and a temporary localhost instance. To select this explicit lane:

```sh
LORISIOT_HA_TEST_VERSION=2026.9.0b2 python -B -m unittest discover -s Server/HomeAssistant/integration_tests -v
```

This proves adapter behaviour against HA; physical device response and context retention still
require an actual-device test. An integration that drops service contexts is conservatively refused
continued ownership rather than receiving guessed follow-up brightness or OFF commands.


## Gentle wake profile (local 0.4.0 implementation)

`sunriseProfile: "gentle-v1"` is opt-in for owned sunrise sessions only. Health advertises
`gentleSunriseVersion: 1`; older servers must be refused by clients before provisioning.
The target must be explicitly listed in `stepped_sunrise_targets`, including when it also
supports native transitions. Existing sessions without this field keep their original behavior.

The profile uses a squared brightness progression to the requested level. When the fresh
light capabilities expose color temperature and finite bounds, it requests 2200–3000 K,
clamped to those bounds. Brightness-only lights remain brightness-only. A reported value
outside the commanded bounds is unconfirmed; no blind replay is used.

After wake, brightness is held, then lowered over the last two minutes before `autoOffAt`
(or half the post-wake interval if shorter). The existing owned OFF transaction remains
sole owner of the final off command. Manual takeover, missing confirmation, missed ramp
completion or restart revokes further progression; no started ramp is reconstructed.
No clinical sleep claim or physical qualification is implied by synthetic tests.

No existing home configuration is migrated or deployed by this source change.
