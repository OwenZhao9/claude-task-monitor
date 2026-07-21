'use strict';
// 尾部读取器 —— 整个引擎的性能红线都在这个文件里。
// 本机存在 134MB 的 jsonl，绝对不允许 readFile / 全量 JSON.parse。
const fs = require('fs');
const log = require('./log');

const DEFAULT_TAIL_BYTES = 64 * 1024;

/**
 * 从文件末尾读最后 N 字节，返回 { text, stat, truncated }。
 * truncated=true 表示 text 的第一行是被切断的半行，调用方必须丢弃。
 * 任何 IO 失败都返回 null，不抛。
 */
function readTailBytes(file, maxBytes = DEFAULT_TAIL_BYTES) {
  let fd = null;
  try {
    fd = fs.openSync(file, 'r');
    const st = fs.fstatSync(fd);
    if (!st.isFile()) return null;
    const size = st.size;
    if (size === 0) return { text: '', stat: st, truncated: false };

    const start = Math.max(0, size - maxBytes);
    const len = size - start;
    const buf = Buffer.allocUnsafe(len);
    let got = 0;
    // read() 不保证一次读满，循环补齐。
    while (got < len) {
      const n = fs.readSync(fd, buf, got, len - got, start + got);
      if (n <= 0) break;
      got += n;
    }
    return {
      text: buf.toString('utf8', 0, got),
      stat: st,
      truncated: start > 0,
    };
  } catch (err) {
    if (err && err.code !== 'ENOENT') log.debug('tail', file, err.code || err.message);
    return null;
  } finally {
    if (fd !== null) { try { fs.closeSync(fd); } catch (_) {} }
  }
}

/**
 * 尾部读 + 逐行 JSON.parse。坏行静默跳过（尾部截断、并发写入撕裂都会产生坏行）。
 * 返回 { entries, stat, bad }。
 */
function readTailJsonl(file, maxBytes = DEFAULT_TAIL_BYTES) {
  const raw = readTailBytes(file, maxBytes);
  if (!raw) return null;

  const lines = raw.text.split('\n');
  // ★ 第一行大概率是被 seek 切断的半行，丢弃。
  if (raw.truncated) lines.shift();

  const entries = [];
  let bad = 0;
  for (const line of lines) {
    const s = line.trim();
    if (!s) continue;
    // 便宜的预筛：不是以 '{' 开头的一定不是我们要的对象行。
    if (s.charCodeAt(0) !== 123) { bad++; continue; }
    try {
      entries.push(JSON.parse(s));
    } catch (_) {
      bad++; // 最后一行可能正在被写入，撕裂很正常
    }
  }
  return { entries, stat: raw.stat, bad };
}

/**
 * 带 mtime+size 缓存的尾部解析。文件没动就直接复用上次结果，
 * 这是 --watch 每秒轮询能压进几十毫秒的关键。
 */
/**
 * 窗口扩大阶梯。
 * ★ 为什么需要这个：用浏览器/截图类工具的会话，单条 tool_result 能有 150KB+。
 *   固定 64KB 的窗口会整个落在一条巨型条目内部，残行一丢就是零条完整条目 ——
 *   引擎会把"数据不足"误判成"会话已空闲"，UI 表现为疯狂在空闲/干活之间闪。
 *   所以解析不出对话条目时要往上爬，直到读到为止。
 */
const TAIL_LADDER = [DEFAULT_TAIL_BYTES, 512 * 1024, 2 * 1024 * 1024];

function createTailCache(maxBytes = DEFAULT_TAIL_BYTES) {
  const cache = new Map(); // file -> { mtimeMs, size, value, bytesUsed }

  const ladderFrom = (start) => {
    const rungs = TAIL_LADDER.filter((b) => b >= start);
    return rungs.length ? rungs : [TAIL_LADDER[TAIL_LADDER.length - 1]];
  };

  return {
    /**
     * @param {string} file
     * @param {(entries:object[]) => any} project 把 entries 归约成小对象，只在文件变化时调用
     * @param {(value:any) => boolean} [needsMore] 返回 true 表示这次读的内容不够，换更大的窗口重读
     */
    get(file, project, needsMore) {
      let st;
      try {
        st = fs.statSync(file);
      } catch (_) {
        cache.delete(file);
        return null;
      }
      const hit = cache.get(file);
      if (hit && hit.mtimeMs === st.mtimeMs && hit.size === st.size) {
        return hit.value;
      }

      // ★ 从"上次真正管用的窗口"起步，避免每秒都从 64KB 重新爬梯子
      const start = hit && hit.bytesUsed ? hit.bytesUsed : maxBytes;
      let value = null;
      let bytesUsed = start;

      for (const bytes of ladderFrom(start)) {
        const parsed = readTailJsonl(file, bytes);
        if (!parsed) break;
        try {
          value = project(parsed.entries);
        } catch (err) {
          log.warn('tail-project', file, err);
          return hit ? hit.value : null;
        }
        bytesUsed = bytes;
        if (typeof needsMore !== 'function' || !needsMore(value)) break;
        if (bytes >= st.size) break;   // 整个文件都读完了，再大也变不出东西
      }

      if (value === null) return hit ? hit.value : null;
      if (value && typeof value === 'object') {
        value.fileMtimeMs = st.mtimeMs;
        value.fileSize = st.size;
        value.tailBytesUsed = bytesUsed;
      }
      cache.set(file, { mtimeMs: st.mtimeMs, size: st.size, value, bytesUsed });
      return value;
    },
    size() { return cache.size; },
    prune(keepSet) {
      for (const k of cache.keys()) if (!keepSet.has(k)) cache.delete(k);
    },
  };
}

module.exports = { readTailBytes, readTailJsonl, createTailCache, DEFAULT_TAIL_BYTES };
