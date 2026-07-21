import AppKit

/// 承载 NSHostingView 的父视图。
///
/// ★ 坑：`isMovableByWindowBackground = true` 单独不够 ——
/// NSHostingView 会吃掉 mouseDown，窗口拖不动。必须在父视图补 mouseDragged。
/// SwiftUI 里非交互区域的 drag 事件会冒泡到这里。
final class DraggableContainerView: NSView {

    override func mouseDragged(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    /// 应用未激活时（.accessory + nonactivating），第一次点击也要能直接拖，
    /// 不要求先「激活」一下。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isFlipped: Bool { false }
}

/// 无边框 NSPanel。
///
/// 当前面板只展示不输入，`canBecomeKey` 保持 false 是对的（不抢焦点）。
/// 以后要往面板里放 TextField / 搜索框，把下面两个 override 打开即可。
final class FloatingPanel: NSPanel {
    // override var canBecomeKey: Bool { true }
    // override var canBecomeMain: Bool { false }
}
