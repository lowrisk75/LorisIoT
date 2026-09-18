import SwiftUI
import IoTCore

public struct IoTDiscoveryView: View {
    @Environment(\.locale) private var locale
    private let types: [String]
    private let selected: @MainActor (ResolvedService) -> Void
    private let manual: @MainActor () -> Void
    @State private var discovery = LocalServiceDiscovery()
    @State private var services: [DiscoveredService] = []
    @State private var scanning = true
    @State private var resolving = false
    @State private var issue: IoTConnectionIssue?
    @State private var resolutionTask: Task<Void, Never>?
    public init(types: [String] = [LocalServiceDiscovery.homeAssistant, LocalServiceDiscovery.shelly],
                selected: @escaping @MainActor (ResolvedService) -> Void, manual: @escaping @MainActor () -> Void) {
        self.types = types; self.selected = selected; self.manual = manual
    }
    public var body: some View {
        List {
            iotText("connect.discovery.help").foregroundStyle(.secondary)
            if scanning || resolving { ProgressView { iotText("loading") } }
            ForEach(services) { service in
                Button {
                    resolving = true
                    resolutionTask = Task { @MainActor in
                        defer { resolving = false }
                        do {
                            let result = try await discovery.resolve(service)
                            try Task.checkCancellation()
                            selected(result)
                        }
                        catch is CancellationError { }
                        catch { issue = .classify(error) }
                    }
                } label: { Label(service.name, systemImage: "network") }
                    .disabled(resolving)
            }
            if !scanning && services.isEmpty { iotText("connect.no_results") }
            if let issue { iotText("recovery.\(issue.rawValue)") }
            Button { resolutionTask?.cancel(); manual() } label: { iotText("connect.manual") }.frame(minHeight: 44)
        }
        .navigationTitle(Text(verbatim: iotString("connect.discovery", locale: locale)))
        .onDisappear { resolutionTask?.cancel(); discovery.stop() }
        .task {
            defer { scanning = false }
            do { for try await found in discovery.scan(types: types) { services = found } }
            catch is CancellationError {}
            catch { issue = .classify(error) }
        }
    }
}
