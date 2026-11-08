import Foundation
import Network

/// 简单的 HTTP 请求
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

/// HTTP 响应
struct HTTPResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()
}

/// 基于 Network.framework 的轻量 HTTP 服务器。
/// 采用 "Connection: close"（每个请求一个连接），实现简单且局域网内足够快。
final class HTTPServer {
    typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    private let port: UInt16
    private let handler: Handler
    private var listener: NWListener?
    private let maxBody = 256 * 1024 * 1024   // 256MB 上传上限

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            NSLog("[LANChat] HTTP 端口 \(port) 启动失败")
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                NSLog("[LANChat] HTTP listener 失败: \(err)")
            }
        }
        listener.start(queue: DispatchQueue(label: "lanchat.http.server"))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - 连接处理

    private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            if case .failed = state { conn.cancel() }
            if case .cancelled = state { }
        }
        conn.start(queue: DispatchQueue(label: "lanchat.http.conn"))
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let error { conn.cancel(); return }

            if let request = Self.tryParse(buf) {
                self.dispatch(conn, request)
                return
            }
            if isComplete {
                // 连接关闭但请求不完整，直接丢弃
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    /// 尝试解析完整请求（头部 + Content-Length 指定长度的 body）
    private static func tryParse(_ buf: Data) -> HTTPRequest? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buf.subdata(in: buf.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        let available = buf.distance(from: bodyStart, to: buf.endIndex)
        guard available >= contentLength else { return nil }   // 还没收完

        let body = contentLength > 0
            ? buf.subdata(in: bodyStart..<buf.index(bodyStart, offsetBy: contentLength))
            : Data()

        // 拆 path / query
        var path = target
        var query: [String: String] = [:]
        if let qIdx = target.firstIndex(of: "?") {
            path = String(target[..<qIdx])
            let qs = String(target[target.index(after: qIdx)...])
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let k = kv.first.map(String.init)?.removingPercentEncoding else { continue }
                let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? "") : ""
                query[k] = v
            }
        }
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    private func dispatch(_ conn: NWConnection, _ request: HTTPRequest) {
        guard request.body.count <= maxBody else {
            respond(conn, HTTPResponse(status: 413, body: Data("too large".utf8)))
            return
        }
        handler(request) { [weak self] response in
            self?.respond(conn, response)
        }
    }

    private func respond(_ conn: NWConnection, _ response: HTTPResponse) {
        var reason = "OK"
        switch response.status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        case 500: reason = "Internal Server Error"
        default: reason = "Status \(response.status)"
        }
        var out = "HTTP/1.1 \(response.status) \(reason)\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        headers["Access-Control-Allow-Origin"] = "*"
        for (k, v) in headers { out += "\(k): \(v)\r\n" }
        out += "\r\n"

        var payload = Data(out.utf8)
        payload.append(response.body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
