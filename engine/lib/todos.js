'use strict';
// todo 条目：~/.claude/tasks/<sessionId>/<n>.json
// 每个条目 { id, subject, description, activeForm, status, blocks, blockedBy }
const fs = require('fs');
const path = require('path');
const { TASKS_DIR } = require('./paths');
const log = require('./log');

const EMPTY = { done: 0, total: 0, current: null };

function createTodoReader() {
  const cache = new Map(); // dir -> { mtimeMs, value }

  return function readTodos(sessionId) {
    const dir = path.join(TASKS_DIR, sessionId);
    let st;
    try {
      st = fs.statSync(dir);
    } catch (_) {
      cache.delete(dir);
      return EMPTY; // 没有 todo 目录是正常状态，不是错误
    }
    const hit = cache.get(dir);
    // 目录 mtime 只在增删文件时变；条目内容改写不动目录 mtime，
    // 所以还要看目录里最大的文件 mtime。下面统一取 max。
    let items = [];
    let maxMtime = st.mtimeMs;
    let names;
    try {
      names = fs.readdirSync(dir);
    } catch (err) {
      log.debug('todos-readdir', dir, err.message);
      return hit ? hit.value : EMPTY;
    }

    const jsonNames = names.filter((n) => n.endsWith('.json'));
    const stats = [];
    for (const n of jsonNames) {
      try {
        const s = fs.statSync(path.join(dir, n));
        if (s.mtimeMs > maxMtime) maxMtime = s.mtimeMs;
        stats.push(n);
      } catch (_) { /* 文件刚被删，跳过 */ }
    }

    if (hit && hit.mtimeMs === maxMtime && hit.count === stats.length) {
      return hit.value;
    }

    for (const n of stats) {
      try {
        const raw = fs.readFileSync(path.join(dir, n), 'utf8');
        const obj = JSON.parse(raw);
        if (obj && typeof obj === 'object' && obj.id != null) items.push(obj);
      } catch (_) { /* 单条坏了不影响其它条目 */ }
    }

    // id 是字符串形式的数字，按数值排序还原用户看到的顺序
    items.sort((a, b) => {
      const x = Number.parseInt(a.id, 10);
      const y = Number.parseInt(b.id, 10);
      if (Number.isFinite(x) && Number.isFinite(y)) return x - y;
      return String(a.id).localeCompare(String(b.id));
    });

    const total = items.length;
    const done = items.filter((t) => t.status === 'completed').length;
    const active = items.find((t) => t.status === 'in_progress')
      || items.find((t) => t.status === 'pending');
    const value = {
      done,
      total,
      current: active ? (active.activeForm || active.subject || null) : null,
      currentStatus: active ? active.status : null,
    };

    cache.set(dir, { mtimeMs: maxMtime, count: stats.length, value });
    return value;
  };
}

module.exports = { createTodoReader, EMPTY_TODOS: EMPTY };
