import SwiftUI
import IoTCore

public enum IoTConnectionKind: String, CaseIterable, Identifiable, Sendable {
    case homeAssistant, shelly, mqtt, govee
    public var id: Self { self }
    public var displayName: String {
        switch self { case .homeAssistant: "Home Assistant"; case .shelly: "Shelly"; case .mqtt: "MQTT / Zigbee2MQTT"; case .govee: "Govee" }
    }
}

public struct IoTConnectionRequest: Sendable {
    public let kind: IoTConnectionKind
    public let name: String
    public let address: String
    public let username: String
    public let secret: String
}

/// The app supplies persistence/provider creation and OAuth presentation, keeping its policy explicit.
public struct IoTConnectionView: View {
    private let connect: @MainActor (IoTConnectionRequest) async throws -> Void
    private let authorize: (@MainActor (_ address: String, _ name: String) async throws -> Void)?
    private let goveeDiscovery: IoTNetworkDiscovery?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var kind: IoTConnectionKind
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var busy = false
    @State private var issue: IoTConnectionIssue?
    @State private var advanced = false
    @State private var showDiscovery = false
    @State private var connectionTask: Task<Void, Never>?

    public init(kind: IoTConnectionKind = .homeAssistant,
                connect: @escaping @MainActor (IoTConnectionRequest) async throws -> Void,
                authorize: (@MainActor (String, String) async throws -> Void)? = nil,
                goveeDiscovery: IoTNetworkDiscovery? = nil) {
        _kind = State(initialValue: kind); self.connect = connect; self.authorize = authorize
        self.goveeDiscovery = goveeDiscovery
    }
    public var body: some View {
        Form {
            Section {
                Picker(selection: $kind) { ForEach(IoTConnectionKind.allCases) { Text($0.displayName).tag($0) } }
                    label: { iotText("connect.title") }
                TextField(text: $name) { iotText("connect.name") }
                TextField(text: $address) { iotText("connect.address") }
                    .autocorrectionDisabled()
                if kind != .govee || goveeDiscovery != nil {
                    Button { showDiscovery = true } label: { iotText("connect.discovery") }
                }
            }.disabled(busy)
            if kind == .govee {
                iotText("connect.govee.help").font(.callout).foregroundStyle(.secondary)
                submit
            } else if kind == .homeAssistant {
                if let authorize {
                    Button {
                        let capturedAddress = address
                        let capturedName = name
                        run { try await authorize(capturedAddress, capturedName) }
                    } label: { iotText("connect.authorize") }
                    .buttonStyle(.borderedProminent).disabled(busy || address.isEmpty)
                }
                if authorize != nil {
                    DisclosureGroup(isExpanded: $advanced) { manualHomeAssistant }
                        label: { iotText("connect.advanced") }
                } else { manualHomeAssistant }
            } else {
                if kind == .mqtt { TextField(text: $username) { iotText("connect.username") }.autocorrectionDisabled().disabled(busy) }
                SecureField(text: $secret) { iotText("connect.password") }.disabled(busy)
                submit
            }
            if busy { ProgressView { iotText("connection.connecting") } }
            if let issue { iotText("recovery.\(issue.rawValue)").foregroundStyle(.secondary) }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle(Text(verbatim: iotString("connect.title", locale: locale)))
        .toolbar { Button { dismiss() } label: { iotText("connect.cancel") } }
        .onChange(of: kind) { _, _ in secret = ""; issue = nil }
        .onDisappear { connectionTask?.cancel(); connectionTask = nil; secret = "" }
        .sheet(isPresented: $showDiscovery) {
            NavigationStack {
                if kind == .govee, let goveeDiscovery {
                    IoTNetworkDiscoveryView(backend: goveeDiscovery) { candidate in
                        address = candidate.address
                        if name.isEmpty { name = candidate.name }
                        showDiscovery = false
                    }
                } else {
                IoTDiscoveryView(types: kind == .shelly ? [LocalServiceDiscovery.shelly]
                                 : kind == .mqtt ? [LocalServiceDiscovery.mqtt] : [LocalServiceDiscovery.homeAssistant]) { resolved in
                    address = resolved.url(scheme: kind == .mqtt ? "mqtt" : "http")?.absoluteString ?? resolved.host
                    showDiscovery = false
                } manual: { showDiscovery = false }
                }
            }
            .environment(\.locale, locale)
        }
    }
    private var manualHomeAssistant: some View {
        Group {
            SecureField(text: $secret) { iotText("connect.token") }.disabled(busy)
            submit
        }
    }
    private var submit: some View {
        Button {
            let request = IoTConnectionRequest(kind: kind, name: name, address: address,
                                               username: username, secret: secret)
            run {
                try await connect(request)
            }
        } label: { iotText(kind == .govee ? "connect.govee.action" : "connect.action") }
        .buttonStyle(.borderedProminent).disabled(busy || address.isEmpty || (kind == .homeAssistant && secret.isEmpty))
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; issue = nil
        connectionTask = Task { @MainActor in
            defer { busy = false }
            do { try await action(); try Task.checkCancellation(); secret = ""; dismiss() }
            catch is CancellationError {}
            catch { issue = .classify(error) }
        }
    }
}
