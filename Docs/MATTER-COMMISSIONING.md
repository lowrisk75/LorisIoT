# Managed Matter fabric and on-network commissioning

`MatterFabric` owns an application-scoped Apple controller factory, persistent
fabric identity and a commissioning driver. It targets devices already connected
to IP networking, with a commissioning window explicitly opened for this app.
Scanner/manual entry, MatterSupport system onboarding and first-time Wi-Fi/Thread
network provisioning belong to the host UI. No device is paired automatically.

## Create, reopen, commission and read

The app supplies its assigned vendor ID, nonzero fabric ID and explicitly trusted
PAA certificates in DER form. There is no built-in test vendor, default development
trust store, automatic trust download or attestation bypass. Use a dedicated
Keychain service in one app process; do not share it with extensions or unrelated
integrations. Creation is explicit; `open` never creates replacement credentials.

```swift
// One-time creation, with host-approved PAA certificates.
let fabric = try MatterFabric.create(
    service: "com.example.myapp.matter",
    vendorID: assignedVendorID, fabricID: chosenFabricID,
    trustedPAAs: approvedPAACertificates)

// On subsequent launches instead:
// let fabric = try MatterFabric.open(
//     service: "com.example.myapp.matter", trustedPAAs: approvedPAACertificates)

// The host obtains this payload through local scan/manual/system UI.
// Never log it or include it in analytics. The selected device must be in an
// open commissioning window. This call changes its fabric membership.
let nodeID = try await fabric.commission(onboardingPayload: locallyEnteredPayload)
let configuration = try MatterSensorConfiguration(
    nodeID: nodeID, endpointID: measurementEndpoint, name: "Room")
let provider = try fabric.sensorProvider(sensors: [configuration])
try await provider.connect()

// Retain fabric/provider during use. Close in this order:
await provider.disconnect()
try fabric.close()
```

An endpoint is supplied explicitly. Successful commissioning does not imply that
the device supports temperature/humidity; `provider.connect` checks its ServerList.
Only one live controller for the fabric can be leased. Commissioning is refused
while the sensor provider is connected. `close` refuses to stop a connected
provider. A foreign already-running global Matter factory is refused, never adopted
or stopped. Call `close` explicitly; dropping the reference is not a reset API.

## Credentials and persistence

One Keychain record contains the UUID, fabric ID, vendor ID, 16-byte random IPK,
P-256 root signing key and bounded node-reservation journal. All Apple stack
storage is also in Keychain under a separate account prefix. Items use the data
protection Keychain, `AfterFirstUnlockThisDeviceOnly`, no synchronization and no
cross-app access group. Private key bytes are not exposed by the public API.
The Security key is immutable and signs DER ECDSA messages; the public identity
is checked when reopening the stored fabric.

Writes update existing items in place. A failed update never deletes the previous
record. Locked/unavailable/corrupt storage is an error, not an empty fresh fabric.
Stack storage failures latch and stop subsequent controller creation. A partially
created fabric is recovered only if its stored root public key and fabric ID
match; an initialized fabric missing from stack storage is refused.

This deliberate device-only policy differs from Apple's cross-device iCloud
Keychain guidance: there is no cross-device restoration/export in this API. Loss
of the original Keychain can require an accessory-side fabric removal/new pairing.
Do not advertise account-based fabric recovery. `close` retains all credentials
and pairings; no erase/reset API is provided.

## Cancellation, failure and reconciliation

A unique node ID is persisted **before** discovery/PASE. The ID is never reused,
including after failure, cancellation or a crash. Completion must match that ID
and follow session establishment; duplicate/late callbacks cannot grant success.
The driver has a monotonic 180-second deadline and propagates task cancellation.
It cancels the selected session and shuts down its controller on failure.

`commissioningRecords()` exposes node IDs with `pending`, `commissioned` or
`uncertain` disposition. Pending after a restart can mean interruption after an
accessory-side change. Uncertain is not proof that pairing did not happen. Neither
state is retried automatically; the host must reconcile the accessory's fabric
membership before offering a new attempt. Persistence failure after native success
also returns an error and preserves the reservation.

## Validation and remaining gates

Tests exercise credential continuity/signature verification, durable reservations,
storage failure/corruption, callback ordering and cancellation/deadline gating.
Signed-app Keychain accessibility, local network/Bluetooth permissions, selected
device attestation and actual commissioning/reconnection require hardware tests.
No fixture is presented as successful physical pairing.

Sources: Apple's [onboarding guide](https://developer.apple.com/documentation/matter/onboarding-a-matter-device),
[MTRStorage](https://developer.apple.com/documentation/matter/mtrstorage),
[MTRKeypair](https://developer.apple.com/documentation/matter/mtrkeypair).
