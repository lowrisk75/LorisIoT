import Foundation
import CryptoKit
import IoTCore

#if canImport(Darwin)
/// Undocumented Meross HTTP API as implemented by the open reference client. Isolated here.
enum MerossCloudRequest {
    static let secret = "23x17ahWarFH6w29"

    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func sign(secret: String, timestampMs: Int, nonce: String, encodedParams: String) -> String {
        md5Hex(secret + String(timestampMs) + nonce + encodedParams)
    }
    static func nonce() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }
    static func build(baseURL: URL, path: String, params: [String: MerossJSON], token: String?,
                      nonce: String = nonce(), timestampMs: Int = Int(Date().timeIntervalSince1970 * 1000)) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw IoTError.notConfigured }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encodedParams = try encoder.encode(MerossJSON.object(params)).base64EncodedString()
        let body: MerossJSON = .object(["params": .string(encodedParams), "sign": .string(sign(secret: secret, timestampMs: timestampMs, nonce: nonce, encodedParams: encodedParams)),
                                        "timestamp": .number(Double(timestampMs)), "nonce": .string(nonce)])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + (token ?? ""), forHTTPHeaderField: "Authorization")
        request.setValue("meross", forHTTPHeaderField: "vender")
        request.setValue("3.22.4", forHTTPHeaderField: "AppVersion")
        request.setValue("iOS", forHTTPHeaderField: "AppType")
        request.setValue("EN", forHTTPHeaderField: "AppLanguage")
        request.setValue("LorisIoT", forHTTPHeaderField: "User-Agent")
        return request
    }
}

struct MerossCloudEnvelope: Decodable, Sendable {
    static let ok = 0
    static let redirectRegion = 1030
    let apiStatus: Int
    let info: String?
    let data: MerossJSON?
}

struct MerossSignInResponse: Hashable, Sendable {
    let token: String, key: String, userid: String, email: String, domain: String, mqttDomain: String
    init?(data: MerossJSON?) {
        guard let token = data?["token"]?.stringValue, let key = data?["key"]?.stringValue,
              let userid = data?["userid"]?.stringValue ?? data?["userid"]?.intValue.map(String.init),
              !token.isEmpty, !key.isEmpty, !userid.isEmpty else { return nil }
        self.token = token; self.key = key; self.userid = userid
        email = data?["email"]?.stringValue ?? ""
        domain = data?["domain"]?.stringValue ?? MerossRegion.eu.rawValue
        mqttDomain = data?["mqttDomain"]?.stringValue ?? ""
    }
}

extension MerossCloudDevice {
    static func list(from data: MerossJSON?) -> [MerossCloudDevice] {
        (data?.arrayValue ?? []).compactMap { item in
            guard let uuid = item["uuid"]?.stringValue, !uuid.isEmpty, uuid.utf8.count <= 64 else { return nil }
            return MerossCloudDevice(uuid: uuid, devName: item["devName"]?.stringValue ?? "Meross",
                                     deviceType: item["deviceType"]?.stringValue ?? "", fmwareVersion: item["fmwareVersion"]?.stringValue ?? "",
                                     onlineStatus: item["onlineStatus"]?.intValue ?? 0,
                                     channelCount: max(1, item["channels"]?.arrayValue?.count ?? 1))
        }
    }
}
#endif
