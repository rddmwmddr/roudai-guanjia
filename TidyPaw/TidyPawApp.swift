import SwiftUI

@main
struct TidyPawApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }  // 这是工具类应用，去掉「新建窗口」
        }
    }
}
