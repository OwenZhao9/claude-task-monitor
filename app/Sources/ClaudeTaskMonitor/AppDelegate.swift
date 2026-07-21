import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: FloatingPanel!
    private var hostingView: NSHostingView<ContentView>!
    private let store = SessionStore()
    private let sound = SoundNotifier()
    private let panelState = PanelState()
    private var cancellables = Set<AnyCancellable>()

    /// 用户手动拖过之后就不再强制回右上角（除非屏幕参数变了）
    private var userMoved = false
    private var isHovering = false

    // 透明度档位。
    // ★ 三档现在都是 1.0 —— 常亮，不 hover 也完全清晰。
    //   原来平时压到 0.30，鼠标移上去才看得清，但这窗口存在的意义就是
    //   「扫一眼就知道」，需要先把鼠标挪过去等于白做。
    //   想恢复「平时淡出、hover 变亮」：把 restingAlpha 调回 0.3~0.6 即可，
    //   下面的 animateAlpha 机制原样保留着。
    private let hoverAlpha: CGFloat     = 1.00   // 鼠标悬停
    private let restingAlpha: CGFloat   = 1.00   // 平时
    private let attentionAlpha: CGFloat = 1.00   // 有会话在等你时

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 无 Dock 图标、不进 Cmd-Tab。与 Info.plist 的 LSUIElement 双保险。
        NSApp.setActivationPolicy(.accessory)

        buildPanel()
        store.start()
        observeStore()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        applyGeometry(resetToCorner: true)
        panel.alphaValue = targetRestingAlpha
        panel.orderFrontRegardless()   // ★ 不用 makeKeyAndOrderFront，会破坏 nonactivating 语义
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()   // 内部同步 stop 掉 engine 子进程，不留孤儿 node
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - 面板构造

    private func buildPanel() {
        let initialHeight = Layout.panelHeight(for: 0, collapsed: panelState.isCollapsed)

        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: initialHeight),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.collectionBehavior = [.canJoinAllSpaces,      // 跟随所有桌面空间
                                    .stationary,            // Mission Control 里不参与排布
                                    .fullScreenAuxiliary,   // 全屏 App 之上仍可见
                                    .ignoresCycle]          // 不进窗口循环
        panel.isFloatingPanel = true
        panel.level = .statusBar          // ★ 必须在 isFloatingPanel 之后，否则被静默打回 .floating
        panel.hidesOnDeactivate = false   // utilityWindow 默认 true，切走 app 就没了
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear    // 与 isOpaque=false 缺一不可，否则圆角外露底色
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .utilityWindow
        panel.isReleasedWhenClosed = false

        let root = ContentView(store: store, panel: panelState) { [weak self] hovering in
            self?.setHovering(hovering)
        }
        hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]

        let container = DraggableContainerView(
            frame: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: initialHeight)
        )
        hostingView.frame = container.bounds
        container.addSubview(hostingView)
        container.menu = buildContextMenu()   // ★ 唯一的退出入口，见下
        panel.contentView = container
    }

    /// ★ 这个 app 是 LSUIElement + .accessory：没有 Dock 图标、没有菜单栏、
    ///   面板是 nonactivating 永远不成为 key window，所以 Cmd-Q 也捕获不到。
    ///   没有这个右键菜单，装上之后就只能去终端 killall —— 必须留出口。
    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        // 收起后顶栏那个箭头热区只有 16pt，菜单里再给一条路
        let fold = NSMenuItem(title: panelState.isCollapsed ? "展开" : "收起",
                              action: #selector(toggleCollapse), keyEquivalent: "")
        fold.target = self
        menu.addItem(fold)

        let reset = NSMenuItem(title: "贴回右上角", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        // 提示音开关。常驻窗口会响铃这件事必须能一键关掉，
        // 否则开会 / 录屏的时候只能退出整个 app。
        let mute = NSMenuItem(title: "提示音", action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        mute.state = sound.isMuted ? .off : .on
        menu.addItem(mute)

        let preview = NSMenuItem(title: "试听提示音", action: #selector(previewSound), keyEquivalent: "")
        preview.target = self
        menu.addItem(preview)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Claude 任务监控", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func toggleCollapse() {
        panelState.toggle()
        panel.contentView?.menu = buildContextMenu()   // 标题要在 收起/展开 之间切
    }

    @objc private func resetPosition() {
        userMoved = false
        applyGeometry(resetToCorner: true)
    }

    @objc private func toggleMute() {
        sound.isMuted.toggle()
        // 菜单是每次构造好挂上去的，状态变了要重建，否则勾号不刷新
        panel.contentView?.menu = buildContextMenu()
    }

    @objc private func previewSound() {
        sound.preview()
    }

    @objc private func quit() {
        NSApp.terminate(nil)   // 会走 applicationWillTerminate，子进程在那里被杀
    }

    private func observeStore() {
        // 会话数 / 等待数 / 未读数任一变化 -> 重算窗口尺寸。
        // 收起态的宽度取决于后两个，所以三个都要盯。
        store.$sessions
            .combineLatest(store.$unread)
            .map { sessions, unread in
                // ★ 必须用闭包收到的值，不能回头读 store.xxx。
                //   @Published 是 willSet 时机发布的 —— sink 执行时 store 里还是旧值。
                //   用旧值算窗口尺寸，而 SwiftUI 已按新值画内容，两边打架，
                //   结果就是内容溢出被裁、顶栏消失。
                Geom(count: sessions.count,
                     waiting: sessions.filter { $0.status.isWaitingOnUser }.count,
                     unread: unread.count)
            }
            .removeDuplicates()   // 每秒的 tick 只改秒数，不该触发几何重算
            .sink { [weak self] g in
                MainActor.assumeIsolated { self?.applyGeometry(resetToCorner: false, geom: g) }
            }
            .store(in: &cancellables)

        // 收起/展开 -> 重算窗口尺寸，右上角锚定。
        panelState.$isCollapsed
            .removeDuplicates()
            .dropFirst()          // 初始值已经在启动时算过了
            .sink { [weak self] collapsed in
                // ★ 必须用闭包收到的 collapsed。@Published 在 willSet 发布，
                //   此刻 panelState.isCollapsed 仍是旧值。
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // ★ NSWindow 改尺寸是同步立即生效的，SwiftUI 重绘要等下一个
                    //   渲染周期 —— 两者天然差一帧。所以要安排顺序，
                    //   让那一帧永远落在"无害"的组合上：
                    //   窗口比内容宽 = 多块空白（没人看得出来）
                    //   窗口比内容窄 = 文字被挤没（看着像渲染坏了）
                    if collapsed {
                        // 收起：先让 SwiftUI 画出紧凑顶栏，下一轮再缩窗口
                        DispatchQueue.main.async {
                            self.applyGeometry(resetToCorner: false, collapsed: true)
                        }
                    } else {
                        // 展开：先把窗口放大，内容随后填进来
                        self.applyGeometry(resetToCorner: false, collapsed: false)
                    }
                }
            }
            .store(in: &cancellables)

        // 状态跃迁提示音。同样用闭包收到的 sessions，不回头读 store。
        store.$sessions
            .sink { [weak self] sessions in
                MainActor.assumeIsolated { self?.sound.evaluate(sessions) }
            }
            .store(in: &cancellables)

        // 等待中的会话数变化 -> 重算静息透明度
        store.$sessions
            .map { $0.contains { $0.status.needsAttention } }
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.animateAlpha() }
            }
            .store(in: &cancellables)
    }

    // MARK: - 定位

    /// 主屏 = frame.origin 为 (0,0) 的那块，它拥有菜单栏
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
    }

    /// 面板当前所在的屏（面积重叠最大的那块）
    private func currentScreen() -> NSScreen? {
        let f = panel.frame
        let best = NSScreen.screens.max { a, b in
            a.frame.intersection(f).area < b.frame.intersection(f).area
        }
        if let best, best.frame.intersects(f) { return best }
        return targetScreen()
    }

    /// 面板尺寸取决于这三个数，单独拎出来做去重，避免每秒 tick 都重算几何。
    struct Geom: Equatable {
        var count: Int
        var waiting: Int
        var unread: Int
    }

    private var currentGeom: Geom {
        Geom(count: store.sessions.count,
             waiting: store.sessions.filter { $0.status.isWaitingOnUser }.count,
             unread: store.unread.count)
    }

    /// 重算尺寸并摆好位置。
    /// - resetToCorner: true 强制回右上角；false 保持用户拖到的位置（右上角锚定）。
    /// - geom: 来自发布者闭包的新值。★ 不传就读 store，但在 @Published 的 sink 里
    ///         读 store 拿到的是**旧值**（willSet 时机），必须由调用方传进来。
    /// - collapsed: 同理，来自 `$isCollapsed` 闭包的新值。★ 不传就读 panelState，
    ///              但在它自己的 sink 里读到的是**旧值**，必须由调用方传。
    private func applyGeometry(resetToCorner: Bool, geom: Geom? = nil, collapsed: Bool? = nil) {
        let g = geom ?? currentGeom
        let collapsed = collapsed ?? panelState.isCollapsed
        let height = Layout.panelHeight(for: g.count, collapsed: collapsed)
        let width = Layout.panelWidth(collapsed: collapsed, count: g.count,
                                      waiting: g.waiting, unread: g.unread)
        let size = CGSize(width: width, height: height)

        guard let screen = resetToCorner ? targetScreen() : currentScreen() else { return }
        // visibleFrame 已自动排除菜单栏 / Dock / 刘海带，不要手算 33 或 34
        let vf = screen.visibleFrame
        let m = Layout.screenMargin

        var origin: NSPoint
        if resetToCorner || !userMoved {
            origin = NSPoint(x: vf.maxX - size.width - m, y: vf.maxY - size.height - m)
        } else {
            // ★ 右上角锚定：宽高变化时向左下生长，右上角不动。
            //   收起时宽度从 296 缩到 ~90，如果锚左边缘，窗口会原地往左缩，
            //   右侧空出一大块，看着像跑偏了。
            let top = panel.frame.maxY
            let right = panel.frame.maxX
            origin = NSPoint(x: right - size.width, y: top - size.height)
        }

        var frame = NSRect(origin: origin, size: size)
        frame = clamp(frame, into: vf)
        panel.setFrame(frame, display: true, animate: false)

        if let container = panel.contentView {
            hostingView.frame = container.bounds
        }
    }

    /// 保证面板完全落在可视区内。多显示器插拔后窗口飞出屏幕主要靠这个兜底。
    private func clamp(_ frame: NSRect, into vf: NSRect) -> NSRect {
        var f = frame
        f.origin.x = min(max(f.origin.x, vf.minX), max(vf.minX, vf.maxX - f.width))
        f.origin.y = min(max(f.origin.y, vf.minY), max(vf.minY, vf.maxY - f.height))
        return f
    }

    @objc nonisolated func screensChanged() {
        MainActor.assumeIsolated {
            // ★ 屏幕参数变了，之前记住的目标屏可能已经拔掉了 —— 一律重新贴边
            self.userMoved = false
            self.applyGeometry(resetToCorner: true)
        }
    }

    // MARK: - hover 透明度

    private var targetRestingAlpha: CGFloat {
        // 用 needsAttention 而非 isWaitingOnUser：报错的会话同样不该在 30% 透明度下被忽略
        store.sessions.contains { $0.status.needsAttention } ? attentionAlpha : restingAlpha
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        animateAlpha()
    }

    private func animateAlpha() {
        let target = isHovering ? hoverAlpha : targetRestingAlpha
        guard abs(panel.alphaValue - target) > 0.001 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = target
        }
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
