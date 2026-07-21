#!/usr/bin/env bash
# Claude 任务监控 —— hook 配置合并器
#
# 默认推荐手动合并（见 install.md）。这个脚本只是把同样的事做成幂等的。
# 它会改你的 ~/.claude/settings.json，所以：
#   - 动手前先备份（settings.json.bak.<时间戳>）
#   - 幂等：重复跑不会产生重复条目
#   - 原子：先写临时文件 + 校验，成功才 mv 覆盖；失败原文件一个字节都不动
#
# 用法：
#   ./install.sh              合并 hook 配置
#   ./install.sh --uninstall  移除本项目的 hook 配置
#   CLAUDE_SETTINGS=/tmp/x.json ./install.sh    指定别的 settings 文件（测试用）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMIT="$SCRIPT_DIR/emit.js"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

EVENTS=(SessionStart UserPromptSubmit PermissionRequest PermissionDenied
        Notification SubagentStart Stop StopFailure SessionEnd)

die() { echo "错误：$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "需要 jq（macOS 14+ 自带 /usr/bin/jq）"
[ -f "$EMIT" ] || die "找不到 $EMIT"

# 解析 node 的绝对路径 —— hook 在非交互 shell 里跑，PATH 里通常没有 node
NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
[ -n "$NODE_BIN" ] || die "找不到 node，请设置 NODE_BIN=/path/to/node"
[ -x "$NODE_BIN" ] || die "$NODE_BIN 不可执行"
"$NODE_BIN" -e 'process.exit(0)' >/dev/null 2>&1 || die "$NODE_BIN 跑不起来"

MODE="install"
[ "${1:-}" = "--uninstall" ] && MODE="uninstall"

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq -e . "$SETTINGS" >/dev/null 2>&1 || die "$SETTINGS 不是合法 JSON，先修好再来"

# ---- 备份 -------------------------------------------------------------------
BACKUP="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
cp -p "$SETTINGS" "$BACKUP"
echo "已备份 -> $BACKUP"

TMP="$SETTINGS.tmp.$$"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

# ---- 先无条件清掉本项目已有的条目（幂等的关键）--------------------------------
# 认领标准：command 里含有 emit.js 的绝对路径。
CLEAN='
def clean($p):
  if (.hooks | type) != "object" then .
  else
      .hooks |= (
        with_entries(
          .value |= (
            map(.hooks |= map(select(((.command // "") | contains($p)) | not)))
            | map(select((.hooks | length) > 0))
          )
        )
        | with_entries(select((.value | length) > 0))
      )
    | if (.hooks | length) == 0 then del(.hooks) else . end
  end;
clean($p)
'

if [ "$MODE" = "uninstall" ]; then
  jq --arg p "$EMIT" "$CLEAN" "$SETTINGS" > "$TMP"
  jq -e . "$TMP" >/dev/null || die "生成的 JSON 非法，已放弃（原文件未改动）"
  mv "$TMP" "$SETTINGS"
  echo "已移除 Claude 任务监控的 hook 配置。"
  echo "事件文件如需一并删除： rm -f ~/.claude/task-monitor-events.ndjson"
  exit 0
fi

# ---- 构造新条目并追加（不覆盖用户在同一事件上的其它 hook）----------------------
NEW_HOOKS=$("$NODE_BIN" -e '
const [nodeBin, emit, ...events] = process.argv.slice(1);
const out = {};
for (const e of events) {
  out[e] = [{ hooks: [{
    type: "command",
    command: `${nodeBin} ${JSON.stringify(emit).replace(/^"|"$/g, "'"'"'")} ${e}`,
    timeout: 5,
    async: true,
  }]}];
}
process.stdout.write(JSON.stringify(out));
' "$NODE_BIN" "$EMIT" "${EVENTS[@]}")

echo "$NEW_HOOKS" | jq -e . >/dev/null || die "构造 hook 配置失败"

jq --arg p "$EMIT" --argjson new "$NEW_HOOKS" "
$CLEAN
| .hooks //= {}
| reduce (\$new | to_entries[]) as \$e (.; .hooks[\$e.key] = ((.hooks[\$e.key] // []) + \$e.value))
" "$SETTINGS" > "$TMP"

jq -e . "$TMP" >/dev/null || die "生成的 JSON 非法，已放弃（原文件未改动）"
jq -e --arg p "$EMIT" '[.hooks[][] | .hooks[] | select((.command // "") | contains($p))] | length == 9' "$TMP" >/dev/null \
  || die "校验失败：预期 9 条 hook，已放弃（原文件未改动）"

mv "$TMP" "$SETTINGS"
echo "已写入 $SETTINGS（9 个事件）"
echo
echo "生效方式：新开一个 Claude Code 会话，或在现有会话里打开一次 /hooks 让它重载配置。"
echo "验证：跑一轮对话后 cat ~/.claude/task-monitor-events.ndjson 应该能看到 Stop 事件。"
