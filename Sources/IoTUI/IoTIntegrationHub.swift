import SwiftUI
import IoTCore

public struct IoTIntegrationHub: View {
    @Environment(\.locale) private var locale
    private let providers: [any DeviceProvider]
    private let addConnection: @MainActor () -> Void

    public init(providers: [any DeviceProvider], addConnection: @escaping @MainActor () -> Void) {
        self.providers = providers; self.addConnection = addConnection
    }
    public var body: some View {
        List {
            if providers.isEmpty {
                ContentUnavailableView {
                    Label { iotText("hub.empty.title") } icon: { Image(systemName: "house.and.flag") }
                } description: { iotText("hub.empty.detail") }
                    actions: { Button(action: addConnection) { iotText("add_connection") }.buttonStyle(.borderedProminent) }
            }
            ForEach(providers.map(ProviderEntry.init)) { entry in
                IoTProviderSection(provider: entry.provider)
            }
        }
        .navigationTitle(Text(verbatim: iotString("hub.title", locale: locale)))
        .toolbar { Button(action: addConnection) { Label { iotText("add_connection") } icon: { Image(systemName: "plus") } } }
    }
}

private struct ProviderEntry: Identifiable {
    let provider: any DeviceProvider
    var id: ObjectIdentifier { ObjectIdentifier(provider) }
    init(_ provider: any DeviceProvider) { self.provider = provider }
}

private struct IoTProviderSection: View {
    let provider: any DeviceProvider
    @State private var devices: [Device] = []
    @State private var connection: ProviderConnectionState = .disconnected
    @State private var issue: IoTConnectionIssue?
    @State private var loading = false

    var body: some View {
        Section {
            HStack {
                Label { iotText("connection.\(connection.rawValue)") }
                    icon: { Image(systemName: connection == .connected ? "network" : "wifi.exclamationmark") }
                Spacer()
                if loading { ProgressView().accessibilityLabel(iotText("loading")) }
                else { Button { Task { await refresh() } } label: { iotText("refresh") } }
            }
            if let issue { iotText("recovery.\(issue.rawValue)").foregroundStyle(.secondary) }
            ForEach(devices) { device in
                NavigationLink {
                    IoTDeviceDetailView(device: device, provider: provider)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name).font(.headline)
                        if let model = device.model { Text(model).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 8)
                }
            }
            if devices.isEmpty, !loading, issue == nil { iotText("devices.empty").foregroundStyle(.secondary) }
        } header: { Text(provider.displayName) }
        .task { await refresh() }
        .task {
            for await event in await provider.connectionEvents() {
                guard !Task.isCancelled else { return }
                connection = event.state
            }
        }
    }

    @MainActor private func refresh() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            try await provider.connect()
            devices = try await provider.devices(); issue = nil
        } catch is CancellationError {}
        catch { issue = .classify(error) }
    }
}
