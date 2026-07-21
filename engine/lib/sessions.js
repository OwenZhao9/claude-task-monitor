'use strict';
// 活跃会话注册表：~/.claude/sessions/<pid>.json
const fs = require('fs');
const path = require('path');
const { SESSIONS_DIR } = require('./paths');
const log = require('./log');

/**
 * pid 存活检查。signal 0 只做权限/存在性校验，不真发信号。
 * EPERM = 进程存在但不属于我们（仍算活着）。ESRCH = 已回收。
 */
function isPidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err && err.code === 'EPERM';
  }
}

function readSessions() {
  let files;
  try {
    files = fs.readdirSync(SESSIONS_DIR);
  } catch (err) {
    if (err.code !== 'ENOENT') log.warn('sessions-dir', err);
    return [];
  }

  const out = [];
  for (const f of files) {
    if (!f.endsWith('.json')) continue;
    const full = path.join(SESSIONS_DIR, f);
    let rec;
    try {
      rec = JSON.parse(fs.readFileSync(full, 'utf8'));
    } catch (err) {
      // 注册表文件可能正在被写、或被 kill -9 留下半截 —— 跳过这一个，别影响别人
      log.debug('sessions-parse', f, err.message);
      continue;
    }
    if (!rec || typeof rec !== 'object' || !rec.sessionId) continue;

    const pidFromName = Number.parseInt(path.basename(f, '.json'), 10);
    const pid = Number.isInteger(rec.pid) ? rec.pid : pidFromName;
    out.push({
      pid,
      sessionId: String(rec.sessionId),
      cwd: typeof rec.cwd === 'string' ? rec.cwd : null,
      startedAt: Number.isFinite(rec.startedAt) ? rec.startedAt : null,
      version: rec.version || null,
      kind: rec.kind || null,
      entrypoint: rec.entrypoint || null,
      name: rec.name || null,
      nameSource: rec.nameSource || null,
      registryFile: full,
      isAlive: isPidAlive(pid),
    });
  }
  return out;
}

module.exports = { readSessions, isPidAlive };
