import SwiftUI

struct ContentView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var panel: PanelState
    /// hover 状态回传给 AppDelegate 去动 window.alphaValue
    var onHoverChange: (Bool) -> Void

    private var waitingCount: Int {
        store.sessions.filter { $0.status.isWaitingOnUser }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // 收起时换成紧凑顶栏：丢掉"Claude 任务"文字标签，横向才收得下去
            (panel.isCollapsed ? AnyView(compactHeader) : AnyView(header))
                .frame(height: Layout.headerHeight)
            // 收起时整个列表区（含 headerGap）都不参与布局
            if !panel.isCollapsed {
                Spacer(minLength: 0).frame(height: Layout.headerGap)
                list
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(Layout.contentPadding)
        // ★ 内容按 Layout 自己算出确切尺寸，材质背景紧贴这个尺寸画。
        //   然后整体锚定到宿主视图的**右上角**，多出来的窗口面积保持透明。
        //
        //   为什么这么做：NSWindow 改尺寸是同步的，SwiftUI 重绘要等下一个渲染
        //   周期，两者必然差一帧甚至更久（主线程忙时 async 会被拉长）。
        //   以前让内容撑满窗口，这一帧就会露馅 ——
        //   窗口大内容小 = 紧凑顶栏浮在一大片半透明空盒子正中间；
        //   窗口小内容大 = 文字被挤没。
        //   现在错位那部分是纯透明的，位置又和最终态重合，所以**肉眼不可见**。
        .frame(width: contentWidth, height: contentHeight)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onHover { onHoverChange($0) }
    }

    /// 与 AppDelegate.applyGeometry 用同一批 Layout 函数，保证两边算出的是同一个数
    private var contentWidth: CGFloat {
        Layout.panelWidth(collapsed: panel.isCollapsed,
                          count: store.sessions.count,
                          waiting: waitingCount,
                          unread: store.unread.count)
    }

    private var contentHeight: CGFloat {
        Layout.panelHeight(for: store.sessions.count, collapsed: panel.isCollapsed)
    }

    // MARK: 顶栏（同时也是拖动把手区）

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            Text("Claude 任务")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)

            // ★ 有人在等我 —— 顶栏也来一份，卡片滚出可视区时仍然看得见
            if waitingCount > 0 {
                Text("\(waitingCount) 个等你")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(SessionState.needsAuth.tint, in: Capsule())
            }

            // 同理：未读数也放顶栏，超过 5 个滚出去的不会漏
            if !store.unread.isEmpty {
                HStack(spacing: 3) {
                    Circle()
                        .fill(Color(red: 1.00, green: 0.23, blue: 0.19))
                        .frame(width: 5, height: 5)
                    Text("\(store.unread.count) 未读")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            Circle()
                .fill(store.isConnected
                      ? SessionState.working.tint
                      : SessionState.idle.tint)
                .frame(width: 5, height: 5)

            Text("\(store.sessions.count)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            collapseButton
        }
        .padding(.horizontal, 2)
        .contentShape(Rectangle())   // 空白处也能拖
    }

    /// 收起态的紧凑顶栏。
    /// 只保留「不看就会漏」的三样：在等你的数量、未读数、连接状态。
    /// 标题文字第一个牺牲 —— 你知道这是什么窗口，不需要它一直告诉你。
    private var compactHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(store.isConnected ? Color.secondary : SessionState.idle.tint)

            Text("\(store.sessions.count)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if waitingCount > 0 {
                Text("\(waitingCount) 等")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(SessionState.needsAuth.tint, in: Capsule())
            }

            if !store.unread.isEmpty {
                HStack(spacing: 2) {
                    Circle()
                        .fill(Color(red: 1.00, green: 0.23, blue: 0.19))
                        .frame(width: 5, height: 5)
                    Text("\(store.unread.count)")
                        .font(.system(size: 9.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            // minLength 0：多算出来的余量由它吸收，绝不能反过来去挤文字
            Spacer(minLength: 0)
            collapseButton
        }
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 收起 / 展开。收起后只剩顶栏一条，但等待数和未读数照常显示。
    private var collapseButton: some View {
        Button {
            // ★ 这里不能包 withAnimation。
            //   窗口尺寸是 AppDelegate 里 animate:false 瞬间改的，
            //   内容却animate 0.18s 慢慢过渡 —— 这段时间里展开态顶栏
            //   （带绿色连接点和向上箭头）被硬塞进已经缩窄的窗口，
            //   文字全被挤没，看着像渲染坏了。两边必须同帧完成。
            panel.toggle()
        } label: {
            Image(systemName: panel.isCollapsed ? "chevron.down" : "chevron.up")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)          // 点击热区放大到 16pt，光标好对准
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(panel.isCollapsed ? "展开" : "收起")
    }

    // MARK: 卡片列表

    @ViewBuilder
    private var list: some View {
        if store.sessions.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: Layout.cardSpacing) {
                    ForEach(store.sessions) { session in
                        SessionCardView(
                            session: session,
                            isUnread: store.unread.contains(session.sessionId)
                        )
                        .help(session.cwd)   // 悬停看完整路径，标题占位后目录名没地方显示了
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.2)) {
                                store.markRead(session.sessionId)
                            }
                        }
                    }
                }
            }
            .scrollDisabled(store.sessions.count <= Layout.maxVisibleCards)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 16, weight: .light))
            Text("没有活跃会话")
                .font(.system(size: 11))
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
