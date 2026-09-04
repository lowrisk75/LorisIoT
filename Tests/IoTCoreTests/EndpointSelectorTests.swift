import Testing
import Foundation
@testable import IoTCore

/// Scriptable prober: latencies per endpoint id, mutable between rounds. nil = unreachable.
private actor FakeProber: EndpointProber {
    private var latencies: [String: Double?]
    private(set) var probeCount = 0

    init(_ latencies: [String: Double?]) { self.latencies = latencies }
    func set(_ id: String, _ latency: Double?) { latencies[id] = latency }
    func probe(_ endpoint: IoTEndpoint) async -> Double? {
        probeCount += 1
        return latencies[endpoint.id] ?? nil
    }
}

/// Mutable SSID box for the injectable reader.
private actor SSIDBox {
    private var value: String?
    init(_ value: String?) { self.value = value }
    func set(_ newValue: String?) { value = newValue }
    func get() -> String? { value }
}

/// Manual clock so cooldown tests don't sleep.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: Double) { lock.lock(); date += seconds; lock.unlock() }
}

private func endpoint(_ id: String, ssidLock: String? = nil, enabled: Bool = true) -> IoTEndpoint {
    IoTEndpoint(id: id, url: URL(string: "http://\(id).local:5000")!, label: id,
                isEnabled: enabled, ssidLock: ssidLock)
}

@Suite struct EndpointSelectorTests {

    @Test func picksLowestLatencyEndpointInitially() async {
        let prober = FakeProber(["lan": 0.005, "vpn": 0.060])
        let selector = EndpointSelector(endpoints: [endpoint("vpn"), endpoint("lan")], prober: prober)
        await selector.probeOnce()
        #expect(await selector.active?.id == "lan")
    }

    @Test func smallLatencyWinDoesNotFlap() async {
        // 20% better and only 2ms absolute — both hysteresis gates must block the switch.
        let prober = FakeProber(["a": 0.010, "b": 0.008])
        let clock = ManualClock()
        let selector = EndpointSelector(endpoints: [endpoint("a"), endpoint("b")],
                                        prober: prober, now: { clock.now() })
        await selector.probeOnce()          // "b" wins the empty seat
        #expect(await selector.active?.id == "b")
        await prober.set("a", 0.0085)       // now "a" is 6% slower — no switch back
        clock.advance(60)
        await selector.probeOnce()
        #expect(await selector.active?.id == "b")
    }

    @Test func bigLatencyWinSwitchesAfterCooldown() async {
        let prober = FakeProber(["vpn": 0.080, "lan": nil])
        let clock = ManualClock()
        let selector = EndpointSelector(endpoints: [endpoint("vpn"), endpoint("lan")],
                                        prober: prober, now: { clock.now() })
        await selector.probeOnce()
        #expect(await selector.active?.id == "vpn")

        await prober.set("lan", 0.004)      // came home: LAN now 20× faster
        await selector.probeOnce()          // inside 30s cooldown → no switch yet
        #expect(await selector.active?.id == "vpn")

        clock.advance(31)
        await selector.probeOnce()
        #expect(await selector.active?.id == "lan")
    }

    @Test func downedActiveEndpointSwitchesImmediatelyIgnoringCooldown() async {
        let prober = FakeProber(["a": 0.005, "b": 0.050])
        let clock = ManualClock()
        let selector = EndpointSelector(endpoints: [endpoint("a"), endpoint("b")],
                                        prober: prober, now: { clock.now() })
        await selector.probeOnce()
        #expect(await selector.active?.id == "a")
        await prober.set("a", nil)          // active dies; cooldown must not delay recovery
        clock.advance(1)
        await selector.probeOnce()
        #expect(await selector.active?.id == "b")
    }

    @Test func ssidLockFailsClosedOnUnknownNetwork() async {
        // SSID reader returns nil (cellular / no permission) → locked endpoint ineligible.
        let prober = FakeProber(["locked": 0.001, "open": 0.050])
        let selector = EndpointSelector(
            endpoints: [endpoint("locked", ssidLock: "HomeNet"), endpoint("open")],
            prober: prober, currentSSID: { nil })
        await selector.probeOnce()
        #expect(await selector.active?.id == "open")
    }

    @Test func leavingLockedSSIDSwitchesWithoutStaleLatencyComparison() async {
        // NET-N01: active SSID-locked endpoint drops out of the pool → categorical switch,
        // even though its (stale) recorded latency still beats the challenger's.
        let prober = FakeProber(["locked": 0.001, "cell": 0.080])
        let ssid = SSIDBox("HomeNet")
        let selector = EndpointSelector(
            endpoints: [endpoint("locked", ssidLock: "HomeNet"), endpoint("cell")],
            prober: prober, currentSSID: { await ssid.get() })
        await selector.probeOnce()
        #expect(await selector.active?.id == "locked")

        await ssid.set(nil)                  // walked out the door
        await selector.probeOnce()
        #expect(await selector.active?.id == "cell")
    }

    @Test func noEligibleEndpointsDemotesToNil() async {
        let prober = FakeProber(["locked": 0.001])
        let ssid = SSIDBox("HomeNet")
        let selector = EndpointSelector(
            endpoints: [endpoint("locked", ssidLock: "HomeNet")],
            prober: prober, currentSSID: { await ssid.get() })
        await selector.probeOnce()
        #expect(await selector.active?.id == "locked")

        await ssid.set("CoffeeShop")
        await selector.probeOnce()
        #expect(await selector.active == nil)
        #expect(await selector.lastReachable["locked"] == false)
    }

    @Test func allUnreachableSeedsFallbackInsteadOfNilLock() async {
        // LR-C01: HEAD probes fail but the app may still stream — seed a client anyway.
        let prober = FakeProber(["a": nil, "b": nil])
        let selector = EndpointSelector(endpoints: [endpoint("a"), endpoint("b")], prober: prober)
        await selector.probeOnce()
        #expect(await selector.active?.id == "a")
        #expect(await selector.nextProbeDelay() == 10)   // on the backoff ramp
    }

    @Test func backoffRampsWhileUnreachableAndNeedsTwoSuccessesToReset() async {
        // NET-DEEP-H02: one good round must not reset the ramp; two consecutive ones do.
        let prober = FakeProber(["a": nil])
        let selector = EndpointSelector(endpoints: [endpoint("a")], prober: prober)
        await selector.probeOnce()
        await selector.probeOnce()
        await selector.probeOnce()
        #expect(await selector.nextProbeDelay() == 40)   // ramped 10→20→40

        await prober.set("a", 0.005)
        await selector.probeOnce()                        // 1st success: healthy cadence,
        #expect(await selector.nextProbeDelay() == 300)   // but ramp index survives…
        await prober.set("a", nil)
        await selector.probeOnce()                        // …so a relapse resumes high
        #expect(await selector.nextProbeDelay() == 60)    // 40's successor, not 10

        await prober.set("a", 0.005)
        await selector.probeOnce()
        await selector.probeOnce()                        // 2 consecutive successes → reset
        await prober.set("a", nil)
        await selector.probeOnce()
        #expect(await selector.nextProbeDelay() == 10)    // restarted from the bottom of the ramp
    }

    @Test func forcedEndpointBlocksAutoSwitching() async {
        let prober = FakeProber(["slow": 0.100, "fast": 0.001])
        let selector = EndpointSelector(endpoints: [endpoint("slow"), endpoint("fast")], prober: prober)
        await selector.forceEndpoint(endpoint("slow"))
        await selector.probeOnce()
        #expect(await selector.active?.id == "slow")

        await selector.releaseForce()                     // re-probes and frees the choice
        #expect(await selector.active?.id == "fast")
    }

    @Test func selectionsStreamEmitsSwitchesAndDemotion() async {
        let prober = FakeProber(["a": 0.005])
        let selector = EndpointSelector(endpoints: [endpoint("a")], prober: prober)
        let stream = await selector.selections()
        await selector.probeOnce()
        await selector.setEndpoints([])                   // user removed every endpoint
        await selector.stop()

        var events: [EndpointSelection] = []
        for await selection in stream { events.append(selection) }
        #expect(events.map(\.endpoint?.id) == ["a", nil])
        #expect(events.map(\.reason) == [.networkChange, .noneEligible])
    }

    @Test func disabledEndpointsAreNeverCandidates() async {
        let prober = FakeProber(["off": 0.001, "on": 0.050])
        let selector = EndpointSelector(
            endpoints: [endpoint("off", enabled: false), endpoint("on")], prober: prober)
        await selector.probeOnce()
        #expect(await selector.active?.id == "on")
    }
}

@Suite struct AdaptiveLatencyProberTests {

    @Test func timeoutAdaptsToNetworkClass() {
        #expect(AdaptiveLatencyProber.adaptiveTimeout(for: URL(string: "http://192.168.1.10:5000")!) == 2)
        #expect(AdaptiveLatencyProber.adaptiveTimeout(for: URL(string: "http://nvr.tail1234.ts.net")!) == 5)
        #expect(AdaptiveLatencyProber.adaptiveTimeout(for: URL(string: "http://100.64.0.7")!) == 5)
        #expect(AdaptiveLatencyProber.adaptiveTimeout(for: URL(string: "https://cam.example.com")!) == 4)
    }

    @Test func privateHostDetectionCoversRFC1918() {
        #expect(AdaptiveLatencyProber.isPrivateHost("10.0.0.8"))
        #expect(AdaptiveLatencyProber.isPrivateHost("172.16.0.1"))
        #expect(AdaptiveLatencyProber.isPrivateHost("172.31.255.255"))
        #expect(!AdaptiveLatencyProber.isPrivateHost("172.32.0.1"))
        #expect(AdaptiveLatencyProber.isPrivateHost("localhost"))
        #expect(!AdaptiveLatencyProber.isPrivateHost("8.8.8.8"))
    }
}
