import Foundation
import SQLite3
import UIKit
import CommonCrypto

/// SQLite 持久化。表结构与电脑版 lanchat.py 完全一致，
/// 所有访问都通过串行队列，线程安全。
final class Store {
    static let shared = Store()

    let dataDir: URL
    let filesDir: URL
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "lanchat.store")

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        dataDir = base.appendingPathComponent("LANChat", isDirectory: true)
        filesDir = dataDir.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

        let path = dataDir.appendingPathComponent("chat.db").path
        var handle: OpaquePointer?
        if sqlite3_open_v2(path, &handle,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            db = handle
            sqlite3_busy_timeout(db, 10_000)
        }
        initSchema()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Schema

    private func initSchema() {
        execute("""
        CREATE TABLE IF NOT EXISTS devices(
            id TEXT PRIMARY KEY,
            name TEXT DEFAULT '',
            remark TEXT DEFAULT '',
            last_seen REAL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS convs(
            id TEXT PRIMARY KEY,
            type TEXT,
            name TEXT DEFAULT '',
            members TEXT DEFAULT '[]',
            created REAL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS msgs(
            id TEXT PRIMARY KEY,
            conv_id TEXT,
            sender_id TEXT,
            sender_name TEXT,
            kind TEXT,
            text TEXT DEFAULT '',
            file_id TEXT DEFAULT '',
            file_name TEXT DEFAULT '',
            size INTEGER DEFAULT 0,
            ts REAL,
            dir TEXT,
            read INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_msgs_conv ON msgs(conv_id, ts);
        CREATE TABLE IF NOT EXISTS files(
            id TEXT PRIMARY KEY,
            name TEXT,
            size INTEGER,
            path TEXT,
            ts REAL
        );
        """)
    }

    // MARK: - 基础执行

    /// 执行一条或多条 SQL（分号分隔，不带回参）
    func execute(_ sql: String) {
        queue.sync {
            var errmsg: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, sql, nil, nil, &errmsg)
            if let errmsg { sqlite3_free(errmsg) }
        }
    }

    /// 带参数的写操作
    func run(_ sql: String, _ params: [SQLValue]) {
        queue.sync { runLocked(sql, params) }
    }

    /// 带参数的查询，返回字典数组（列名 -> 值）
    func query(_ sql: String, _ params: [SQLValue] = []) -> [[String: SQLValue]] {
        queue.sync {
            var rows: [[String: SQLValue]] = []
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return rows }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, params)
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: SQLValue] = [:]
                let count = sqlite3_column_count(stmt)
                for i in 0..<count {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER:
                        row[name] = .int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT:
                        row[name] = .double(sqlite3_column_double(stmt, i))
                    case SQLITE_TEXT:
                        row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                    default:
                        row[name] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    /// 在队列内直接执行（供批处理使用）
    private func runLocked(_ sql: String, _ params: [SQLValue]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        _ = sqlite3_step(stmt)
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [SQLValue]) {
        for (idx, p) in params.enumerated() {
            let i = Int32(idx + 1)
            switch p {
            case .null:
                sqlite3_bind_null(stmt, i)
            case .int(let v):
                sqlite3_bind_int64(stmt, i, v)
            case .double(let v):
                sqlite3_bind_double(stmt, i, v)
            case .text(let v):
                sqlite3_bind_text(stmt, i, v, -1, Self.transient)
            case .blob(let v):
                sqlite3_bind_blob(stmt, i, v, Int32(v.count), Self.transient)
            }
        }
    }

    // MARK: - 设备

    func deviceID() -> String {
        let p = dataDir.appendingPathComponent("device_id.txt")
        if let v = try? String(contentsOf: p, encoding: .utf8), !v.isEmpty {
            return v
        }
        let seed = "\(UIDevice.current.name)-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 0..<1_000_000))"
        let d = md5Hex(seed)
        try? d.write(to: p, atomically: true, encoding: .utf8)
        return d
    }

    func upsertDevice(id: String, name: String, ts: Double) {
        run("INSERT OR IGNORE INTO devices(id,name,last_seen) VALUES(?,?,?)",
            [.text(id), .text(name), .double(ts)])
        run("UPDATE devices SET name=?, last_seen=? WHERE id=? AND remark=''",
            [.text(name), .double(ts), .text(id)])
        run("UPDATE devices SET last_seen=? WHERE id=?", [.double(ts), .text(id)])
    }

    func ensureDevice(id: String, name: String) {
        run("INSERT OR IGNORE INTO devices(id,name) VALUES(?,?)",
            [.text(id), .text(String(name.prefix(6)))])
    }

    func deviceLabel(_ did: String, _ fallback: String) -> String {
        let rows = query("SELECT name,remark FROM devices WHERE id=?", [.text(did)])
        if let r = rows.first {
            let remark = r["remark"]?.stringValue ?? ""
            let name = r["name"]?.stringValue ?? ""
            let label = !remark.isEmpty ? remark : (!name.isEmpty ? name : fallback)
            if !label.isEmpty { return label }
        }
        return fallback.isEmpty ? String(did.prefix(6)) : fallback
    }

    func setRemark(id: String, remark: String) {
        ensureDevice(id: id, name: String(id.prefix(6)))
        run("UPDATE devices SET remark=? WHERE id=?", [.text(remark), .text(id)])
    }

    func myRemark(deviceID: String, deviceName: String) -> String {
        let rows = query("SELECT remark,name FROM devices WHERE id=?", [.text(deviceID)])
        if let r = rows.first, let remark = r["remark"]?.stringValue, !remark.isEmpty {
            return remark
        }
        return deviceName
    }

    // MARK: - 会话

    func ensureConv(id: String, type: String, name: String, members: [String], created: Double) {
        run("INSERT OR IGNORE INTO convs(id,type,name,members,created) VALUES(?,?,?,?,?)",
            [.text(id), .text(type), .text(name), .text(Self.jsonString(members)), .double(created)])
    }

    /// 群聊信息更新（重名时不覆盖已有名称）
    func upsertGroupConv(id: String, name: String, members: [String]) {
        run("INSERT OR IGNORE INTO convs(id,type,name,members,created) VALUES(?,?,?,?,?)",
            [.text(id), .text("group"), .text(name), .text(Self.jsonString(members)), Date().timeIntervalSince1970])
        run("UPDATE convs SET members=? WHERE id=?", [.text(Self.jsonString(members)), .text(id)])
    }

    func convInfo(_ cid: String) -> [String: Any]? {
        let rows = query("SELECT * FROM convs WHERE id=?", [.text(cid)])
        guard let r = rows.first else { return nil }
        let members = Self.parseArray(r["members"]?.stringValue ?? "[]")
        return ["id": r["id"]?.stringValue ?? cid,
                "type": r["type"]?.stringValue ?? "group",
                "name": r["name"]?.stringValue ?? "",
                "members": members]
    }

    /// 对齐电脑版 list_convs：含未读数、最后一条、在线状态
    func listConvs(onlineIDs: Set<String>) -> [[String: Any]] {
        let rows = query("""
        SELECT c.*,
        (SELECT COUNT(*) FROM msgs m WHERE m.conv_id=c.id AND m.dir='in' AND m.read=0) unread,
        (SELECT ts FROM msgs m WHERE m.conv_id=c.id ORDER BY ts DESC LIMIT 1) ts,
        (SELECT text FROM msgs m WHERE m.conv_id=c.id AND m.kind='text' ORDER BY ts DESC LIMIT 1) last_text,
        (SELECT file_name FROM msgs m WHERE m.conv_id=c.id AND m.kind!='text' ORDER BY ts DESC LIMIT 1) last_file
        FROM convs c ORDER BY ts DESC
        """)
        var out: [[String: Any]] = []
        for r in rows {
            let cid = r["id"]?.stringValue ?? ""
            let members = Self.parseArray(r["members"]?.stringValue ?? "[]")
            var name = r["name"]?.stringValue ?? ""
            var peerID = ""
            var remark = ""
            if cid == "all" {
                name = "局域网总群"
            } else if cid.hasPrefix("dm:") {
                peerID = String(cid.dropFirst(3))
                let rr = query("SELECT name,remark FROM devices WHERE id=?", [.text(peerID)])
                if let first = rr.first, let rm = first["remark"]?.stringValue, !rm.isEmpty {
                    remark = rm
                }
                name = deviceLabel(peerID, String(peerID.prefix(6)))
            }
            let lastText = r["last_text"]?.stringValue ?? ""
            let lastFile = r["last_file"]?.stringValue ?? ""
            let last = !lastText.isEmpty ? lastText : (!lastFile.isEmpty ? "[文件] " + lastFile : "")
            out.append([
                "id": cid,
                "type": r["type"]?.stringValue ?? "group",
                "name": name,
                "remark": remark,
                "peer_id": peerID,
                "members": members,
                "unread": Int(r["unread"]?.int64Value ?? 0),
                "ts": r["ts"]?.doubleValue ?? 0,
                "last": last,
                "online": peerID.isEmpty ? true : onlineIDs.contains(peerID),
            ])
        }
        return out
    }

    // MARK: - 消息

    @discardableResult
    func saveMsg(convID: String, senderID: String, senderName: String, kind: String,
                 text: String, fileID: String, fileName: String, size: Int,
                 direction: String, msgID: String?) -> String {
        let mid = msgID ?? uuidHex()
        run("INSERT OR IGNORE INTO msgs(id,conv_id,sender_id,sender_name,kind,text,"
            + "file_id,file_name,size,ts,dir,read) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            [.text(mid), .text(convID), .text(senderID), .text(senderName), .text(kind),
             .text(text), .text(fileID), .text(fileName), .int64(Int64(size)),
             .double(Date().timeIntervalSince1970), .text(direction), .int64(0)])
        return mid
    }

    func messages(convID: String, labelFor: (String, String) -> String) -> [[String: Any]] {
        let rows = query("SELECT * FROM msgs WHERE conv_id=? ORDER BY ts ASC LIMIT 500", [.text(convID)])
        return rows.map { r in
            let sid = r["sender_id"]?.stringValue ?? ""
            let sname = r["sender_name"]?.stringValue ?? ""
            return [
                "id": r["id"]?.stringValue ?? "",
                "kind": r["kind"]?.stringValue ?? "text",
                "text": r["text"]?.stringValue ?? "",
                "file_id": r["file_id"]?.stringValue ?? "",
                "file_name": r["file_name"]?.stringValue ?? "",
                "size": Int(r["size"]?.int64Value ?? 0),
                "ts": r["ts"]?.doubleValue ?? 0,
                "dir": r["dir"]?.stringValue ?? "in",
                "sender_name": labelFor(sid, sname),
            ]
        }
    }

    func markRead(convID: String) {
        run("UPDATE msgs SET read=1 WHERE conv_id=? AND dir='in'", [.text(convID)])
    }

    // MARK: - 文件

    func insertFile(id: String, name: String, size: Int, path: String) {
        run("INSERT OR REPLACE INTO files(id,name,size,path,ts) VALUES(?,?,?,?,?)",
            [.text(id), .text(name), .int64(Int64(size)), .text(path),
             .double(Date().timeIntervalSince1970)])
    }

    func fileByID(_ fid: String) -> (name: String, path: String)? {
        let rows = query("SELECT name,path FROM files WHERE id=?", [.text(fid)])
        guard let r = rows.first,
              let name = r["name"]?.stringValue,
              let path = r["path"]?.stringValue else { return nil }
        return (name, path)
    }

    func fileExists(_ fid: String) -> Bool {
        !query("SELECT id FROM files WHERE id=?", [.text(fid)]).isEmpty
    }

    func filePath(forID fid: String, name: String) -> String {
        let safe = sanitizeFileName(name)
        return filesDir.appendingPathComponent(fid + "_" + safe).path
    }

    // MARK: - 工具

    static func sanitizeFileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let cleaned = name.components(separatedBy: bad).joined(separator: "_")
        return cleaned.isEmpty ? "文件" : cleaned
    }

    static func jsonString(_ arr: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    static func parseArray(_ s: String) -> [String] {
        guard let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr
    }
}

// MARK: - SQL 值类型

enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    var stringValue: String? {
        if case .text(let v) = self { return v }
        return nil
    }
    var int64Value: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }
    var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }
}

// MARK: - 基础工具函数

func md5Hex(_ s: String) -> String {
    let data = Data(s.utf8)
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    _ = data.withUnsafeBytes { buf in
        CC_MD5(buf.baseAddress, CC_LONG(data.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
}

func uuidHex() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}
