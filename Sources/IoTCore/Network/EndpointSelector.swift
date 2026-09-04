import Foundation
#if canImport(Network)
import Network
#endif

// Ported from Lumen `ConnectionManager` (app + LumenTV forks — this replaces both). The selector
// owns WHICH base URL to talk to when a server is reachable at several addresses (LAN IP,
// Tailscale, public reverse-proxy): adaptive-latency probing, switch hysteresis, SSID-lock
// eligibility, probe backoff with storm suppression. App-side concerns stay out of Core:
// persistence/stats UI, client construction on switch, login flows, HTTP→HTTPS URL rewriting.

// MARK: - Model

public struct IoTEndpoint: Sendable, Hashable, Identifiable {
    public let id: String
    public var url: URL
    public var label: String
    public var isEnabled: Bool
    /// When set, the endpoint is eligible ONLY while the current Wi-Fi SSID matches — and
    /// **fail-closed**: unknown SSID (cellular, or no Location permission) means NOT eligible.
    /// For trusted, unauthenticated LAN-only addresses.
    public var ssidLock: String?

    public init(id: String, url: URL, label: String = "", isEnabled: Bool = true, ssidLock: String? = nil) {
        self.id = id; self.url = url; self.label = label.isEmpty ? url.host() ?? id : label
        self.isEnabled = isEnabled; self.ssidLock = ssidLock
    }
}

public enum EndpointSwitchReason: String, Sendable, Codable {
    case networkChange, latencyWin, endpointDown, manual, fallbackSeed, noneEligible
}

/// Emitted on every change of the active endpoint. `endpoint == nil` = full demotion (no endpoint
/// is active anymore), not merely "switched" — consumers must handle both.
public struct EndpointSelection: Sendable, Equatable {
    public let endpoint: IoTEndpoint?
    public let reason: EndpointSwitchReason
}

/// Latency probe seam — injectable so the selector is unit-testable with no network.
public protocol EndpointProber: Sendable {
    /// Round-trip seconds to a health endpoint, or nil if unreachable.
    func probe(_ endpoint: IoTEndpoint) async -> Double?
}

// MARK: - Selector

/// Picks the best endpoint and re-picks as conditions change. Drive it with `probeOnce()` (or the
/// self-scheduling `run()`), feed network transitions via `noteNetworkChanged()`, observe with
/// `selections()`. Hysteresis prevents flapping between two comparable endpoints; the SSID-lock +
/// demotion + "active dropped out of the candidate pool" rules port Lumen's field fixes (NET-N01,
/// NET-DEEP-H02, QA05).
public actor EndpointSelector {

    public struct Config: Sendable {
        /// A challenger must beat the incumbent by ≥ this fraction of the incumbent's latency…
        public var switchThresholdPercent: Double
        /// …AND by ≥ this absolute margin (both, or micro-differences flap on a fast LAN).
        public var switchMinAbsoluteSeconds: Double
        /// Minimum seconds between latency-win switches (down/ineligible switches bypass this).
        public var switchCooldownSeconds: Double
        /// Probe-retry delays while everything is unreachable (capped at the last value).
        public var probeBackoff: [Double]
        /// Consecutive fully-successful probe rounds required before the backoff resets —
        /// 1 flaky + 1 stable endpoint must not reset the ramp every other round (NET-DEEP-H02).
        public var successesToResetBackoff: Int
        /// Re-probe cadence while healthy (detects "came home onto the LAN").
        public var periodicProbeSeconds: Double

        public init(switchThresholdPercent: Double = 0.30,
                    switchMinAbsoluteSeconds: Double = 0.010,
                    switchCooldownSeconds: Double = 30,
                    probeBackoff: [Double] = [10, 20, 40, 60],
                    successesToResetBackoff: Int = 2,
                    periodicProbeSeconds: Double = 300) {
            self.switchThresholdPercent = switchThresholdPercent
            self.switchMinAbsoluteSeconds = switchMinAbsoluteSeconds
            self.switchCooldownSeconds = switchCooldownSeconds
            self.probeBackoff = probeBackoff.isEmpty ? [10] : probeBackoff
            self.successesToResetBackoff = max(1, successesToResetBackoff)
            self.periodicProbeSeconds = periodicProbeSeconds
        }
    }

    public private(set) var endpoints: [IoTEndpoint]
    public private(set) var active: IoTEndpoint?
    public private(set) var isForced = false
    /// Last measured latency (seconds) per endpoint id; absent = never reached.
    public private(set) var lastLatency: [String: Double] = [:]
    /// Reachability from the most recent round each endpoint took part in.
    public private(set) var lastReachable: [String: Bool] = [:]

    private let config: Config
    private let prober: any EndpointProber
    private let currentSSID: @Sendable () async -> String?
    private let now: @Sendable () -> Date

    private var lastSwitchAt: Date?
    private var backoffIndex = 0
    private var currentBackoffDelay: Double = 0
    private var consecutiveSuccesses = 0
    private var allUnreachableLastRound = false
    private var continuation: AsyncStream<EndpointSelection>.Continuation?
    private var runTask: Task<Void, Never>?

    /// - Parameters:
    ///   - currentSSID: reads the joined Wi-Fi SSID (`NEHotspotNetwork.fetchCurrent()?.ssid` on
    ///     iOS, `CWWiFiClient` on macOS). Defaults to nil = "unknown", which fail-closes every
    ///     SSID-locked endpoint — apps with locked endpoints MUST inject a real reader.
    public init(endpoints: [IoTEndpoint],
                config: Config = .init(),
                prober: any EndpointProber,
                currentSSID: @escaping @Sendable () async -> String? = { nil },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoints = endpoints
        self.config = config
        self.prober = prober
        self.currentSSID = currentSSID
        self.now = now
    }

    // MARK: Observation

    /// Stream of active-endpoint changes (including demotion to nil). Single consumer.
    public func selections() -> AsyncStream<EndpointSelection> {
        AsyncStream { continuation in self.continuation = continuation }
    }

    // MARK: Lifecycle

    /// Self-scheduling probe loop: probes immediately, then re-probes at `periodicProbeSeconds`
    /// while healthy or on the backoff ramp while everything is unreachable. Idempotent.
    public func start() {
        guard runTask == nil else { return }
        runTask = Task {
            while !Task.isCancelled {
                await probeOnce()
                try? await Task.sleep(for: .seconds(nextProbeDelay()))
            }
        }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        continuation?.finish()
        continuation = nil
    }

    /// Call on a meaningful network transition (interface-family change or Wi-Fi SSID change —
    /// NOT on screen-lock Wi-Fi flicker, see QA05): resets the backoff ramp and re-probes now.
    /// Feed from `NetworkStatusMonitor.stream()` deduplicated on `interface`.
    public func noteNetworkChanged() async {
        backoffIndex = 0
        consecutiveSuccesses = 0
        await probeOnce()
    }

    /// Replace the endpoint list (user edited servers). Active endpoint is kept if it survives.
    public func setEndpoints(_ newEndpoints: [IoTEndpoint]) async {
        endpoints = newEndpoints
        if let active, !newEndpoints.contains(where: { $0.id == active.id }) {
            switchTo(nil, reason: .noneEligible)
        }
        await probeOnce()
    }

    /// Pin an endpoint manually; auto-switching pauses until `releaseForce()`.
    public func forceEndpoint(_ endpoint: IoTEndpoint) {
        isForced = true
        switchTo(endpoint, reason: .manual)
    }

    public func releaseForce() async {
        isForced = false
        lastSwitchAt = nil   // an explicit user action resets the anti-flap cooldown
        await probeOnce()
    }

    // MARK: Probing

    /// One full probe round: eligibility → concurrent latency probes → switch decision.
    public func probeOnce() async {
        let candidates = await eligibleEndpoints()

        guard !candidates.isEmpty else {
            // Full demotion: an SSID-locked endpoint after leaving its network must not linger as
            // "active" — it would keep receiving requests, defeating the lock (Lumen NET-N01 kin).
            allUnreachableLastRound = false
            if !isForced, active != nil {
                if let demoted = active { lastReachable[demoted.id] = false }
                switchTo(nil, reason: .noneEligible)
            }
            return
        }

        let results: [(IoTEndpoint, Double?)] = await withTaskGroup(of: (IoTEndpoint, Double?).self) { group in
            for endpoint in candidates {
                let p = prober
                group.addTask { (endpoint, await p.probe(endpoint)) }
            }
            var collected: [(IoTEndpoint, Double?)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        for (endpoint, latency) in results {
            lastReachable[endpoint.id] = latency != nil
            if let latency { lastLatency[endpoint.id] = latency }
        }

        guard !isForced else { return }

        let reachable = results.compactMap { ep, lat in lat.map { (ep, $0) } }.sorted { $0.1 < $1.1 }

        guard let (best, bestLatency) = reachable.first else {
            consecutiveSuccesses = 0
            allUnreachableLastRound = true
            // Delay at the CURRENT ramp position, then advance — first failure waits
            // probeBackoff[0], not [1] (Lumen scheduleRetry semantics).
            currentBackoffDelay = config.probeBackoff[min(backoffIndex, config.probeBackoff.count - 1)]
            backoffIndex = min(backoffIndex + 1, config.probeBackoff.count - 1)
            // Never-connected safety net: probes can fail while real requests would succeed
            // (proxy buffers HEAD, cookie-auth rejects it). Seed the first candidate rather than
            // leaving the app nil-locked with tiles spinning forever (Lumen LR-C01).
            if active == nil, let fallback = candidates.first {
                switchTo(fallback, reason: .fallbackSeed)
            }
            return
        }

        allUnreachableLastRound = false
        consecutiveSuccesses += 1
        if consecutiveSuccesses >= config.successesToResetBackoff { backoffIndex = 0 }

        if active == nil {
            switchTo(best, reason: .networkChange)
        } else if let current = active, !candidates.contains(where: { $0.id == current.id }) {
            // NET-N01: the active endpoint dropped out of THIS round's pool (SSID lock broke,
            // user disabled it). Its stats are stale — comparing latencies against them routinely
            // blocks the Wi-Fi→cellular switch. Categorical ineligibility switches immediately.
            switchTo(best, reason: .networkChange)
        } else if let current = active, lastReachable[current.id] == false {
            switchTo(best, reason: .endpointDown)
        } else if let current = active, current.id != best.id,
                  let currentLatency = lastLatency[current.id] {
            let improvement = currentLatency - bestLatency
            let cooldownOK = lastSwitchAt.map { now().timeIntervalSince($0) >= config.switchCooldownSeconds } ?? true
            if improvement / currentLatency >= config.switchThresholdPercent,
               improvement >= config.switchMinAbsoluteSeconds,
               cooldownOK {
                switchTo(best, reason: .latencyWin)
            }
        }
    }

    /// Delay before the next automatic probe: backoff ramp while everything is unreachable,
    /// periodic cadence while healthy.
    public func nextProbeDelay() -> Double {
        allUnreachableLastRound ? currentBackoffDelay : config.periodicProbeSeconds
    }

    // MARK: Internals

    private func eligibleEndpoints() async -> [IoTEndpoint] {
        let enabled = endpoints.filter(\.isEnabled)
        guard enabled.contains(where: { $0.ssidLock?.isEmpty == false }) else { return enabled }
        let ssid = await currentSSID()
        return enabled.filter { endpoint in
            guard let lock = endpoint.ssidLock, !lock.isEmpty else { return true }
            guard let ssid else { return false }    // fail-closed on unknown network
            return ssid == lock
        }
    }

    private func switchTo(_ endpoint: IoTEndpoint?, reason: EndpointSwitchReason) {
        guard endpoint?.id != active?.id else { return }
        active = endpoint
        lastSwitchAt = now()
        continuation?.yield(EndpointSelection(endpoint: endpoint, reason: reason))
    }
}

// MARK: - Default prober

/// HEAD-probe against `<endpoint>/<healthPath>` with a network-class-adaptive timeout
/// (LAN 2 s · Tailscale 5 s · public 4 s — NET-H03). `http://` targets probe over raw TCP
/// (ATS bypass, same reason as `RawTCPWebSocketTransport`); HTTPS goes through URLSession.
/// 2xx–3xx counts as reachable. Auth headers (Basic, Cookie, CF-Access…) must be supplied —
/// a header-blind probe 403s behind zero-trust proxies and no endpoint ever looks reachable
/// (Lumen LR-C01).
public struct AdaptiveLatencyProber: EndpointProber {
    public var healthPath: String
    public var headers: [String: String]

    public init(healthPath: String, headers: [String: String] = [:]) {
        self.healthPath = healthPath
        self.headers = headers
    }

    /// A probe measures transport reachability, not whether the caller's
    /// credentials have completed the device's login flow. An authenticated
    /// origin can legitimately answer 401 to a stateless HEAD, and some
    /// proxies reject HEAD with 405 while accepting real GETs. Both prove
    /// DNS, TLS and the HTTP origin are alive.
    ///
    /// 403 is deliberately excluded: it usually means a zero-trust service
    /// token or header is missing or rejected, which is not reachability.
    ///
    /// Ported from Lumen's ConnectionManager (2026-09), where treating 401 as
    /// unreachable made every auth-enabled Frigate server look down.
    public static func isReachableHTTPStatus(_ statusCode: Int) -> Bool {
        (200...399).contains(statusCode) || statusCode == 401 || statusCode == 405
    }

    /// Visible for testing.

    static func adaptiveTimeout(for url: URL) -> Double {
        guard let host = url.host() else { return 4 }
        if host.hasSuffix(".ts.net") || host.hasPrefix("100.") { return 5 }
        if isPrivateHost(host) { return 2 }
        return 4
    }

    static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasPrefix("127.") || host == "::1" { return true }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }

    public func probe(_ endpoint: IoTEndpoint) async -> Double? {
        let url = endpoint.url.appendingPathComponent(healthPath)
        let start = Date()
        #if canImport(Network)
        if url.scheme == "http" || url.scheme == "ws" {
            return await rawTCPHead(url) ? Date().timeIntervalSince(start) : nil
        }
        #endif
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = Self.adaptiveTimeout(for: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  Self.isReachableHTTPStatus(http.statusCode) else { return nil }
            return Date().timeIntervalSince(start)
        } catch {
            return nil
        }
    }

    #if canImport(Network)
    private func rawTCPHead(_ url: URL) async -> Bool {
        guard let host = url.host(), !host.isEmpty else { return false }
        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) ?? .http
        let connection = NWConnection(host: .init(host), port: port, using: .tcp)
        defer { connection.cancel() }

        var lines = "HEAD \(url.path.isEmpty ? "/" : url.path) HTTP/1.1\r\n"
        lines += "Host: \(host)\r\nConnection: close\r\n"
        let reserved: Set<String> = ["host", "connection"]
        for (name, value) in headers where !reserved.contains(name.lowercased()) {
            lines += "\(name): \(value)\r\n"
        }
        lines += "\r\n"

        do {
            try await NWConnectionAsync.waitReady(connection, timeout: Self.adaptiveTimeout(for: url))
            try await NWConnectionAsync.send(connection, Data(lines.utf8))
            let response = try await NWConnectionAsync.receiveChunk(connection, max: 1024)
            guard let text = String(data: response, encoding: .utf8), text.hasPrefix("HTTP/") else { return false }
            let statusLine = text.prefix { $0 != "\r" && $0 != "\n" }
            let parts = statusLine.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2, let code = Int(parts[1]) else { return false }
            return Self.isReachableHTTPStatus(code)
        } catch {
            return false
        }
    }
    #endif
}
