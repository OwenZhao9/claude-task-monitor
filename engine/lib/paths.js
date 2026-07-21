'use strict';
const os = require('os');
const path = require('path');

const CLAUDE_HOME = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');

module.exports = {
  CLAUDE_HOME,
  SESSIONS_DIR: path.join(CLAUDE_HOME, 'sessions'),
  PROJECTS_DIR: path.join(CLAUDE_HOME, 'projects'),
  TASKS_DIR: path.join(CLAUDE_HOME, 'tasks'),
  // hook 事件汇聚文件（可选，不存在就当没有）
  EVENTS_FILE: process.env.ENGINE_EVENTS_FILE
    || path.join(CLAUDE_HOME, 'task-monitor-events.ndjson'),

  // 实测确认的 slug 规则：cwd 里所有非 [a-zA-Z0-9] 字符逐个替换成 '-'。
  //   "/Users/you/projects/my-app"  -> "-Users-you-projects-my-app"
  //   "/Users/you/项目/视频工具"      -> "-Users-you-------"   （非 ASCII 逐字符替换）
  // 非 ASCII 逐字符展开成 '-'，所以 slug 不可逆、且可能撞车 —— 只当快路径用，
  // 命中失败必须回退到扫描 projects/ 找真正含有 <sessionId>.jsonl 的目录。
  slugForCwd(cwd) {
    if (typeof cwd !== 'string') return null;
    return cwd.replace(/[^a-zA-Z0-9]/g, '-');
  },
};
