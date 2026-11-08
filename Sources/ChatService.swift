import Foundation
import UIKit

/// 核心服务：设备发现 + HTTP 接口 + 消息收发 + 文件互传
/// 接口行为与电脑版 lanchat.py 完全一致
final class ChatService {
    static let shared = ChatService()

    let httpPort: UInt16 = 8090
    let store = Store.shared

    private(set) var deviceID = ""
    private(set) var deviceName = ""

    private var httpServer: HTTPServer?
    private var discovery: Discovery?
    private var cleanTimer: DispatchSourceTimer?
    private var serverStarted = false

    private struct Peer {
        var name: String
        var ip: String
        var port: Int
        var last: TimeInterval
    }
    private var peers: [String: Peer] = [:]
    private let peersLock = NSLock()

    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "webp"]

    // MARK: - 启动

    func start() {
        guard !serverStarted else { return }
        serverStarted = true

        deviceID = store.deviceID()
        deviceName = UIDevice.current.name
        // 首次运行把自己登记进 devices 表
        store.run("INSERT OR REPLACE INTO devices(id,name,remark,last_seen) "
                  + "SELECT ?,?,COALESCE((SELECT remark FROM devices WHERE id=?),''),?",
                  [.text(deviceID), .text(deviceName), .text(deviceID),
                   .double(Date().timeIntervalSince1970)])
        store.ensureConv(id: "all", type: "group", name: "局域网总群",
                         members: [], created: Date().timeIntervalSince1970)

        startDiscovery()
        startHTTP()
        startCleaner()
        NSLog("[LANChat] 已启动 id=\(deviceID) name=\(deviceName)")
    }

    // MARK: - 发现

    private func startDiscovery() {
        let d = Discovery()
        d.selfID = { [weak self] in self?.deviceID ?? "" }
        d.onPeer = { [weak self] id, name, ip, port in
            self?.peerSeen(id: id, name: name, ip: ip, port: port)
        }
        d.start { [weak self] in self?.beaconData() }
        discovery = d
    }

    private func beaconData() -> Data {
        let obj: [String: Any] = [
            "proto": Discovery.proto,
            "id": deviceID,
            "name": myRemark(),
            "port": Int(httpPort),
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    private func peerSeen(id: String, name: String, ip: String, port: Int) {
        peersLock.lock()
        peers[id] = Peer(name: name, ip: ip, port: port, last: Date().timeIntervalSince1970)
        peersLock.unlock()
        store.upsertDevice(id: id, name: name, ts: Date().timeIntervalSince1970)
    }

    private func startCleaner() {
        cleanTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        cleanTimer?.schedule(deadline: .now() + 3, repeating: 3)
        cleanTimer?.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            self.peersLock.lock()
            self.peers = self.peers.filter { now - $0.value.last < 8 }
            self.peersLock.unlock()
        }
        cleanTimer?.resume()
    }

    private func snapshotPeers() -> [(id: String, name: String, ip: String, port: Int)] {
        peersLock.lock()
        defer { peersLock.unlock() }
        return peers.map { ($0.key, $0.value.name, $0.value.ip, $0.value.port) }
    }

    private func onlineIDs() -> Set<String> {
        Set(snapshotPeers().map { $0.id })
    }

    // MARK: - 名称

    func myRemark() -> String {
        store.myRemark(deviceID: deviceID, deviceName: deviceName)
    }

    func localIP() -> String {
        localIPAddress() ?? ""
    }

    // MARK: - HTTP 路由

    private func startHTTP() {
        let server = HTTPServer(port: httpPort) { [weak self] request, respond in
            self?.route(request, respond)
        }
        server.start()
        httpServer = server
    }

    private func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        var r = HTTPResponse(status: status)
        r.headers["Content-Type"] = "application/json; charset=utf-8"
        if JSONSerialization.isValidJSONObject(obj),
           let data = try? JSONSerialization.data(withJSONObject: obj) {
            r.body = data
        } else {
            r.body = Data("{\"error\":\"json\"}".utf8)
        }
        return r
    }

    private func text(_ s: String, status: Int = 200, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        var r = HTTPResponse(status: status)
        r.headers["Content-Type"] = type
        r.body = Data(s.utf8)
        return r
    }

    private func route(_ req: HTTPRequest, _ respond: @escaping (HTTPResponse) -> Void) {
        switch (req.method, req.path) {

        case ("GET", "/"):
            let html = Bundle.main.url(forResource: "index", withExtension: "html")
                .flatMap { try? Data(contentsOf: $0) } ?? Data("<h1>LANChat</h1>".utf8)
            var r = HTTPResponse(body: html)
            r.headers["Content-Type"] = "text/html; charset=utf-8"
            respond(r)

        case ("GET", "/manifest.json"):
            respond(json([
                "name": "局域网聊天", "short_name": "局域网聊天",
                "start_url": "/", "display": "standalone",
                "background_color": "#f5f5f5", "theme_color": "#111827",
                "lang": "zh-CN",
            ]))

        case ("GET", "/icon-180.png"), ("GET", "/icon-192.png"), ("GET", "/icon-512.png"):
            let size = req.path.split(separator: "-")[1].split(separator: ".")[0]
            var r = HTTPResponse()
            if let url = Bundle.main.url(forResource: "icon-\(size)", withExtension: "png"),
               let data = try? Data(contentsOf: url) {
                r.body = data
                r.headers["Content-Type"] = "image/png"
                r.headers["Cache-Control"] = "public, max-age=86400"
            } else {
                r.status = 404
            }
            respond(r)

        case ("GET", "/api/state"):
            let plist = snapshotPeers().map {
                ["id": $0.id,
                 "name": store.deviceLabel($0.id, $0.name),
                 "ip": $0.ip, "port": $0.port]
            }
            respond(json([
                "me": ["id": deviceID, "name": myRemark()],
                "peers": plist,
                "local_ip": localIP(),
            ]))

        case ("GET", "/api/convs"):
            respond(json(["convs": store.listConvs(onlineIDs: onlineIDs())]))

        case ("GET", "/api/messages"):
            let cid = req.query["conv"] ?? ""
            let list = store.messages(convID: cid) { sid, fallback in
                store.deviceLabel(sid, fallback)
            }
            respond(json(["messages": list]))

        case ("GET", "/api/file"):
            guard let fid = req.query["id"], let f = store.fileByID(fid),
                  FileManager.default.fileExists(atPath: f.path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: f.path)) else {
                respond(text("not found", status: 404))
                return
            }
            var r = HTTPResponse(body: data)
            r.headers["Content-Type"] = "application/octet-stream"
            let quoted = f.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? f.name
            r.headers["Content-Disposition"] = "inline; filename*=UTF-8''\(quoted)"
            respond(r)

        case ("POST", "/api/upload"):
            handleUpload(req, respond)

        case ("POST", "/api/send"):
            handleSend(req, respond)

        case ("POST", "/api/inbox"):
            handleInbox(req, respond)

        case ("POST", "/api/read"):
            let d = Self.bodyDict(req.body)
            store.markRead(convID: d["conv"] as? String ?? "")
            respond(json(["ok": true]))

        case ("POST", "/api/remark"):
            let d = Self.bodyDict(req.body)
            let pid = d["id"] as? String ?? ""
            let remark = d["remark"] as? String ?? ""
            guard !pid.isEmpty else {
                respond(json(["ok": false], status: 400))
                return
            }
            store.setRemark(id: pid, remark: remark)
            respond(json(["ok": true]))

        case ("POST", "/api/me"):
            let d = Self.bodyDict(req.body)
            let name = (d["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                store.run("INSERT OR IGNORE INTO devices(id,name) VALUES(?,?)",
                          [.text(deviceID), .text(deviceName)])
                store.run("UPDATE devices SET remark=? WHERE id=?",
                          [.text(name), .text(deviceID)])
            }
            respond(json(["ok": true]))

        case ("POST", "/api/group"):
            handleGroup(req, respond)

        default:
            respond(json(["error": "not found"], status: 404))
        }
    }

    // MARK: - 上传

    private func handleUpload(_ req: HTTPRequest, _ respond: @escaping (HTTPResponse) -> Void) {
        let rawName = (req.query["name"] ?? "文件") as NSString
        var name = rawName.lastPathComponent
        name = Store.sanitizeFileName(name)
        guard !req.body.isEmpty else {
            respond(json(["error": "empty"], status: 400))
            return
        }
        let fid = uuidHex()
        let path = store.filePath(forID: fid, name: name)
        do {
            try req.body.write(to: URL(fileURLWithPath: path))
        } catch {
            respond(json(["error": "write failed"], status: 500))
            return
        }
        let ext = (name as NSString).pathExtension.lowercased()
        let kind = Self.imageExts.contains(ext) ? "image" : "file"
        store.insertFile(id: fid, name: name, size: req.body.count, path: path)
        respond(json(["id": fid, "name": name, "size": req.body.count, "kind": kind]))
    }

    // MARK: - 发送

    private func handleSend(_ req: HTTPRequest, _ respond: @escaping (HTTPResponse) -> Void) {
        let d = Self.bodyDict(req.body)
        let cid = d["conv"] as? String ?? ""
        var info = store.convInfo(cid)
        if info == nil && cid.hasPrefix("dm:") {
            let pid = String(cid.dropFirst(3))
            store.ensureConv(id: cid, type: "direct",
                             name: store.deviceLabel(pid, String(pid.prefix(6))),
                             members: [], created: Date().timeIntervalSince1970)
            info = store.convInfo(cid)
        }
        guard let conv = info else {
            respond(json(["error": "会话不存在"], status: 400))
            return
        }
        let kind = d["kind"] as? String ?? "text"
        let textBody = d["text"] as? String ?? ""
        let fid = d["file_id"] as? String ?? ""
        let fname = d["file_name"] as? String ?? ""
        let size = (d["size"] as? Int) ?? Int((d["size"] as? Double) ?? 0)

        let mid = store.saveMsg(convID: cid, senderID: deviceID, senderName: myRemark(),
                                kind: kind, text: textBody, fileID: fid, fileName: fname,
                                size: size, direction: "out", msgID: nil)
        let payload: [String: Any] = [
            "conv": conv,
            "msg": ["id": mid, "kind": kind, "text": textBody, "file_id": fid,
                    "file_name": fname, "size": size,
                    "ts": Date().timeIntervalSince1970],
            "sender": ["id": deviceID, "name": myRemark()],
        ]
        let targets = convTargets(cid, members: conv["members"] as? [String] ?? [])
        var ok = 0
        for t in targets {
            if Self.postJSON(urlString: "http://\(t.ip):\(t.port)/api/inbox",
                             payload: payload, timeout: 6) { ok += 1 }
        }
        respond(json(["ok": true, "msg_id": mid, "delivered": ok, "total": targets.count]))
    }

    // MARK: - 收件

    private func handleInbox(_ req: HTTPRequest, _ respond: @escaping (HTTPResponse) -> Void) {
        let d = Self.bodyDict(req.body)
        let conv = d["conv"] as? [String: Any] ?? [:]
        let msg = d["msg"] as? [String: Any] ?? [:]
        let sender = d["sender"] as? [String: Any] ?? [:]
        let sid = sender["id"] as? String ?? ""
        let sname = sender["name"] as? String ?? String(sid.prefix(6))
        guard !sid.isEmpty, !msg.isEmpty else {
            respond(json(["ok": false], status: 400))
            return
        }
        store.upsertDevice(id: sid, name: sname, ts: Date().timeIntervalSince1970)

        let type = conv["type"] as? String ?? "group"
        let cid: String
        if type == "direct" {
            cid = "dm:" + sid
            store.ensureConv(id: cid, type: "direct",
                             name: store.deviceLabel(sid, sname),
                             members: [], created: Date().timeIntervalSince1970)
        } else {
            cid = conv["id"] as? String ?? "all"
            let members = (conv["members"] as? [String]) ?? []
            store.upsertGroupConv(id: cid,
                                  name: conv["name"] as? String ?? "群聊",
                                  members: members)
        }
        let kind = msg["kind"] as? String ?? "text"
        let fid = msg["file_id"] as? String ?? ""
        store.saveMsg(convID: cid, senderID: sid, senderName: sname,
                      kind: kind, text: msg["text"] as? String ?? "",
                      fileID: fid, fileName: msg["file_name"] as? String ?? "",
                      size: (msg["size"] as? Int) ?? Int((msg["size"] as? Double) ?? 0),
                      direction: "in", msgID: msg["id"] as? String)

        // 收到文件 → 拉一份到本地，离线也能看
        if !fid.isEmpty && (kind == "file" || kind == "image") {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.fetchFile(senderID: sid, fileID: fid,
                                fileName: msg["file_name"] as? String ?? fid)
            }
        }
        respond(json(["ok": true]))
    }

    // MARK: - 建群

    private func handleGroup(_ req: HTTPRequest, _ respond: @escaping (HTTPResponse) -> Void) {
        let d = Self.bodyDict(req.body)
        let name = d["name"] as? String ?? "新群聊"
        let members = (d["members"] as? [String]) ?? []
        let gid = "grp:" + String(uuidHex().prefix(8))
        store.ensureConv(id: gid, type: "group", name: name,
                         members: members, created: Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "conv": ["id": gid, "type": "group", "name": name, "members": members],
            "msg": ["id": uuidHex(), "kind": "text",
                    "text": "\(myRemark()) 创建了群聊「\(name)」",
                    "file_id": "", "file_name": "", "size": 0,
                    "ts": Date().timeIntervalSince1970],
            "sender": ["id": deviceID, "name": myRemark()],
        ]
        for t in convTargets(gid, members: members) {
            DispatchQueue.global(qos: .utility).async {
                Self.postJSON(urlString: "http://\(t.ip):\(t.port)/api/inbox",
                              payload: payload, timeout: 6)
            }
        }
        respond(json(["ok": true, "id": gid]))
    }

    // MARK: - 推送目标

    private func convTargets(_ convID: String, members: [String]) -> [(id: String, name: String, ip: String, port: Int)] {
        let all = snapshotPeers()
        let online = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        if convID == "all" { return all }
        if convID.hasPrefix("dm:") {
            let pid = String(convID.dropFirst(3))
            return online[pid].map { [$0] } ?? []
        }
        return members.compactMap { online[$0] }
    }

    // MARK: - 拉取文件

    private func fetchFile(senderID: String, fileID: String, fileName: String) {
        guard let p = snapshotPeers().first(where: { $0.id == senderID }) else { return }
        if store.fileExists(fileID) { return }
        guard let url = URL(string: "http://\(p.ip):\(p.port)/api/file?id=\(fileID)") else { return }
        var request = URLRequest(url: url, timeoutInterval: 30)
        guard let data = Self.syncData(request) else { return }
        let name = Store.sanitizeFileName(fileName)
        let path = store.filePath(forID: fileID, name: name)
        try? data.write(to: URL(fileURLWithPath: path))
        store.insertFile(id: fileID, name: name, size: data.count, path: path)
    }

    /// 同步 GET，返回响应数据
    static func syncData(_ request: URLRequest) -> Data? {
        var result: Data?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 35)
        return result
    }

    // MARK: - 工具

    private static func bodyDict(_ data: Data) -> [String: Any] {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// 同步 POST JSON，返回是否成功（HTTP 200）
    static func postJSON(urlString: String, payload: [String: Any], timeout: TimeInterval) -> Bool {
        guard let url = URL(string: urlString),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        var ok = false
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return ok
    }
}
