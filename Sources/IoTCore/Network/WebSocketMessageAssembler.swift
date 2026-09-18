import Foundation

/// A complete message can span frames, with control frames interleaved. Both bytes and fragments are bounded.
struct WebSocketMessageAssembler: Sendable {
    private var opcode: WebSocketFrame.Opcode?
    private var buffer = Data()
    private var fragments = 0
    let maxPayloadBytes: Int
    init(maxPayloadBytes: Int = 4_194_304) { self.maxPayloadBytes = maxPayloadBytes }

    mutating func consume(_ frame: WebSocketFrame) throws -> Data? {
        guard maxPayloadBytes > 0, frame.payload.count <= maxPayloadBytes else { throw IoTError.invalidResponse }
        switch frame.opcode {
        case .ping, .pong, .close: return nil
        case .text, .binary:
            guard opcode == nil else { throw IoTError.invalidResponse }
            if frame.isFinal { return try validate(frame.payload, opcode: frame.opcode) }
            opcode = frame.opcode; buffer = frame.payload; fragments = 1
        case .continuation:
            guard let opcode, fragments < 1024, frame.payload.count <= maxPayloadBytes - buffer.count else {
                throw IoTError.invalidResponse
            }
            fragments += 1; buffer.append(frame.payload)
            if frame.isFinal {
                let result = try validate(buffer, opcode: opcode)
                self.opcode = nil; buffer = Data(); fragments = 0
                return result
            }
        }
        return nil
    }
    private func validate(_ data: Data, opcode: WebSocketFrame.Opcode) throws -> Data {
        if opcode == .text, String(data: data, encoding: .utf8) == nil { throw IoTError.invalidResponse }
        return data
    }
}
