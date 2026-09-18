import Foundation
import Testing
import IoTCore
@testable import IoTHomeAssistant

/// Qualification against a real Home Assistant instance. Strictly read-only: inventory through
/// `devices()`, state through `readState` on a bounded sample — no control capability is ever
/// invoked. Opt in with LORISIOT_READONLY_HA_URL and LORISIOT_READONLY_HA_TOKEN.
@Suite struct HomeAssistantReadOnlyLiveTests {
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { env["LORISIOT_READONLY_HA_URL"] != nil && env["LORISIOT_READONLY_HA_TOKEN"] != nil }

    /// Ground truth read directly from the instance, independent of the SDK code under test.
    struct Truth { let state: String; let lastReported: Date? }

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    static func groundTruth(url: URL, token: String) async throws -> [String: Truth] {
        var request = URLRequest(url: url.appendingPathComponent("api/states"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var truth: [String: Truth] = [:]
        for row in rows {
            guard let id = row["entity_id"] as? String, let state = row["state"] as? String else { continue }
            truth[id] = Truth(state: state,
                              lastReported: parseDate((row["last_reported"] ?? row["last_updated"]) as? String))
        }
        return truth
    }

    /// One entity's truth, read *after* the SDK observation so it can never be staler than it.
    static func truthAfter(_ id: String, url: URL, token: String) async throws -> Truth {
        var request = URLRequest(url: url.appendingPathComponent("api/states/\(id)"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let row = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Truth(state: row["state"] as? String ?? "",
                     lastReported: parseDate((row["last_reported"] ?? row["last_updated"]) as? String))
    }

    @Test(.enabled(if: enabled))
    func availabilityAndFreshnessAreNeverOverstatedAgainstARealInstance() async throws {
        let rawURL = try #require(Self.env["LORISIOT_READONLY_HA_URL"])
        let url = try #require(URL(string: rawURL))
        let token = try #require(Self.env["LORISIOT_READONLY_HA_TOKEN"])
        let truth = try await Self.groundTruth(url: url, token: token)

        let provider = HomeAssistantProvider(config: HAConfig(baseURL: url), token: token)
        try await provider.connect()

        // Inventory: the SDK must neither invent devices nor drop any the instance exposes.
        let devices = try await provider.devices()
        let sdkIDs = Set(devices.map(\.id.rawValue))
        #expect(sdkIDs.subtracting(truth.keys).isEmpty, "SDK reported devices absent from the instance")
        let missing = Set(truth.keys).subtracting(sdkIDs)

        // Bounded, deterministic sample: 20 unavailable + 20 recently reporting entities.
        let now = Date()
        let unavailable = truth.filter { $0.value.state == "unavailable" }.keys.sorted().prefix(20)
        let live = truth.filter { $0.value.state != "unavailable" && $0.value.state != "unknown"
            && ($0.value.lastReported.map { now.timeIntervalSince($0) < 3600 } ?? false) }.keys.sorted().prefix(20)

        var falseOnline: [String] = [], falseOffline: [String] = [], overstatedFreshness: [String] = []
        var understatedGaps: [TimeInterval] = []
        for id in Array(unavailable) + Array(live) {
            let capabilities = try await provider.capabilities(for: DeviceID(rawValue: id))
            let reader = try #require(capabilities.readState)
            let state = try await reader.state()
            let t = try await Self.truthAfter(id, url: url, token: token)
            if t.state == "unavailable", state.availability == .online { falseOnline.append(id) }
            if t.state != "unavailable", t.state != "unknown", state.availability != .online { falseOffline.append(id) }
            if let reported = t.lastReported {
                // Never claim fresher than the instance knows (5 s clock tolerance).
                if state.observedAt > reported.addingTimeInterval(5) { overstatedFreshness.append(id) }
                if t.state != "unavailable" { understatedGaps.append(reported.timeIntervalSince(state.observedAt)) }
            }
        }
        await provider.disconnect()

        #expect(falseOnline.isEmpty, "unavailable entities reported online: \(falseOnline)")
        #expect(falseOffline.isEmpty, "live entities reported offline: \(falseOffline)")
        #expect(overstatedFreshness.isEmpty, "freshness overstated for: \(overstatedFreshness)")

        let sortedGaps = understatedGaps.sorted()
        let median = sortedGaps.isEmpty ? 0 : sortedGaps[sortedGaps.count / 2]
        print("LIVE-HA inventory instance=\(truth.count) sdk=\(devices.count) missing=\(missing.count) "
            + "| sample unavailable=\(unavailable.count) live=\(live.count) "
            + "| staleness understated by last_updated: median=\(Int(median))s max=\(Int(sortedGaps.last ?? 0))s")
    }
}
