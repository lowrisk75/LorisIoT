import Foundation
import Testing
import IoTCore
@testable import IoTMeross

#if canImport(Darwin)
/// Scripted device: answers by namespace, records SETs, can flip failure modes.
actor FakeMerossDevice: MerossLANClient {
    var uuid = "ABC"
    var online = 1
    var togglex: [Int: Int] = [0: 0, 1: 0, 2: 1]
    var abilities: [String] = [MerossNamespace.systemAll, MerossNamespace.systemAbility, MerossNamespace.toggleX, MerossNamespace.electricity]
    var sets: [MerossMessage] = []
    var reads = 0
    var failNextSetTransport = false
    var rejectSets = false
    var wrongKey = false
    var applyWrites = true

    func setUUID(_ value: String) { uuid = value }
    func setFailNextSetTransport(_ value: Bool) { failNextSetTransport = value }
    func setRejectSets(_ value: Bool) { rejectSets = value }
    func setWrongKey(_ value: Bool) { wrongKey = value }
    func setApplyWrites(_ value: Bool) { applyWrites = value }
    func setOnline(_ value: Int) { online = value }

    func exchange(_ request: MerossMessage, host: String) async throws -> MerossMessage {
        func reply(_ method: MerossMethod, _ payload: MerossJSON) -> MerossMessage {
            MerossMessage(header: .init(from: "/appliance/\(uuid)/publish", messageId: request.header.messageId, method: method,
                                        namespace: request.header.namespace, payloadVersion: 1, sign: "", timestamp: 1, triggerSrc: nil), payload: payload)
        }
        if wrongKey { return reply(.error, .object(["error": .object(["code": .number(5001), "detail": .string("sign error")])])) }
        switch (request.header.method, request.header.namespace) {
        case (.get, MerossNamespace.systemAll):
            reads += 1
            let list = togglex.keys.sorted().map { MerossJSON.object(["channel": .number(Double($0)), "onoff": .number(Double(togglex[$0]!))]) }
            return reply(.getAck, .object(["all": .object(["system": .object(["hardware": .object(["uuid": .string(uuid)]), "firmware": .object(["version": .string("6.1.8"), "innerIp": .string(host)]), "online": .object(["status": .number(Double(online))])]),
                                                           "digest": .object(["togglex": .array(list)])])]))
        case (.get, MerossNamespace.systemAbility):
            return reply(.getAck, .object(["ability": .object(Dictionary(uniqueKeysWithValues: abilities.map { ($0, MerossJSON.object([:])) }))]))
        case (.get, MerossNamespace.electricity):
            let channel = request.payload["electricity"]?["channel"]?.intValue ?? 0
            return reply(.getAck, .object(["electricity": .object(["channel": .number(Double(channel)), "current": .number(100), "voltage": .number(2300), "power": .number(5000)])]))
        case (.set, MerossNamespace.toggleX):
            sets.append(request)
            if failNextSetTransport { failNextSetTransport = false; throw MerossLANTransport.Failure.http(500) }
            if rejectSets { return reply(.error, .object(["error": .object(["code": .number(5000), "detail": .string("busy")])])) }
            if applyWrites, let channel = request.payload["togglex"]?["channel"]?.intValue, let on = request.payload["togglex"]?["onoff"]?.intValue { togglex[channel] = on }
            return reply(.setAck, .object([:]))
        default:
            return reply(.error, .object(["error": .object(["code": .number(4000), "detail": .string("unsupported")])]))
        }
    }
}

struct MerossProviderTests {
    private let account = MerossAccount(userId: "42", key: "fixture-key", token: "tok", domain: "https://iotx-eu.meross.com", mqttDomain: "", email: "e@x")
    private let config = MerossDeviceConfig(uuid: "ABC", host: "127.0.0.1", name: "Strip", model: "mss425f", firmware: nil, channelCount: 3)

    @Test func discoverMatchesKnownDevice() async throws {
        let device = FakeMerossDevice()
        let known = [MerossCloudDevice(uuid: "ABC", devName: "Strip", deviceType: "mss425f", fmwareVersion: "6.1.8", onlineStatus: 1, channelCount: 3)]
        let found = try await MerossDeviceConfig.discover(host: " 127.0.0.1 ", key: "fixture-key", known: known, client: device)
        #expect(found.uuid == "ABC" && found.host == "127.0.0.1" && found.name == "Strip" && found.channelCount == 3 && found.firmware == "6.1.8")
        await device.setUUID("ZZZ")
        await #expect(throws: IoTError.invalidResponse) { _ = try await MerossDeviceConfig.discover(host: "127.0.0.1", key: "fixture-key", known: known, client: device) }
        await device.setWrongKey(true)
        await #expect(throws: IoTError.authenticationFailed(reason: "Meross key rejected")) { _ = try await MerossDeviceConfig.discover(host: "127.0.0.1", key: "fixture-key", known: known, client: device) }
    }
    @Test func connectVerifiesIdentityAndExpandsChannels() async throws {
        let device = FakeMerossDevice()
        let provider = MerossProvider(account: account, devices: [config], client: device)
        try await provider.connect()
        let devices = try await provider.devices()
        #expect(devices.map(\.id.rawValue) == ["meross:ABC#1", "meross:ABC#2"])
        #expect(devices.first?.kind == .outlet && devices.first?.manufacturer == "Meross" && devices.first?.firmwareVersion == "6.1.8")
        #expect(devices.first?.capabilities.map(\.id) == [.readState, .subscribe, .control])
        let reader = try #require(try await provider.capabilities(for: "meross:ABC#2").readState)
        let state = try await reader.state()
        #expect(state.primaryValue == .bool(true) && state.attributes["watt"]?.value == .decimal(5.0))
        await provider.disconnect()
        await #expect(throws: IoTError.notConnected) { try await reader.state() }
    }
    @Test func identityMismatchAndBadKeyFailConnect() async throws {
        let device = FakeMerossDevice()
        await device.setUUID("OTHER")
        let provider = MerossProvider(account: account, devices: [config], client: device)
        await #expect(throws: IoTError.invalidResponse) { try await provider.connect() }
        await device.setUUID("ABC"); await device.setWrongKey(true)
        await #expect(throws: IoTError.authenticationFailed(reason: "Meross key rejected")) { try await provider.connect() }
    }
    @Test func executeConfirmsByReread() async throws {
        let device = FakeMerossDevice()
        let provider = MerossProvider(account: account, devices: [config], client: device)
        try await provider.connect()
        let control = try #require(try await provider.capabilities(for: "meross:ABC#1").control)
        let applied = try await control.execute(SetPowerCommand(deviceID: "meross:ABC#1", isOn: true))
        #expect(applied.outcome == .applied && applied.state?.primaryValue == .bool(true))
        #expect(await device.sets.last?.payload["togglex"]?["channel"]?.intValue == 1)
        await device.setApplyWrites(false)
        let notApplied = try await control.execute(SetPowerCommand(deviceID: "meross:ABC#1", isOn: false))
        #expect(notApplied.outcome == .uncertain && notApplied.state?.primaryValue == .bool(true))
        await device.setRejectSets(true)
        let rejected = try await control.execute(SetPowerCommand(deviceID: "meross:ABC#1", isOn: false))
        #expect(rejected.outcome == .rejected && rejected.providerTransactionID == "meross-error:5000")
        await device.setRejectSets(false); await device.setFailNextSetTransport(true)
        let uncertain = try await control.execute(SetPowerCommand(deviceID: "meross:ABC#1", isOn: false))
        #expect(uncertain.outcome == .uncertain)
        await #expect(throws: IoTError.notConfigured) { try await control.execute(SetPowerCommand(deviceID: "meross:ABC#2", isOn: true)) }
        await #expect(throws: IoTError.notSupported("Meross setLevel")) { try await control.execute(SetLevelCommand(deviceID: "meross:ABC#1", level: try UnitInterval(0.5))) }
    }
    @Test func offlineStatusIsReported() async throws {
        let device = FakeMerossDevice()
        await device.setOnline(2)
        let provider = MerossProvider(account: account, devices: [config], client: device)
        try await provider.connect()
        let state = try await #require(try await provider.capabilities(for: "meross:ABC#1").readState).state()
        #expect(state.availability == .offline)
    }
    @Test func duplicateConfigurationFailsBeforeNetwork() async {
        let device = FakeMerossDevice()
        let provider = MerossProvider(account: account, devices: [config, config], client: device)
        await #expect(throws: IoTError.notConfigured) { try await provider.connect() }
        #expect(await device.reads == 0)
    }
}
#endif
