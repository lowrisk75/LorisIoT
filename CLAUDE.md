# LorisIoT — session context

Shared internal IoT framework for LorisLabs apps (Velya · Éclair · Lumen · Piscine).
**Private / all-rights-reserved.** Swift 6 strict, iOS 17+/macOS 14+, `IoTCore` has zero runtime deps.

**Run IoT work here**, not in an app's session: `cd ~/GitHub/LorisIoT && claude`.

## Where things live
- Code: this repo (`Package.swift`, `Sources/IoT*`, `Tests/IoT*Tests`).
- Design + research: `~/GitHub/iot-framework/` — `IoTKit-DESIGN.md` (salvage map + skeleton),
  `research/` (22 deep-research reports), `IoTKit-ClaudeDesign-prompts.md`.
- NotebookLM "IoTKit : Cadre de Développement IoT pour LorisLabs" holds all reports.
- The commissioned technical spec Kevin aligned the code to: `~/Downloads/TECHNICAL SPECIFICATION SHARED MULTI-PROVIDER IOT CLIENT FRAMEWORK (SWIFT 6).md`.
- Migration into apps: the `adopt-lorisiot` skill.

## Architecture (the two laws)
1. **Capability `.schedule`** — a timed action must be pre-provisioned on an always-on system
   (Shelly cron / HMTimerTrigger / HA input_datetime); iOS can't run it in the background.
2. **Confirm-by-reread** — `execute` re-reads and returns `.applied`/`.rejected`/`.uncertain`/`.accepted`,
   never optimistic success.
Model = capability-discovery (`DeviceProvider.capabilities(for:)` → `DeviceCapabilitySet` with typed
Control/ReadState/Schedule/Subscribe capability actors), typed IDs, closed `StateValue`, `CommandReceipt`.

## Built (all green, `swift test`)
IoTCore · IoTHomeAssistant · IoTShelly · IoTMQTT (transport injectable) · IoTWebhook · IoTHomeKit.
Plus DynamicTariffScheduler + ExecutionContext (App-Intents remote-proxy) in IoTCore.

## TODO (open)
- **IoTCore: raw-TCP `RealtimeTransport`** (NWConnection, ATS-bypass for `ws://`/`http://` LAN) —
  needed by Lumen; port from Lumen `FrigateMQTTClient` raw path.
- **IoTCore: `EndpointSelector`** (adaptive-latency probe + hysteresis + **SSID-lock**) — port from
  Lumen `ConnectionManager`; needed by Lumen (kills its app/TV fork).
- **IoTMQTT real transport** (MQTTNIO 2.13, isolated target) — needs API verify + a broker to test.
- **IoTShelly BLE-RPC** (CoreBluetooth GATT, device-gated).
- **IoTNodeRED** contract flow shipping; multi-package split (distribution).
- Adopt into apps: **Piscine** (ready), **Lumen** (after raw-TCP + EndpointSelector), **Velya**
  (after its 1.0.2 App Store review clears), **Éclair** (dedupe primitives).

## House rules
- Build/test with scratch path under /tmp: `swift test --scratch-path /tmp/lorisiot-build`.
- Never expose a provider SDK type across the Core boundary; keep DTOs `internal`.
- Tests: no live device/broker — inject transports, use fixtures, decode-only.
- Commit convention: `[lorisiot] <type>: <desc>`; co-author line for Claude.
