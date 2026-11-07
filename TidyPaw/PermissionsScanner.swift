import Foundation
import AppKit
import SQLite3
import os

// MARK: - 模型

struct PermissionGrant: Identifiable, Hashable, Sendable {
    let id = UUID()
    let service: String
    let friendly: String
    let sensitive: Bool
    let limited: Bool        // auth_value == 3（受限授权）
}

struct AppPermissions: Identifiable, Sendable {
    let id: String           // client：bundle id 或可执行文件路径
    let displayName: String
    let isBundleID: Bool
    var grants: [PermissionGrant]
    var hasSensitive: Bool { grants.contains { $0.sensitive } }
}

struct PermissionsResult: Sendable {
    let apps: [AppPermissions]
    let readable: Bool       // 是否至少成功读到一个 TCC.db
}

// MARK: - TCC 扫描器

enum PermissionsScanner {

    /// kTCCService* → 中文名
    static let serviceMap: [String: String] = [
        "kTCCServiceCamera": "摄像头",
        "kTCCServiceMicrophone": "麦克风",
        "kTCCServiceAddressBook": "通讯录",
        "kTCCServiceContactsFull": "完整通讯录",
        "kTCCServiceContactsLimited": "受限通讯录",
        "kTCCServicePhotos": "照片图库",
        "kTCCServicePhotosAdd": "向照片添加",
        "kTCCServiceCalendar": "日历",
        "kTCCServiceReminders": "提醒事项",
        "kTCCServiceLocation": "位置服务",
        "kTCCServiceLiverpool": "位置（应用级）",
        "kTCCServiceScreenCapture": "屏幕录制",
        "kTCCServiceAccessibility": "辅助功能（可控制电脑）",
        "kTCCServiceSystemPolicyAllFiles": "完全磁盘访问",
        "kTCCServicePostEvent": "合成输入事件",
        "kTCCServiceListenEvent": "输入监控（监听键鼠）",
        "kTCCServiceAppleEvents": "自动化（控制其他App）",
        "kTCCServiceSystemPolicyDocumentsFolder": "“文稿”文件夹",
        "kTCCServiceSystemPolicyDownloadsFolder": "“下载”文件夹",
        "kTCCServiceSystemPolicyDesktopFolder": "“桌面”文件夹",
        "kTCCServiceSystemPolicyNetworkVolumes": "网络宗卷",
        "kTCCServiceSystemPolicyRemovableVolumes": "可移除宗卷",
        "kTCCServiceSystemPolicySysAdminFiles": "受管理系统文件",
        "kTCCServiceDeveloperTool": "开发者工具",
        "kTCCServiceBluetoothAlways": "蓝牙",
        "kTCCServiceUbiquity": "iCloud 云盘",
        "kTCCServiceFileProviderDomain": "第三方云盘域",
        "kTCCServiceMediaLibrary": "媒体资料库",
        "kTCCServiceMotion": "运动与健身",
        "kTCCServiceSpeechRecognition": "语音识别",
        "kTCCServiceWillow": "家庭/HomeKit",
        "kTCCServiceFocusStatus": "专注模式状态",
        "kTCCServiceRemoteDesktop": "远程桌面",
        "kTCCServiceEndpointSecurityClient": "端点安全",
    ]

    /// 高敏感权限（界面标红，重点提醒）
    static let sensitiveServices: Set<String> = [
        "kTCCServiceCamera", "kTCCServiceMicrophone", "kTCCServiceScreenCapture",
        "kTCCServiceAccessibility", "kTCCServiceSystemPolicyAllFiles",
        "kTCCServiceListenEvent", "kTCCServicePostEvent", "kTCCServiceAppleEvents",
        "kTCCServiceRemoteDesktop", "kTCCServiceEndpointSecurityClient",
        "kTCCServiceDeveloperTool",
    ]

    static func friendly(_ service: String) -> String {
        serviceMap[service] ?? service.replacingOccurrences(of: "kTCCService", with: "")
    }

    static var dbPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
    }

    static func scan() -> PermissionsResult {
        var rows: [(service: String, client: String, type: Int, auth: Int)] = []
        var anyReadable = false
        for path in dbPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let r = readDB(path) {
                anyReadable = true
                rows.append(contentsOf: r)
            }
        }

        // 只保留已授予（2=允许 / 3=受限），按 client 聚合并去重
        var byClient: [String: AppPermissions] = [:]
        var seen = Set<String>()  // client|service 去重
        var nameCache: [String: (String, Bool)] = [:]
        for row in rows where row.auth == 2 || row.auth == 3 {
            guard !row.client.isEmpty else { continue }
            let key = row.client + "|" + row.service
            guard seen.insert(key).inserted else { continue }
            let grant = PermissionGrant(
                service: row.service,
                friendly: friendly(row.service),
                sensitive: sensitiveServices.contains(row.service),
                limited: row.auth == 3
            )
            if byClient[row.client] == nil {
                let resolved = nameCache[row.client] ?? {
                    let v = resolveName(client: row.client, type: row.type)
                    nameCache[row.client] = v
                    return v
                }()
                byClient[row.client] = AppPermissions(id: row.client, displayName: resolved.0,
                                                      isBundleID: resolved.1, grants: [])
            }
            byClient[row.client]?.grants.append(grant)
        }

        // 敏感的排前面，再按授权数量多到少
        let apps = byClient.values
            .map { app -> AppPermissions in
                var a = app
                a.grants.sort { ($0.sensitive ? 0 : 1, $0.friendly) < ($1.sensitive ? 0 : 1, $1.friendly) }
                return a
            }
            .sorted {
                if $0.hasSensitive != $1.hasSensitive { return $0.hasSensitive }
                if $0.grants.count != $1.grants.count { return $0.grants.count > $1.grants.count }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        return PermissionsResult(apps: apps, readable: anyReadable)
    }

    /// client → (显示名, 是否bundleID)
    private static func resolveName(client: String, type: Int) -> (String, Bool) {
        switch type {
        case 0:  // bundle id
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: client),
               let bundle = Bundle(url: url) {
                let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary
                if let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String),
                   !name.isEmpty {
                    return (name, true)
                }
                return (url.deletingPathExtension().lastPathComponent, true)
            }
            return (client, true)  // 已卸载/找不到，显示原始 id
        case 1:  // 可执行文件绝对路径
            return ((client as NSString).lastPathComponent, false)
        default: // 未知 client_type，原样显示，不猜
            return (client, false)
        }
    }

    private static let log = Logger(subsystem: "com.ahuamiao.roudaiguanjia", category: "permissions")

    /// 只读、immutable 方式打开 TCC.db 并取 access 表。
    /// immutable=1：当作只读快照、跳过加锁、也跳过读取 -wal 旁文件。
    /// 取舍：tccd 刚写进 WAL 还没 checkpoint 的极新授权可能暂时读不到（可接受的轻微滞后）。
    private static func readDB(_ path: String) -> [(String, String, Int, Int)]? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let uri = "file:" + encoded + "?immutable=1"
        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard openRC == SQLITE_OK else {
            log.error("打开 TCC.db 失败 rc=\(openRC)：\(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT service, client, client_type, auth_value FROM access"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("查询 access 表失败：\(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var out: [(String, String, Int, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let svcC = sqlite3_column_text(stmt, 0) else { continue }
            let service = String(cString: svcC)
            let client = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let type = Int(sqlite3_column_int(stmt, 2))
            let auth = Int(sqlite3_column_int(stmt, 3))
            out.append((service, client, type, auth))
        }
        return out
    }
}
