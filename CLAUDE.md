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

## Built (all green, `swift test` — 73 tests)
IoTCore · IoTHomeAssistant · IoTShelly · IoTMQTT (transport injectable) · IoTWebhook · IoTHomeKit.
Plus in IoTCore: DynamicTariffScheduler · ExecutionContext (App-Intents remote-proxy) ·
**RawTCPWebSocketTransport** (NWConnection ws:// ATS-bypass; pure handshake/frame codec; redirect
surfaced as `IoTError.redirected(toHTTPS:)`; loopback-tested) · **EndpointSelector** (+
`AdaptiveLatencyProber`; hysteresis 30%+10ms+30s, SSID-lock fail-closed, backoff 2-success reset,
fallback seed) — Lumen's raw-TCP + ConnectionManager ports are DONE.

## TODO (open)
- **IoTMQTT real transport** (MQTTNIO 2.13, isolated target) — needs API verify + a broker to test.
- **IoTShelly BLE-RPC** (CoreBluetooth GATT, device-gated).
- **IoTNodeRED** contract flow shipping; multi-package split (distribution).
- Adopt into apps: **Piscine** (ready), **Lumen** (ready — raw-TCP + EndpointSelector shipped;
  app keeps persistence/stats UI + WSS pivot on `.redirected`), **Velya** (after its 1.0.2
  App Store review clears), **Éclair** (dedupe primitives).

## House rules
- Build/test with scratch path under /tmp: `swift test --scratch-path /tmp/lorisiot-build`.
- Never expose a provider SDK type across the Core boundary; keep DTOs `internal`.
- Tests: no live device/broker — inject transports, use fixtures, decode-only.
- Commit convention: `[lorisiot] <type>: <desc>`; co-author line for Claude.
