'use strict';
const path = require('path');
const { readSessions } = require('./sessions');
const { createTranscriptLocator, createTranscriptReader, createAgentActivityReader } = require('./transcript');
const { createTodoReader, EMPTY_TODOS } = require('./todos');
const { createEventReader } = require('./events');
const { decide, STATUS, truncate } = require('./status');
const log = require('./log');

function projectNameOf(cwd) {
  if (typeof cwd !== 'string' || !cwd) return null;
  const base = path.basename(cwd.replace(/\/+$/, ''));
  return base || cwd;
}

function createEngine() {
  const locate = createTranscriptLocator();
  const readTranscript = createTranscriptReader();
  const readAgentActivity = createAgentActivityReader();
  const readTodos = createTodoReader();
  const readEvents = createEventReader();

  // ★ 每个会话最后一次「判得出来」的状态。
  //   尾部窗口偶尔读不到完整对话条目时（巨型 tool_result），沿用它，
  //   而不是把"不知道"渲染成"空闲" —— 后者正是状态疯狂闪烁的根源。
  const lastGood = new Map(); // sessionId -> verdict

  return function snapshot() {
    const startedNs = process.hrtime.bigint();
    const now = Date.now();

    let events = new Map();
    try {
      events = readEvents();
    } catch (err) {
      log.warn('events', err); // hook 文件坏了不影响主流程
    }

    const sessions = readSessions();
    const rows = [];

    for (const s of sessions) {
      try {
        rows.push(buildRow(s, events, now));
      } catch (err) {
        // ★ 单个会话解析失败绝不能拖垮整个进程，降级成一条最小可用记录
        log.warn('session', s.sessionId, err);
        rows.push({
          sessionId: s.sessionId,
          name: s.name || null,
          title: null,
          cwd: s.cwd || null,
          projectName: projectNameOf(s.cwd),
          status: STATUS.UNKNOWN,
          statusDetail: `解析失败：${err && err.message ? err.message : 'unknown'}`,
          statusSource: 'error',
          lastActivityAt: null,
          idleSeconds: null,
          elapsedSeconds: s.startedAt ? Math.max(0, Math.round((now - s.startedAt) / 1000)) : null,
          todos: { ...EMPTY_TODOS },
          pid: s.pid,
          isAlive: s.isAlive,
          degraded: true,
        });
      }
    }

    // 稳定排序：活跃的排前面，然后按最近活动倒序
    const rank = { running: 0, waiting_permission: 1, waiting_input: 2, error: 3, idle: 4, unknown: 5, dead: 6 };
    rows.sort((a, b) => {
      const r = (rank[a.status] ?? 9) - (rank[b.status] ?? 9);
      if (r !== 0) return r;
      return (b.lastActivityAt || 0) - (a.lastActivityAt || 0);
    });

    // 会话消失了就别留着它的历史判定，否则 Map 只增不减
    if (lastGood.size > rows.length) {
      const alive = new Set(rows.map((r) => r.sessionId));
      for (const k of lastGood.keys()) if (!alive.has(k)) lastGood.delete(k);
    }

    const elapsedMs = Number(process.hrtime.bigint() - startedNs) / 1e6;
    return {
      ts: new Date(now).toISOString(),
      scanMs: Math.round(elapsedMs * 100) / 100,
      sessionCount: rows.length,
      sessions: rows,
    };
  };

  function buildRow(s, events, now) {
    const file = locate(s.sessionId, s.cwd);
    const tx = file ? readTranscript(file) : null;
    const txMtimeMs = tx && tx.fileMtimeMs ? tx.fileMtimeMs : 0;

    // 同名的会话子目录（去掉 .jsonl）下有 subagents/ workflows/ tool-results/
    const sessionDir = file ? file.replace(/\.jsonl$/, '') : null;
    const agentMtimeMs = sessionDir ? readAgentActivity(sessionDir) : 0;

    // actionable = 最近一条能改变状态的事件；latest = 最近一条任意事件（可能是未知事件）。
    // 状态只认 actionable，附加信息（last_assistant_message）两者都可以出。
    const slot = events.get(s.sessionId) || null;
    const event = slot ? slot.actionable : null;
    const anyEvent = slot ? slot.latest : null;

    let verdict = decide({
      isAlive: s.isAlive,
      tx,
      txMtimeMs,
      agentMtimeMs,
      event,
      now,
    });

    if (verdict.source === 'insufficient') {
      const prev = lastGood.get(s.sessionId);
      // 沿用上次的判定；source 打上标记，方便排查时看出这一帧是沿用的
      if (prev) verdict = { ...prev, source: `${prev.source}~held` };
    } else if (verdict.status !== STATUS.UNKNOWN) {
      lastGood.set(s.sessionId, verdict);
    }

    const lastActivityMs = Math.max(
      txMtimeMs,
      agentMtimeMs,
      (tx && tx.lastTs) || 0,
      (anyEvent && anyEvent.hasWallClock) ? anyEvent.at : 0,
    ) || null;

    let todos = EMPTY_TODOS;
    try {
      todos = readTodos(s.sessionId);
    } catch (err) {
      log.debug('todos', s.sessionId, err.message);
    }

    // 标题：自定义标题 > AI 标题 > 最近一条用户提示 > 项目名 > 会话代号
    const title = (tx && tx.title)
      || truncate(tx && tx.lastPrompt, 60)
      || projectNameOf(s.cwd)
      || s.name
      || s.sessionId.slice(0, 8);

    // 最后一句话：优先用 hook 带来的 last_assistant_message（不用碰 134MB 文件）
    const lastMessage = truncate(
      (anyEvent && anyEvent.lastAssistantMessage)
        || (event && event.lastAssistantMessage)
        || (tx && tx.lastAssistantText),
      280,
    );

    return {
      sessionId: s.sessionId,
      name: s.name || null,
      title,
      cwd: s.cwd || null,
      projectName: projectNameOf(s.cwd),
      status: verdict.status,
      statusDetail: verdict.statusDetail,
      statusSource: verdict.source,
      lastActivityAt: lastActivityMs ? new Date(lastActivityMs).toISOString() : null,
      idleSeconds: lastActivityMs ? Math.max(0, Math.round((now - lastActivityMs) / 1000)) : null,
      elapsedSeconds: s.startedAt ? Math.max(0, Math.round((now - s.startedAt) / 1000)) : null,
      todos: { done: todos.done, total: todos.total, current: todos.current },
      pid: s.pid,
      isAlive: s.isAlive,
      // ---- 附加字段，Swift 端可忽略 ----
      lastMessage,
      mode: (tx && tx.mode) || null,
      version: s.version || null,
      entrypoint: s.entrypoint || null,
      transcriptPath: file,
      transcriptFound: Boolean(file),
    };
  }
}

module.exports = { createEngine, STATUS };
