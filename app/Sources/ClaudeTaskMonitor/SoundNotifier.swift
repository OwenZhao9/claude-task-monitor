import AppKit

/// 状态跃迁提示音。
///
/// ★ 核心约束：引擎每秒推一次**全量快照**。
///   如果按「当前有会话在等授权就响」来写，会变成每秒响一次的酷刑。
///   所以这里维护上一次每个会话的状态，只在**跃迁瞬间**响一次。
@MainActor
final class SoundNotifier {

    /// 触发响铃的时机
    private enum Alert: Int {
        case needsAuth   = 0   // 优先级最高
        case failed      = 1
        case needsInput  = 2
        case finished    = 3

        var soundName: String {
            switch self {
            case .needsAuth:  return "Sosumi"   // 尖锐，代表"卡住了，等你点同意"
            case .failed:     return "Basso"    // 低沉，出错
            case .needsInput: return "Ping"     // 清脆，Claude 在问你
            case .finished:   return "Glass"    // 悦耳，一轮干完
            }
        }

        var label: String {
            switch self {
            case .needsAuth:  return "等你授权"
            case .failed:     return "出错"
            case .needsInput: return "等你输入"
            case .finished:   return "已完成"
            }
        }
    }

    private var lastState: [String: SessionState] = [:]
    /// ★ 首批快照只建立基线，不响。
    ///   否则 app 一启动，所有已经在等授权的会话会一起炸响。
    private var primed = false
    private var lastPlayedAt: Date = .distantPast
    private var cache: [String: NSSound] = [:]

    /// 两次响铃的最小间隔。多个会话同时完成时不至于连珠炮。
    private let minInterval: TimeInterval = 1.5

    private let muteKey = "SoundNotifier.muted"

    var isMuted: Bool {
        get { UserDefaults.standard.bool(forKey: muteKey) }
        set { UserDefaults.standard.set(newValue, forKey: muteKey) }
    }

    // MARK: - 主入口

    /// 每来一批快照调一次。内部自己做跃迁判定。
    func evaluate(_ sessions: [SessionStatus]) {
        var next: [String: SessionState] = [:]
        next.reserveCapacity(sessions.count)

        var triggered: Alert?

        for s in sessions {
            next[s.sessionId] = s.status
            let previous = lastState[s.sessionId]

            // ★ 第一次见到这个会话不响。
            //   app 重启、或某个会话刚被发现时，它可能早就处于等待态了 ——
            //   那不是"刚刚发生"，响了就是噪音。
            guard let previous else { continue }
            guard previous != s.status else { continue }

            if let a = alert(from: previous, to: s.status) {
                if triggered == nil || a.rawValue < triggered!.rawValue {
                    triggered = a
                }
            }
        }

        lastState = next   // 顺带清理掉已消失的会话，不会无限增长

        guard primed else { primed = true; return }
        guard let alert = triggered else { return }
        play(alert)
    }

    // MARK: - 跃迁 -> 提示音

    private func alert(from old: SessionState, to new: SessionState) -> Alert? {
        switch new {
        case .needsAuth:
            return .needsAuth
        case .needsInput:
            return .needsInput
        case .failed:
            return .failed
        case .idle:
            // 「出结果了」= 干活干完停下来。
            // 只认 working -> idle；从等待态回到 idle 是你自己处理完了，不用再提醒。
            return old == .working ? .finished : nil
        case .working, .dead:
            return nil
        }
    }

    // MARK: - 播放

    private func play(_ alert: Alert) {
        guard !isMuted else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPlayedAt) >= minInterval else { return }
        lastPlayedAt = now
        FileHandle.standardError.write(Data("[sound] \(alert.label) -> \(alert.soundName)\n".utf8))
        playSound(named: alert.soundName)
    }

    private func playSound(named name: String) {
        let sound: NSSound
        if let cached = cache[name] {
            sound = cached
        } else if let s = NSSound(named: NSSound.Name(name)) {
            cache[name] = s
            sound = s
        } else {
            NSSound.beep()   // 系统音缺失时的兜底
            return
        }
        // 同一个 NSSound 实例还在播时再 play 是无效的，先停
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// 给右键菜单「试听」用
    func preview() {
        playSound(named: Alert.needsAuth.soundName)
    }
}
