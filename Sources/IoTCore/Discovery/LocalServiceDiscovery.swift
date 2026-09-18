import Foundation
@preconcurrency import Network

public struct DiscoveredService: Sendable, Hashable, Identifiable {
    public let name: String
    public let type: String
    public let domain: String
    public var id: String { "\(type)|\(domain)|\(name)" }
    public init(name: String, type: String, domain: String = "local.") {
        self.name = name; self.type = type; self.domain = domain
    }
}

public struct ResolvedService: Sendable, Hashable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
    public func url(scheme: String) -> URL? {
        var c = URLComponents(); c.scheme = scheme; c.host = host; c.port = Int(port)
        return c.url
    }
}

/// Bonjour discovery with a finite window. The host must declare NSBonjourServices and a Local
/// Network usage description. Discovery identifies candidates; authenticated probing verifies them.
@MainActor public final class LocalServiceDiscovery {
    public static let homeAssistant = "_home-assistant._tcp"
    public static let shelly = "_shelly._tcp"
    public static let mqtt = "_mqtt._tcp"
    private var browsers: [NWBrowser] = []
    private var continuation: AsyncThrowingStream<[DiscoveredService], any Error>.Continuation?
    private var results: [String: [DiscoveredService]] = [:]
    private var timer: Task<Void, Never>?
    private var generation: UInt64 = 0
    public init() {}

    public func scan(types: [String] = [homeAssistant, shelly], duration: TimeInterval = 8)
        -> AsyncThrowingStream<[DiscoveredService], any Error> {
        stop()
        let token = generation
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { c in
            guard duration.isFinite, duration > 0, duration <= 60,
                  !types.isEmpty, types.count <= 8, Set(types).count == types.count,
                  types.allSatisfy({ $0.hasPrefix("_") && $0.hasSuffix("._tcp") }) else {
                c.finish(throwing: IoTError.notConfigured); return
            }
            continuation = c; c.yield([])
            c.onTermination = { [weak self] _ in
                Task { @MainActor in if self?.generation == token { self?.stop() } }
            }
            for type in types {
                let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: .tcp)
                browser.browseResultsChangedHandler = { [weak self] found, _ in
                    let services = found.compactMap { result -> DiscoveredService? in
                        guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
                        return DiscoveredService(name: name, type: type, domain: domain)
                    }
                    Task { @MainActor in self?.update(services, type: type, generation: token) }
                }
                browser.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .failed, .waiting:
                        Task { @MainActor in
                            guard self?.generation == token else { return }
                            self?.continuation?.finish(throwing: IoTError.transport("Local discovery unavailable"))
                            self?.stop()
                        }
                    default: break
                    }
                }
                browsers.append(browser); browser.start(queue: .global(qos: .utility))
            }
            timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                if self?.generation == token { self?.stop() }
            }
        }
    }

    public func stop() {
        generation &+= 1; timer?.cancel(); timer = nil
        for browser in browsers { browser.cancel() }; browsers = []; results = [:]
        continuation?.finish(); continuation = nil
    }

    private func update(_ services: [DiscoveredService], type: String, generation token: UInt64) {
        guard token == generation else { return }
        results[type] = services
        let all = results.values.flatMap { $0 }
        guard all.count <= 128 else { continuation?.finish(throwing: IoTError.invalidResponse); stop(); return }
        continuation?.yield(all.sorted { $0.id < $1.id })
    }

    public func resolve(_ service: DiscoveredService) async throws -> ResolvedService {
        let operation = ServiceResolution(service)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation.value()
        } onCancel: { Task { @MainActor in operation.cancel() } }
    }
}

@MainActor private final class ServiceResolution {
    private let connection: NWConnection
    private var continuation: CheckedContinuation<ResolvedService, any Error>?
    private var timer: Task<Void, Never>?
    private var cancelled = false
    init(_ service: DiscoveredService) {
        connection = NWConnection(to: .service(name: service.name, type: service.type, domain: service.domain, interface: nil), using: .tcp)
    }
    func value() async throws -> ResolvedService {
        guard !cancelled else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { c in
            continuation = c
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.changed(state) }
            }
            timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.finish(.failure(IoTError.timeout))
            }
            connection.start(queue: .global(qos: .utility))
        }
    }
    func cancel() { cancelled = true; finish(.failure(CancellationError())) }
    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint else {
                finish(.failure(IoTError.invalidResponse)); return
            }
            finish(.success(ResolvedService(host: "\(host)", port: port.rawValue)))
        case .failed: finish(.failure(IoTError.notConnected))
        case .cancelled: finish(.failure(CancellationError()))
        default: break
        }
    }
    private func finish(_ result: Result<ResolvedService, any Error>) {
        guard let c = continuation else { return }; continuation = nil
        timer?.cancel(); timer = nil; connection.cancel(); c.resume(with: result)
    }
}
