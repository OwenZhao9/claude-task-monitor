import Foundation
import Combine

/// 面板自身的 UI 状态（跟会话数据无关，所以不放 SessionStore）。
@MainActor
final class PanelState: ObservableObject {

    private let collapsedKey = "PanelState.collapsed"

    /// 收起后只留顶栏一条 —— 但"N 个等你"和未读数仍然可见，
    /// 否则收起就等于关掉了，失去意义。
    @Published var isCollapsed: Bool {
        didSet {
            guard isCollapsed != oldValue else { return }
            UserDefaults.standard.set(isCollapsed, forKey: collapsedKey)
        }
    }

    init() {
        isCollapsed = UserDefaults.standard.bool(forKey: collapsedKey)
    }

    func toggle() { isCollapsed.toggle() }
}
