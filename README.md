# 肉呆大管家

一个原生 SwiftUI 的 macOS 系统管家：既能扫描清理电脑里不用的东西（缓存、日志、Xcode 编译产物、旧文件、重复文件…），又能把任意 App 连同它的全部残留一起干净卸载。通用二进制（Intel + Apple Silicon），兼容 macOS 13 及以上；在 macOS 26+ 上采用「液态玻璃」(Liquid Glass) 设计，旧系统自动回退到材质。

两大模式：

- **磁盘清理** — 按分类扫描可清理项，分级勾选、移废纸篓可恢复。
- **拖拽卸载** — 拖入一个 App，揪出它在 ~/Library、系统级目录和安装收据里的全部残留，按「精确匹配 / 可能相关 / 高风险」分级，逐项确认后移到废纸篓（系统项支持管理员授权移动并自动把所有权交还给你）。

## 设计原则：安全第一

- **默认移到废纸篓，可恢复**：除「废纸篓」分类本身是永久清空外，其余所有清理都走 `trashItem`，绝不直接 `rm`。
- **分级勾选**：缓存/日志这类「可放心清理」的项目扫描后默认勾选；你的个人文件、Xcode 归档等「建议先确认」的项目默认不勾选，需手动选择。
- **只扫已知的垃圾位置**，不会乱翻 `~/Library/Application Support`、钥匙串、iCloud 等敏感目录。
- 清理前有二次确认弹窗，清理后给出释放空间汇总。

## 扫描分类

| 分类 | 路径 | 安全等级 |
|---|---|---|
| 用户缓存 | `~/Library/Caches` | 可放心清理 |
| 应用日志 | `~/Library/Logs` | 可放心清理 |
| Xcode 编译缓存 | `~/Library/Developer/Xcode/DerivedData` | 可放心清理 |
| Xcode 设备支持 | `~/Library/Developer/Xcode/*DeviceSupport` | 可放心清理 |
| Xcode 归档 | `~/Library/Developer/Xcode/Archives` | 建议先确认 |
| 废纸篓 | `~/.Trash`（永久清空） | 建议先确认 |
| 下载目录旧文件 | `~/Downloads` 中 >90 天未改的 | 建议先确认 |
| 大文件 | 个人目录中 >200 MB 的文件 | 建议先确认 |
| 重复文件 | 桌面/文稿/下载中内容相同的文件（保留一份，SHA-256 校验） | 建议先确认 |
| 卸载残留 | 已卸载应用在 ~/Library 留下的缓存/偏好/数据残留 | 建议先确认 |

## 每个文件都告诉你「是什么 / 哪来的」

- **类型识别**：用 `UTType` 从磁盘真实读取类型，给出中文标签（视频/图片/磁盘镜像/安装包/代码/缓存数据…）。
- **用途/来源**：结合所在分类 + 名字解析说明它大概是干嘛的，例如：
  - 缓存里的 `com.apple.Safari` → 「Safari 的缓存数据，清掉后会自动重建」
  - DerivedData 里的 `HuamiaoMath-xxxx` → 「Xcode 工程「HuamiaoMath」的编译中间产物」
  - bundle id 解析优先取本地化显示名（中文/emoji 名，如「🐷➕🪡检查器」「微信」）

## 文件定位

- 每个文件行**右键**：在访达中显示 / 拷贝路径
- **双击**文件行：直接在访达里高亮定位它
- 悬停看完整路径

## 「卸载残留」是怎么做到安全的

这是最容易误判的功能，因此做得很保守（规则在真机上实测过）：

- 用 `lsregister` 拿到**权威的已安装应用清单**（~1600 个 id），拿不到就直接放弃、不猜
- 只认 **3 段以上的反向 DNS bundle id**，排除 UUID、裸名、`.sock/.store/.dat/.log` 等运行产物
- **否定名单**：`com.apple.*` 系统服务、内嵌浏览器框架、更新器、崩溃/统计 SDK（Bugly/Bugsnag/Firebase/Sentry…）一律不标记
- **双向父子 + 同产品祖先匹配**：已安装应用的 helper/子组件不会被误判
- **输入法**单独补进已安装集合（它们不在 lsregister 应用清单里）
- 结果全部**默认不勾选**，逐项可在访达查看，清理走**废纸篓可恢复**

## 运行

用 Xcode 打开 `TidyPaw.xcodeproj`，选中 `TidyPaw` scheme，⌘R 运行即可（首次会以「本地签名」运行）。

> 若有项目提示无法清理，去「系统设置 › 隐私与安全性 › 完全磁盘访问权限」里把肉呆大管家加上，
> 它才能读到其它 App 写在 Caches/Logs 里的文件。

## 工程结构

```
TidyPaw/
├── TidyPawApp.swift     # App 入口
├── Models.swift         # 数据模型（分类、文件条目、风险等级）
├── FileScanner.swift    # 纯函数式扫描器（体积计算 / 大文件 / 重复文件哈希）
├── FileClassifier.swift # 类型识别 + 用途/来源说明（UTType + bundle id → 应用名）
├── LeftoverScanner.swift# 卸载残留检测（保守、lsregister 权威清单 + 多重过滤）
├── ScanEngine.swift     # 协调扫描、磁盘信息、安全清理
├── ContentView.swift    # 主界面（侧边栏 / 磁盘条 / 底部栏）
├── DetailViews.swift    # 分类详情、文件行、文件定位、欢迎页
├── GlassStyles.swift    # 液态玻璃设计系统（品牌色 + 26+ glass / 旧系统材质回退）
├── ScanningAnimation.swift # 扫描动画（纯 SwiftUI 涟漪/脉动，无 Timer）
├── UninstallScanner.swift  # 拖拽卸载：扫描某 App 的全部残留（分级 + 管理员标记）
├── UninstallEngine.swift   # 卸载流程（两步确认 / 退出运行中App / 移废纸篓 / 管理员授权）
├── UninstallView.swift     # 拖拽卸载界面（拖拽区 + 候选列表）
└── Assets.xcassets      # 应用图标（蓝色管家：钥匙 + 清单 + 扫帚 + 闪光）
```

## 后续可以加

- 菜单栏常驻 + 磁盘空间监控
- 清理前自动快照大小、清理历史记录
- 自定义大文件阈值 / 旧文件天数
- Sparkle 自动更新
