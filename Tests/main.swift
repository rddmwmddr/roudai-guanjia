import Foundation
import UniformTypeIdentifiers
import Darwin

// 回归测试：只在假 Home 里操作，不碰真实文件。用 Tests/run.sh 运行。

guard let fakeHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !fakeHome.isEmpty else {
    print("拒绝运行：必须通过 Tests/run.sh 在假 Home 里跑")
    exit(2)
}

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
var passed = 0
var failed = 0

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failed += 1 }
    print("\(ok ? "  通过" : "✗ 失败")  \(name)\(ok ? "" : "  → \(detail())")")
}
func section(_ s: String) { print("\n── \(s)") }
func path(_ sub: String) -> URL { home.appendingPathComponent(sub) }
func mkdir(_ url: URL) { try! fm.createDirectory(at: url, withIntermediateDirectories: true) }
func write(_ url: URL, bytes: Int = 8192, fill: UInt8 = 1) {
    mkdir(url.deletingLastPathComponent())
    try! Data(repeating: fill, count: bytes).write(to: url)
}
func makeApp(_ name: String, _ info: [String: Any]) -> URL {
    let app = path("FakeApps/\(name)")
    mkdir(app.appendingPathComponent("Contents/MacOS"))
    let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try! data.write(to: app.appendingPathComponent("Contents/Info.plist"))
    return app
}
/// 把「加入目录的时间」改到过去，模拟很久以前下载的文件
func setAddedDate(_ url: URL, _ date: Date) {
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
    var ts = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
    setattrlist(url.path, &list, &ts, MemoryLayout<timespec>.size, 0)
}
func makeOld(_ url: URL, _ date: Date) {
    try! fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    setAddedDate(url, date)
}

// 准备真实存在的目录，让错误的路径拼接能「命中」它们
for dir in ["Library/Application Support/SomeRealApp", "Library/Caches/com.real.app", "Library/Logs/x", "Documents", "Downloads", "Desktop", ".Trash"] {
    mkdir(path(dir))
}
write(path("Library/Application Support/SomeRealApp/important.db"))
write(path("Documents/keep.txt"))

// MARK: - 卸载扫描：不可信的 Info.plist

section("卸载扫描：异常的 Info.plist 不能波及别的目录")
let hostile: [(String, [String: Any])] = [
    ("EmptyName.app", ["CFBundleIdentifier": "com.test.empty", "CFBundleDisplayName": "", "CFBundleExecutable": "EmptyName"]),
    ("Blank.app", ["CFBundleIdentifier": "com.test.blank", "CFBundleDisplayName": "   ", "CFBundleName": "  ", "CFBundleExecutable": ""]),
    ("DotDot.app", ["CFBundleIdentifier": "com.test.dotdot", "CFBundleName": "..", "CFBundleDisplayName": "..", "CFBundleExecutable": ".."]),
    ("Dot.app", ["CFBundleIdentifier": ".", "CFBundleName": ".", "CFBundleExecutable": "."]),
    ("Traversal.app", ["CFBundleIdentifier": "../../Documents", "CFBundleName": "../../Documents", "CFBundleExecutable": "../../../Documents"]),
    ("Slash.app", ["CFBundleIdentifier": "com.test/slash", "CFBundleName": "a/b", "CFBundleExecutable": "Library/Caches"]),
]
for (file, info) in hostile {
    let app = makeApp(file, info)
    let result = try! UninstallScanner().scan(appURL: app)
    let paths = result.candidates.map(\.url.path)
    let extra = paths.filter { $0 != result.identity.appURL.path }
    check("\(file)：只列出 App 本体", extra.isEmpty, "多列了 \(extra)")
    check("\(file)：名字可用于确认弹窗", PathSafety.isSafeComponent(result.identity.appName), "appName=[\(result.identity.appName)]")
}

section("卸载扫描：正常 App")
let goodApp = makeApp("Good.app", ["CFBundleIdentifier": "com.test.good", "CFBundleName": "Good", "CFBundleExecutable": "Good"])
write(path("Library/Preferences/com.test.good.plist"))
write(path("Library/Application Support/Good/data"))
write(path("Library/Caches/com.test.good/c"))
let good = try! UninstallScanner().scan(appURL: goodApp)
check("找到本体、偏好、数据、缓存", good.candidates.count == 4, "\(good.candidates.map(\.url.lastPathComponent))")
check("都默认勾选", good.candidates.allSatisfy(\.defaultSelected))

section("卸载扫描：通用名字不算精确匹配")
let electron = makeApp("Shell.app", ["CFBundleIdentifier": "com.test.shell", "CFBundleName": "Shell", "CFBundleExecutable": "Electron"])
write(path("Library/Application Support/Electron/other-app-data"))
let electronScan = try! UninstallScanner().scan(appURL: electron)
let electronDir = electronScan.candidates.first { $0.url.lastPathComponent == "Electron" }
check("列出来但不默认勾选", electronDir?.defaultSelected == false, "\(String(describing: electronDir))")
check("标为可能相关", electronDir?.confidence == .likely)

section("卸载扫描：拖入符号链接 / 系统应用 / 只读磁盘")
let realApp = makeApp("RealThing.app", ["CFBundleIdentifier": "com.test.real", "CFBundleName": "RealThing", "CFBundleExecutable": "RealThing"])
let link = path("Desktop/RealThing.app")
try! fm.createSymbolicLink(at: link, withDestinationURL: realApp)
let linked = try! UninstallScanner().scan(appURL: link)
check("本体解析到真实 App", linked.candidates.first?.url.resolvingSymlinksInPath().path == realApp.resolvingSymlinksInPath().path, "\(linked.candidates.first?.url.path ?? "nil")")

do {
    _ = try UninstallScanner().scan(appURL: URL(fileURLWithPath: "/Applications/Safari.app"))
    check("拒绝 /Applications/Safari.app", false, "没有抛错")
} catch { check("拒绝 /Applications/Safari.app", (error as? UninstallError).map { "\($0)" } == "systemApp", "\(error)") }

let dmgDir = path("dmg"); mkdir(dmgDir)
let srcFolder = dmgDir.appendingPathComponent("src/Mounted.app/Contents"); mkdir(srcFolder)
try! PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.test.mounted"], format: .xml, options: 0)
    .write(to: srcFolder.appendingPathComponent("Info.plist"))
let dmg = dmgDir.appendingPathComponent("t.dmg").path
let mountPoint = dmgDir.appendingPathComponent("mnt").path
_ = runProcess("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", dmgDir.appendingPathComponent("src").path, "-format", "UDZO", dmg], timeout: 60)
let attached = runProcess("/usr/bin/hdiutil", ["attach", "-quiet", "-readonly", "-nobrowse", "-mountpoint", mountPoint, dmg], timeout: 60)
if attached?.status == 0 {
    do {
        _ = try UninstallScanner().scan(appURL: URL(fileURLWithPath: mountPoint + "/Mounted.app"))
        check("拒绝只读 DMG 里的 App", false, "没有抛错")
    } catch { check("拒绝只读 DMG 里的 App", (error as? UninstallError).map { "\($0)" } == "readOnlyVolume", "\(error)") }
    _ = runProcess("/usr/bin/hdiutil", ["detach", "-quiet", mountPoint], timeout: 30)
} else {
    print("  跳过  只读 DMG（hdiutil 挂载失败）")
}

section("多个 App 一起卸载")
func candidate(_ sub: String) -> RemovalCandidate {
    RemovalCandidate(url: path(sub), kind: "x", evidence: "x", confidence: .exact, requiresAdmin: false, size: 1, defaultSelected: true)
}
let sharedPath = candidate("Library/Application Support/Shared")
let merged = UninstallEngine.removingSharedPaths([
    [candidate("Applications/A.app"), sharedPath],
    [candidate("Applications/B.app"), candidate("Library/Application Support/Shared")],
])
check("共用路径只归在先加入的 App 名下", merged[0].count == 2 && merged[1].map(\.url.lastPathComponent) == ["B.app"], "\(merged.map { $0.map(\.url.lastPathComponent) })")
let nested = UninstallEngine.topLevel([candidate("Applications/A.app"), candidate("Applications/A.app/Contents/Inner.app"), candidate("Applications/AB.app")])
check("App 包里的项目不单独搬，前缀相同的兄弟不受影响", nested.map(\.url.lastPathComponent) == ["A.app", "AB.app"], "\(nested.map(\.url.lastPathComponent))")

// MARK: - 路径保护

section("路径保护")
for sub in ["", "Library", "Library/Application Support", "Library/Caches", "Documents", "Downloads", ".Trash"] {
    check("保护 ~/\(sub)", PathSafety.isProtected(path(sub)))
}
for abs in ["/", "/System", "/System/Library/CoreServices", "/Library", "/Library/Application Support", "/usr/bin/ls", "/Applications", "/private/var/db/receipts", "/Users"] {
    check("保护 \(abs)", PathSafety.isProtected(URL(fileURLWithPath: abs)))
}
check("保护 ~/Library/Caches/../Application Support（带 ..）", PathSafety.isProtected(path("Library/Caches/../Application Support")))
check("放行 ~/Library/Caches/com.foo", !PathSafety.isProtected(path("Library/Caches/com.foo")))
check("放行 ~/Documents/a.txt", !PathSafety.isProtected(path("Documents/a.txt")))
check("放行 /Applications/Foo.app", !PathSafety.isProtected(URL(fileURLWithPath: "/Applications/Foo.app")))
for bad in ["", " ", ".", "..", "a/b", "/", " .. "] { check("文件名不安全：[\(bad)]", !PathSafety.isSafeComponent(bad)) }
for ok in ["微信", "QQ", "🐷", "Google Chrome", ".hidden", "a..b"] { check("文件名安全：[\(ok)]", PathSafety.isSafeComponent(ok)) }

// MARK: - 重复文件

section("重复文件")
let dupDir = path("Documents/dups"); mkdir(dupDir)
let mb = 1024 * 1024
write(dupDir.appendingPathComponent("report.pdf"), bytes: 2 * mb, fill: 7)
write(dupDir.appendingPathComponent("report (1).pdf"), bytes: 2 * mb, fill: 7)
write(path("Downloads/report.pdf"), bytes: 2 * mb, fill: 7)
try! fm.linkItem(at: dupDir.appendingPathComponent("report.pdf"), to: dupDir.appendingPathComponent("hardlink.pdf"))
// 头尾相同、只有中间不同：只有全文哈希能分开
var head = Data(repeating: 9, count: 3 * mb); head[mb + 5] = 1
var other = Data(repeating: 9, count: 3 * mb); other[mb + 5] = 2
try! head.write(to: dupDir.appendingPathComponent("mid-a.bin"))
try! other.write(to: dupDir.appendingPathComponent("mid-b.bin"))
write(dupDir.appendingPathComponent("small-a.bin"), bytes: 100, fill: 3)
write(dupDir.appendingPathComponent("small-b.bin"), bytes: 100, fill: 3)

let dups = FileScanner.duplicates(minBytes: Int64(mb))
// 临时目录在 /var 下，枚举出来的路径可能多一个 /private 前缀，所以按 "/home/" 截取相对路径
let dupNames = Set(dups.map { $0.url.path.components(separatedBy: "/home/").last ?? $0.url.path })
check("同内容的副本被找到", dupNames.contains("Documents/dups/report (1).pdf"), "\(dupNames)")
check("下载目录那份算副本", dupNames.contains("Downloads/report.pdf"), "\(dupNames)")
check("保留名字最短且不在下载目录的那份", !dupNames.contains("Documents/dups/report.pdf"), "\(dupNames)")
check("硬链接不算重复", !dupNames.contains("Documents/dups/hardlink.pdf"), "\(dupNames)")
check("正好列出两个副本", dupNames.count == 2, "\(dupNames)")
check("头尾相同、中间不同的不算重复", !dupNames.contains { $0.contains("mid-") }, "\(dupNames)")
check("小于阈值的不算", !dupNames.contains { $0.contains("small-") })
check("每份都记下了保留的路径", dups.allSatisfy { $0.keeperPath?.hasSuffix("/report.pdf") == true })

section("哈希：读取出错必须返回 nil")
let realDigest = FileScanner.sha256(of: dupDir.appendingPathComponent("report.pdf"))
check("正常文件有结果", realDigest != nil)
check("读目录（read 必定报 EISDIR）返回 nil", FileScanner.sha256(of: dupDir) == nil)
check("实际长度和预期不符返回 nil", FileScanner.sha256(of: dupDir.appendingPathComponent("report.pdf"), expectedSize: 1) == nil)
check("文件不存在返回 nil", FileScanner.sha256(of: path("nope")) == nil)
check("和 CLI 的 shasum 结果一致", {
    guard let digest = realDigest else { return false }
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    let out = runCommand("/usr/bin/shasum", ["-a", "256", dupDir.appendingPathComponent("report.pdf").path])
    return out.hasPrefix(hex)
}())

// MARK: - 类型识别

section("类型识别")
func coarse(_ name: String) -> String {
    let url = path("types/\(name)"); write(url, bytes: 16)
    return FileClassifier.coarseType(of: FileItem(url: url, size: 16, modified: Date(), isDirectory: false))
}
check("mp3 是音频", coarse("a.mp3") == "音频", coarse("a.mp3"))
check("flac 是音频", coarse("a.flac") == "音频", coarse("a.flac"))
check("mp4 是视频", coarse("a.mp4") == "视频", coarse("a.mp4"))
check("mov 是视频", coarse("a.mov") == "视频", coarse("a.mov"))
check("png 是图片", coarse("a.png") == "图片", coarse("a.png"))
check("dmg 是磁盘镜像", coarse("a.dmg") == "磁盘镜像", coarse("a.dmg"))
check("zip 是压缩包", coarse("a.zip") == "压缩包", coarse("a.zip"))
check("微信 flac 归音频", WeChatScanner.bucket(for: URL(fileURLWithPath: "/x/a.flac"), contentType: UTType(filenameExtension: "flac")) == "音频")
check("微信 webm 归视频", WeChatScanner.bucket(for: URL(fileURLWithPath: "/x/a.webm"), contentType: UTType.movie) == "视频")
check("~/Documents/Movies/x 属于文稿", FileClassifier.rootFolderCN(for: path("Documents/Movies/x.mov")) == "文稿")
check("~/Movies/Documents/x 属于影片", FileClassifier.rootFolderCN(for: path("Movies/Documents/x.mov")) == "影片")
check("~/其他/x 是个人目录", FileClassifier.rootFolderCN(for: path("Other/x")) == "个人目录")

// MARK: - 下载旧文件

section("下载目录旧文件")
let longAgo = Date().addingTimeInterval(-200 * 86_400)
let dl = path("Downloads")
write(dl.appendingPathComponent("project/edited-today.txt"))
makeOld(dl.appendingPathComponent("project"), longAgo)
try! fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dl.appendingPathComponent("project/edited-today.txt").path)

write(dl.appendingPathComponent("fresh-download.dmg"))                 // 刚下载，修改时间却是服务器上的旧日期
try! fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: dl.appendingPathComponent("fresh-download.dmg").path)

write(dl.appendingPathComponent("really-old.zip"))
makeOld(dl.appendingPathComponent("really-old.zip"), longAgo)

write(dl.appendingPathComponent("old-folder/inner.txt"))
makeOld(dl.appendingPathComponent("old-folder/inner.txt"), longAgo)
makeOld(dl.appendingPathComponent("old-folder"), longAgo)

write(dl.appendingPathComponent(".DS_Store"))
makeOld(dl.appendingPathComponent(".DS_Store"), longAgo)

let oldNames = Set(FileScanner.oldEntries(in: dl, olderThanDays: 90).map(\.name))
check("真正的旧文件被列出", oldNames.contains("really-old.zip"), "\(oldNames)")
check("真正的旧文件夹被列出", oldNames.contains("old-folder"), "\(oldNames)")
check("里面有新改动的文件夹不算旧", !oldNames.contains("project"), "\(oldNames)")
check("刚下载的文件不算旧", !oldNames.contains("fresh-download.dmg"), "\(oldNames)")
check(".DS_Store 不列出", !oldNames.contains(".DS_Store"), "\(oldNames)")

// MARK: - 权限

section("目录权限判断")
check("/var/root 读不了 → 判为被拒", FileScanner.isAccessDenied(URL(fileURLWithPath: "/var/root")))
check("不存在的目录 → 不算被拒", !FileScanner.isAccessDenied(path("does-not-exist")))
check("能读的目录 → 不算被拒", !FileScanner.isAccessDenied(path("Documents")))

// MARK: - 清理计划

section("清理计划：跨分类去重")
func item(_ sub: String, size: Int64 = 100, dir: Bool = false, keeper: String? = nil) -> FileItem {
    FileItem(url: path(sub), size: size, modified: Date(), isDirectory: dir, keeperPath: keeper)
}
let keeperOnDisk = path("Documents/keeper.bin"); write(keeperOnDisk)

var plan = CleanPlanner.plan(selected: [item("Library/Caches/com.a", dir: true), item("Library/Caches/com.a", dir: true)])
check("同一路径出现在两个分类只算一次", plan.items.count == 1, "\(plan.items.map(\.path))")

plan = CleanPlanner.plan(selected: [item("Downloads/folder/big.mov", size: 50), item("Downloads/folder", size: 80, dir: true)])
check("父目录也被选中时不再单独处理子文件", plan.items.map(\.name) == ["folder"], "\(plan.items.map(\.name))")

plan = CleanPlanner.plan(selected: [item("Downloads/folder", size: 80, dir: true), item("Downloads/folder2/big.mov", size: 50)])
check("前缀相同的兄弟目录不受影响", plan.items.count == 2, "\(plan.items.map(\.name))")

plan = CleanPlanner.plan(selected: [item("Documents/keeper.bin", size: 9), item("Downloads/copy.bin", keeper: keeperOnDisk.path)])
check("保留的那份也被选中时，副本不动", plan.items.map(\.name) == ["keeper.bin"] && plan.keptForSafety == 1, "\(plan.items.map(\.name))")

plan = CleanPlanner.plan(selected: [item("Documents", dir: true), item("Downloads/copy.bin", keeper: keeperOnDisk.path)])
check("保留的那份所在目录被选中时，副本不动", plan.keptForSafety == 1)

plan = CleanPlanner.plan(selected: [item("Downloads/copy.bin", keeper: path("Documents/gone.bin").path)])
check("保留的那份已不在时，副本不动", plan.items.isEmpty && plan.keptForSafety == 1)

plan = CleanPlanner.plan(selected: [item("Downloads/copy.bin", keeper: keeperOnDisk.path)])
check("正常情况副本可以清理", plan.items.count == 1 && plan.keptForSafety == 0)

section("清理动作")
let trashed = path(".Trash/throwaway"); write(trashed)
if case .deleted = ScanEngine.remove(trashed) { check("废纸篓里的文件被永久删除", !fm.fileExists(atPath: trashed.path)) }
else { check("废纸篓里的文件被永久删除", false) }
for protected in [path("Documents"), path("Library/Application Support"), home] {
    if case .failed = ScanEngine.remove(protected) { check("拒绝清理 \(protected.lastPathComponent)", fm.fileExists(atPath: protected.path)) }
    else { check("拒绝清理 \(protected.lastPathComponent)", false) }
}

// MARK: - 管理员移动（用不提权的 osascript 跑同一份脚本）

section("管理员移动脚本")
let adminSrc = path("adminsrc"); let adminTrash = path("admintrash"); mkdir(adminTrash)
let weirdNames = ["a b'c.app", "中文 \"引号\".txt", "back\\slash.txt", "dollar$(touch pwned).txt", "line\nbreak.txt", "*.txt"]
var adminURLs = weirdNames.map { adminSrc.appendingPathComponent($0) }
for url in adminURLs { write(url) }
// 同批同名、大小写不同也算同名
write(adminSrc.appendingPathComponent("sub1/same.txt"), fill: 1)
write(adminSrc.appendingPathComponent("sub2/same.txt"), fill: 2)
write(adminSrc.appendingPathComponent("sub3/SAME.txt"), fill: 3)
adminURLs += ["sub1/same.txt", "sub2/same.txt", "sub3/SAME.txt"].map { adminSrc.appendingPathComponent($0) }
// 废纸篓里已有同名目录：mv 不能把东西塞进去
write(adminSrc.appendingPathComponent("exists.app"))
mkdir(adminTrash.appendingPathComponent("exists.app"))
write(adminTrash.appendingPathComponent("exists.app/already-here"))
adminURLs.append(adminSrc.appendingPathComponent("exists.app"))
let missing = adminSrc.appendingPathComponent("no-such-file")
adminURLs.append(missing)

let moves = AdminTrash.plan(adminURLs, in: adminTrash)
let shell = AdminTrash.shellScript(moves, uid: getuid(), gid: getgid())
check("脚本只调用一次 osascript（一次授权）", AdminTrash.appleScript(shell: shell, admin: true).components(separatedBy: "do shell script").count == 2)
check("提权版带 administrator privileges", AdminTrash.appleScript(shell: shell, admin: true).contains("with administrator privileges"))
let adminResult = AdminTrash.run(moves, script: AdminTrash.appleScript(shell: shell, admin: false))
check("存在的项目全部搬走", adminResult.trashed.count == adminURLs.count - 1, "搬走 \(adminResult.trashed.count)，失败 \(adminResult.failures)")
check("不存在的项目报失败", adminResult.failures.count == 1 && adminResult.failures[0].0 == missing, "\(adminResult.failures)")
check("源文件都不在了", adminURLs.allSatisfy { !fm.fileExists(atPath: $0.path) })
let trashContents = (try? fm.contentsOfDirectory(atPath: adminTrash.path)) ?? []
check("废纸篓里数量正确", trashContents.count == adminURLs.count, "\(trashContents.count) 个：\(trashContents)")
check("同名文件没有互相覆盖", trashContents.filter { $0.lowercased().hasPrefix("same") }.count == 3, "\(trashContents)")
check("没有被塞进已存在的同名目录", (try? fm.contentsOfDirectory(atPath: adminTrash.appendingPathComponent("exists.app").path)) == ["already-here"])
check("文件名里的命令没有被执行", !fm.fileExists(atPath: path("pwned").path) && !fm.fileExists(atPath: "pwned"))

// MARK: - 系统信息

section("进程枚举")
let pids = DiskIOScanner.allPIDs()
let psCount = runCommand("/bin/ps", ["-ax", "-o", "pid="]).split(separator: "\n").count
check("和 ps 看到的进程数基本一致", abs(pids.count - psCount) < 50, "allPIDs=\(pids.count) ps=\(psCount)")
check("包含自己", pids.contains(getpid()))
let start = Date()
let readers = DiskIOScanner.topReaders()
print("  信息  topReaders 用时 \(String(format: "%.2f", Date().timeIntervalSince(start))) 秒，列出 \(readers.count) 项")

section("进程归属")
let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
check("helper 归到最外层 App", ProcessNames.outermostApp(in: chromeHelper) == "/Applications/Google Chrome.app", "\(String(describing: ProcessNames.outermostApp(in: chromeHelper)))")
check("中文 App 路径不被转义", ProcessNames.outermostApp(in: "/Applications/微信.app/Contents/MacOS/WeChat") == "/Applications/微信.app")
check("App 内的 XPC 服务也归到 App", ProcessNames.outermostApp(in: "/Applications/Foo.app/Contents/XPCServices/x.xpc/Contents/MacOS/x") == "/Applications/Foo.app")
check("命令行工具不属于任何 App", ProcessNames.outermostApp(in: "/usr/libexec/rapportd") == nil)
check("名字里带 .app 字样的目录不会误判", ProcessNames.outermostApp(in: "/opt/my.apple/bin/tool") == nil)
check("取到自己的真实路径", ProcessNames.executablePath(pid: getpid()) == Bundle.main.executablePath || ProcessNames.executablePath(pid: getpid())?.hasSuffix("/tests") == true, "\(String(describing: ProcessNames.executablePath(pid: getpid())))")
check("不存在的进程返回 nil", ProcessNames().resolve(pid: 999_999) == nil)
print("  信息  系统透视前 8 名：\(readers.prefix(8).map(\.name))")
let helperRows = (readers.map(\.name) + NetworkScanner.topUploaders().map(\.name)).filter { $0.contains(" Helper") }
print("  信息  仍带 Helper 字样的行：\(helperRows)")

section("电池解析")
let thisMacShape: [String: Any] = [   // Mac16,5 + macOS 27 上的真实结构
    "CurrentCapacity": 100, "MaxCapacity": 100, "CycleCount": 34, "IsCharging": false, "ExternalConnected": true,
    "BatteryData": ["DesignCapacity": 8579, "NominalChargeCapacity": 7683, "AppleRawMaxCapacity": 7439],
]
let parsed = BatteryReader.parse(thisMacShape)
check("键在 BatteryData 子字典里也能读到", parsed != nil)
check("健康度 90%（和系统设置一致）", parsed?.healthPercent == 90, "\(String(describing: parsed?.healthPercent))")
check("满电容量取 Nominal", parsed?.maxCapacity == 7683)
check("当前电量 100%", parsed?.charge == 100)
let intel = BatteryReader.parse(["CurrentCapacity": 3000, "MaxCapacity": 4000, "DesignCapacity": 5000, "CycleCount": 300] as [String: Any])
check("Intel：健康度按 mAh 算", intel?.healthPercent == 80, "\(String(describing: intel?.healthPercent))")
check("Intel：当前电量换算成百分比", intel?.charge == 75, "\(String(describing: intel?.charge))")
let older = BatteryReader.parse(["CurrentCapacity": 50, "MaxCapacity": 100, "DesignCapacity": 5000, "AppleRawMaxCapacity": 4000] as [String: Any])
check("旧版 Apple 芯片结构", older?.healthPercent == 80 && older?.charge == 50)
check("缺设计容量返回 nil", BatteryReader.parse(["CurrentCapacity": 50] as [String: Any]) == nil)
func condition(_ health: Int) -> String {
    BatteryInfo(cycleCount: 0, healthPercent: health, maxCapacity: 0, designCapacity: 0, charge: 0, charging: false, acConnected: false).condition
}
check("健康度越低提示越急", condition(90) == "正常" && condition(70) == "建议更换" && condition(50) == "建议尽快更换")
if case .info(let live) = BatteryReader.read() {
    let reported = runCommand("/usr/sbin/system_profiler", ["SPPowerDataType"], timeout: 30)
    let systemValue = reported.components(separatedBy: "Maximum Capacity: ").dropFirst().first?.prefix { $0.isNumber }
    print("  信息  本机读数 \(live.healthPercent)%，系统报告 \(systemValue.map(String.init) ?? "?")%")
    if let systemValue, let value = Int(systemValue) { check("本机读数和系统报告一致", abs(live.healthPercent - value) <= 1, "\(live.healthPercent) vs \(value)") }
}

section("蓝牙状态")
let bt = BluetoothScanner.scan()
print("  信息  powered=\(String(describing: bt.powered))，设备 \(bt.devices.count) 个")
check("读到了状态", bt.powered != nil)

section("网络上传")
let uploaders = NetworkScanner.topUploaders()
print("  信息  列出 \(uploaders.count) 项")
check("能解析 nettop", !uploaders.isEmpty)

// MARK: - 残留判定算法：优化后结果必须和原算法完全一致

section("残留判定：新旧算法对照（真实 lsregister 数据）")
func oldIsInstalled(_ id: String, _ installed: Set<String>) -> Bool {
    let l = id.lowercased()
    if installed.contains(l) { return true }
    for inst in installed {
        if inst.hasPrefix(l + ".") || l.hasPrefix(inst + ".") { return true }
    }
    let parts = l.split(separator: ".")
    guard parts.count >= 3 else { return false }
    if parts.count >= 4 {
        let ancestor = parts.prefix(3).joined(separator: ".")
        if installed.contains(where: { $0 == ancestor || $0.hasPrefix(ancestor + ".") }) { return true }
    }
    let vendor = parts.prefix(2).joined(separator: ".")
    if !LeftoverScanner.multiTenantRoots.contains(vendor),
       installed.contains(where: { $0.hasPrefix(vendor + ".") }) { return true }
    return false
}
let lsStart = Date()
let installed = LeftoverScanner.lsregisterIDs()
print("  信息  lsregister 解析出 \(installed.count) 个 id，用时 \(String(format: "%.2f", Date().timeIntervalSince(lsStart))) 秒")
check("清单数量合理", installed.count >= 50)
check("uppercase 的 id 也能解析", LeftoverScanner.parseIdentifiers("   identifier:   COM.Foo.Bar  \nother: x\nidentifier:  has space here\n") == ["com.foo.bar"])

var probes = Array(installed)
for id in installed.prefix(400) {
    probes.append(id + ".helper")
    probes.append(id + ".helper.extra")
    probes.append(id + "x")
    probes.append(String(id.dropLast()))
    let parts = id.split(separator: ".")
    if parts.count >= 2 {
        probes.append(parts.prefix(2).joined(separator: "."))
        probes.append(parts.prefix(2).joined(separator: ".") + ".unrelated.tool")
        probes.append("zz" + parts.prefix(2).joined(separator: ".") + ".unrelated.tool")
    }
    if parts.count >= 3 { probes.append(parts.prefix(3).joined(separator: ".") + ".sub.component") }
}
probes += ["com.github.foo.bar", "io.github.someone.tool", "jp.co.x.y", "not.installed.at.all", "COM.APPLE.SAFARI", "a.b.c", "x"]

let index = LeftoverScanner.InstalledIndex(installed)
let newStart = Date()
let newResults = probes.map { index.contains($0) }
let newTime = Date().timeIntervalSince(newStart)
let oldProbes = Array(probes.prefix(3000))
let oldStart = Date()
let oldResults = oldProbes.map { oldIsInstalled($0, installed) }
let oldTime = Date().timeIntervalSince(oldStart)
let mismatches = oldProbes.indices.filter { oldResults[$0] != newResults[$0] }
check("\(oldProbes.count) 个 id 判定结果完全一致", mismatches.isEmpty, "\(mismatches.prefix(5).map { oldProbes[$0] })")
print("  信息  同样 \(oldProbes.count) 个判定：旧算法 \(String(format: "%.0f", oldTime * 1000)) 毫秒，新算法约 \(String(format: "%.1f", newTime * 1000 * Double(oldProbes.count) / Double(probes.count))) 毫秒")

// MARK: - 微信目录

section("微信数据目录")
let xwechat = path("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_x/msg/video")
write(xwechat.appendingPathComponent("v.mp4"), bytes: 4096)
let legacy = path("Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat/old")
write(legacy.appendingPathComponent("o.jpg"), bytes: 4096)
let oldContainer = path("Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat")
mkdir(oldContainer.deletingLastPathComponent())
try! fm.createSymbolicLink(at: path("Library/Application Support/com.tencent.xinWeChat"), withDestinationURL: legacy.deletingLastPathComponent())
let probed = WeChatScanner.probe()
check("扫到微信 4.x 的 xwechat_files", probed.roots.contains { $0.path.hasSuffix("xwechat_files") }, "\(probed.roots)")
check("符号链接指向同一目录时只算一次", probed.roots.count == 2, "\(probed.roots.map(\.lastPathComponent))")
let wechat = WeChatScanner.scan()
check("视频和图片都统计到", wechat.buckets.map(\.label).sorted() == ["图片", "视频"].sorted(), "\(wechat.buckets.map(\.label))")
check("没有重复计数", wechat.buckets.reduce(0) { $0 + $1.count } == 2, "\(wechat.buckets.map(\.count))")

// MARK: - 系统命令

section("系统命令")
let sleepStart = Date()
let killed = runProcess("/bin/sleep", ["30"], timeout: 1)
check("超时会被杀掉", Date().timeIntervalSince(sleepStart) < 5 && killed?.status != 0, "\(Date().timeIntervalSince(sleepStart)) 秒")
let bigFile = path("big.txt"); write(bigFile, bytes: 512 * 1024)
check("超过管道缓冲的输出不会卡死", runProcess("/bin/cat", [bigFile.path], timeout: 10)?.output.count == 512 * 1024)
check("命令不存在返回 nil", runProcess("/no/such/cmd", []) == nil)

print("\n结果：通过 \(passed)，失败 \(failed)")
exit(failed == 0 ? 0 : 1)
