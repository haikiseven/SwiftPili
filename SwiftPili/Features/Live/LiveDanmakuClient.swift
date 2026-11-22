import Foundation
import Compression

struct LiveDanmakuEvent: Sendable {
    let uid: Int
    let uname: String
    let text: String
    let medalName: String?
    let medalLevel: Int?
    let medalColor: Int?
}

final class LiveDanmakuClient: @unchecked Sendable {
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private let onMessage: @Sendable (LiveDanmakuEvent) -> Void
    private let onPopularity: @Sendable (Int) -> Void

    init(
        onMessage: @escaping @Sendable (LiveDanmakuEvent) -> Void,
        onPopularity: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.onMessage = onMessage
        self.onPopularity = onPopularity
    }

    deinit {
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    func connect(roomID: Int, token: String, host: String) {
        let urlStr = "wss://\(host)/sub"
        guard let url = URL(string: urlStr) else {
            PlayerLog.log("[DanmakuWS] invalid endpoint")
            return
        }

        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        let newSession = URLSession(configuration: .default)
        session = newSession
        webSocket = newSession.webSocketTask(with: url)
        webSocket?.resume()
        PlayerLog.log("[DanmakuWS] connecting")

        sendAuth(roomID: roomID, token: token)
        startReceiving()
    }

    func disconnect() {
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
        PlayerLog.log("[DanmakuWS] disconnected")
    }

    // MARK: - Protocol

    private func sendAuth(roomID: Int, token: String) {
        let uid = Int(AuthManager.shared.dedeUserID ?? "0") ?? 0
        let buvid = BuvidManager.getBuvid() ?? ""
        let auth: [String: Any] = [
            "uid": uid,
            "roomid": roomID,
            "protover": 3,
            "buvid": buvid,
            "platform": "web",
            "type": 2,
            "key": token,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: auth) else {
            PlayerLog.log("[DanmakuWS] failed to serialize auth")
            return
        }

        let packet = buildPacket(data: jsonData, operation: 7)
        webSocket?.send(.data(packet)) { error in
            if let error {
                PlayerLog.log("[DanmakuWS] auth send error: \(error)")
            } else {
                PlayerLog.log("[DanmakuWS] auth sent for room \(roomID)")
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let socket = self.webSocket else { break }
                let packet = self.buildPacket(data: Data(), operation: 2)
                try? await socket.send(.data(packet))
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let msg = try await self.webSocket?.receive() else { break }
                    switch msg {
                    case .data(let data):
                        self.parsePacket(data)
                    case .string(let str):
                        PlayerLog.log("[DanmakuWS] got string len=\(str.utf8.count)")
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        PlayerLog.log("[DanmakuWS] receive error: \(error)")
                    }
                    break
                }
            }
        }
    }

    private func buildPacket(data: Data, operation: Int) -> Data {
        let headerLen = 16
        let packetLen = headerLen + data.count
        var packet = Data(capacity: packetLen)

        var pLen = UInt32(packetLen).bigEndian
        var hLen = UInt16(headerLen).bigEndian
        var ver = UInt16(1).bigEndian
        var op = UInt32(operation).bigEndian
        var seq = UInt32(1).bigEndian

        packet.append(Data(bytes: &pLen, count: 4))
        packet.append(Data(bytes: &hLen, count: 2))
        packet.append(Data(bytes: &ver, count: 2))
        packet.append(Data(bytes: &op, count: 4))
        packet.append(Data(bytes: &seq, count: 4))
        packet.append(data)

        return packet
    }

    private func parsePacket(_ data: Data) {
        guard data.count >= 16 else { return }

        let packetLen = data.readUInt32BE(at: 0)
        let headerLen = data.readUInt16BE(at: 4)
        let protoVer = data.readUInt16BE(at: 6)
        let operation = data.readUInt32BE(at: 8)

        guard packetLen >= headerLen, packetLen > 0 else { return }

        let bodyData = data.subdata(in: Int(headerLen)..<min(Int(packetLen), data.count))

        switch operation {
        case 8:
            PlayerLog.log("[DanmakuWS] auth success")
            startHeartbeat()

        case 3:
            if bodyData.count >= 4 {
                let popularity = Int(bodyData.readUInt32BE(at: 0))
                onPopularity(popularity)
            }

        case 5:
            switch protoVer {
            case 0, 1:
                parseMessages(bodyData)
            case 2:
                if let decompressed = bodyData.zlibDecompress() {
                    parseMultiPackets(decompressed)
                }
            case 3:
                if let decompressed = bodyData.brotliDecompress() {
                    parseMultiPackets(decompressed)
                } else {
                    PlayerLog.log("[DanmakuWS] brotli decompress failed, len=\(bodyData.count)")
                }
            default:
                PlayerLog.log("[DanmakuWS] unknown protoVer=\(protoVer)")
            }

        default:
            break
        }

        let consumed = Int(packetLen)
        if consumed < data.count {
            parsePacket(data.subdata(in: consumed..<data.count))
        }
    }

    private func parseMultiPackets(_ data: Data) {
        var offset = 0
        while offset + 16 <= data.count {
            let packetLen = Int(data.readUInt32BE(at: offset))
            let headerLen = Int(data.readUInt16BE(at: offset + 4))
            guard packetLen > headerLen, offset + packetLen <= data.count else { break }

            let body = data.subdata(in: (offset + headerLen)..<(offset + packetLen))
            parseMessages(body)
            offset += packetLen
        }
    }

    private func parseMessages(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = json["cmd"] as? String else { return }

        switch cmd {
        case "DANMU_MSG":
            if let info = json["info"] as? [Any],
               info.count > 2,
               let text = info[1] as? String,
               let userInfo = info[2] as? [Any],
               userInfo.count > 1,
               let uname = userInfo[1] as? String {
                let uid = (userInfo[0] as? NSNumber)?.intValue ?? 0
                var medalName: String?
                var medalLevel: Int?
                var medalColor: Int?
                if info.count > 3, let medal = info[3] as? [Any], medal.count > 4 {
                    medalLevel = (medal[0] as? NSNumber)?.intValue
                    medalName = medal[1] as? String
                    medalColor = (medal[4] as? NSNumber)?.intValue
                }
                onMessage(LiveDanmakuEvent(
                    uid: uid,
                    uname: uname,
                    text: text,
                    medalName: medalName,
                    medalLevel: medalLevel,
                    medalColor: medalColor
                ))
            }

        default:
            break
        }
    }
}

// MARK: - Data Helpers

private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let i = startIndex + offset
        return UInt32(self[i]) << 24
            | UInt32(self[i + 1]) << 16
            | UInt32(self[i + 2]) << 8
            | UInt32(self[i + 3])
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let i = startIndex + offset
        return UInt16(self[i]) << 8
            | UInt16(self[i + 1])
    }

    func zlibDecompress() -> Data? {
        guard count > 2 else { return nil }
        let bufferSize = count * 10
        var output = Data(count: bufferSize)
        let result = output.withUnsafeMutableBytes { outPtr in
            self.withUnsafeBytes { inPtr in
                let srcPtr = inPtr.bindMemory(to: UInt8.self)
                let dstPtr = outPtr.bindMemory(to: UInt8.self)
                return compression_decode_buffer(
                    dstPtr.baseAddress!, bufferSize,
                    srcPtr.baseAddress!, count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard result > 0 else { return nil }
        return output.prefix(result)
    }

    func brotliDecompress() -> Data? {
        guard count > 0 else { return nil }
        let bufferSize = count * 20
        var output = Data(count: bufferSize)
        let result = output.withUnsafeMutableBytes { outPtr in
            self.withUnsafeBytes { inPtr in
                let srcPtr = inPtr.bindMemory(to: UInt8.self)
                let dstPtr = outPtr.bindMemory(to: UInt8.self)
                return compression_decode_buffer(
                    dstPtr.baseAddress!, bufferSize,
                    srcPtr.baseAddress!, count,
                    nil, COMPRESSION_BROTLI
                )
            }
        }
        guard result > 0 else { return nil }
        return output.prefix(result)
    }
}
