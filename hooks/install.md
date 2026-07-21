# Claude 任务监控 —— hook 事件推送安装说明

引擎（`engine/`）靠轮询 `~/.claude/` 下的文件推导会话状态，但有两个状态文件里**根本看不出来**：

| 状态 | 为什么轮询判不出来 | 靠哪个 hook |
|---|---|---|
| Claude 一轮干完停下来了 | 流水最后一条是 assistant，和"还在生成中"长得一样 | `Stop` |
| Claude 在等用户授权 | 权限弹窗只存在于内存/TUI，不落盘 | `PermissionRequest` / `Notification` |

装上 hook 后，这两个状态就是**实时推送**的，不再靠猜。
不装也能用 —— 引擎发现事件文件不存在会静默降级回纯轮询。

---

## 红线：本文件不会替你改 `settings.json`

`~/.claude/settings.json` 是你的全局配置，**必须由你自己决定是否合并**。
下面给出可直接复制的片段和步骤。（也提供了 `install.sh`，但默认推荐手动合并。）

---

## 一、先确认路径

下面的配置片段里有两个绝对路径，是按**本机当前状态**生成的：

- node：`/opt/homebrew/bin/node`
- 脚本：`/ABSOLUTE/PATH/TO/claude-task-monitor/hooks/emit.js`

> **为什么必须写 node 的绝对路径？**
> hook 跑在非交互 shell 里，实测 `env -i /bin/bash -c 'command -v node'` 找不到 node
> （node 来自 Homebrew，只在交互式 shell 的 PATH 里）。写 `node` 会静默失败。

自己核对一遍：

```bash
command -v node          # 应输出 /opt/homebrew/bin/node
ls -l "/ABSOLUTE/PATH/TO/claude-task-monitor/hooks/emit.js"
```

如果**项目目录被移动过**，或 node 换了位置，就把下面片段里对应的路径整体替换掉。
（脚本路径出现 9 次，建议用编辑器全局替换。）

---

## 二、待合并的 JSON 片段

把 `"hooks"` 这一整个键合并进 `~/.claude/settings.json` 的**顶层对象**。

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/opt/homebrew/bin/node '/ABSOLUTE/PATH/TO/claude-task-monitor/hooks/emit.js' SessionStart",
            "timeout": 5,
            "async": true
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/opt/homebrew/bin/node '/ABSOLUTE/PATH/TO/claude-task-monitor/hooks/emit.js' UserPromptSubmit",
            "timeout": 5,
            "async": true
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/opt/homebrew/bin/node '/ABSOLUTE/PATH/TO/claude-task-monitor/hooks/emit.js' PermissionRequest",
            "timeout": 5,
            "async": true
          }
        ]
      }
    ],
    "PermissionDenied": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/opt/homebrew/bin/node '/ABSOLUTE/PATH/TO/claude-task-monitor/hooks/emit.js' PermissionDenied",
            "timeout": 5,
            "async": true
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/opt/homebrew/bin/node '/ABSOLUTE/PATH/TO/claude-task-monitor/hooks/emit.js' Notification",
            "timeout": 5,
            "async": true
          }
        ]
      }
    ],
    "SubagentStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/opt/homebrew/bin/node '/ABSOLUTE/PATH/TO/claude-task-monitor/hooks/emit.js' SubagentStart",
            "timeout": 5,
            "async": true
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/opt/homebrew/bin/node '/ABSOLUTE/PATH/TO/claude-task-monitor/hooks/emit.js' Stop",
            "timeout": 5,
            "async": true
          }
        ]
      }
    ],
    "StopFailure": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/opt/homebrew/bin/node '/ABSOLUTE/PATH/TO/claude-task-monitor/hooks/emit.js' StopFailure",
            "timeout": 5,
            "async": true
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/opt/homebrew/bin/node '/ABSOLUTE/PATH/TO/claude-task-monitor/hooks/emit.js' SessionEnd",
            "timeout": 5,
            "async": true
          }
        ]
      }
    ]
  }
}
```

### 这几个字段的含义

- `"async": true` —— **hook 在后台跑，完全不阻塞会话**。这是"绝不能拖慢用户会话"这条要求的
  结构性保证：即使脚本卡住，Claude Code 也不等它。
- `"timeout": 5` —— 二道保险（脚本自己还有 800ms 的自杀闸）。
- 没有 `matcher` —— 表示该事件的所有情况都触发。`Notification` 的 matcher 匹配的是
  `notification_type`，不写就是全收，引擎那边对不认识的类型本来就会忽略。

### 为什么**没有** `PreToolUse` / `PostToolUse`

它们每次工具调用都触发，一轮对话可能几十上百次。而"正在跑工具"这个状态，
引擎从流水文件里已经能可靠推出来 —— 挂上去是纯粹的开销换零信息。
只挂低频事件，是这套配置总开销可以忽略的原因。

---

## 三、手动合并步骤

1. **先备份**

   ```bash
   cp ~/.claude/settings.json ~/.claude/settings.json.bak
   ```

2. **打开** `~/.claude/settings.json`。当前内容形如：

   ```json
   {
     "theme": "light",
     "enabledPlugins": { "figma@claude-plugins-official": true },
     "skipWorkflowUsageWarning": true
   }
   ```

3. **把上面片段里的 `"hooks": { ... }` 整块粘进顶层对象**，别忘了前一个键末尾补逗号：

   ```json
   {
     "theme": "light",
     "enabledPlugins": { "figma@claude-plugins-official": true },
     "skipWorkflowUsageWarning": true,
     "hooks": {
       "SessionStart": [ ... ]
     }
   }
   ```

   > **如果你已经有 `"hooks"` 键**：不要整个替换。把上面 9 个事件逐个并进去。
   > 同名事件（比如你已经有 `Stop`）就往那个事件的**数组里追加**一个元素，别覆盖。

4. **校验 JSON 合法**（settings.json 语法错会导致整个文件的设置静默失效）：

   ```bash
   jq -e . ~/.claude/settings.json >/dev/null && echo "JSON OK"
   jq -r '.hooks | keys | join(", ")' ~/.claude/settings.json
   ```

   第二条应输出 9 个事件名。

5. **让配置生效**：新开一个 Claude Code 会话，或在现有会话里打开一次 `/hooks`（会重载配置）。

---

## 四、验证装好了

跑一轮任意对话，然后：

```bash
cat ~/.claude/task-monitor-events.ndjson
```

应该看到类似（每行一条，紧凑）：

```json
{"ts":"2026-07-21T04:45:51.547Z","session_id":"eda966b4-...","hook_event_name":"Stop","last_assistant_message":"...","cwd":"/Users/you/some-project"}
```

再确认引擎真的把它合进去了：

```bash
cd "/ABSOLUTE/PATH/TO/claude-task-monitor"
node engine/index.js --once | jq -r '.sessions[] | "\(.status)\t\(.statusSource)\t\(.statusDetail)"'
```

`statusSource` 出现 `hook:Stop` / `hook:PermissionRequest` 就说明链路通了。
（没装 hook 时这里只会是 `transcript` / `subagents` / `pid`。）

---

## 五、卸载

1. 从 `~/.claude/settings.json` 里删掉那 9 个事件里 command 含 `emit.js` 的条目。
   如果 `"hooks"` 因此变空，把整个 `"hooks"` 键删掉。
2. 校验：`jq -e . ~/.claude/settings.json >/dev/null && echo OK`
3. 删掉事件文件（可选）：

   ```bash
   rm -f ~/.claude/task-monitor-events.ndjson
   ```

引擎发现文件没了会自动降级回纯轮询，不会报错。

也可以用脚本：

```bash
"/ABSOLUTE/PATH/TO/claude-task-monitor/hooks/install.sh" --uninstall
```

---

## 六、可选：用 install.sh 自动合并

**默认推荐手动合并。** 如果要用脚本：

```bash
cd "/ABSOLUTE/PATH/TO/claude-task-monitor/hooks"
./install.sh
```

它做的事：
- 先备份到 `~/.claude/settings.json.bak.<时间戳>`
- **幂等**：重复跑不会产生重复条目（按 emit.js 路径认领自己的条目，先清后加）
- **不覆盖你自己的 hook**：同一事件下是追加，不是替换
- **原子**：先写临时文件并校验，成功才 `mv`；任何一步失败，原文件一个字节都不动

```bash
./install.sh --uninstall    # 移除
```

---

## 附录 A：脚本行为

`emit.js` 从 stdin 读 hook payload，往 `~/.claude/task-monitor-events.ndjson` 追加一行 JSON。

- **永远 exit 0。** 所有异常都吞掉 —— 监控挂了是监控的事，不能让你的会话报错。
- **硬超时 800ms。** 万一 stdin 不 EOF，到点自己退出，绝不吊死会话。
- **并发安全。** 用 `O_APPEND` + 单次 `write` 写一行（硬限 4KB），多会话同时写不会撕裂。
  实测 60 个并发写入：60 行全部完整，0 条坏行。
- **防膨胀。** 超过 256KB 时轮转，只保留尾部 64KB。轮转用独占锁文件避免多进程互踩，
  用 `rename` 原子替换；陈旧锁（>30s）会被自动清理，不会让轮转永久失效。
- **不透传 `tool_input`。** `Write`/`Edit` 的 `tool_input` 里是**整个文件内容**，
  转发它会瞬间撑爆事件文件，也等于把你的源码明文落进一个长期存在的日志。
  引擎的 `status.js` 从没消费过这个字段，丢掉零损失。
- **超大 payload 不丢事件。** `PermissionRequest` 可能带几 MB 的 `tool_input`；
  超过 128KB 就不走 `JSON.parse`，改成只在头部 64KB 里抠出需要的标量字段。
  实测 4MB payload 仍能正确提取 `session_id` / `tool_name`。

### 环境变量

| 变量 | 作用 |
|---|---|
| `TASK_MONITOR_EVENTS_FILE` | 覆盖事件文件路径（测试用） |
| `CLAUDE_CONFIG_DIR` | 覆盖 `~/.claude`，与引擎的 `paths.js` 保持一致 |

### 实测性能

单次调用约 **43ms**（几乎全是 node 冷启动）。因为只挂低频事件，
一轮对话大约触发 2~10 次；且 `async: true` 让它完全不在关键路径上。

---

## 附录 B：事件名是怎么确认的

本机 Claude Code **2.1.114**。事件名和 payload 字段不是猜的，是从二进制里的 zod schema 直接读出来的：

```bash
strings -a ~/.local/share/claude/versions/2.1.114 | grep -o '.\{40\}literal("PermissionRequest").\{200\}'
```

确认到的 payload 结构：

- 公共字段：`session_id`、`transcript_path`、`cwd`、`permission_mode?`、`agent_id?`
- `Stop`：`stop_hook_active`、`last_assistant_message?`
- `PermissionRequest`：`tool_name`、`tool_input`、`permission_suggestions?`
- `PermissionDenied`：`tool_name`、`tool_input`、`tool_use_id`、`reason`
- `Notification`：`message`、`title?`、`notification_type`
- `SessionStart`：`source`（`startup`/`resume`/`clear`/`compact`）、`agent_type?`、`model?`
- `StopFailure`：`error`、`error_details?`、`last_assistant_message?`
- `SessionEnd`：`reason`

### 版本差异注意

- 2.1.114 的 hook 配置**只支持 shell 字符串形式的 `command`**，
  没有更新版本里的 exec 形式 `args` 数组。所以路径必须自己用单引号包好
  （本项目路径含空格和中文，不加引号必炸）。
- 另有会话报 **2.1.215**。上面 9 个事件名在两个版本里都存在，配置可以通用。
  新版本额外多了一些事件，引擎对未知事件是"记录但不改状态"，加了也不会出错。
