# Native Matter sensors

`IoTMatter` adds a read-only `MatterProvider` for Temperature Measurement (0x0402)
and Relative Humidity Measurement (0x0405). It depends only on `IoTCore` and Apple's
Matter framework. No control or scheduling capability is exposed.

## Host integration

The host application commissions devices, creates its fabric, persists its fabric
identity and credentials, and supplies a running `MTRDeviceController`. This module
does not implement commissioning UI, discover Apple Home pairings, or obtain access
to an existing HomeKit fabric. A device already in Apple Home must separately admit
the application's fabric using the appropriate Matter commissioning flow.

```swift
import IoTMatter

let configuration = try MatterSensorConfiguration(
    nodeID: commissionedNodeID, endpointID: measurementEndpoint, name: "Room")
let provider = try MatterProvider.usingExclusiveController(
    fabricIdentity: persistedFabricUUID,
    sensors: [configuration],
    makeController: { try await hostFabric.makeExclusiveRunningController() })
try await provider.connect()
let sensors = try await provider.devices()
let capability = try await provider.capabilities(for: sensors[0].id)
let state = try await capability.readState?.state()
```

The `hostFabric` call above represents application code, not another SDK API.
The factory transfers **exclusive controller ownership**. Do not return a controller
shared with another subsystem. Disconnect shuts down this controller and its
subscriptions, but does not remove pairings or erase host-owned credentials. On
reconnect, return a new controller backed by the same persisted fabric. A stable
fabric UUID is required because device identities include fabric, node and endpoint.

The native factory is available where Apple's Matter framework can be imported.
The portable model is available on all package platforms. The package's existing
minimum OS versions are unchanged. Configure app networking permissions and fabric
storage for the host's commissioning/controller implementation.

## Observation semantics

The provider reads the endpoint's Descriptor ServerList and exposes only supported
temperature/humidity clusters. Inventory is explicit and bounded to 32 endpoints;
there is no network-wide discovery or automatic pairing. Direct `MTRBaseDevice`
reads and shared subscriptions avoid presenting the `MTRDevice` cache as new data.

Temperature is converted from signed hundredths of degrees Celsius; humidity from
hundredths of percent. Matter null remains unknown. Invalid values, duplicate or
foreign paths and incomplete fresh reads are refused. A malformed batch does not
partly renew observation timestamps. Each measurement has its own `ObservedAt`
attribute; a humidity report never renews a temperature timestamp. A later report
received during an in-flight read takes precedence over that read's older response.

`cachedState(for:)` preserves observation age, even after disconnect. Consumers must
evaluate `DeviceState.freshness` at display/use time; no timer periodically emits a
stale event. The default cache age limit is 60 seconds. Devices can negotiate a
longer subscription interval or sleep, so a stale state can be normal and is not
proof of sensor failure. `readState.state()` requests a network read and shares an
existing read for that endpoint. Reads time out after 20 seconds; late callbacks
cannot resume cancelled callers or reconnect an old provider generation.

Reports describe protocol observations, not physical calibration or evidence that
a scheduled action executed. Connection degradation and resubscription do not
grant a control or autonomous scheduling capability.

## Validation and remaining qualification

Swift tests cover decoding, identities, capability limits, freshness, partial
reports, out-of-order reads, disconnect, connection recovery, callback loss and
cancellation. These are software contracts. Physical Matter qualification still
requires host commissioning, a real sensor, sleepy-device/reconnect observations
and a signed app networking/permission check. This module alone does not qualify
an application release or create a standalone commissioner.

Apple references: [Matter](https://developer.apple.com/documentation/matter),
[Onboarding](https://developer.apple.com/documentation/matter/onboarding-a-matter-device),
[Accessory control](https://developer.apple.com/documentation/matter/accessory-control).
