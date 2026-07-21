import Foundation
import Combine

/// 会话状态仓库。
///
/// 数据来源：`ChildRunner` 拉起 `node engine/index.js --watch`，
/// 每行 NDJSON 经 `ingest(ndjsonLine:)` 进来。UI 层只认这里的 `@Published`。
@MainActor
final class SessionStore: ObservableObject {

    @Published private(set) var sessions: [SessionStatus] = []
    /// engine 子进程是否连着。断了要在 UI 上体现，否则用户会盯着一屏过期数据。
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var lastUpdate: Date = .init()

    private var tickTask: Task<Void, Never>?
    private var runner: ChildRunner?

    /// 排序：等你授权 → 等你输入 → 干活中 → 空闲；
    /// 同档内卡得越久越靠前。保证「在等我」的永远浮在最上面。
    private static func sorted(_ input: [SessionStatus]) -> [SessionStatus] {
        input.sorted { a, b in
            if a.status.sortRank != b.status.sortRank {
                return a.status.sortRank < b.status.sortRank
            }
            if a.idleSeconds != b.idleSeconds { return a.idleSeconds > b.idleSeconds }
            return a.projectName < b.projectName
        }
    }

    // MARK: - 生命周期

    func start() {
        let r = ChildRunner(
            onLine: { line in
                // ChildRunner 已经派发到主线程了，这里补 assumeIsolated 是给编译器看的
                MainActor.assumeIsolated { Self.shared?.ingest(ndjsonLine: line) }
            },
            onConnected: { connected in
                MainActor.assumeIsolated { Self.shared?.setConnected(connected) }
            }
        )
        Self.shared = self
        runner = r
        r.start()
        startTicker()
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        runner?.stop()          // 同步杀子进程，不留孤儿
        runner = nil
        Self.shared = nil
    }

    /// ChildRunner 的回调是 @Sendable 的，捞不到 self（@MainActor 隔离）。
    /// app 生命周期内只有一个 store，用一个主线程独占的弱引用做桥。
    @MainActor private static weak var shared: SessionStore?

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// 本地推进计时器。真实数据到来时 engine 会覆盖这些值，
    /// 但两次推送之间 UI 也得自己走秒，否则看着像卡死。
    private func tick() {
        guard !sessions.isEmpty else { return }
        for i in sessions.indices where sessions[i].isAlive {
            sessions[i].elapsedSeconds += 1
            if sessions[i].status != .working {
                sessions[i].idleSeconds += 1
            }
        }
    }

    // MARK: - 数据接入口（下一阶段接子进程 stdout）

    /// 未读：干完活但你还没看过的会话。
    @Published private(set) var unread: Set<String> = []

    /// 整批替换。engine 每次全量推送时调这个。
    func replaceAll(_ incoming: [SessionStatus]) {
        updateUnread(incoming)
        sessions = Self.sorted(incoming)
        lastUpdate = Date()
        isConnected = true
    }

    /// 未读标记的维护。跟提示音一样，只认**跃迁**，不认当前状态。
    private func updateUnread(_ incoming: [SessionStatus]) {
        let previous = Dictionary(sessions.map { ($0.sessionId, $0.status) },
                                  uniquingKeysWith: { a, _ in a })
        var next = unread

        for s in incoming {
            // ★ 第一次见到的会话不标未读。app 重启时，那些早就跑完的会话
            //   不是"刚刚出结果"，全标上红点等于没标。
            guard let old = previous[s.sessionId] else { continue }
            if old == .working, s.status == .idle {
                next.insert(s.sessionId)          // 刚出结果
            } else if s.status != .idle {
                next.remove(s.sessionId)          // 又开始动了 = 你已经接手
            }
        }

        // 会话消失了就别留着标记，否则集合只增不减
        next.formIntersection(Set(incoming.map(\.sessionId)))
        if next != unread { unread = next }
    }

    /// 你看过了
    func markRead(_ sessionId: String) {
        guard unread.contains(sessionId) else { return }
        unread.remove(sessionId)
    }

    /// 单条 upsert。engine 增量推送时调这个。
    func upsert(_ s: SessionStatus) {
        var next = sessions
        if let idx = next.firstIndex(where: { $0.sessionId == s.sessionId }) {
            next[idx] = s
        } else {
            next.append(s)
        }
        sessions = Self.sorted(next)
        lastUpdate = Date()
        isConnected = true
    }

    func remove(sessionId: String) {
        sessions.removeAll { $0.sessionId == sessionId }
        lastUpdate = Date()
    }

    func setConnected(_ connected: Bool) {
        isConnected = connected
    }

    /// NDJSON 单行解析。engine 侧约定：
    ///   {"type":"snapshot","sessions":[...]}   全量
    ///   {"type":"update","session":{...}}      增量
    ///   {"type":"remove","sessionId":"..."}    移除
    /// 解析失败静默丢弃 —— 不能让一行畸形输出把 UI 打崩。
    func ingest(ndjsonLine line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        let dec = JSONDecoder()
        switch type {
        case "snapshot":
            guard let arr = obj["sessions"],
                  let payload = try? JSONSerialization.data(withJSONObject: arr),
                  let list = try? dec.decode([SessionStatus].self, from: payload) else { return }
            replaceAll(list)
        case "update":
            guard let one = obj["session"],
                  let payload = try? JSONSerialization.data(withJSONObject: one),
                  let s = try? dec.decode(SessionStatus.self, from: payload) else { return }
            upsert(s)
        case "remove":
            if let sid = obj["sessionId"] as? String { remove(sessionId: sid) }
        case "error":
            // engine 这一轮扫描炸了。★ 保留上一份数据不动 ——
            // 清空会让满屏真实会话瞬间变成「没有活跃会话」，是比过期数据更坏的谎。
            // 只把连接指示灯灭掉，让用户知道数据不再新鲜。
            setConnected(false)
        default:
            break  // 未知 type 忽略，向前兼容
        }
    }
}
