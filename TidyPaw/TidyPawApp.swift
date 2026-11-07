import SwiftUI

@main
struct TidyPawApp: App {
    var body: some Scene {
        // 单窗口场景：扫描状态都放在 ContentView 里，开第二个窗口只会得到一套互相不同步的状态；
        // 用 Window 还能保证关掉窗口时 App 一起退出，不会变成无窗口的空壳
        Window("肉呆大管家", id: "main") {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }  // 这是工具类应用，去掉「新建窗口」
        }
    }
}
