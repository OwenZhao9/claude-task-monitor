import CoreGraphics

/// ★ 布局常量必须由 SwiftUI 和 AppDelegate 共用。
/// AppDelegate 靠 `panelHeight(for:)` 算窗口高度，SwiftUI 靠同一批常量画。
/// 两边一旦对不上，窗口就会出现裁切或者底部留白。
enum Layout {
    // 目标：用最少的屏幕面积把信息说清楚。
    // 卡片高度是大头 —— 三行文字实际只需要约 40pt，原来的 84pt 里有一半是空白。
    static let panelWidth: CGFloat      = 296
    static let cardHeight: CGFloat      = 56
    static let cardSpacing: CGFloat     = 4
    static let headerHeight: CGFloat    = 19
    static let headerGap: CGFloat       = 5
    static let contentPadding: CGFloat  = 8
    static let cornerRadius: CGFloat    = 13
    static let screenMargin: CGFloat    = 10

    /// 超过这个数量就滚动，不再继续长高
    static let maxVisibleCards: Int     = 5

    /// 列表区（ScrollView）的高度
    static func listHeight(for count: Int) -> CGFloat {
        let n = max(1, min(count, maxVisibleCards))   // 空列表也占一张卡的位置
        return CGFloat(n) * cardHeight + CGFloat(n - 1) * cardSpacing
    }

    /// 整个面板的高度
    static func panelHeight(for count: Int, collapsed: Bool = false) -> CGFloat {
        // 收起时只剩顶栏，连 headerGap 都省掉
        if collapsed { return contentPadding * 2 + headerHeight }
        return contentPadding * 2 + headerHeight + headerGap + listHeight(for: count)
    }

    /// 收起时的宽度 —— 按实际要显示的东西算，不留空。
    ///
    /// ★ 宽度必须是动态的：有没有「等你」徽标、有没有未读数，差出去几十 pt。
    ///   写死一个值要么把徽标挤掉，要么平时空一大块。
    /// ★ 算宽度时每一项都要对应**实际会显示的那个数字**。
    ///   之前这里给"会话数"留位置时错用了 waiting+unread，两者毫无关系 ——
    ///   宽度算少了，SwiftUI 就把 Text 压成零宽，药丸上只剩图标和箭头。
    ///   所以宁可多留几 pt 空白，也绝不能算窄。
    static func collapsedWidth(count: Int, waiting: Int, unread: Int) -> CGFloat {
        var w = contentPadding * 2 + 4        // 面板内边距 + 顶栏自身的 horizontal padding
        w += 12                                // ✦ 图标
        w += 5 + digitsWidth(count)            // 会话数
        if waiting > 0 { w += 5 + digitsWidth(waiting) + 13 + 10 }  // "N 等" 胶囊（含 CJK 字 + 内边距）
        if unread > 0  { w += 5 + 5 + 2 + digitsWidth(unread) }     // 未读红点 + 数字
        w += 6 + 16                            // 折叠箭头
        return (w + 6).rounded()               // 余量，避免四舍五入把最后一个字符挤掉
    }

    /// 数字占位宽度（10pt 等宽数字，一位约 7pt）
    private static func digitsWidth(_ n: Int) -> CGFloat {
        CGFloat(String(max(0, n)).count) * 7
    }

    /// 当前该用多宽
    static func panelWidth(collapsed: Bool, count: Int, waiting: Int, unread: Int) -> CGFloat {
        collapsed ? collapsedWidth(count: count, waiting: waiting, unread: unread) : panelWidth
    }
}
