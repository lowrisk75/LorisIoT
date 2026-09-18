import SwiftUI
import IoTUI
import IoTCore
import IoTShelly
import IoTGovee
import IoTHomeAssistant
import IoTMQTT
import IoTMQTTCocoa

@main struct IoTDemoApp: App {
    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            Showcase().frame(minWidth: 460, minHeight: 600)
            #else
            Showcase()
            #endif
        }
    }
}

private struct Showcase: View {
    @State private var providers: [any DeviceProvider] = [DemoProvider()]
    @State private var adding = false
    @State private var language = "fr"
    var body: some View {
        NavigationStack {
            IoTIntegrationHub(providers: providers) { adding = true }
                .toolbar {
                    Picker("Language / Langue", selection: $language) {
                        Text("Français").tag("fr")
                        Text("English").tag("en")
                    }.frame(maxWidth: 150)
                }
                .safeAreaInset(edge: .bottom) {
                    Text("DEMO · Les appareils initiaux sont simulés · Initial devices are simulated")
                        .font(.caption).padding(12).frame(maxWidth: .infinity).background(.bar)
                }
        }
        .iotTheme(IoTTheme(tint: .teal))
        .sheet(isPresented: $adding) {
            NavigationStack {
                IoTConnectionView(connect: { request in
                    let id = ProviderID(rawValue: UUID().uuidString)
                    let provider: any DeviceProvider
                    switch request.kind {
                    case .govee:
                        let config = try await GoveeDeviceConfig.discover(host: request.address, name: request.name)
                        provider = GoveeProvider(devices: [config], id: id)
                    case .shelly:
                        let raw = request.address.contains("://") ? request.address : "http://" + request.address
                        guard let url = HAConfig.normalize(raw), url.scheme == "http", let host = url.host,
                              url.path.isEmpty || url.path == "/" else { throw IoTError.notConfigured }
                        let authority = host + (url.port.map { ":\($0)" } ?? "")
                        provider = ShellyProvider(devices: [.init(id: "plug", name: request.name.isEmpty ? "Shelly" : request.name,
                            host: authority, password: request.secret)], id: id, routing: .localOnly)
                    case .homeAssistant:
                        guard let url = HAConfig.normalize(request.address) else { throw IoTError.notConfigured }
                        provider = HomeAssistantProvider(config: HAConfig(baseURL: url), token: request.secret, id: id)
                    case .mqtt:
                        let raw = request.address.contains("://") ? request.address : "mqtt://" + request.address
                        guard let c = URLComponents(string: raw), let host = c.host,
                              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
                              ["mqtt", "mqtts"].contains(c.scheme), c.path.isEmpty || c.path == "/",
                              let port = UInt16(exactly: c.port ?? (c.scheme == "mqtts" ? 8883 : 1883)) else { throw IoTError.notConfigured }
                        let config = MQTTBrokerConfig(host: host, port: port, clientID: "lorisiot-demo-\(UUID())",
                            username: request.username.isEmpty ? nil : request.username,
                            password: request.secret.isEmpty ? nil : request.secret, useTLS: c.scheme == "mqtts")
                        let maps = try await Zigbee2MQTTDiscovery.discover(using: CocoaMQTTTransport(config: config))
                        provider = MQTTProvider(devices: maps, transport: CocoaMQTTTransport(config: config), id: id,
                                                maxStateAge: 300)
                    }
                    do {
                        try await provider.connect()
                        try Task.checkCancellation()
                        providers.append(provider)
                    } catch {
                        await provider.disconnect()
                        throw error
                    }
                }, goveeDiscovery: IoTNetworkDiscovery(networks: {
                    try GoveeDiscovery.localNetworks().map {
                        IoTDiscoveryChoice(id: $0.id, name: $0.interfaceName, address: $0.address)
                    }
                }, scan: { network in
                    guard let selected = try GoveeDiscovery.localNetworks().first(where: { $0.id == network }) else {
                        throw IoTError.notConfigured
                    }
                    let active = providers.compactMap { $0 as? GoveeProvider }
                    let found = try await GoveeProvider.withDiscoveryPaused(providers: active) {
                        try await GoveeDiscovery.scan(interfaceAddress: selected.address)
                    }
                    return found.map { IoTDiscoveryChoice(id: $0.id.rawValue, name: $0.name, address: $0.host) }
                }))
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 460)
            #endif
            .environment(\.locale, Locale(identifier: language))
        }
        .environment(\.locale, Locale(identifier: language))
    }
}

private actor DemoProvider: DeviceProvider {
    nonisolated let id: ProviderID = "demo"
    nonisolated let displayName = "Maison de démonstration"
    private let events = ConnectionEventHub(providerID: "demo")
    private var on = false
    private var sequence: UInt64 = 0
    func connect() async { await events.publish(.connected) }
    func disconnect() async { await events.publish(.disconnected) }
    func connectionEvents() async -> AsyncStream<ProviderConnectionEvent> { await events.events() }
    func devices() -> [Device] {
        [Device(id: "plug", providerID: id, nativeID: "plug", name: "Prise du salon", kind: .outlet,
                model: "Démonstration", capabilities: [.init(id: .control, operations: [.control])]),
         Device(id: "temperature", providerID: id, nativeID: "temperature", name: "Température du salon", kind: .sensor,
                model: "Démonstration · mesure récente", capabilities: []),
         Device(id: "stale", providerID: id, nativeID: "stale", name: "Température du garage", kind: .sensor,
                model: "Démonstration · mesure ancienne", capabilities: [])]
    }
    func capabilities(for deviceID: DeviceID) -> DeviceCapabilitySet {
        let capability = DemoCapability(provider: self, deviceID: deviceID)
        return DeviceCapabilitySet(descriptors: [], control: deviceID == "plug" ? capability : nil, readState: capability)
    }
    func state(_ deviceID: DeviceID) -> DeviceState {
        sequence &+= 1
        let date = deviceID == "stale" ? Date().addingTimeInterval(-86400) : Date()
        let value: StateValue = deviceID == "plug" ? .bool(on) : .decimal(deviceID == "stale" ? 18.4 : 23.6)
        return DeviceState(deviceID: deviceID, availability: deviceID == "stale" ? .degraded : .online,
            primaryValue: value, primaryUnit: deviceID == "plug" ? nil : .celsius,
            attributes: deviceID == "plug" ? [:] : ["temperature": .init(value: value, unit: .celsius)],
            observedAt: date, receivedAt: date, origin: .local, revision: .init(localSequence: sequence))
    }
    func set(_ value: Bool) async -> DeviceState {
        try? await Task.sleep(for: .milliseconds(250)); on = value; return state("plug")
    }
}
private actor DemoCapability: ControlCapability, ReadStateCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .readState, operations: [.readState, .control])
    let provider: DemoProvider
    let deviceID: DeviceID
    init(provider: DemoProvider, deviceID: DeviceID) { self.provider = provider; self.deviceID = deviceID }
    func state() async -> DeviceState { await provider.state(deviceID) }
    func execute<C: DeviceCommand>(_ command: C) async throws -> CommandReceipt {
        guard command.deviceID == deviceID, deviceID == "plug", case .setPower(let on) = command.payload else {
            throw IoTError.notConfigured
        }
        return CommandReceipt(commandID: command.id, deviceID: deviceID, outcome: .applied, state: await provider.set(on))
    }
}
