import Foundation

/// 保守的「卸载残留」检测器：找出 ~/Library 下、bundle id 已无对应已安装应用的残留。
///
/// 安全原则（来自真机核实）：
/// - 只把结果当作**候选**，全部默认不勾选，由用户逐项确认。
/// - 拿不到「已安装应用清单」就直接放弃（返回空），绝不靠猜。
/// - 系统/SDK/更新器/登录助手等一律进否定名单，永不标记。
/// - UUID / (null) 这类无法解析身份的目录永不标记。
/// - Group Containers / Application Scripts / LaunchAgents 默认完全不扫（跨应用共享或会改登录行为）。
/// - 比对大小写无关 + 双向父子前缀（已安装应用的子组件/助手不会被误判）。
enum LeftoverScanner {
    static let fm = FileManager.default
    static var home: URL { fm.homeDirectoryForCurrentUser }

    /// 永不标记的前缀（小写比较）。含系统、内嵌浏览器框架、更新器，以及常见的崩溃/统计 SDK——
    /// 这些都没有独立 app，却是已安装应用的活跃组件，纯 id 匹配会把它们误判成残留。
    static let denyPrefixes: [String] = [
        "com.apple.", "group.com.apple.", "systemgroup.com.apple.",
        "org.chromium.", "org.cef.", "org.cups.", "org.swift.swiftpm",
        "com.google.keystone", "com.bugsnag.", "com.firebase.", "com.google.firebase",
        "com.segment.storage.", "com.plausiblelabs.crashreporter.",
        "com.hackemist.", "com.onevcat.kingfisher",
        // 常见内嵌 SDK（崩溃上报 / 统计 / 推送 / 云服务）
        "io.sentry", "com.crashlytics", "io.fabric", "com.umeng", "com.appsflyer",
        "com.adjust.", "com.microsoft.appcenter",
        "com.tencent.bugly", "com.tencent.fireeye", "com.tencent.feedback", "com.tencent.qcloud",
    ]
    static let denySubstrings: [String] = [
        ".helper.renderer", ".helper.gpu", ".helper (", ".autoupdate",
        ".launchatloginhelper", ".loginhelper",
        "bugsnag-shared", ".bugly", ".qcloud",
    ]
    /// 这些是程序运行产物，不是 app 残留（哪怕名字长得像 bundle id）
    static let artifactSuffixes: [String] = [".sock", ".socket", ".store", ".dat", ".log"]

    // 3 段及以上的反向 DNS；排除 UUID
    static let bundleIdRegex = try! NSRegularExpression(
        pattern: "^[A-Za-z][A-Za-z0-9-]*(\\.[A-Za-z0-9_-]+){2,}$")
    static let uuidRegex = try! NSRegularExpression(
        pattern: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-")

    /// 权威已安装清单：lsregister 的应用 id ∪ 输入法 id。空集合 = 调用方必须放弃。
    static func installedBundleIDs() -> Set<String> {
        var ids = lsregisterIDs()
        guard !ids.isEmpty else { return [] }   // lsregister 失败 → 放弃，绝不靠猜
        ids.formUnion(inputMethodIDs())         // 输入法不在 lsregister 应用清单里，单独补上
        return ids
    }

    /// lsregister -dump，取 identifier: 行，小写。
    static func lsregisterIDs() -> Set<String> {
        let lsr = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        guard fm.isExecutableFile(atPath: lsr) else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: lsr)
        p.arguments = ["-dump"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice   // stderr 不读，直接丢弃，避免管道写满死锁
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // 非 0 退出（被 kill / 中途崩溃）→ 视为失败，绝不拿半截清单去判残留
        guard p.terminationStatus == 0 else { return [] }
        var ids = Set<String>()
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("identifier:") else { continue }
            let id = t.dropFirst("identifier:".count).trimmingCharacters(in: .whitespaces).lowercased()
            if !id.isEmpty, !id.contains(" ") { ids.insert(id) }
        }
        // 健康的 Mac 会注册成百上千个 id；过少说明 dump 不完整 → 放弃
        guard ids.count >= 50 else { return [] }
        return ids
    }

    /// 输入法（~/Library/Input Methods 与 /Library/Input Methods 里的 *.app）的 bundle id
    static func inputMethodIDs() -> Set<String> {
        var ids = Set<String>()
        let roots = [home.appendingPathComponent("Library/Input Methods"),
                     URL(fileURLWithPath: "/Library/Input Methods")]
        for root in roots {
            let apps = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for app in apps where app.pathExtension == "app" {
                if let id = Bundle(url: app)?.bundleIdentifier, !id.isEmpty {
                    ids.insert(id.lowercased())
                }
            }
        }
        return ids
    }

    static func isDenied(_ id: String) -> Bool {
        let l = id.lowercased()
        if denyPrefixes.contains(where: { l.hasPrefix($0) }) { return true }
        if denySubstrings.contains(where: { l.contains($0) }) { return true }
        return false
    }

    static func looksLikeBundleID(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        if uuidRegex.firstMatch(in: s, range: r) != nil { return false }
        return bundleIdRegex.firstMatch(in: s, range: r) != nil
    }

    /// 大小写无关 + 双向父子前缀匹配 + 共享产品祖先（消除已安装应用的 helper/子组件误判）
    static func isInstalled(_ id: String, _ installed: Set<String>) -> Bool {
        let l = id.lowercased()
        if installed.contains(l) { return true }
        for inst in installed {
            if inst.hasPrefix(l + ".") || l.hasPrefix(inst + ".") { return true }
        }
        return sharesProductAncestor(l, installed)
    }

    /// 已知的「多租户」根（不同主体共用一个前缀，不能当作同一厂商）
    static let multiTenantRoots: Set<String> = [
        "jp.co", "io.github", "com.github", "com.googlecode",
        "net.sourceforge", "io.gitlab", "org.eclipse",
    ]

    /// 放宽匹配，消除「同一应用/同一厂商」的残留误判。方向上宁可漏判，绝不误删活数据：
    /// - ≥4 段子组件：取前 3 段「厂商.产品」做祖先匹配（com.bjango.istatmenus6.extras）
    /// - 任意 ≥3 段：取前 2 段「根.厂商」，仅当它是单租户根且该厂商有应用已安装时也算已安装。
    ///   例：com.ugreen.desktop 是已安装的 UGREEN 应用写入的数据，厂商 com.ugreen 下有已安装 id → 不标记。
    static func sharesProductAncestor(_ lowercasedID: String, _ installed: Set<String>) -> Bool {
        let parts = lowercasedID.split(separator: ".")
        guard parts.count >= 3 else { return false }
        if parts.count >= 4 {
            let ancestor = parts.prefix(3).joined(separator: ".")
            if installed.contains(where: { $0 == ancestor || $0.hasPrefix(ancestor + ".") }) { return true }
        }
        let vendor = parts.prefix(2).joined(separator: ".")
        if !multiTenantRoots.contains(vendor),
           installed.contains(where: { $0.hasPrefix(vendor + ".") }) { return true }
        return false
    }

    /// 返回候选残留的 URL 列表。已安装清单为空 → 返回空（放弃）。
    static func candidateURLs() -> [URL] {
        let installed = installedBundleIDs()
        guard !installed.isEmpty else { return [] }   // 硬性放弃：绝不在没有可靠清单时乱猜

        // 保守目录集合：刻意不含 Group Containers / Application Scripts / LaunchAgents
        let dirs: [(sub: String, suffix: String?)] = [
            ("Library/Saved Application State", ".savedState"),
            ("Library/HTTPStorages", ".binarycookies"),
            ("Library/WebKit", nil),
            ("Library/Preferences", ".plist"),
            ("Library/Application Support", nil),
            ("Library/Caches", nil),
        ]

        var out: [URL] = []
        var seen = Set<String>()   // 同一 bundle id 在多个目录都有残留时，避免重复列同名（仍按 URL 区分）
        for (sub, suffix) in dirs {
            let base = home.appendingPathComponent(sub)
            let kids = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            for url in kids {
                let raw = url.lastPathComponent
                // 跳过 .sock/.store/.dat/.log 之类运行产物
                if artifactSuffixes.contains(where: { raw.hasSuffix($0) }) { continue }
                var name = raw
                if let s = suffix, name.hasSuffix(s) { name.removeLast(s.count) }
                guard looksLikeBundleID(name), !isDenied(name) else { continue }
                guard !isInstalled(name, installed) else { continue }
                let key = url.path
                if seen.insert(key).inserted { out.append(url) }
            }
        }
        return out
    }
}
