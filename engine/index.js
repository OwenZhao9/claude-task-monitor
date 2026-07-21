'use strict';
/**
 * Claude Code 会话状态引擎
 *
 *   node index.js --once              打印一次状态 JSON 后退出
 *   node index.js --watch             每约 1 秒输出一行 NDJSON，持续运行
 *   node index.js --watch --interval 2000
 *   node index.js --once --pretty     缩进输出（仅调试用，会破坏 NDJSON 契约）
 *
 * 契约：stdout 只出干净 JSON，日志一律走 stderr。
 * 零依赖，纯 Node。
 */
const { createEngine } = require('./lib/engine');
const log = require('./lib/log');

function parseArgs(argv) {
  const args = { mode: null, interval: 1000, pretty: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--once') args.mode = 'once';
    else if (a === '--watch') args.mode = 'watch';
    else if (a === '--pretty') args.pretty = true;
    else if (a === '--interval') {
      const v = Number.parseInt(argv[++i], 10);
      if (Number.isFinite(v) && v >= 100) args.interval = v;
    } else if (a === '--help' || a === '-h') args.mode = 'help';
  }
  return args;
}

/**
 * 套上消费端（Swift）约定的信封。
 * Swift 侧靠顶层 type 字段分发，没有 type 的行会被整行丢弃。
 * type 放在最前，方便人眼 tail 时一眼看出来。
 */
function envelope(snap) {
  return Object.assign({ type: 'snapshot' }, snap);
}

function write(obj, pretty) {
  let line;
  try {
    line = JSON.stringify(obj, null, pretty ? 2 : 0);
  } catch (err) {
    log.error('serialize', err);
    return;
  }
  try {
    process.stdout.write(line + '\n');
  } catch (err) {
    // 下游（Swift 端）关掉管道时会 EPIPE —— 正常退出，不要打崩溃栈
    if (err && err.code === 'EPIPE') process.exit(0);
    log.error('stdout', err);
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.mode === 'help' || !args.mode) {
    process.stderr.write(
      'usage: node index.js --once [--pretty]\n' +
      '       node index.js --watch [--interval MS]\n',
    );
    process.exit(args.mode === 'help' ? 0 : 2);
  }

  const snapshot = createEngine();

  // 引擎是旁路监控，任何未捕获异常都不该让进程死掉（Swift 端会以为监控挂了）
  process.on('uncaughtException', (err) => log.error('uncaught', err));
  process.on('unhandledRejection', (err) => log.error('unhandled', err));
  // stdout 管道被下游关闭
  process.stdout.on('error', (err) => {
    if (err && err.code === 'EPIPE') process.exit(0);
  });

  if (args.mode === 'once') {
    write(envelope(snapshot()), args.pretty);
    return;
  }

  // --watch：用 setTimeout 自调度而非 setInterval，
  // 保证上一轮跑完才排下一轮，慢机器上不会堆积回调。
  let stopped = false;
  const tick = () => {
    if (stopped) return;
    try {
      write(envelope(snapshot()), false);
    } catch (err) {
      log.error('tick', err);
      // 出错也要继续，并输出一条带错误标记的行，免得 Swift 端以为流断了。
      // ★ 这里绝不能发 type:'snapshot' + sessions:[] —— 那会被消费端当成
      //   「一个会话都没有」，把满屏真实会话瞬间抹成空状态。
      //   发 type:'error'，消费端保留上一份数据、只把连接指示灯灭掉。
      write({ type: 'error', ts: new Date().toISOString(), error: String(err && err.message) }, false);
    }
    setTimeout(tick, args.interval).unref?.();
    // unref 后要保持进程存活，靠下面的 keepAlive
  };

  const keepAlive = setInterval(() => {}, 1 << 30);
  const shutdown = () => { stopped = true; clearInterval(keepAlive); process.exit(0); };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);

  tick();
}

main();
