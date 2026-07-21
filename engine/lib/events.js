'use strict';
// 可选的 hook 事件流：~/.claude/task-monitor-events.ndjson
// 文件不存在 = 用户还没装 hook，属于正常情况，静默降级到纯文件轮询。
const { createTailCache } = require('./tail');
const { EVENTS_FILE } = require('./paths');

// hook 事件比文件轮询精确得多，但只在"足够新"的时候才允许覆盖文件推断出的状态。
const EVENT_TRUST_MS = 15 * 60 * 1000;

// 已知事件白名单。★ 未知事件必须记录但不崩 ——
// 事件列表在快速扩张（2.1.114 已 27 个，2.1.215 可能更多），穷举 switch 早晚炸。
const KNOWN = new Set([
  'SessionStart', 'UserPromptSubmit', 'Stop', 'StopFailure', 'Notification',
  'PermissionRequest', 'PermissionDenied', 'SessionEnd', 'TaskCreated',
  'TaskCompleted', 'SubagentStart', 'SubagentStop', 'PostToolUseFailure',
  'PreToolUse', 'PostToolUse', 'PreCompact', 'PostCompact', 'CwdChanged',
]);

// 能改变状态的事件。★ 必须和"最新事件"分开跟踪：
// 否则 PermissionRequest 后面跟一条 TaskCreated / 未知事件，就会把"等授权"冲掉，
// 用户面前的红点消失，而 Claude 还卡在授权弹窗上。
const ACTIONABLE = new Set([
  'SessionStart', 'UserPromptSubmit', 'Stop', 'StopFailure', 'Notification',
  'PermissionRequest', 'PermissionDenied', 'SessionEnd', 'SubagentStart',
  'PreToolUse', 'PostToolUse', 'PostToolUseFailure',
]);

function eventTime(ev) {
  for (const k of ['ts', 'timestamp', 'time', 'at']) {
    const v = ev[k];
    if (typeof v === 'number' && Number.isFinite(v)) return v > 1e12 ? v : v * 1000;
    if (typeof v === 'string') {
      const ms = Date.parse(v);
      if (Number.isFinite(ms)) return ms;
    }
  }
  return 0;
}

function createEventReader(file = EVENTS_FILE) {
  // 事件文件可能被多个并发会话 append，尾部撕裂是预期内的，坏行直接丢。
  const tails = createTailCache(128 * 1024);

  return function readEvents() {
    const bySession = tails.get(file, (entries) => {
      const map = new Map(); // sid -> { latest, actionable }
      let seq = 0;
      for (const ev of entries) {
        seq++;
        if (!ev || typeof ev !== 'object') continue;
        const sid = ev.session_id || ev.sessionId;
        const rawName = ev.hook_event_name || ev.event;
        if (!sid || !rawName) continue;
        const name = String(rawName);
        const at = eventTime(ev) || seq; // 没时间戳就用文件顺序兜底
        const rec = {
          name,
          known: KNOWN.has(name),
          at,
          hasWallClock: eventTime(ev) > 0,
          notificationType: ev.notification_type || null,
          message: typeof ev.message === 'string' ? ev.message.slice(0, 300) : null,
          toolName: ev.tool_name || null,
          toolInput: ev.tool_input ?? null,
          error: ev.error || null,
          reason: ev.reason || null,
          source: ev.source || null,
          // ★ Stop 自带 last_assistant_message，拿到它就完全不用 seek 那个 134MB 文件
          lastAssistantMessage: typeof ev.last_assistant_message === 'string'
            ? ev.last_assistant_message.slice(0, 2048) // 长度未知，强制截断兜底
            : null,
          transcriptPath: ev.transcript_path || null,
          cwd: ev.cwd || null,
        };

        let slot = map.get(sid);
        if (!slot) { slot = { latest: null, actionable: null }; map.set(sid, slot); }
        if (!slot.latest || at >= slot.latest.at) slot.latest = rec;
        if (ACTIONABLE.has(name) && (!slot.actionable || at >= slot.actionable.at)) {
          slot.actionable = rec;
        }
      }
      return map;
    });
    return bySession || new Map();
  };
}

module.exports = { createEventReader, EVENT_TRUST_MS };
