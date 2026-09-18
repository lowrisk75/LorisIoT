# LorisIoT scheduling for Home Assistant

Local implementation and isolated qualification candidate. No installation on a user's Home
Assistant is performed by this repository or its tests. Production deployment, device execution,
upgrade/backup recovery and a sustained final-candidate run remain separate qualification gates.

## Contract

The custom component persists one-shot intents in a bounded SQLite journal. A timer runs
inside Home Assistant independently of an app connection. Supported targets are explicit
`switch`, `light`, `fan` and `input_boolean` entity IDs; only `turn_on` and `turn_off` are accepted.
There are no area, floor, label, device-group, arbitrary service or webhook selectors. Scenes and
recurring wall-clock schedules are not implemented.

A `light` target may additionally carry a `level` (0 to 1) and a `transition` (0 to 3600 seconds).
A sunrise ramp is therefore **one atomic command**: the luminaire performs the ramp itself using the
Zigbee/Matter Level Control transition time, which HA exposes as `light.turn_on { brightness,
transition }`. Neither the app nor this component ever steps brightness, so a ramp survives a server
restart in the middle of it. A level or transition requested on a target whose reported
`supported_color_modes`/`supported_features` cannot perform it is refused at provisioning with
`target_has_no_brightness`, `target_has_no_transition` or `target_state_unknown` — never silently
degraded to an instant change at wake time. Both fields are additive and optional: an older client
omits them, and a newer client that sends them to an older server is refused, never partially applied.

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
0.1.0 and the internal SQLite schema is version 2. Other existing journal versions are rejected,
never reset. Enabling this component on a real home requires separate deployment authorization
and device-specific acceptance. Existing television, plug and home schedules must be preserved.

## Implementation sources

- [HA HTTP view contract, 2026.9.1](https://github.com/home-assistant/core/blob/2026.9.1/homeassistant/helpers/http.py)
- [HA authentication models, 2026.9.1](https://github.com/home-assistant/core/blob/2026.9.1/homeassistant/auth/models.py)
- [HA core lifecycle and reported states, 2026.9.1](https://github.com/home-assistant/core/blob/2026.9.1/homeassistant/core.py)
- [HA async and executor guidance](https://developers.home-assistant.io/docs/asyncio_working_with_async/)
- [SQLite atomic commit](https://www.sqlite.org/atomiccommit.html)
- [SQLite synchronous policy](https://www.sqlite.org/pragma.html#pragma_synchronous)
