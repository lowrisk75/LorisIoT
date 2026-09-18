import Foundation
import Darwin
import IoTCore
import IoTHomeAssistant

/// Synthetic HA protocol load through the real SDK and MainActor observers. No home network access.
@main struct IoTBench {
    static func main() async {
        do { try await run() }
        catch {
            emit(["status": "failed", "error": String(describing: error)])
            exit(1)
        }
    }
    static func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data([10]))
    }
    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 3, args[1] == "--seconds", let seconds = Int(args[2]),
              (10...86400).contains(seconds) else { throw BenchFailure.usage }
        let clock = BenchClock()
        let sink = await MainActor.run { BenchSink(clock: clock) }
        let transport = BenchTransport(clock: clock)
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://synthetic.invalid")!),
            token: "synthetic-token", makeTransport: { transport })
        var listeners: [Task<Void, any Error>] = []
        for index in 0..<1000 {
            let caps = try await provider.capabilities(for: DeviceID(rawValue: "sensor.bench_\(index)"))
            guard let subscription = caps.subscribe else { throw BenchFailure.subscription }
            let stream = await subscription.stateChanges()
            listeners.append(Task {
                for try await change in stream {
                    if Task.isCancelled { return }
                    switch change {
                    case .snapshot(let state), .updated(_, let state): await sink.accept(state)
                    case .unavailable: await sink.unavailable()
                    }
                }
            })
        }
        let activeListeners = listeners
        let cleanup = { @Sendable in
            for task in activeListeners { task.cancel() }
            await provider.disconnect()
        }
        do {
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while await sink.entityCount < 1000 {
                guard ContinuousClock.now < readyDeadline else { throw BenchFailure.bootstrap }
                try await Task.sleep(for: .milliseconds(10))
            }
            await sink.beginMeasurement()
            let started = ContinuousClock.now
            emit(["status": "running", "mode": "synthetic-ha-mainactor", "seconds": seconds, "entities": 1000, "updatesPerSecond": 100])
            for sequence in 0..<(seconds * 100) {
                try await Task.sleep(until: started.advanced(by: .milliseconds(sequence * 10)), clock: .continuous)
                try await transport.publish(sequence)
                if sequence > 0, sequence % 6000 == 0 {
                    let checkpoint = try await sink.report(status: "running", expected: sequence + 1, elapsed: elapsed(started))
                    FileHandle.standardOutput.write(checkpoint.data + Data([10]))
                }
            }
            let drainDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while await sink.received < seconds * 100, ContinuousClock.now < drainDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let report = try await sink.report(status: "completed", expected: seconds * 100, elapsed: elapsed(started))
            FileHandle.standardOutput.write(report.data + Data([10]))
            guard report.passed else { throw BenchFailure.threshold }
            await cleanup()
            for task in listeners { _ = try? await task.value }
        } catch {
            await cleanup()
            throw error
        }
    }
    static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }
}
enum BenchFailure: Error { case usage, subscription, bootstrap, overflow, threshold }

/// Fixed-size monotonic timestamp ring; all mutable state is protected by the lock.
final class BenchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var slots = [(Int, ContinuousClock.Instant)?](repeating: nil, count: 2048)
    func stamp(_ sequence: Int) { lock.withLock { slots[sequence % slots.count] = (sequence, .now) } }
    func latency(_ sequence: Int) -> Double? {
        lock.withLock {
            guard sequence >= 0, let slot = slots[sequence % slots.count], slot.0 == sequence else { return nil }
            let duration = slot.1.duration(to: .now).components
            return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        }
    }
}

@MainActor final class BenchSink {
    let clock: BenchClock
    private var entities: [DeviceID: DeviceState] = [:]
    private var histogram = [Int](repeating: 0, count: 1001) // millisecond bins, last bin >= 1 second
    private(set) var received = 0
    private var gaps = 0
    private var outages = 0
    private var baselineRSS: UInt64 = 0
    private var peakRSS: UInt64 = 0
    var entityCount: Int { entities.count }
    init(clock: BenchClock) { self.clock = clock }
    func beginMeasurement() { baselineRSS = residentBytes(); peakRSS = baselineRSS; outages = 0 }
    func unavailable() { outages += 1 }
    func accept(_ state: DeviceState) {
        entities[state.deviceID] = state
        guard case .decimal(let raw) = state.primaryValue, raw >= 0 else { return }
        let sequence = Int(raw)
        received += 1
        if let latency = clock.latency(sequence) { histogram[min(1000, max(0, Int(latency.rounded(.up))))] += 1 }
        else { gaps += 1 }
        if received % 100 == 0 { peakRSS = max(peakRSS, residentBytes()) }
    }
    func percentile(_ fraction: Double) -> Int {
        let target = max(1, Int((Double(received - gaps) * fraction).rounded(.up)))
        var count = 0
        for (index, samples) in histogram.enumerated() { count += samples; if count >= target { return index } }
        return 1000
    }
    func report(status: String, expected: Int, elapsed: Double) throws -> (data: Data, passed: Bool) {
        peakRSS = max(peakRSS, residentBytes())
        let growth = peakRSS > baselineRSS ? peakRSS - baselineRSS : 0
        let passed = received == expected && gaps == 0 && outages == 0 && percentile(0.95) <= 100
            && baselineRSS > 0 && growth < 64 * 1024 * 1024
        let report: [String: Any] = ["status": status, "mode": "synthetic-ha-mainactor", "entities": entities.count,
                "expected": expected, "received": received, "timestampGaps": gaps, "unavailableEvents": outages,
                "elapsedSeconds": elapsed, "p50MillisecondsUpperBound": percentile(0.5),
                "p95MillisecondsUpperBound": percentile(0.95), "p99MillisecondsUpperBound": percentile(0.99),
                "baselineRSSBytes": baselineRSS, "peakRSSBytes": peakRSS, "peakRSSGrowthBytes": growth,
                "passed": passed,
                "scope": "SDK delivery to MainActor; excludes SwiftUI rendering, LAN latency and physical devices"]
        return (try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), passed)
    }
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}

actor BenchTransport: RealtimeTransport {
    let clock: BenchClock
    private var frames: [Data] = []
    private var pending: CheckedContinuation<Data, any Error>?
    private var closed = false
    init(clock: BenchClock) { self.clock = clock }
    func open() throws { closed = false; frames = []; try deliver(Data(#"{"type":"auth_required"}"#.utf8)) }
    func send(_ data: Data) throws {
        let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch message?["type"] as? String {
        case "auth": try deliver(Data(#"{"type":"auth_ok"}"#.utf8))
        case "subscribe_events": try deliver(Data(#"{"type":"result","id":1,"success":true,"result":null}"#.utf8))
        case "get_states":
            let entities = (0..<1000).map { ["entity_id": "sensor.bench_\($0)", "state": "-1", "attributes": [:]] as [String: Any] }
            try deliver(JSONSerialization.data(withJSONObject: ["type": "result", "id": 2, "success": true, "result": entities]))
        case "ping": try deliver(Data(#"{"type":"pong","id":999}"#.utf8))
        default: throw IoTError.invalidResponse
        }
    }
    func publish(_ sequence: Int) throws {
        let id = "sensor.bench_\(sequence % 1000)"
        let state: [String: Any] = ["entity_id": id, "state": String(sequence), "attributes": ["unit_of_measurement": "°C"]]
        let data = try JSONSerialization.data(withJSONObject: ["type": "event", "event": [
            "event_type": "state_changed", "data": ["entity_id": id, "new_state": state]]])
        clock.stamp(sequence)
        try deliver(data)
    }
    func receive() async throws -> Data {
        guard !closed else { throw IoTError.notConnected }
        if !frames.isEmpty { return frames.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func close() {
        closed = true; frames = []
        let waiter = pending; pending = nil
        waiter?.resume(throwing: IoTError.cancelled)
    }
    private func deliver(_ data: Data) throws {
        guard !closed else { throw IoTError.notConnected }
        if let waiter = pending { pending = nil; waiter.resume(returning: data) }
        else { guard frames.count < 256 else { throw BenchFailure.overflow }; frames.append(data) }
    }
}
