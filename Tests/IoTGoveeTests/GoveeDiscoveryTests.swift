import Foundation
import Testing
import IoTCore
@testable import IoTGovee

#if canImport(Darwin)
struct GoveeDiscoveryTests {
    func packet(id: String = "AA:BB:CC:DD:EE:FF:00:11", host: String = "127.0.0.1", model: String = "H6022") -> Data {
        Data(("{\"msg\":{\"cmd\":\"scan\",\"data\":{\"device\":\""+id+"\",\"sku\":\""+model+"\",\"ip\":\""+host+"\"}}}").utf8)
    }
    @Test func repeatedRepliesDeduplicateAndWrongSourceIsIgnored() throws {
        var inventory = GoveeDiscoveryInventory()
        try inventory.receive(packet(), source: "127.0.0.2")
        #expect(inventory.devices.isEmpty)
        for _ in 0..<3 { try inventory.receive(packet(), source: "127.0.0.1") }
        #expect(inventory.devices.count == 1)
    }
    @Test func conflictingIdentityStaysQuarantined() throws {
        var inventory = GoveeDiscoveryInventory()
        try inventory.receive(packet(), source: "127.0.0.1")
        try inventory.receive(packet(model: "H61E6"), source: "127.0.0.1")
        try inventory.receive(packet(), source: "127.0.0.1")
        #expect(inventory.devices.isEmpty)
        #expect(inventory.hasConflicts)
    }
    @Test func sameHostCannotAdvertiseTwoDevices() throws {
        var inventory = GoveeDiscoveryInventory()
        try inventory.receive(packet(), source: "127.0.0.1")
        try inventory.receive(packet(id: "AA:BB:CC:DD:EE:FF:00:22"), source: "127.0.0.1")
        #expect(inventory.devices.isEmpty)
    }
    @Test func datagramBudgetIncludesMalformedNoise() throws {
        var inventory = GoveeDiscoveryInventory()
        for _ in 0..<512 { try inventory.receive(Data([0xff]), source: "127.0.0.1") }
        #expect(throws: (any Error).self) { try inventory.receive(packet(), source: "127.0.0.1") }
    }
    @Test func deviceInventoryCannotGrowPastItsLimit() throws {
        var inventory = GoveeDiscoveryInventory()
        for number in 0..<64 {
            let host = "127.0.0.\(number + 1)"
            let id = String(format: "AA:BB:CC:DD:EE:FF:00:%02X", number)
            try inventory.receive(packet(id: id, host: host), source: host)
        }
        #expect(inventory.devices.count == 64)
        #expect(throws: (any Error).self) {
            try inventory.receive(packet(id: "AA:BB:CC:DD:EE:FF:00:FF", host: "127.0.0.200"), source: "127.0.0.200")
        }
        #expect(inventory.devices.count == 64)
    }
    @Test func cancellationBeforeScanSendsNothing() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GoveeDiscovery.scan(interfaceAddress: "127.0.0.1")
        }
        await #expect(throws: (any Error).self) { try await task.value }
    }
}
#endif
