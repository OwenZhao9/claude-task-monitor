import Foundation
import SwiftUI

// MARK: - 会话状态枚举
//
// 下一阶段 engine 侧会以 NDJSON 的形式吐出 status 字段（字符串）。
// 这里用 rawValue 对齐，并且提供 `init(fromWire:)` 做未知值兜底，
// 保证 engine 新增状态时 app 不会解码失败直接崩。

enum SessionState: String, Codable, CaseIterable, Sendable {
    case working      // 干活中
    case needsInput   // 等你输入（Claude 问了问题在等回答）
    case needsAuth    // 等你授权（工具调用等待 permission）
    case idle         // 空闲
    case failed       // 会话报错（api_error 等）
    case dead         // 进程已不在

    /// ★ engine 侧的状态词表与这里的 rawValue **不一样**，必须显式映射。
    ///   engine: running / waiting_input / waiting_permission / idle / error / dead / unknown
    ///   这里:   working / needsInput    / needsAuth          / idle / failed / dead
    ///
    ///   早期版本直接用 `SessionState(rawValue:) ?? .idle` 兜底，结果是
    ///   engine 发来的每一个状态都匹配不上、**全部静默塌成 .idle** ——
    ///   窗口不报错、只是把所有会话画成灰色空闲，比崩溃还难发现。
    ///   所以这里既接 engine 词表，也接自身 rawValue，且未知值明确归 .idle。
    init(fromWire raw: String) {
        switch raw {
        case "running":             self = .working
        case "waiting_input":       self = .needsInput
        case "waiting_permission":  self = .needsAuth
        case "idle":                self = .idle
        case "error":               self = .failed
        case "dead":                self = .dead
        default:
            // 同时容忍本枚举自身的 rawValue（便于本地造数据 / 回放）
            self = SessionState(rawValue: raw) ?? .idle
        }
    }

    /// 是否属于「在等我说话」—— 顶栏 "N 个等你" 的计数依据
    var isWaitingOnUser: Bool {
        switch self {
        case .needsInput, .needsAuth:            return true
        case .working, .idle, .failed, .dead:    return false
        }
    }

    /// 是否需要我注意 —— 比 isWaitingOnUser 宽，多包含「报错」。
    /// 驱动窗口静息透明度：报错的会话不该在 30% 透明度下被忽略掉。
    var needsAttention: Bool {
        isWaitingOnUser || self == .failed
    }

    /// 排序权重：等授权 > 等输入 > 报错 > 干活中 > 空闲 > 已死
    var sortRank: Int {
        switch self {
        case .needsAuth:   return 0
        case .needsInput:  return 1
        case .failed:      return 2
        case .working:     return 3
        case .idle:        return 4
        case .dead:        return 5
        }
    }

    var label: String {
        switch self {
        case .working:    return "干活中"
        case .needsInput: return "等你输入"
        case .needsAuth:  return "等你授权"
        case .idle:       return "空闲"
        case .failed:     return "出错"
        case .dead:       return "已退出"
        }
    }

    /// 徽标里的符号（SF Symbols 名）
    var symbol: String {
        switch self {
        case .working:    return "bolt.horizontal.fill"
        case .needsInput: return "bubble.left.fill"
        case .needsAuth:  return "lock.open.fill"
        case .idle:       return "moon.zzz.fill"
        case .failed:     return "exclamationmark.triangle.fill"
        case .dead:       return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        // 绿：跑得好好的，不用管
        case .working:    return Color(red: 0.20, green: 0.78, blue: 0.42)
        // 橙：在等你说话
        case .needsInput: return Color(red: 1.00, green: 0.62, blue: 0.04)
        // 红：在等你点同意 —— 最刺眼
        case .needsAuth:  return Color(red: 1.00, green: 0.27, blue: 0.23)
        // 洋红：报错，和「等授权」的红拉开距离，避免误读成要点同意
        case .failed:     return Color(red: 0.91, green: 0.22, blue: 0.55)
        // 灰：没事干
        case .idle:       return Color(red: 0.55, green: 0.56, blue: 0.60)
        // 深灰：进程没了
        case .dead:       return Color(red: 0.40, green: 0.41, blue: 0.44)
        }
    }
}

// MARK: - Todo 进度

struct TodoProgress: Codable, Hashable, Sendable {
    var done: Int
    var total: Int
    /// 当前正在做的那条（对应 tasks/<n>.json 里 status == in_progress 的 activeForm/subject）
    var current: String?

    static let empty = TodoProgress(done: 0, total: 0, current: nil)

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    var isEmpty: Bool { total == 0 }
}

// MARK: - 单个会话状态
//
// ★ 字段与 engine 侧 NDJSON 一一对齐。改这里必须同步改 engine。

struct SessionStatus: Identifiable, Codable, Hashable, Sendable {
    var sessionId: String
    /// ~/.claude/sessions/<pid>.json 里的 name（如 "claude-e1"）
    var name: String
    /// jsonl 里 type == "ai-title" 那行给出的会话标题
    var title: String?
    var cwd: String
    /// cwd 的末级目录名，UI 主要显示这个
    var projectName: String

    var status: SessionState
    /// 状态的补充说明，直接显示在卡片第二行
    var statusDetail: String?

    /// 最后一次活动的时间戳（Unix 毫秒，与 sessions/*.json 的 startedAt 同单位）
    var lastActivityAt: Double
    /// 已经卡了多久（秒）—— 等待类状态的关键指标
    var idleSeconds: Double
    /// 这个会话总共跑了多久（秒）
    var elapsedSeconds: Double

    var todos: TodoProgress
    var pid: Int32
    var isAlive: Bool

    var id: String { sessionId }

    // NDJSON 里可能缺字段，给全套默认值
    enum CodingKeys: String, CodingKey {
        case sessionId, name, title, cwd, projectName
        case status, statusDetail, lastActivityAt
        case idleSeconds, elapsedSeconds, todos, pid, isAlive
    }

    init(
        sessionId: String,
        name: String,
        title: String? = nil,
        cwd: String,
        projectName: String? = nil,
        status: SessionState,
        statusDetail: String? = nil,
        lastActivityAt: Double = Date().timeIntervalSince1970 * 1000,
        idleSeconds: Double = 0,
        elapsedSeconds: Double = 0,
        todos: TodoProgress = .empty,
        pid: Int32 = -1,
        isAlive: Bool = true
    ) {
        self.sessionId = sessionId
        self.name = name
        self.title = title
        self.cwd = cwd
        self.projectName = projectName ?? (cwd as NSString).lastPathComponent
        self.status = status
        self.statusDetail = statusDetail
        self.lastActivityAt = lastActivityAt
        self.idleSeconds = idleSeconds
        self.elapsedSeconds = elapsedSeconds
        self.todos = todos
        self.pid = pid
        self.isAlive = isAlive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId      = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? UUID().uuidString
        name           = try c.decodeIfPresent(String.self, forKey: .name) ?? "claude"
        title          = try c.decodeIfPresent(String.self, forKey: .title)
        cwd            = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        projectName    = try c.decodeIfPresent(String.self, forKey: .projectName)
                         ?? (cwd as NSString).lastPathComponent
        let rawStatus  = try c.decodeIfPresent(String.self, forKey: .status) ?? "idle"
        status         = SessionState(fromWire: rawStatus)
        statusDetail   = try c.decodeIfPresent(String.self, forKey: .statusDetail)
        // ★ engine 发的是 ISO-8601 字符串（"2026-07-21T04:39:15.603Z"），不是数字。
        //   直接 decodeIfPresent(Double.self) 遇到字符串会 **抛 typeMismatch**，
        //   而 SessionStatus 是整条一起解的 —— 一个字段抛错，整条会话被丢，
        //   最终表现为窗口一片空白。所以这里两种都收。
        lastActivityAt = Self.decodeTimestamp(c, forKey: .lastActivityAt) ?? 0
        idleSeconds    = try c.decodeIfPresent(Double.self, forKey: .idleSeconds) ?? 0
        elapsedSeconds = try c.decodeIfPresent(Double.self, forKey: .elapsedSeconds) ?? 0
        todos          = try c.decodeIfPresent(TodoProgress.self, forKey: .todos) ?? .empty
        pid            = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? -1
        isAlive        = try c.decodeIfPresent(Bool.self, forKey: .isAlive) ?? true
    }

    /// 时间戳容错解码：接受 Unix 毫秒数字，也接受 ISO-8601 字符串。
    /// 统一返回 Unix 毫秒。解不出来返回 nil，绝不抛错。
    private static func decodeTimestamp(
        _ c: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let ms = try? c.decodeIfPresent(Double.self, forKey: key) { return ms }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return Self.parseISO(s)
    }

    /// 解析 `YYYY-MM-DDTHH:MM:SS[.sss]Z`，返回 Unix 毫秒。
    ///
    /// 不用 `ISO8601DateFormatter`：它不是 `Sendable`，做成 static let 会被 Swift 6
    /// 严格并发拦下，而每次解码都新建一个又太浪费（每秒 × 会话数）。
    /// engine 侧固定用 JS `toISOString()`，格式是死的，手写按位取反而更快更稳。
    private static func parseISO(_ s: String) -> Double? {
        let b = Array(s.utf8)
        guard b.count >= 19 else { return nil }

        func int(_ lo: Int, _ hi: Int) -> Int? {
            var v = 0
            for i in lo..<hi {
                let c = b[i]
                guard c >= 0x30, c <= 0x39 else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            return v
        }

        guard let year = int(0, 4), let month = int(5, 7), let day = int(8, 10),
              let hour = int(11, 13), let minute = int(14, 16), let second = int(17, 19)
        else { return nil }

        // 可选的 .sss
        var millis = 0
        if b.count >= 23, b[19] == UInt8(ascii: ".") { millis = int(20, 23) ?? 0 }

        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second

        var cal = Calendar(identifier: .gregorian)
        // toISOString() 永远是 UTC；即便哪天格式变了，按 UTC 解也只是差个时区，不会崩
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

        guard let date = cal.date(from: comps) else { return nil }
        return date.timeIntervalSince1970 * 1000 + Double(millis)
    }
}

// MARK: - 时长格式化

enum DurationFormat {
    /// 12s / 4m12s / 1h04m / 26h
    static func short(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 {
            let m = s / 60, r = s % 60
            return r == 0 ? "\(m)m" : "\(m)m\(r)s"
        }
        let h = s / 3600, m = (s % 3600) / 60
        if h < 24 { return m == 0 ? "\(h)h" : String(format: "%dh%02dm", h, m) }
        return "\(h / 24)d\(h % 24)h"
    }
}
