# LorisIoT

Shared IoT framework for LorisLabs Apple apps (Velya · Éclair · Lumen · Piscine).
**Internal / all-rights-reserved** — not for public distribution.

Swift 6 strict concurrency · iOS 17+ / macOS 14+ / watchOS 10+ / tvOS 17+ / visionOS 1+ · zero
runtime dependencies in `IoTCore`.

Design + research: `~/GitHub/iot-framework/` (`IoTKit-DESIGN.md`, 22 deep-research reports, and the
`LorisIoT` NotebookLM).

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
