import AppKit

// ★ 文件名是 main.swift 时不要加 @main，直接写顶层代码。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
