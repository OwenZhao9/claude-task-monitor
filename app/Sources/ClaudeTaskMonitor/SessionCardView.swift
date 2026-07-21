import SwiftUI

/// 单张会话卡片。
///
/// ★ 设计目标：一眼扫过去就知道哪个在等我。
/// 手段有四层，叠加使用：
///   1. 排序 —— 等待类永远在最上面（SessionStore 负责）
///   2. 左侧强调条 —— 等待 4pt 实色，非等待 2pt 半透明
///   3. 背景着色 —— 等待有明显色底 + 描边，非等待近乎无色
///   4. 整体透明度 —— 干活中 0.88 / 空闲 0.62，等待 1.0，形成明暗对比
struct SessionCardView: View {
    let session: SessionStatus
    /// 干完活但还没被你看过
    var isUnread: Bool = false
    @State private var pulse = false

    private var waiting: Bool { session.status.isWaitingOnUser }
    private var tint: Color { session.status.tint }

    var body: some View {
        HStack(spacing: 0) {
            accentBar
            // 去掉了原来 detailRow 和 footerRow 之间的 Spacer ——
            // 卡片高度固定，Spacer 会把页脚死死顶到底边，中间撑出一大片空白。
            // 现在三行自然贴紧，整体在卡片里垂直居中。
            VStack(alignment: .leading, spacing: 2) {
                titleRow
                detailRow
                footerRow
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: Layout.cardHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(cardBorder)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(cardOpacity)
        .shadow(color: waiting ? tint.opacity(0.28) : .clear, radius: 6, y: 1)
    }

    // MARK: 左侧强调条

    private var accentBar: some View {
        Rectangle()
            .fill(waiting ? tint : tint.opacity(0.45))
            .frame(width: waiting ? 4 : 2)
    }

    // MARK: 第一行 —— 项目名 + 状态徽标

    private var titleRow: some View {
        HStack(spacing: 5) {
            // 未读红点：干完活还没被你看过
            if isUnread {
                Circle()
                    .fill(Color(red: 1.00, green: 0.23, blue: 0.19))
                    .frame(width: 6, height: 6)
                    .transition(.scale.combined(with: .opacity))
            }

            // ★ 显示 Claude Code 里的会话名（ai-title），不是目录名 ——
            //   这样窗口里的名字和你在侧边栏看到的对得上。
            //   还没生成标题的新会话没有 title，退回目录名。
            Text(session.title ?? session.projectName)
                .font(.system(size: 12.5, weight: waiting || isUnread ? .bold : .semibold))
                .lineLimit(1)
                .truncationMode(.tail)   // 标题看开头，尾部截断
                .foregroundStyle(.primary)

            if !session.isAlive {
                Text("已退出")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.10), in: Capsule())
            }

            Spacer(minLength: 4)
            statusBadge
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 3) {
            // 等待类用会呼吸的圆点，比静态图标更抓眼
            if waiting {
                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
                    .opacity(pulse ? 1.0 : 0.25)
            } else {
                Image(systemName: session.status.symbol)
                    .font(.system(size: 7.5, weight: .bold))
            }
            Text(session.status.label)
                .font(.system(size: 9.5, weight: .bold))
                .fixedSize()
        }
        .foregroundStyle(waiting ? Color.white : tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(waiting ? tint : tint.opacity(0.16), in: Capsule())
        .onAppear {
            guard waiting else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: 第二行 —— 状态文案

    private var detailRow: some View {
        Text(session.statusDetail ?? session.title ?? "—")
            .font(.system(size: 10.5))
            .foregroundStyle(waiting ? Color.primary.opacity(0.85) : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 第三行 —— 时长 + todo 进度

    private var footerRow: some View {
        HStack(spacing: 6) {
            Text(timingText)
                .font(.system(size: 10, weight: waiting ? .bold : .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(waiting ? tint : Color.secondary)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 4)
            todoProgress
        }
    }

    /// 等待类突出「卡了多久」，干活中突出「跑了多久」
    private var timingText: String {
        switch session.status {
        case .needsAuth, .needsInput:
            return "卡住 " + DurationFormat.short(session.idleSeconds)
        case .working:
            return "已跑 " + DurationFormat.short(session.elapsedSeconds)
        case .idle:
            return "闲置 " + DurationFormat.short(session.idleSeconds)
        case .failed:
            // 报错时「卡了多久」比「跑了多久」更有用 —— 决定你要不要现在去管它
            return "出错 " + DurationFormat.short(session.idleSeconds)
        case .dead:
            return "结束于 " + DurationFormat.short(session.idleSeconds) + "前"
        }
    }

    private var todoProgress: some View {
        HStack(spacing: 4) {
            if session.todos.isEmpty {
                Text("无 todo")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule()
                            .fill(tint.opacity(waiting ? 0.95 : 0.65))
                            .frame(width: max(2, geo.size.width * session.todos.fraction))
                    }
                }
                .frame(width: 42, height: 4)

                Text("\(session.todos.done)/\(session.todos.total)")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    // MARK: 背景 / 描边 / 透明度

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(waiting ? tint.opacity(0.16) : Color.primary.opacity(0.05))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                waiting ? tint.opacity(0.55) : Color.primary.opacity(0.07),
                lineWidth: waiting ? 1 : 0.5
            )
    }

    /// 卡片自身的透明度。
    /// ★ 原来空闲卡压到 0.62、干活中 0.88，叠加窗口整体的 30% 静息透明度后
    ///   基本看不清。现在窗口常亮了，这里也只保留很轻的层次差 ——
    ///   「不抢眼」和「看不清」是两回事。
    private var cardOpacity: Double {
        if waiting { return 1.0 }
        if !session.isAlive { return 0.72 }
        return session.status == .idle ? 0.90 : 1.0
    }
}
