# Native Dreo provider — implementation checkpoint

`IoTDreo` communicates with Dreo's published v2 cloud API directly. It does not use Home
Assistant. `DreoProvider(token:allowsControl:)` obtains a `DreoAccessToken` from the host
application before each request. The token includes account identity, explicit EU/NA
region and expiry. A region suffix is validated and removed from the Authorization header.
An account/region change requires disconnecting and connecting again. Credentials are not
persisted by this module; no password, published client secret or login identity is embedded.

The host must supply its own authorized sign-in/refresh arrangement. This package does not
register an application with Dreo or ship a login screen. Velya does not yet link this module.
Do not confuse passing fixture tests with a live account or a verified physical fan.

## Capabilities

Inventory uses deviceSn and preserves the returned model. Each device offers read-state;
control is opt-in. DR-HAF001S and DR-HAF003S circulation fans expose power, discrete speed
and mode only when an appropriate fan profile is present. Speed ranges and mode allowlists
come from the fresh inventory configuration. Unknown models remain read-only. Oscillation,
provisioning, timers/schedules, subscriptions and LAN transport are not advertised.

Use `SetPowerCommand` for power and `DreoFanCommand(deviceID:speed:)` or
`DreoFanCommand(deviceID:mode:)` for fan parameters. No speed command implicitly powers on
a fan or changes mode. Before each command the provider rechecks account membership,
profile limits and connected state. A successful cloud response is accepted, not physically
applied. Lost responses are uncertain; no automatic command retry or fallback takes place.

The published flat cloud state has no device observation timestamp. It retains receivedAt
but uses distantPast observedAt and degraded/unknown availability instead of inventing fresh
physical evidence. The cloud connected flag is available as an attribute. Disconnect
invalidates all previously obtained capability handles, including after reconnection.

## Network and bounds

HTTPS only to open-api-eu.dreo-tech.com or open-api-us.dreo-tech.com; exact list/state/control
routes and query keys. No redirects, arbitrary URL, client-side regional fallback or token
in a URL. Responses capped at2MiB, inventory at1000, serial/name/profile inputs bounded.
Production URLSession transport is included; tests inject HTTP and do not reach a real fan.

## Evidence and references

14 fixture tests: routing/auth/expiry, read-only default, unknown models, speed bounds,
model/profile revocation, wrong target/offline refusal, lost response, old handles and
cancellation during token lookup. Whole SDK suite and iOS17-target compilation recorded in
../iot-framework/evidence/dreo-native-20260921. Real Dreo account/device verification OPEN.

Protocol sources inspected (independent Swift implementation, no vendor credentials copied):
- https://github.com/dreo-team/pydreo-client/tree/5e4fa54abe795a557e95e2537b7573656a9e9ab7
- https://github.com/dreo-team/hass-dreoverse/tree/86327d5547b7dd759db51df842acb14d1b154717

The latter publishes the device config/flat state directives. These are protocol references;
IoTDreo neither links that integration nor requires a running Home Assistant server.
