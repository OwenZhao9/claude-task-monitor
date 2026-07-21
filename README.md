# Claude 任务监控

macOS 右上角常驻的小窗口，实时显示本机所有 Claude Code 会话的状态：哪个在干活、哪个在等你、卡了多久、todo 进度。

纯本地，不联网，不需要任何 API key。对 `~/.claude/` **只读**。

```
┌─────────────────────────────┐
│ ✦ Claude 任务        ● 2    │
├─────────────────────────────┤
│ api-gateway 重构   〜干活中  │
│ 执行 Bash                   │
│ 已跑 7m44s          无 todo │
├─────────────────────────────┤
│ docs 站点            ☾ 空闲 │
│ 一轮结束，等你下一句        │
│ 闲置 7m26s          无 todo │
└─────────────────────────────┘
```

## 环境要求

- macOS 14+
- Swift 6（命令行工具即可，不需要 Xcode GUI）
- Node.js —— 引擎是纯 Node 零依赖脚本，不用 `npm install`

## 构建与运行

```bash
bash app/build.sh                    # 编译 + 组装 .app
open build/ClaudeTaskMonitor.app     # 启动
```

窗口出现在主屏右上角，永远置顶，不抢焦点，不进 Dock / Mission Control / Cmd-Tab。

## 怎么用

| 操作 | 效果 |
|---|---|
| **顶栏右侧箭头** | 收起 / 展开 |
| **点击卡片** | 标记已读，清掉红点 |
| 悬停卡片 | 显示完整工作目录 |
| 拖动窗口 | 换位置；之后高度变化按顶边锚定 |
| **右键窗口** | 收起 / 贴回右上角 / 提示音开关 / 试听 / **退出** |

收起后**横向纵向一起收**，变成右上角一颗小药丸：

| | 尺寸 |
|---|---|
| 展开（5 张卡） | 296 × 336 |
| 收起 | **72 × 35**（约 2.5% 面积） |

宽度按内容动态算 —— 有「N 等」徽标或未读数时自动变宽（约 107 / 126pt），没有就缩到最小。收起时**右边缘锚定不动**，只往左下收。

即使收起，**连接指示灯、会话数、等待数、未读数仍然可见** —— 收起是为了省地方，不是为了失明。状态记在 `UserDefaults`，重启保持。

卡片显示的是 Claude Code 里那个会话名（`ai-title`），和你在侧边栏看到的一致；还没生成标题的新会话退回显示目录名。

## 未读红点

会话**干完活**（干活中 → 空闲）时打红点，表示「出结果了但你还没看」。顶栏同时显示未读总数，卡片滚出可视区也不会漏。

清除时机：
- 你点了那张卡片
- 会话重新开始活动 —— 说明你已经接手了

同样只认跃迁：app 重启时那些早就跑完的会话不会全被标成未读（那不是「刚刚出结果」）。

窗口常亮，不需要 hover 就看得清。想恢复「平时淡出、鼠标移上去才变亮」，把 [AppDelegate.swift](app/Sources/ClaudeTaskMonitor/AppDelegate.swift) 里的 `restingAlpha` 从 `1.00` 调回 `0.3~0.6` 即可，机制原样保留着。

## 提示音

状态**跃迁瞬间**响一次，不是持续响：

| 时机 | 声音 |
|---|---|
| 有会话开始等你授权 | Sosumi（尖锐） |
| 有会话报错 | Basso（低沉） |
| Claude 问你问题 | Ping（清脆） |
| 一轮干完（干活中 → 空闲） | Glass（悦耳） |

几个刻意的设计：

- **启动时不响。** 首批快照只建立基线 —— app 重启时那些早就在等授权的会话不是「刚刚发生」，一起炸响就是噪音。
- **新发现的会话不响。** 同理，第一次见到某个会话时只记录状态。
- **最短间隔 1.5 秒。** 多个会话同时完成时不会连珠炮。
- **一键静音。** 右键菜单里关掉，选择记在 `UserDefaults`，重启仍生效。开会或录屏时不用退出整个 app。

> **退出只能走右键菜单。** 这个 app 是 `LSUIElement`，没有 Dock 图标、没有菜单栏，面板是 nonactivating 所以 Cmd-Q 也捕获不到。实在不行才用 `killall ClaudeTaskMonitor`。

## 状态含义

| 徽标 | 含义 |
|---|---|
| 干活中（绿） | Claude 正在执行工具或生成回复 |
| 等你输入（橙） | Claude 主动问了问题在**阻塞等你**（AskUserQuestion / 计划确认） |
| 等你授权（红） | 工具调用在等权限确认 —— 最该马上处理 |
| 出错（洋红） | 会话遇到 API 错误 |
| 空闲（灰） | 一轮正常结束，等你说下一句。不紧急 |
| 已退出（深灰） | 进程已不在 |

排序永远是「等授权 → 等输入 → 出错 → 干活中 → 空闲 → 已退出」，同档内卡得越久越靠前 —— 需要你处理的永远浮在最上面。

## 架构

```
engine/     Node 状态引擎，零依赖
            node engine/index.js --once     打印一次
            node engine/index.js --watch    每秒一行 NDJSON

app/        SwiftUI + AppKit NSPanel
            启动时 spawn 引擎子进程，读 stdout 渲染

hooks/      可选。Claude Code hook → 事件文件 → 引擎合并
            让「等授权」「一轮干完」零延迟到达（轮询判不出来）
```

进程间只有一根管道：app spawn `node engine/index.js --watch`，按行读 stdout。引擎挂了自动重启（指数退避，上限 30s），app 退出同步杀子进程。

**hooks 是可选的**，不装窗口照样能用，只是「等你授权」这个状态会判不出来。装法见 [hooks/install.md](hooks/install.md)。

## 数据来源

全部是 Claude Code 自己写在本地的文件：

| 路径 | 用途 |
|---|---|
| `~/.claude/sessions/<pid>.json` | 活跃会话注册表 |
| `~/.claude/projects/<slug>/<sessionId>.jsonl` | 对话流水，判状态用 |
| `~/.claude/tasks/<sessionId>/*.json` | todo 进度 |

`.jsonl` 可能非常大（实测本机有 140MB 的），引擎只 seek 到末尾读最后几十 KB，并用 mtime 缓存跳过没变的文件。实测单轮扫描 3–14ms。

## 卸载

```bash
rm -rf build/ClaudeTaskMonitor.app
```

如果装了 hooks，再把 `~/.claude/settings.json` 里对应的 hooks 配置删掉，并删除事件文件 `~/.claude/task-monitor-events.ndjson`。

## 已知限制

- 只监控**本机**会话。云端 claude.ai/code 的远程任务不在范围内（没有公开 API）。
- 「等你授权」依赖 hooks。不装 hooks 时，工具挂起超 60s 只会在详情里提示「可能在等授权」，不下断言。
- 会话很多时窗口会滚动，超出可视区的卡片要滚才看得到；顶栏的「N 个等你」计数是全量的，不会漏。

---

## 声明

个人项目，与 Anthropic 无关，非官方工具。"Claude" 是 Anthropic 的商标，此处仅用于说明本工具的用途。

本工具对 `~/.claude/` 只读；唯一的写操作是可选的 hook 事件文件（`~/.claude/task-monitor-events.ndjson`），以及在你自己确认后合并进 `~/.claude/settings.json` 的 hook 配置。
