import Foundation

/// 拉起 `node engine/index.js --watch` 并按行消费它的 stdout。
///
/// 设计要点：
///   - 所有可变状态只在 `queue` 上碰，回调再跳回主线程，满足 Swift 6 严格并发。
///   - 子进程死了自动重启，带指数退避 —— 不能疯狂重启把 CPU 打满。
///   - app 退出必须杀干净，不留孤儿 node 进程。
final class ChildRunner: @unchecked Sendable {

    /// 收到一行完整 NDJSON
    private let onLine: @Sendable (String) -> Void
    /// 连接状态变化（子进程活着 = true）
    private let onConnected: @Sendable (Bool) -> Void

    private let queue = DispatchQueue(label: "local.claude.taskmonitor.engine")

    // 以下全部只在 queue 上访问
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var buffer = Data()
    private var stopped = false
    private var backoff: TimeInterval = 1
    private var sawLineThisRun = false

    private let maxBackoff: TimeInterval = 30
    /// 单行上限，防止畸形输出把内存吃光
    private let maxLineBytes = 4 * 1024 * 1024

    init(
        onLine: @escaping @Sendable (String) -> Void,
        onConnected: @escaping @Sendable (Bool) -> Void
    ) {
        self.onLine = onLine
        self.onConnected = onConnected
    }

    // MARK: - 生命周期

    func start() {
        queue.async { [self] in
            stopped = false
            backoff = 1
            spawn()
        }
    }

    func stop() {
        // ★ 同步执行：app 退出时必须确保子进程真的被杀掉，
        //   异步派发会来不及跑完，留下孤儿 node。
        queue.sync { [self] in
            stopped = true
            teardown()
        }
    }

    // MARK: - 拉起

    private func spawn() {
        guard !stopped else { return }

        guard let node = Self.resolveNode() else {
            FileHandle.standardError.write(Data(
                "[runner] 找不到 node。装了 node 的话可用 CLAUDE_MONITOR_NODE 指定绝对路径。\n".utf8))
            notifyConnected(false)
            scheduleRestart()
            return
        }
        guard let engine = Self.resolveEngine() else {
            FileHandle.standardError.write(Data(
                "[runner] 找不到 engine/index.js。可用 CLAUDE_MONITOR_ENGINE 指定绝对路径。\n".utf8))
            notifyConnected(false)
            scheduleRestart()
            return
        }

        let p = Process()
        p.executableURL = node
        p.arguments = [engine.path, "--watch"]
        p.currentDirectoryURL = engine.deletingLastPathComponent()

        // GUI 启动的 .app 拿到的 PATH 极简（不含 /opt/homebrew/bin），
        // 补上 node 自己所在目录，否则 node 起的子工具会找不到。
        var env = ProcessInfo.processInfo.environment
        let nodeDir = node.deletingLastPathComponent().path
        env["PATH"] = ([nodeDir] + (env["PATH"]?.split(separator: ":").map(String.init) ?? [])
                        + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
                        .reduce(into: [String]()) { acc, x in if !acc.contains(x) { acc.append(x) } }
                        .joined(separator: ":")
        p.environment = env

        let outPipe = Pipe()
        p.standardOutput = outPipe
        // engine 的日志走 stderr，直接转到我们自己的 stderr，方便终端里排查
        p.standardError = FileHandle.standardError

        buffer.removeAll(keepingCapacity: true)
        sawLineThisRun = false

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard let self else { return }
            self.queue.async { self.consume(chunk) }
        }

        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async {
                FileHandle.standardError.write(Data(
                    "[runner] engine 退出 status=\(proc.terminationStatus)\n".utf8))
                self.notifyConnected(false)
                self.cleanupPipe()
                self.scheduleRestart()
            }
        }

        do {
            try p.run()
            process = p
            stdoutPipe = outPipe
        } catch {
            FileHandle.standardError.write(Data("[runner] 启动失败: \(error)\n".utf8))
            notifyConnected(false)
            scheduleRestart()
        }
    }

    // MARK: - 按行切分

    private func consume(_ chunk: Data) {
        guard !stopped else { return }
        if chunk.isEmpty { return }   // EOF，交给 terminationHandler 处理

        buffer.append(chunk)

        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !lineData.isEmpty else { continue }
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if !sawLineThisRun {
                sawLineThisRun = true
                backoff = 1              // 拿到有效数据才算这次启动成功，重置退避
                notifyConnected(true)
            }
            let cb = onLine
            DispatchQueue.main.async { cb(trimmed) }
        }

        // 半行超过上限说明对端在吐垃圾，丢掉重来，别把内存撑爆
        if buffer.count > maxLineBytes {
            FileHandle.standardError.write(Data("[runner] 单行超限，丢弃缓冲\n".utf8))
            buffer.removeAll(keepingCapacity: false)
        }
    }

    // MARK: - 重启与清理

    private func scheduleRestart() {
        guard !stopped else { return }
        let delay = backoff
        backoff = min(backoff * 2, maxBackoff)
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard !stopped else { return }
            spawn()
        }
    }

    private func cleanupPipe() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        process = nil
    }

    private func teardown() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        if let p = process, p.isRunning {
            p.terminationHandler = nil    // 主动杀，别再触发重启
            p.terminate()                 // SIGTERM，engine 里已经挂了处理器会干净退出
            // 给一点点时间优雅退出，赖着不走就 SIGKILL
            let deadline = Date().addingTimeInterval(1.0)
            while p.isRunning && Date() < deadline {
                usleep(20_000)
            }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        stdoutPipe = nil
        process = nil
    }

    private func notifyConnected(_ connected: Bool) {
        let cb = onConnected
        DispatchQueue.main.async { cb(connected) }
    }

    // MARK: - 路径解析

    /// GUI 启动的 .app 继承的 PATH 里通常没有 /opt/homebrew/bin，
    /// 所以不能指望 `/usr/bin/env node`，必须挨个探。
    static func resolveNode() -> URL? {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_MONITOR_NODE"] {
            let u = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/node",      // Apple Silicon Homebrew
            "/usr/local/bin/node",         // Intel Homebrew / 官方 pkg
            "/usr/bin/node",
            "\(home)/.local/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.asdf/shims/node",
            "/opt/local/bin/node",         // MacPorts
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        // 兜底：nvm 装的 node 版本号不固定，扫一遍取第一个
        let nvm = "\(home)/.nvm/versions/node"
        if let vers = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for v in vers.sorted().reversed() {
                let p = "\(nvm)/\(v)/bin/node"
                if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
            }
        }
        return nil
    }

    /// engine/index.js 的位置。
    /// 正常情况 .app 在 <项目根>/build/ 下，engine 在 <项目根>/engine/。
    /// 也兼容直接跑 .build/release/ 里的裸可执行文件。
    static func resolveEngine() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["CLAUDE_MONITOR_ENGINE"] {
            let u = URL(fileURLWithPath: override)
            if fm.fileExists(atPath: u.path) { return u }
        }

        var roots: [URL] = []
        // .app bundle 自身
        roots.append(Bundle.main.bundleURL)
        // 可执行文件所在目录（裸跑时）
        if let exe = Bundle.main.executableURL { roots.append(exe.deletingLastPathComponent()) }

        for root in roots {
            var dir = root
            // 逐级上溯找 engine/index.js，最多 6 层，够覆盖
            // build/X.app -> build -> 根，以及 .build/release -> .build -> app -> 根
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("engine/index.js")
                if fm.fileExists(atPath: candidate.path) { return candidate }
                dir = dir.deletingLastPathComponent()
                if dir.path == "/" { break }
            }
        }
        return nil
    }
}
