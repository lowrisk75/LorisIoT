import Foundation
import IoTCore
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

// Shelly Gen2/3 JSON-RPC over BLE GATT (research #20) — the physical fallback channel that
// survives "Wi-Fi down / password changed / mDNS dead" and powers onboarding before Wi-Fi.
// Protocol (official Shelly KB + ALLTERCO/shelly-ble-rpc): one RPC service with three
// characteristics — write the 4-byte big-endian frame length to TX-Control, write the JSON-RPC
// bytes to Data (chunked to the ATT MTU), then read RX-Control for the response length and read
// Data until reassembled. Same `{"id","method","params"}` envelope as HTTP `/rpc`.
//
// Device-gated like IoTHomeKit: the GATT plumbing needs a physical Shelly with "Bluetooth RPC"
// enabled (it is NOT always on — HA #157585) + `NSBluetoothAlwaysUsageDescription`. The framing
// below is pure and fully unit-tested; the CoreBluetooth actor is the thin device-facing shell.
// v1 limitation: no BLE digest-auth (JSON `auth` object) — a password-protected device returns
// 401 which surfaces as `IoTError.authenticationFailed`.

// MARK: - GATT identity (ASCII-derived UUIDs: "_mOS_RPC_SVC_ID_" …)

public enum ShellyBLE {
    public static let serviceUUID = "5F6D4F53-5F52-5043-5F53-56435F49445F"   // _mOS_RPC_SVC_ID_
    public static let dataUUID    = "5F6D4F53-5F52-5043-5F64-6174615F5F5F"   // _mOS_RPC_data___
    public static let txCtlUUID   = "5F6D4F53-5F52-5043-5F74-785F63746C5F"   // _mOS_RPC_tx_ctl_
    public static let rxCtlUUID   = "5F6D4F53-5F52-5043-5F72-785F63746C5F"   // _mOS_RPC_rx_ctl_
}

// MARK: - Framing (pure, fixture-testable)

public enum ShellyBLEFraming {
    /// Sanity cap — a Shelly RPC response is a few KB; anything bigger is corruption.
    public static let maxFrameBytes = 1_048_576

    /// The 4-byte big-endian length written to TX-Control before the payload.
    public static func lengthPrefix(for payload: Data) -> Data {
        let n = UInt32(payload.count)
        return Data([UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
    }

    /// Parse the RX-Control read → expected inbound frame length.
    public static func expectedLength(from control: Data) throws -> Int {
        guard control.count >= 4 else { throw IoTError.invalidResponse }
        let b = [UInt8](control.prefix(4))
        let n = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        guard n <= UInt32(maxFrameBytes) else {
            throw IoTError.transport("BLE-RPC frame exceeds \(maxFrameBytes)B cap")
        }
        return Int(n)
    }

    /// Split an outbound payload into ≤`mtu`-byte chunks for sequential Data-characteristic writes.
    public static func chunks(_ payload: Data, mtu: Int) -> [Data] {
        guard mtu > 0 else { return [payload] }
        var result: [Data] = []
        var index = payload.startIndex
        while index < payload.endIndex {
            let end = payload.index(index, offsetBy: mtu, limitedBy: payload.endIndex) ?? payload.endIndex
            result.append(Data(payload[index..<end]))
            index = end
        }
        return result
    }

    /// Stateful inbound reassembler: created with the RX-Control length, fed Data-notify chunks,
    /// returns the complete frame once every byte arrived.
    public struct Reassembler: Sendable {
        public let expected: Int
        private var buffer = Data()

        public init(expected: Int) { self.expected = expected }

        public var isComplete: Bool { buffer.count >= expected }

        /// Append a chunk; returns the finished frame when complete (over-read is truncated).
        @discardableResult
        public mutating func append(_ chunk: Data) -> Data? {
            buffer.append(chunk)
            guard isComplete else { return nil }
            return Data(buffer.prefix(expected))
        }
    }

    /// Build the JSON-RPC request frame (same envelope as HTTP `/rpc`). `auth` carries the
    /// frame-embedded digest object for password-protected devices (second attempt after a 401).
    public static func requestFrame(id: Int, method: String, params: [String: any Sendable],
                                    auth: [String: any Sendable]? = nil) throws -> Data {
        var body: [String: Any] = ["id": id, "method": method, "params": params]
        if let auth { body["auth"] = auth }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Frame-embedded digest auth (Gen2 RPC over BLE or HTTP): a 401 error's `message` is a JSON
    /// string like `{"auth_type":"digest","nonce":1638000000,"nc":1,"realm":"shellyplus1-…",
    /// "algorithm":"SHA-256"}`. Same SHA-256 scheme as the HTTP header variant (`ShellyDigest`,
    /// username fixed `admin`, HA2 over `dummy_method:dummy_uri`) but delivered as an `auth`
    /// object in the retried frame. Returns nil on an unparseable challenge.
    public static func rpcAuth(challengeMessage: String, password: String,
                               cnonce: Int = Int.random(in: 1...Int(Int32.max))) -> [String: any Sendable]? {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(challengeMessage.utf8))) as? [String: Any],
              let realm = json["realm"] as? String,
              let nonce = json["nonce"] as? Int else { return nil }
        let nc = (json["nc"] as? Int) ?? 1
        let ha1 = ShellyDigest.sha256Hex("admin:\(realm):\(password)")
        let ha2 = ShellyDigest.sha256Hex("dummy_method:dummy_uri")
        let response = ShellyDigest.sha256Hex("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
        return ["realm": realm, "username": "admin", "nonce": nonce, "cnonce": cnonce,
                "response": response, "algorithm": "SHA-256"]
    }

    /// Parse a JSON-RPC response frame → result dict; RPC errors become typed `IoTError`s.
    public static func parseResponse(_ frame: Data) throws -> [String: any Sendable] {
        guard let json = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else {
            throw IoTError.invalidResponse
        }
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int
            let message = (error["message"] as? String) ?? "RPC error"
            if code == 401 { throw IoTError.authenticationFailed(reason: message) }
            throw IoTError.transport(message)
        }
        return (json["result"] as? [String: any Sendable]) ?? [:]
    }
}

#if canImport(CoreBluetooth)

// MARK: - CoreBluetooth transport (device-gated)

/// `ShellyRPC` over BLE GATT. `host` is interpreted as the peripheral's advertised name (Shelly
/// advertises e.g. "ShellyPlus1PM-A8032AB12345"); scanning stops at the first match. One RPC call
/// = scan → connect → discover → framed request/response → disconnect (the emergency/onboarding
/// channel is not a long-lived session).
public actor ShellyBLERPC: ShellyRPC {
    private let scanTimeout: Double
    private let rpcTimeout: Double

    public init(scanTimeout: Double = 10, rpcTimeout: Double = 10) {
        self.scanTimeout = scanTimeout
        self.rpcTimeout = rpcTimeout
    }

    public func call(host: String, password: String?, method: String,
                     params: [String: any Sendable]) async throws -> [String: any Sendable] {
        let request = try ShellyBLEFraming.requestFrame(id: 1, method: method, params: params)
        let session = ShellyBLESession(deviceName: host, scanTimeout: scanTimeout, rpcTimeout: rpcTimeout)
        let response = try await session.exchange(request)
        do {
            return try ShellyBLEFraming.parseResponse(response)
        } catch let IoTError.authenticationFailed(reason: challenge) {
            // Password-protected device: the 401's message IS the digest challenge — retry once
            // with the frame-embedded auth object (mirrors the HTTP 401 → digest-header retry).
            guard let password,
                  let auth = ShellyBLEFraming.rpcAuth(challengeMessage: challenge, password: password) else {
                throw IoTError.authenticationFailed(reason: challenge)
            }
            let authed = try ShellyBLEFraming.requestFrame(id: 2, method: method, params: params, auth: auth)
            let retry = ShellyBLESession(deviceName: host, scanTimeout: scanTimeout, rpcTimeout: rpcTimeout)
            return try await ShellyBLEFraming.parseResponse(retry.exchange(authed))
        }
    }
}

/// One-shot GATT session: CBCentralManager scan by name → connect → discover RPC service/chars →
/// TX-Control length + chunked Data writes → RX-Control length + notify reassembly.
/// `@unchecked Sendable`: every mutable field is confined to `queue` (CoreBluetooth's delegate queue).
private final class ShellyBLESession: NSObject, @unchecked Sendable {
    private let deviceName: String
    private let scanTimeout: Double
    private let rpcTimeout: Double
    private let queue = DispatchQueue(label: "com.lorislabs.iot.shelly-ble")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var dataChar: CBCharacteristic?
    private var txCtl: CBCharacteristic?
    private var rxCtl: CBCharacteristic?
    private var outbound = Data()
    private var reassembler: ShellyBLEFraming.Reassembler?
    private var continuation: CheckedContinuation<Data, any Error>?
    private var finished = false

    init(deviceName: String, scanTimeout: Double, rpcTimeout: Double) {
        self.deviceName = deviceName
        self.scanTimeout = scanTimeout
        self.rpcTimeout = rpcTimeout
    }

    func exchange(_ request: Data) async throws -> Data {
        outbound = request
        defer { tearDown() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
            queue.async {
                self.continuation = cont
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            }
            queue.asyncAfter(deadline: .now() + scanTimeout + rpcTimeout) {
                self.finish(.failure(IoTError.timeout))
            }
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        guard !finished, let cont = continuation else { return }
        finished = true
        continuation = nil
        cont.resume(with: result)
    }

    private func tearDown() {
        queue.async {
            if let peripheral = self.peripheral { self.central?.cancelPeripheralConnection(peripheral) }
            self.central?.stopScan()
            self.central = nil
            self.peripheral = nil
        }
    }
}

extension ShellyBLESession: CBCentralManagerDelegate, CBPeripheralDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: [CBUUID(string: ShellyBLE.serviceUUID)], options: nil)
        case .unauthorized:
            finish(.failure(IoTError.authenticationFailed(reason: "Bluetooth permission denied")))
        case .unsupported, .poweredOff:
            finish(.failure(IoTError.transport("Bluetooth unavailable (\(central.state.rawValue))")))
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard advertised.localizedCaseInsensitiveContains(deviceName) || deviceName.isEmpty else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: ShellyBLE.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        finish(.failure(IoTError.transport(error?.localizedDescription ?? "BLE connect failed")))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: ShellyBLE.serviceUUID) }) else {
            finish(.failure(IoTError.notSupported("Shelly BLE-RPC service absent — enable Bluetooth RPC on the device")))
            return
        }
        peripheral.discoverCharacteristics([CBUUID(string: ShellyBLE.dataUUID),
                                            CBUUID(string: ShellyBLE.txCtlUUID),
                                            CBUUID(string: ShellyBLE.rxCtlUUID)], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case CBUUID(string: ShellyBLE.dataUUID): dataChar = characteristic
            case CBUUID(string: ShellyBLE.txCtlUUID): txCtl = characteristic
            case CBUUID(string: ShellyBLE.rxCtlUUID): rxCtl = characteristic
            default: break
            }
        }
        guard let dataChar, let txCtl else {
            finish(.failure(IoTError.notSupported("Shelly BLE-RPC characteristics absent")))
            return
        }
        // Write frame length, then the payload chunked to the ATT MTU.
        peripheral.writeValue(ShellyBLEFraming.lengthPrefix(for: outbound), for: txCtl, type: .withResponse)
        let mtu = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
        for chunk in ShellyBLEFraming.chunks(outbound, mtu: mtu) {
            peripheral.writeValue(chunk, for: dataChar, type: .withResponse)
        }
        // Response: read the RX-Control length, then drain Data reads until reassembled.
        if let rxCtl { peripheral.readValue(for: rxCtl) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error { finish(.failure(IoTError.transport(error.localizedDescription))); return }
        guard let value = characteristic.value else { return }
        switch characteristic.uuid {
        case CBUUID(string: ShellyBLE.rxCtlUUID):
            do {
                reassembler = ShellyBLEFraming.Reassembler(expected: try ShellyBLEFraming.expectedLength(from: value))
                if let dataChar { peripheral.readValue(for: dataChar) }
            } catch {
                finish(.failure(error))
            }
        case CBUUID(string: ShellyBLE.dataUUID):
            if let frame = reassembler?.append(value) {
                finish(.success(frame))
            } else if let dataChar {
                peripheral.readValue(for: dataChar)   // keep draining until the full frame arrived
            }
        default:
            break
        }
    }
}

#endif
