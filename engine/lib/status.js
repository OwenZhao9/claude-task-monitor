'use strict';
// 状态判定。优先级：进程存活 > hook 事件（够新才信） > 流水文件推断。

const STATUS = {
  DEAD: 'dead',                             // pid 已回收
  ERROR: 'error',                           // API 报错 / StopFailure
  WAITING_PERMISSION: 'waiting_permission', // 等用户授权工具
  WAITING_INPUT: 'waiting_input',           // 等用户回答（AskUserQuestion / MCP elicitation）
  RUNNING: 'running',                       // Claude 正在干活
  IDLE: 'idle',                             // 一轮结束，等用户下一句
  UNKNOWN: 'unknown',                       // 找不到流水文件等
};

// 这些工具挂起 = 在等用户，不是在算
const USER_BLOCKING_TOOLS = new Set(['AskUserQuestion', 'ExitPlanMode']);

// 子代理树比主流水新超过这个阈值，说明后台确实在跑
const AGENT_LEAD_MS = 2000;
// api_error 多久内算"还在错"
const API_ERROR_WINDOW_MS = 90 * 1000;
// ★ 最新一条对话超过这么久没动静，就不能再叫 running。
//   实测踩到：会话被 resume 时只追加 last-prompt/mode 这类无时间戳的元数据行，
//   文件 mtime 变新但对话没推进 —— 只看 mtime 会把闲置会话报成"思考中"。
const STALL_MS = 5 * 60 * 1000;
// 工具挂起超过这么久，八成是卡在授权弹窗上（没挂 hook 时无法确证，只在文案里提示）
const TOOL_SLOW_MS = 60 * 1000;

function truncate(s, n) {
  if (typeof s !== 'string') return null;
  const t = s.replace(/\s+/g, ' ').trim();
  return t.length > n ? t.slice(0, n) + '…' : t;
}

function fromEvent(ev) {
  switch (ev.name) {
    case 'PermissionRequest':
      return {
        status: STATUS.WAITING_PERMISSION,
        detail: ev.toolName ? `等待授权：${ev.toolName}` : '等待授权',
      };
    case 'PermissionDenied':
      return { status: STATUS.RUNNING, detail: `已拒绝 ${ev.toolName || '工具'}` };
    case 'Notification':
      if (ev.notificationType === 'permission_prompt') {
        return { status: STATUS.WAITING_PERMISSION, detail: truncate(ev.message, 120) || '等待授权' };
      }
      if (ev.notificationType === 'idle_prompt') {
        // 同上：措辞跟 IDLE 徽标对齐，别和阻塞式"等你输入"混淆
        return { status: STATUS.IDLE, detail: '已闲置，等你下一句' };
      }
      if (ev.notificationType === 'elicitation_dialog') {
        return { status: STATUS.WAITING_INPUT, detail: truncate(ev.message, 120) || '等待用户输入' };
      }
      return null; // 其它通知类型不改变状态
    case 'UserPromptSubmit':
      return { status: STATUS.RUNNING, detail: '处理用户指令' };
    case 'SubagentStart':
      return { status: STATUS.RUNNING, detail: '子代理运行中' };
    case 'PreToolUse':
    case 'PostToolUse':
      return { status: STATUS.RUNNING, detail: ev.toolName ? `执行 ${ev.toolName}` : '执行工具' };
    case 'PostToolUseFailure':
      return { status: STATUS.RUNNING, detail: `${ev.toolName || '工具'} 执行失败` };
    case 'Stop':
      return { status: STATUS.IDLE, detail: '已完成，等待用户' };
    case 'StopFailure':
      return { status: STATUS.ERROR, detail: `中断：${ev.error || 'unknown'}` };
    case 'SessionEnd':
      return { status: STATUS.DEAD, detail: `会话结束（${ev.reason || 'other'}）` };
    case 'SessionStart':
      return { status: STATUS.IDLE, detail: '会话已启动' };
    default:
      // ★ 未知事件：记录但不改状态，也绝不抛异常
      return null;
  }
}

/**
 * @param {object} ctx
 *   isAlive, tx(流水归约结果|null), txMtimeMs, agentMtimeMs, event(hook事件|null), now
 */
function decide(ctx) {
  const { isAlive, tx, txMtimeMs, agentMtimeMs, event, now } = ctx;

  if (!isAlive) {
    return { status: STATUS.DEAD, statusDetail: '进程已退出', source: 'pid' };
  }

  // ---- 文件侧先算一个基线，事件只在更新时覆盖它 ----
  const base = decideFromFiles(tx, txMtimeMs, agentMtimeMs, now);

  if (event) {
    const mapped = fromEvent(event);
    if (mapped) {
      // 只有带真实墙钟时间、且比流水活动更新的事件才允许覆盖。
      // 没有墙钟时间的事件（用序号兜底的）一律不覆盖，避免陈旧事件顶掉新状态。
      const fileActivity = Math.max(txMtimeMs || 0, agentMtimeMs || 0, (tx && tx.lastTs) || 0);
      const fresh = event.hasWallClock
        && event.at >= fileActivity - 1000
        && now - event.at < 15 * 60 * 1000;
      if (fresh) {
        return { status: mapped.status, statusDetail: mapped.detail, source: `hook:${event.name}` };
      }
    }
  }

  return base;
}

function decideFromFiles(tx, txMtimeMs, agentMtimeMs, now) {
  if (!tx) {
    return { status: STATUS.UNKNOWN, statusDetail: '未找到会话流水', source: 'none' };
  }

  // 1) 挂起的工具调用 —— 最确定的信号
  //    只看属于"最新一轮"的挂起工具，避免尾部窗口切出来的孤儿 tool_use 造成误判。
  const pending = tx.pendingTools.filter((t) => t.ts >= (tx.lastConvTs || 0));
  if (pending.length) {
    const blocking = pending.find((t) => USER_BLOCKING_TOOLS.has(t.name));
    if (blocking) {
      return {
        status: STATUS.WAITING_INPUT,
        statusDetail: blocking.name === 'ExitPlanMode' ? '等待用户确认计划' : '等待用户回答',
        source: 'transcript',
      };
    }
    const names = pending.map((t) => t.name).join(', ');
    const waited = now - Math.min(...pending.map((t) => t.ts));
    // 挂起很久的工具：可能是长任务，也可能卡在授权弹窗。没有 hook 就不下断言，
    // 只把等待时长暴露给 UI，让用户自己判断。
    const hint = waited > TOOL_SLOW_MS ? `（已 ${Math.round(waited / 1000)}s，可能在等授权）` : '';
    return { status: STATUS.RUNNING, statusDetail: `执行 ${names}${hint}`, source: 'transcript' };
  }

  // 2) API 出错且还在重试窗口内
  if (tx.lastApiError && tx.lastApiErrorTs && now - tx.lastApiErrorTs < API_ERROR_WINDOW_MS) {
    const e = tx.lastApiError;
    const retry = e.retryAttempt != null ? `（重试 ${e.retryAttempt}/${e.maxRetries}）` : '';
    return { status: STATUS.ERROR, statusDetail: `API 错误 ${e.message}${retry}`, source: 'transcript' };
  }

  // 3) ★ 子代理 / 工作流在跑：主流水此时完全不追加，只看主文件会误判成 idle
  if (agentMtimeMs && txMtimeMs && agentMtimeMs > txMtimeMs + AGENT_LEAD_MS) {
    return { status: STATUS.RUNNING, statusDetail: '子代理运行中', source: 'subagents' };
  }

  // 4) 按"最新一条对话是谁说的"判定 —— 不依赖 mtime 新鲜度，
  //    否则 Claude 刚说完话的头几十秒会被错判成 running。
  if (tx.lastKind === 'assistant') {
    // ★ 文案要和 IDLE 徽标读起来一致。原来写"等待用户输入"，
    //   在 UI 上和灰色的"空闲"徽标并排出现，看着自相矛盾像 bug。
    //   真正阻塞式的"等你回答"是 WAITING_INPUT（AskUserQuestion 等），不是这里。
    return { status: STATUS.IDLE, statusDetail: '一轮结束，等你下一句', source: 'transcript' };
  }

  // 用户/工具结果之后还没等到回复 = Claude 在算。但要防"陈旧未完成回合"：
  const stalled = !tx.lastConvTs || now - tx.lastConvTs > STALL_MS;
  if (tx.lastKind === 'user_prompt') {
    return stalled
      ? { status: STATUS.IDLE, statusDetail: '空闲（上一回合未产出）', source: 'transcript' }
      : { status: STATUS.RUNNING, statusDetail: '思考中', source: 'transcript' };
  }
  if (tx.lastKind === 'tool_result') {
    return stalled
      ? { status: STATUS.IDLE, statusDetail: '空闲（上一回合未产出）', source: 'transcript' }
      : { status: STATUS.RUNNING, statusDetail: '处理工具结果', source: 'transcript' };
  }
  // ★ lastKind 为 null = 尾部窗口里一条完整对话条目都没有。
  //   这是"读得不够"，不是"会话空闲"。以前这里直接返回 IDLE，
  //   导致用巨型 tool_result（浏览器截图等）的会话在 空闲<->干活 之间疯狂闪。
  //   现在明确报 UNKNOWN，由上层沿用上一次的已知状态。
  if (tx.lastKind === null) {
    return { status: STATUS.UNKNOWN, statusDetail: '数据不足', source: 'insufficient' };
  }

  return { status: STATUS.IDLE, statusDetail: '空闲', source: 'transcript' };
}

module.exports = { decide, STATUS, truncate };
