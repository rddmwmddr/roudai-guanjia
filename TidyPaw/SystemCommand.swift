import Foundation

/// 跑一个系统命令并等它结束，返回 stdout 和退出码；stderr 丢弃。
/// 超时先发 SIGTERM，还不退就 SIGKILL，避免 nettop 这类流式命令把任务永远卡住。
/// 被杀掉时退出码非 0，调用方可据此丢弃半截输出。
func runProcess(_ path: String, _ args: [String], timeout: TimeInterval = 12) -> (output: Data, status: Int32)? {
    guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }

    var alreadyAskedToQuit = false
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + timeout, repeating: 3)
    watchdog.setEventHandler {
        guard process.isRunning else { return }
        if alreadyAskedToQuit {
            kill(process.processIdentifier, SIGKILL)
        } else {
            alreadyAskedToQuit = true
            process.terminate()
        }
    }
    watchdog.resume()
    defer { watchdog.cancel() }

    // 必须先读完再 wait：输出超过管道缓冲（约 64 KB）时，反过来会互相等死
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (output, process.terminationStatus)
}

func runCommand(_ path: String, _ args: [String], timeout: TimeInterval = 12) -> String {
    guard let result = runProcess(path, args, timeout: timeout) else { return "" }
    return String(decoding: result.output, as: UTF8.self)
}
