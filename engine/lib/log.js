'use strict';
// stdout 是给 Swift 端解析的纯 NDJSON 通道，任何日志必须走 stderr。
const LEVELS = { silent: 0, error: 1, warn: 2, info: 3, debug: 4 };
const level = LEVELS[process.env.ENGINE_LOG_LEVEL] ?? LEVELS.warn;

function emit(tag, lvl, args) {
  if (LEVELS[lvl] > level) return;
  try {
    process.stderr.write(`[engine:${lvl}] ${tag} ` + args.map(stringify).join(' ') + '\n');
  } catch (_) { /* stderr 也可能是坏的，绝不因为日志崩掉 */ }
}

function stringify(v) {
  if (typeof v === 'string') return v;
  if (v instanceof Error) return v.message;
  try { return JSON.stringify(v); } catch (_) { return String(v); }
}

module.exports = {
  error: (tag, ...a) => emit(tag, 'error', a),
  warn: (tag, ...a) => emit(tag, 'warn', a),
  info: (tag, ...a) => emit(tag, 'info', a),
  debug: (tag, ...a) => emit(tag, 'debug', a),
};
