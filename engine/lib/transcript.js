'use strict';
// 定位并尾读会话流水 ~/.claude/projects/<slug>/<sessionId>.jsonl
const fs = require('fs');
const path = require('path');
const { PROJECTS_DIR, slugForCwd } = require('./paths');
const { createTailCache } = require('./tail');
const log = require('./log');

// jsonl 里混着的元数据行，不参与"最后一条对话是什么"的判定。
const META_TYPES = new Set([
  'last-prompt', 'ai-title', 'custom-title', 'mode', 'summary',
  'file-history-snapshot', 'queue-operation', 'attachment',
]);

/* ---------------------------------------------------------------- 定位 */

function createTranscriptLocator() {
  const resolved = new Map();  // sessionId -> jsonl 路径
  let scanIndex = null;        // sessionId -> 路径（全量扫描结果）
  let scanAt = 0;

  function verify(p) {
    try { return fs.statSync(p).isFile(); } catch (_) { return false; }
  }

  // 兜底：扫 projects/ 每个子目录，找真正含 <sessionId>.jsonl 的那个。
  // slug 规则对非 ASCII 是有损的（每个汉字变一个 '-'），不同 cwd 可能撞同一个 slug，
  // 所以快路径命中失败时必须以文件实际存在为准。
  function rescan() {
    const idx = new Map();
    let dirs;
    try {
      dirs = fs.readdirSync(PROJECTS_DIR, { withFileTypes: true });
    } catch (err) {
      if (err.code !== 'ENOENT') log.warn('projects-dir', err);
      return idx;
    }
    for (const d of dirs) {
      if (!d.isDirectory()) continue;
      const dir = path.join(PROJECTS_DIR, d.name);
      let files;
      try { files = fs.readdirSync(dir); } catch (_) { continue; }
      for (const f of files) {
        if (!f.endsWith('.jsonl')) continue;
        idx.set(f.slice(0, -6), path.join(dir, f));
      }
    }
    scanAt = Date.now();
    return idx;
  }

  return function locate(sessionId, cwd) {
    const cached = resolved.get(sessionId);
    if (cached && verify(cached)) return cached;

    // 快路径：由 cwd 推 slug 直接拼路径
    const slug = slugForCwd(cwd);
    if (slug) {
      const guess = path.join(PROJECTS_DIR, slug, `${sessionId}.jsonl`);
      if (verify(guess)) { resolved.set(sessionId, guess); return guess; }
    }

    // 慢路径：全量扫描（结果缓存 30s，避免每轮都扫）
    if (!scanIndex || Date.now() - scanAt > 30000) scanIndex = rescan();
    let found = scanIndex.get(sessionId);
    if (!found || !verify(found)) {
      scanIndex = rescan();
      found = scanIndex.get(sessionId);
    }
    if (found && verify(found)) { resolved.set(sessionId, found); return found; }
    return null;
  };
}

/* ------------------------------------------------------- 子代理活跃度 */

/**
 * 会话目录 ~/.claude/projects/<slug>/<sessionId>/ 下有 subagents/ workflows/ tool-results/。
 * ★ 实测关键点：主 jsonl 在子代理/工作流跑的时候完全不追加，
 *   只看主文件会把一个正在干活的会话误判成 idle。所以要取整棵树的最大 mtime。
 * 有界遍历，防止哪天目录被塞爆把轮询拖垮。
 */
function newestMtimeInTree(dir, maxDepth = 4, budget = { n: 300 }) {
  let newest = 0;
  if (maxDepth < 0 || budget.n <= 0) return newest;
  let ents;
  try {
    ents = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_) { return newest; }

  for (const e of ents) {
    if (budget.n-- <= 0) break;
    if (e.name.startsWith('.')) continue;
    const p = path.join(dir, e.name);
    try {
      if (e.isDirectory()) {
        const sub = newestMtimeInTree(p, maxDepth - 1, budget);
        if (sub > newest) newest = sub;
      } else if (e.isFile()) {
        const m = fs.statSync(p).mtimeMs;
        if (m > newest) newest = m;
      }
    } catch (_) { /* 文件正在被换掉，忽略 */ }
  }
  return newest;
}

function createAgentActivityReader() {
  const cache = new Map(); // dir -> { at, value }
  return function read(sessionDir) {
    const now = Date.now();
    const hit = cache.get(sessionDir);
    // 树遍历比 stat 贵，节流到 900ms（--watch 周期约 1s，等效每轮一次）
    if (hit && now - hit.at < 900) return hit.value;
    let value = 0;
    try {
      if (fs.statSync(sessionDir).isDirectory()) value = newestMtimeInTree(sessionDir);
    } catch (_) { value = 0; }
    cache.set(sessionDir, { at: now, value });
    return value;
  };
}

/* ---------------------------------------------------------------- 归约 */

function tsOf(entry) {
  const t = entry && entry.timestamp;
  if (typeof t !== 'string') return 0;
  const ms = Date.parse(t);
  return Number.isFinite(ms) ? ms : 0;
}

function contentBlocks(entry) {
  const c = entry && entry.message && entry.message.content;
  return Array.isArray(c) ? c : null;
}

function textOf(entry) {
  const blocks = contentBlocks(entry);
  if (blocks) {
    const parts = [];
    for (const b of blocks) {
      if (b && b.type === 'text' && typeof b.text === 'string') parts.push(b.text);
    }
    return parts.join('\n').trim();
  }
  const c = entry && entry.message && entry.message.content;
  return typeof c === 'string' ? c.trim() : '';
}

/**
 * 把尾部 entries 归约成一个小对象。只在文件 mtime 变化时被调用一次。
 *
 * ★ 实测：entries 不是按 timestamp 严格有序的 —— system 子条目会成批延迟落盘，
 *   出现在时间上更晚的 assistant 条目之后。所以：
 *   - "最后活动时间" 取所有条目 timestamp 的最大值，不是最后一行的 timestamp
 *   - "最后一条对话"按 timestamp 挑最大的那条，不是数组末尾那条
 */
function reduceTranscript(entries) {
  const out = {
    lastTs: 0,
    title: null,
    lastPrompt: null,
    mode: null,
    lastAssistantText: null,
    lastKind: null,          // 'assistant' | 'user_prompt' | 'tool_result' | null
    pendingTools: [],        // 已发出但没看到 tool_result 的 tool_use
    lastApiError: null,
    lastApiErrorTs: 0,
    turnEndedTs: 0,          // stop_hook_summary 出现的时间 = 一轮确切结束
    entryCount: entries.length,
  };

  const toolUses = new Map();   // tool_use_id -> { name, ts }
  const satisfied = new Set();  // 见过 tool_result 的 id
  let bestConv = null;
  let bestConvTs = -1;

  for (const e of entries) {
    if (!e || typeof e !== 'object') continue;
    const type = e.type;

    // ---- 元数据行 ----
    if (type === 'custom-title') { if (e.customTitle) out.title = e.customTitle; continue; }
    if (type === 'ai-title') { if (!out.title && e.aiTitle) out.title = e.aiTitle; continue; }
    if (type === 'last-prompt') { if (e.lastPrompt) out.lastPrompt = e.lastPrompt; continue; }
    if (type === 'mode') { if (e.mode) out.mode = e.mode; continue; }

    const ts = tsOf(e);
    if (ts > out.lastTs) out.lastTs = ts;

    if (type === 'system') {
      if (e.subtype === 'api_error' && ts >= out.lastApiErrorTs) {
        out.lastApiErrorTs = ts;
        const msg = e.error && (e.error.formatted || e.error.message);
        out.lastApiError = {
          message: typeof msg === 'string' ? msg.slice(0, 200) : 'api error',
          status: e.error && e.error.status ? e.error.status : null,
          retryAttempt: e.retryAttempt ?? null,
          maxRetries: e.maxRetries ?? null,
        };
      }
      if (e.subtype === 'stop_hook_summary' && ts > out.turnEndedTs) out.turnEndedTs = ts;
      continue;
    }

    if (META_TYPES.has(type)) continue;

    // ---- 真正的对话条目 ----
    // 侧链（子代理内部对话）不参与主会话状态判定
    if (e.isSidechain === true) continue;

    if (type === 'assistant') {
      const blocks = contentBlocks(e);
      if (blocks) {
        for (const b of blocks) {
          if (b && b.type === 'tool_use' && b.id) toolUses.set(b.id, { name: b.name || '?', ts });
        }
      }
      const txt = textOf(e);
      if (txt && ts >= (out._lastAssistantTs || 0)) {
        out._lastAssistantTs = ts;
        out.lastAssistantText = txt;
      }
      if (ts > bestConvTs) { bestConvTs = ts; bestConv = e; }
      continue;
    }

    if (type === 'user') {
      const blocks = contentBlocks(e);
      let isToolResult = false;
      if (blocks) {
        for (const b of blocks) {
          if (b && b.type === 'tool_result') {
            isToolResult = true;
            if (b.tool_use_id) satisfied.add(b.tool_use_id);
          }
        }
      }
      if (ts > bestConvTs) { bestConvTs = ts; bestConv = e; bestConv.__isToolResult = isToolResult; }
      continue;
    }
  }

  delete out._lastAssistantTs;

  for (const [id, info] of toolUses) {
    if (!satisfied.has(id)) out.pendingTools.push({ id, name: info.name, ts: info.ts });
  }
  out.pendingTools.sort((a, b) => a.ts - b.ts);

  if (bestConv) {
    out.lastConvTs = bestConvTs;
    if (bestConv.type === 'assistant') out.lastKind = 'assistant';
    else if (bestConv.__isToolResult) out.lastKind = 'tool_result';
    else out.lastKind = 'user_prompt';
  } else {
    out.lastConvTs = 0;
  }

  return out;
}

function createTranscriptReader() {
  const tails = createTailCache(64 * 1024);
  return function read(file) {
    // ★ 一条对话条目都没解析出来 = 窗口整个落在某条巨型条目内部
    //   （浏览器截图类 tool_result 单条能有 150KB+）。
    //   这不是"会话空闲"，是"读得不够"，让 tail 换更大的窗口重来。
    return tails.get(file, reduceTranscript, (v) => !v || v.lastKind === null);
  };
}

module.exports = {
  createTranscriptLocator,
  createTranscriptReader,
  createAgentActivityReader,
  reduceTranscript,
};
