# LorisIoT

Shared IoT framework for Apple platforms — the device, networking and safety layer
behind the LorisLabs apps (Velya · Éclair · Lumen · Piscine).

Licensed under Apache 2.0.

Swift 6 strict concurrency · iOS 17+ / macOS 14+ / watchOS 10+ / tvOS 17+ / visionOS 1+ · zero
runtime dependencies in `IoTCore`.


## Architecture

A dependency-free **`IoTCore`** + per-integration satellite modules that depend only on it. Apps keep
their own `@MainActor @Observable` orchestrator (provider registry, UI) out of the framework.

```
IoTCore                         ← this package (v1)
├─ DeviceProvider / SchedulingProvider   (actor-constrained spine)
├─ DeviceState / DeviceCommand / DeviceCapability / DeviceSchedule / ProviderError
├─ RealtimeSocketClient<Message>         (watchdog + backoff + circuit breaker + reconnect)
├─ RetryPolicy · CircuitBreaker · NetworkStatusMonitor
├─ Actuator / SafetyEnvelope / SafeActuator   (confirm-by-reread + safety interlock)
└─ KeychainStore(accessGroup:)           (ThisDeviceOnly; opt-in cross-app sharing)

IoTHomeAssistant · IoTShelly · IoTMQTT · IoTHomeKit · IoTWebhook   ← satellites (added next)
```

### The two laws it encodes
1. **Capability `.schedule`** — an app can only promise a *timed* action through a provider that can
   pre-provision it on an always-on system (device schedule / HomeKit timer / HA input_datetime). iOS
   cannot run code at a precise time in the background, so control-only providers (cloud toggle,
   phone-fired webhook) are refused at the type level.
2. **Confirm-by-reread** — `setState` / `setOn` re-read the device and throw if the physical state
   isn't confirmed. Never optimistic success.

## Status
- ✅ `IoTCore` v1: builds clean under Swift 6; 11 tests pass (incl. silent-death watchdog reconnect).
- ⏭️ Next: `IoTHomeAssistant` (WebSocket + REST), `IoTShelly` (Gen1/2/3 local + cloud + schedule),
  then `IoTMQTT`. Then the differentiators: App-Intents remote-proxy, `DynamicTariffScheduler`,
  Shelly BLE-RPC.

## Build
```
swift build
swift test
```

## Confirmed wake occurrences

The durable multi-device coordinator and HA/Shelly/HomeKit adapters are documented in
[Multi-device wake](Docs/MULTI-DEVICE-WAKE.md). One-shot readback, cancellation and recovery are
fixture-tested; hardware and release qualification remain separate gates.

## Native Matter sensors

`IoTMatter` provides read-only temperature/humidity reads and subscriptions through
Apple's Matter framework, using an exclusively owned controller supplied by the
host application. Commissioning and durable fabric storage remain host responsibilities.
See [Matter sensors](Docs/MATTER-SENSORS.md) for ownership, freshness and physical
qualification requirements. The module does not expose control or scheduling.
