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

## Built (all green, `swift test` — 91 tests)
IoTCore · IoTHomeAssistant · IoTShelly (incl. **BLE-RPC** GATT fallback, framing pure-tested,
CoreBluetooth shell device-gated, no BLE digest-auth in v1) · IoTMQTT (transport injectable) ·
**IoTMQTTCocoa** (CocoaMQTT 2.4 wrapped per research #18 — isolated target, lib types never cross
the boundary; broker-less delegate-bridge tests; NOT validated against a live broker yet) ·
IoTWebhook (+ shipped contract: `Docs/WEBHOOK-CONTRACT.md` + `Docs/nodered/flows.json` reference
flow, contract-freeze tests) · IoTHomeKit.
Plus in IoTCore: DynamicTariffScheduler · ExecutionContext · **RawTCPWebSocketTransport**
(NWConnection ws:// ATS-bypass; redirect → `IoTError.redirected(toHTTPS:)`; loopback-tested) ·
**EndpointSelector** (+ `AdaptiveLatencyProber`; hysteresis 30%+10ms+30s, SSID-lock fail-closed).

**Multi-package split: WON'T DO** (2026-08-12) — single package with per-product isolated targets
already gives dependency isolation (apps not linking IoTMQTTCocoa never pull CocoaMQTT), and a
split would break the `path:`-based references in Piscine/Lumen. Revisit only if the framework is
ever distributed outside the monorepo tree.

## TODO (open, device/broker-gated)
- Validate IoTMQTTCocoa against a live broker (mosquitto on the homelab) — wiring is tested, the
  CocoaMQTT session itself is not.
- BLE-RPC on-device test + BLE digest-auth (password-protected Shellys).
- Adopt into apps: **Piscine DONE** (2026-08-12, `904c499`), **Lumen DONE** (2026-08-12,
  `56626fed` on branch `refactor/adopt-lorisiot`, not merged — FrigateMQTTClient +
  ConnectionManager iOS/TV on IoTCore; TV fork unified), **Velya** (after its 1.0.2 App Store
  review clears), **Éclair** (dedupe primitives).

## House rules
- Build/test with scratch path under /tmp: `swift test --scratch-path /tmp/lorisiot-build`.
- Never expose a provider SDK type across the Core boundary; keep DTOs `internal`.
- Tests: no live device/broker — inject transports, use fixtures, decode-only.
- Commit convention: `[lorisiot] <type>: <desc>`; co-author line for Claude.
