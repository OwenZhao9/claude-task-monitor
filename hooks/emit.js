#!/usr/bin/env node
'use strict';
/*
 * Claude 任务监控 —— hook 事件推送
 *
 * 这个脚本挂在用户【每一次真实会话】上，所以它的设计约束和普通脚本完全不同：
 *   1. 永远 exit 0。任何异常都吞掉。监控挂了是监控的事，绝不能让用户的会话报错。
 *   2. 不做任何网络/重活。全程只有一次 append（+ 极少数情况下一次轮转）。
 *   3. 有硬超时兜底：万一 stdin 不关（管道对端卡住），到点自己退出，不吊死会话。
 *   4. 并发安全：多个会话可能同时往同一个文件写。用 O_APPEND + 单次 write 小行
 *      保证原子性，绝不 read-modify-write。
 *
 * 消费端是 engine/lib/events.js，字段名严格对齐它读的那几个：
 *   session_id / hook_event_name / ts / notification_type / message /
 *   tool_name / error / reason / source / last_assistant_message /
 *   transcript_path / cwd
 *
 * ★ 故意不透传 tool_input：Write/Edit 的 tool_input 里是整个文件内容，
 *   转发它会瞬间撑爆事件文件，也等于把源码明文落到一个长期存在的日志里。
 *   engine 那边 toolInput 字段收下了但 status.js 从没消费过，丢掉零损失。
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

// ---- 调参区 ----------------------------------------------------------------
const HARD_TIMEOUT_MS = 800;        // stdin 迟迟不 EOF 时的自杀闸
const MAX_BYTES = 256 * 1024;       // 超过就轮转
const KEEP_BYTES = 64 * 1024;       // 轮转后保留的尾部大小
const MAX_LINE = 4096;              // 单行硬上限，保证 O_APPEND 单次 write 的原子性
const PARSE_LIMIT = 128 * 1024;     // 超过这个大小就不走 JSON.parse，改用抽取式解析
const HEAD_SCAN = 64 * 1024;        // 抽取式解析只扫头部（基础字段都排在最前）
const LOCK_STALE_MS = 30 * 1000;    // 轮转锁多久算陈旧

const CLAUDE_HOME = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const EVENTS_FILE = process.env.TASK_MONITOR_EVENTS_FILE
  || path.join(CLAUDE_HOME, 'task-monitor-events.ndjson');

// argv[2]：事件名兜底。正常情况下 stdin 里就有 hook_event_name，
// 但配置里带上它，万一 payload 结构变了也还能认出是哪个事件。
const FALLBACK_EVENT = typeof process.argv[2] === 'string' ? process.argv[2] : null;

let finished = false;
const watchdog = setTimeout(() => finish(''), HARD_TIMEOUT_MS);

// ---- 工具 ------------------------------------------------------------------

function str(v, n) {
  if (typeof v !== 'string' || v === '') return undefined;
  return v.length > n ? v.slice(0, n) : v;
}

/**
 * 抽取式解析：payload 太大时不整体 JSON.parse，直接按 key 抠出需要的标量。
 * 只扫头部 —— PermissionRequest 的对象是 {...基础字段, hook_event_name, tool_name, tool_input}，
 * 我们要的全在 tool_input 之前，所以头部 64KB 足够。
 */
function salvage(head, key) {
  try {
    const re = new RegExp('"' + key + '"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"');
    const m = re.exec(head);
    if (!m) return undefined;
    return JSON.parse('"' + m[1] + '"'); // 交给 JSON 做转义还原，别自己手搓
  } catch (_) {
    return undefined;
  }
}

function parsePayload(raw) {
  if (typeof raw !== 'string' || raw === '') return {};
  if (raw.length <= PARSE_LIMIT) {
    try {
      const o = JSON.parse(raw);
      if (o && typeof o === 'object') return o;
    } catch (_) {
      // 落到下面的抽取式解析
    }
  }
  // 超大 payload（多半是 PermissionRequest 带了个巨大的 tool_input），
  // 或者 JSON 本身坏了 —— 能抠出多少算多少，绝不因此丢掉整条事件。
  const head = raw.slice(0, HEAD_SCAN);
  const out = {};
  for (const k of ['hook_event_name', 'session_id', 'tool_name', 'notification_type',
                   'cwd', 'transcript_path', 'reason', 'error', 'source']) {
    const v = salvage(head, k);
    if (v !== undefined) out[k] = v;
  }
  return out;
}

/** 组装成 engine 认识的一行 NDJSON。缺 session_id 或事件名就返回 null（写了也没人认领）。 */
function buildLine(raw) {
  const p = parsePayload(raw);

  const name = str(p.hook_event_name, 64) || FALLBACK_EVENT;
  const sid = str(p.session_id, 128);
  if (!name || !sid) return null;

  // ts 必须是真墙钟时间：engine 只信 hasWallClock 为真的事件，
  // 没时间戳的事件它会拿文件序号兜底，然后拒绝用它覆盖轮询结果。
  const ev = {
    ts: new Date().toISOString(),
    session_id: sid,
    hook_event_name: name,
  };

  const optional = {
    notification_type: str(p.notification_type, 64),
    message: str(p.message, 300),                      // engine 自己也切到 300
    tool_name: str(p.tool_name, 64),
    error: str(p.error, 200),
    reason: str(p.reason, 200),
    source: str(p.source, 64),
    last_assistant_message: str(p.last_assistant_message, 500),
    transcript_path: str(p.transcript_path, 512),
    cwd: str(p.cwd, 512),
  };
  for (const k of Object.keys(optional)) {
    if (optional[k] !== undefined) ev[k] = optional[k];
  }

  let line = JSON.stringify(ev) + '\n';
  if (line.length > MAX_LINE) {
    // 兜底：真超长就砍掉最占地方的两个字段，保住状态判定必需的部分
    delete ev.last_assistant_message;
    delete ev.message;
    line = JSON.stringify(ev) + '\n';
    if (line.length > MAX_LINE) {
      line = JSON.stringify({ ts: ev.ts, session_id: sid, hook_event_name: name }) + '\n';
    }
  }
  return line;
}

/**
 * 防无限膨胀。轮转天生是 read-modify-write，所以：
 *   - 用 'wx' 独占创建锁文件，同一时刻只让一个进程转；
 *   - 用 rename 原子替换，读侧永远看到一个完整文件；
 *   - 转丢几行是可以接受的（这是监控数据，不是账本）。
 */
function rotate() {
  let st;
  try {
    st = fs.statSync(EVENTS_FILE);
  } catch (_) {
    return; // 文件还不存在，没什么好转的
  }
  if (st.size <= MAX_BYTES) return;

  const lock = EVENTS_FILE + '.lock';
  let lfd;
  try {
    lfd = fs.openSync(lock, 'wx', 0o600);
  } catch (_) {
    // 没抢到锁。检查是不是陈旧锁（持锁进程被 kill 了会留下它，
    // 不清理的话轮转就永久失效，文件会一直涨）。
    try {
      const lst = fs.statSync(lock);
      if (Date.now() - lst.mtimeMs > LOCK_STALE_MS) fs.unlinkSync(lock);
    } catch (_) {}
    return; // 这一轮不转，下次事件会再试
  }

  const tmp = EVENTS_FILE + '.' + process.pid + '.tmp';
  try {
    const fd = fs.openSync(EVENTS_FILE, 'r');
    let buf;
    try {
      const size = fs.fstatSync(fd).size;
      const start = Math.max(0, size - KEEP_BYTES);
      buf = Buffer.allocUnsafe(size - start);
      let got = 0;
      while (got < buf.length) {
        const n = fs.readSync(fd, buf, got, buf.length - got, start + got);
        if (n <= 0) break;
        got += n;
      }
      buf = buf.subarray(0, got);
    } finally {
      try { fs.closeSync(fd); } catch (_) {}
    }

    // 头部大概率是被切断的半行，丢掉
    const nl = buf.indexOf(0x0a);
    buf = nl >= 0 ? buf.subarray(nl + 1) : Buffer.alloc(0);

    fs.writeFileSync(tmp, buf, { mode: 0o600 });
    fs.renameSync(tmp, EVENTS_FILE); // 原子
  } catch (_) {
    try { fs.unlinkSync(tmp); } catch (_) {} // 失败不留半截文件
  } finally {
    try { fs.closeSync(lfd); } catch (_) {}
    try { fs.unlinkSync(lock); } catch (_) {}
  }
}

/** 单次 write 到 O_APPEND 打开的 fd —— 这是多进程并发追加的原子性保证。 */
function append(line) {
  let fd;
  try {
    fd = fs.openSync(EVENTS_FILE, 'a', 0o600);
    fs.writeSync(fd, line);
  } catch (_) {
    // 磁盘满 / 权限问题 / 目录不存在：静默放弃，绝不影响会话
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch (_) {} }
  }
}

function finish(raw) {
  if (finished) return;
  finished = true;
  try { clearTimeout(watchdog); } catch (_) {}
  try {
    const line = buildLine(raw);
    if (line) {
      rotate();   // 先转再写，保证这条新事件一定落在轮转之后的文件里
      append(line);
    }
  } catch (_) {
    // 任何意外都不允许冒泡
  }
  process.exit(0);
}

// ---- main ------------------------------------------------------------------

try {
  const chunks = [];
  let total = 0;
  process.stdin.on('data', (c) => {
    total += c.length;
    if (total <= 8 * 1024 * 1024) chunks.push(c); // 8MB 封顶，超出的直接不要
  });
  process.stdin.on('end', () => {
    let raw = '';
    try { raw = Buffer.concat(chunks).toString('utf8'); } catch (_) {}
    finish(raw);
  });
  process.stdin.on('error', () => finish(''));
  process.stdin.resume();
} catch (_) {
  finish('');
}

// 最后一道保险：连未捕获异常都不许改变退出码
process.on('uncaughtException', () => finish(''));
process.on('unhandledRejection', () => finish(''));
