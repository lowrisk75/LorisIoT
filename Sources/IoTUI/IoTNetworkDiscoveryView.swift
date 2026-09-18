import SwiftUI
import IoTCore

public struct IoTDiscoveryChoice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let address: String
    public init(id: String, name: String, address: String) { self.id = id; self.name = name; self.address = address }
}

public struct IoTNetworkDiscovery: Sendable {
    public let networks: @MainActor @Sendable () async throws -> [IoTDiscoveryChoice]
    public let scan: @MainActor @Sendable (String) async throws -> [IoTDiscoveryChoice]
    public init(networks: @escaping @MainActor @Sendable () async throws -> [IoTDiscoveryChoice],
                scan: @escaping @MainActor @Sendable (String) async throws -> [IoTDiscoveryChoice]) {
        self.networks = networks; self.scan = scan
    }
}

struct IoTNetworkDiscoveryView: View {
    let backend: IoTNetworkDiscovery
    let select: (IoTDiscoveryChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var networks: [IoTDiscoveryChoice] = []
    @State private var selected = ""
    @State private var results: [IoTDiscoveryChoice] = []
    @State private var issue: IoTConnectionIssue?
    @State private var busy = false
    @State private var loadingNetworks = true
    @State private var searched = false
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var networkGeneration = UUID()

    var body: some View {
        Form {
            Section {
                iotText("discovery.network.help").font(.callout).foregroundStyle(.secondary)
                Picker(selection: $selected) {
                    iotText("discovery.network.choose").tag("")
                    ForEach(networks) { network in
                        Text("\(network.name) — \(network.address)").tag(network.id)
                    }
                } label: { iotText("discovery.network.title") }
                .disabled(busy)
                Button { scan() } label: { iotText("discovery.network.scan") }
                    .disabled(busy || selected.isEmpty)
                if busy { ProgressView { iotText("discovery.network.scanning") } }
                if loadingNetworks { ProgressView() }
                if networks.isEmpty && !busy && !loadingNetworks { iotText("discovery.network.none") }
            }
            if let issue { iotText("recovery.\(issue.rawValue)").foregroundStyle(.secondary) }
            if searched && results.isEmpty && !busy && issue == nil { iotText("discovery.network.empty") }
            ForEach(results) { device in
                Button { select(device) } label: {
                    VStack(alignment: .leading) {
                        Text(device.name).font(.headline)
                        Text(device.address).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(busy)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle(iotText("connect.discovery"))
        .toolbar { Button { dismiss() } label: { iotText("connect.cancel") } }
        .task {
            let identity = UUID(); networkGeneration = identity
            loadingNetworks = true
            defer { if networkGeneration == identity { loadingNetworks = false } }
            do {
                let values = try await backend.networks()
                try Task.checkCancellation()
                guard networkGeneration == identity else { return }
                guard values.count <= 32, Set(values.map(\.id)).count == values.count else { throw IoTError.invalidResponse }
                networks = values
                if !values.contains(where: { $0.id == selected }) { selected = "" }
            } catch is CancellationError {} catch {
                if networkGeneration == identity && !Task.isCancelled { issue = .classify(error) }
            }
        }
        .onChange(of: selected) { _, _ in results = []; searched = false; issue = nil }
        .onDisappear {
            generation = UUID(); networkGeneration = UUID()
            task?.cancel(); task = nil
            busy = false; loadingNetworks = false
        }
    }

    private func scan() {
        guard !busy, networks.contains(where: { $0.id == selected }) else { return }
        busy = true; results = []; issue = nil; searched = true
        let identity = UUID(); generation = identity
        let network = selected
        task = Task { @MainActor in
            defer { if generation == identity { busy = false } }
            do {
                let found = try await backend.scan(network)
                try Task.checkCancellation()
                guard generation == identity else { return }
                guard found.count <= 64, Set(found.map(\.id)).count == found.count else { throw IoTError.invalidResponse }
                results = found
            } catch is CancellationError {} catch {
                if generation == identity { issue = .classify(error) }
            }
        }
    }
}
