import Foundation

/// Strict wire boundary. UDP source validation and freshness belong to the transport/session.
/// Missing fields remain unknown; receiving a partial packet must never imply power off.
public enum GoveeLANMessage: Equatable, Sendable {
    public struct Discovery: Decodable, Equatable, Sendable {
        public let device: String
        public let sku: String
        public let ip: String
    }
    public struct Status: Decodable, Equatable, Sendable {
        public let onOff: Int?
        public let brightness: Int?
        public let colorTemInKelvin: Int?
        public let color: RGB?
    }
    public struct RGB: Codable, Equatable, Sendable {
        public let r: Int
        public let g: Int
        public let b: Int
    }
    public enum WireError: Error { case invalid, oversized, unsupported }
    case discovery(Discovery)
    case status(Status)

    private struct Envelope<T: Decodable>: Decodable {
        let msg: Message<T>
    }
    private struct Message<T: Decodable>: Decodable {
        let cmd: String
        let data: T
    }
    private struct Header: Decodable {
        struct Message: Decodable { let cmd: String }
        let msg: Message
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 8192 else { throw WireError.oversized }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        switch header.msg.cmd {
        case "scan":
            let value = try decoder.decode(Envelope<Discovery>.self, from: data).msg.data
            let bytes = value.device.split(separator: ":", omittingEmptySubsequences: false)
            guard bytes.count == 8, bytes.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }),
                  value.sku.count == 5, value.sku.first == "H",
                  value.sku.dropFirst().allSatisfy({ $0.isASCII && ($0.isNumber || $0.isUppercase) }),
                  validIPv4(value.ip) else { throw WireError.invalid }
            return .discovery(value)
        case "devStatus":
            let value = try decoder.decode(Envelope<Status>.self, from: data).msg.data
            guard value.onOff != nil || value.brightness != nil || value.color != nil
                    || value.colorTemInKelvin != nil,
                  value.onOff.map({ (0...1).contains($0) }) ?? true,
                  value.brightness.map({ (0...100).contains($0) }) ?? true,
                  value.colorTemInKelvin.map({ $0 == 0 || (2000...9000).contains($0) }) ?? true,
                  value.color.map({ [ $0.r, $0.g, $0.b ].allSatisfy { (0...255).contains($0) } }) ?? true
            else { throw WireError.invalid }
            return .status(value)
        default: throw WireError.unsupported
        }
    }

    private static func validIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy {
            guard let n = UInt8($0) else { return false }
            return String(n) == $0
        }
    }

    public static let discoveryQuery = Data(#"{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}"#.utf8)
    public static let statusQuery = Data(#"{"msg":{"cmd":"devStatus","data":{}}}"#.utf8)
}
