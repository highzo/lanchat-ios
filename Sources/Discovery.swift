import Foundation
import Network

/// 设备发现：UDP 广播，协议与电脑版/安卓版完全一致。
/// 广播内容：{"proto":"lanchat1","id":...,"name":...,"port":8090} → 255.255.255.255:52347
final class Discovery {
    static let proto = "lanchat1"
    static let port: UInt16 = 52_347
    static let interval: TimeInterval = 2.0

    var onPeer: ((_ id: String, _ name: String, _ ip: String, _ port: Int) -> Void)?
    var selfID: (() -> String)?

    private var sendConn: NWConnection?
    private var listener: NWListener?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "lanchat.discovery")

    func start(beacon: @escaping () -> Data) {
        // 接收别人的广播
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        if let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!) {
            listener = l
            l.newConnectionHandler = { [weak self] conn in
                self?.receiveLoop(conn)
            }
            l.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    NSLog("[LANChat] UDP listener 失败: \(err)")
                }
            }
            l.start(queue: queue)
        } else {
            NSLog("[LANChat] UDP 端口 \(Self.port) 占用")
        }

        // 广播自己
        sendConn = NWConnection(host: NWEndpoint.Host("255.255.255.255"),
                                port: NWEndpoint.Port(rawValue: Self.port)!,
                                using: .udp)
        sendConn?.stateUpdateHandler = { (state: NWConnection.State) in
            if case .ready = state {
                NSLog("[LANChat] UDP 广播通道就绪")
            }
        }
        sendConn?.start(queue: queue)

        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now(), repeating: Self.interval)
        timer?.setEventHandler { [weak self] in
            guard let self else { return }
            let data = beacon()
            self.sendBroadcast(data)
        }
        timer?.resume()
    }

    func stop() {
        timer?.cancel()
        sendConn?.cancel()
        listener?.cancel()
    }

    private func sendBroadcast(_ data: Data) {
        // 目标：全网广播 + 本网段定向广播（部分路由器会拦 255.255.255.255）
        var targets = ["255.255.255.255"]
        if let ip = localIPAddress(), let lastDot = ip.lastIndex(of: ".") {
            targets.append(String(ip[..<lastDot]) + ".255")
        }
        for host in Set(targets) {
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Self.port)!, using: .udp)
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    conn.send(content: data, completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                }
                if case .failed = state { conn.cancel() }
            }
            conn.start(queue: queue)
        }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, error == nil {
                self.handleDatagram(data, from: conn)
            }
            if error == nil {
                self.receiveLoop(conn)
            } else {
                conn.cancel()
            }
        }
    }

    private func handleDatagram(_ data: Data, from conn: NWConnection) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["proto"] as? String == Self.proto else { return }
        let id = obj["id"] as? String ?? ""
        if id.isEmpty || id == selfID?() { return }
        let name = obj["name"] as? String ?? id
        let port = (obj["port"] as? Int) ?? 8090

        var ip = ""
        if case let .hostPort(host, _) = conn.endpoint {
            switch host {
            case .ipv4, .ipv6:
                ip = "\(host)"          // CustomStringConvertible，输出点分地址
            case .name(let n, _):
                ip = n
            @unknown default:
                break
            }
        }
        guard !ip.isEmpty else { return }
        onPeer?(id, name, ip, port)
    }
}

// MARK: - 本机局域网 IPv4

func localIPAddress() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }

    var result: String?
    var ptr = ifaddr
    while let p = ptr {
        let ifa = p.pointee
        if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
            var sin = sockaddr_in()
            memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
            let name = String(cString: ifa.ifa_name)
            let sinLen = sin.sin_len
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = withUnsafePointer(to: &sin) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                    getnameinfo(saptr, socklen_t(sinLen), &host,
                                socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                }
            }
            if ok == 0 {
                let ip = String(cString: host)
                if name.hasPrefix("en") { return ip }
                if result == nil { result = ip }
            }
        }
        ptr = p.pointee.ifa_next
    }
    return result
}
