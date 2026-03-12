# Claude Code Dispatch

> 一键分发开发任务到 [Claude Code](https://docs.anthropic.com/en/docs/claude-code)，任务完成后自动通过 Telegram 通知。零轮询，零 token 浪费。

这是一个 [OpenClaw](https://github.com/openclaw/openclaw) 技能，将 Claude Code CLI 封装成"发射后不管"的工作流：派发任务，去忙别的，完成后自动收到通知。

## 特性

- **发射即忘** — `nohup` 后台派发，通过 Stop Hook 自动回调
- **Agent Teams** — 通过结构化 `--agents` JSON 定义多智能体并行开发，配备专职测试 Agent
- **成本控制** — `--max-budget-usd` 花费上限 + `--max-turns` 轮次限制 + `--fallback-model` 过载自动降级
- **Git Worktree 隔离** — `--worktree` 实现并行任务在独立分支中工作
- **自定义 Subagent** — 通过 `--agents-json` 定义专用 Agent（安全审计、测试、性能分析等）
- **自动回调** — 支持群组通知、DM 回调、webhook 唤醒事件
- **富通知** — 任务状态、耗时、测试结果、文件树，一条 Telegram 消息全搞定
- **PTY 包装器** — 在非 TTY 环境（CI、exec、cron）中也能可靠运行
- **MCP 集成** — 通过 `--mcp-config` 加载 MCP 服务器
- **System Prompt 定制** — `--append-system-prompt` / `--append-system-prompt-file`

## 架构

```
dispatch.sh
  → 写入 task-meta-${SESSION_ID}.json
  → 通过 claude_code_run.py (PTY) 启动 Claude Code
  → [Agent Teams: --agents JSON 定义 Testing Agent + 自定义子 Agent]
  → Claude Code 完成 → Stop/TaskCompleted Hook 自动触发
    → notify-agi.sh 读取 meta + 输出
    → 写入 latest.json
    → 发送 Telegram 通知
    → 写入 pending-wake.json（心跳兜底）
```

## 快速开始

### 前置条件

- 已安装并配置 [OpenClaw](https://github.com/openclaw/openclaw)
- 已安装 [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)（`claude` 命令）
- 已在 OpenClaw 中配置 Telegram bot（用于通知）

### 安装

将技能复制到 OpenClaw 技能目录：

```bash
cp -r claude-code-dispatch ~/.openclaw/skills/
# 或创建软链接
ln -s /path/to/claude-code-dispatch ~/.openclaw/skills/claude-code-dispatch
```

设置 Hook（详见 [Hook 配置指南](references/hook-setup.md)）：

```bash
mkdir -p ~/.claude/hooks
cp scripts/notify-agi.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/notify-agi.sh
```

在 `~/.claude/settings.json` 中配置 hooks：

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/notify-agi.sh" }] }],
    "TaskCompleted": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/notify-agi.sh" }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/notify-agi.sh" }] }]
  }
}
```

### 使用方法

⚠️ **必须使用 `nohup` + 后台运行（`&`）** — dispatch 会持续运行直到 Claude Code 完成。

```bash
# 简单任务
nohup bash scripts/dispatch.sh \
  -p "用 FastAPI 构建一个 Python REST API" \
  -n "my-api" \
  -g "-5006066016" \
  --permission-mode bypassPermissions \
  --workdir $HOME/projects/my-api \
  > /tmp/dispatch-my-api.log 2>&1 &

# 使用 Agent Teams（并行开发 + 测试）
nohup bash scripts/dispatch.sh \
  -p "用 FastAPI 构建一个 Python REST API" \
  -n "my-api" \
  --agent-teams \
  --permission-mode bypassPermissions \
  --workdir $HOME/projects/my-api \
  > /tmp/dispatch-my-api.log 2>&1 &

# 带成本控制 + 模型降级
nohup bash scripts/dispatch.sh \
  -p "重构认证模块" \
  -n "auth-refactor" \
  --max-budget-usd 5.00 \
  --max-turns 50 \
  --fallback-model sonnet \
  --permission-mode bypassPermissions \
  --workdir $HOME/projects/my-app \
  > /tmp/dispatch-auth.log 2>&1 &

# 使用 git worktree 隔离
nohup bash scripts/dispatch.sh \
  -p "实现功能 X" \
  -n "feature-x" \
  --worktree feature-x \
  --permission-mode bypassPermissions \
  --workdir $HOME/projects/my-app \
  > /tmp/dispatch-feature.log 2>&1 &
```

## 参数说明

| 参数 | 缩写 | 必填 | 说明 |
|------|------|------|------|
| `--prompt` | `-p` | ✅* | 任务描述 |
| `--prompt-file` | | ✅* | 从文件读取 prompt |
| `--name` | `-n` | | 任务名称（用于追踪） |
| `--group` | `-g` | | Telegram 群组 ID（用于通知） |
| `--workdir` | `-w` | | 工作目录（默认：当前目录） |
| `--agent-teams` | | | 启用 Agent Teams 模式 |
| `--agents-json` | | | 自定义 subagent 定义（JSON 字符串） |
| `--teammate-mode` | | | 显示模式：`auto` / `in-process` / `tmux` |
| `--permission-mode` | | | `bypassPermissions` / `plan` / `acceptEdits` / `default` |
| `--allowed-tools` | | | 工具白名单（如 `"Read,Bash"`） |
| `--disallowed-tools` | | | 工具黑名单 |
| `--model` | | | 模型覆盖（sonnet/opus/haiku/完整名称） |
| `--fallback-model` | | | 主模型过载时的降级模型 |
| `--max-budget-usd` | | | 最大花费上限（美元），超出自动停止 |
| `--max-turns` | | | 最大 Agent 轮次，超出自动停止 |
| `--worktree` | | | Git worktree 名称，用于隔离 |
| `--no-session-persistence` | | | 不保存 session 到磁盘 |
| `--append-system-prompt` | | | 追加文本到系统提示词 |
| `--append-system-prompt-file` | | | 从文件追加系统提示词 |
| `--mcp-config` | | | MCP 服务器 JSON 配置文件路径 |
| `--verbose` | | | 启用详细日志 |
| `--callback-group` | | | 派发 agent 的回调群组 ID |
| `--callback-dm` | | | DM 回调的 Telegram 用户 ID |
| `--callback-account` | | | DM 回调的 Telegram bot 账号 |

\* `--prompt` 或 `--prompt-file` 二选一，必填。

## Agent Teams

### 默认模式

启用 `--agent-teams` 但不传 `--agents-json` 时，dispatch 脚本会通过 Claude Code 的 `--agents` CLI 参数自动定义一个结构化的 Testing Agent：

```json
{
  "testing-agent": {
    "description": "专职测试 Agent，负责全面的测试覆盖",
    "prompt": "为所有代码变更编写并运行测试...",
    "tools": ["Read", "Edit", "Write", "Bash", "Glob", "Grep"],
    "model": "sonnet"
  }
}
```

这取代了旧版的 prompt 注入方式，使用 Claude Code 原生的 `--agents` 参数，让 Testing Agent 拥有独立的上下文窗口、工具限制和模型选择。

### 自定义 Subagent

通过 `--agents-json` 定义你自己的团队：

```bash
--agents-json '{
  "security-reviewer": {
    "description": "代码安全审查专家",
    "prompt": "关注 OWASP Top 10 安全问题...",
    "tools": ["Read", "Grep", "Glob"],
    "model": "opus"
  },
  "perf-analyst": {
    "description": "性能分析和优化专家",
    "prompt": "对代码进行性能分析并提出优化建议...",
    "tools": ["Read", "Bash", "Grep"],
    "model": "sonnet"
  }
}'
```

每个子 Agent 是独立的 Claude Code 进程，拥有独立上下文窗口，共享同一文件系统。

## 成本控制

通过以下参数控制花费：

| 参数 | 说明 |
|------|------|
| `--max-budget-usd 5.00` | 硬性花费上限（美元） |
| `--max-turns 50` | 最大 Agent 轮次 |
| `--fallback-model sonnet` | 主模型过载时自动切换 |

这对 Agent Teams 尤为重要，多 Agent 任务的 token 消耗显著增加。

## Git Worktree 隔离

使用 `--worktree <名称>` 在隔离的 git worktree 中运行任务：

```bash
--worktree feature-auth
# Claude Code 在 <repo>/.claude/worktrees/feature-auth 中运行
```

这允许多个并行 dispatch 任务在同一仓库上工作而不冲突。

## 自动回调检测

如果没有传 `--callback-group` 或 `--callback-dm`，脚本会在工作目录中查找 `dispatch-callback.json`：

```json
// 群组回调
{ "type": "group", "group": "-5189558203" }

// DM 回调
{ "type": "dm", "dm": "8009709280", "account": "coding-bot" }

// Wake 钩子（主 agent 用）
{ "type": "wake" }
```

## Hook 事件

通知 hook（`notify-agi.sh`）处理多个 Claude Code 生命周期事件：

| 事件 | 触发时机 | 用途 |
|------|---------|------|
| `Stop` | Claude 完成响应时 | 主要的完成信号 |
| `TaskCompleted` | 任务被明确标记为完成 | 精确完成检测（Agent Teams） |
| `SessionEnd` | 会话终止时 | 兜底信号 |

内置去重机制（`.hook-lock`，30 秒窗口）防止重复通知。

也支持 HTTP hooks 作为替代方案 — 详见 [Hook 配置指南](references/hook-setup.md)。

## 结果文件

所有结果写入 `data/claude-code-results/`：

| 文件 | 内容 |
|------|------|
| `latest.json` | 完整结果（输出、任务名、群组、时间戳） |
| `task-meta-${SESSION_ID}.json` | 任务元数据（prompt、工作目录、状态、成本参数，按会话隔离） |
| `task-output-${SESSION_ID}.txt` | Claude Code 原始输出（按会话隔离） |
| `pending-wake.json` | 心跳兜底通知 |
| `hook.log` | Hook 执行日志 |

## 调试

```bash
# 查看 hook 日志
tail -f data/claude-code-results/hook.log

# 检查最新结果
cat data/claude-code-results/latest.json | jq .

# 检查任务元数据
cat data/claude-code-results/task-meta-${SESSION_ID}.json | jq .

# 测试 Telegram 发送
openclaw message send --channel telegram --target "-5006066016" --message "test"
```

## 注意事项

1. **必须使用 PTY 包装器** — 直接 `claude -p` 在 exec 环境中会挂起
2. **Hook 会触发两次** — Stop + SessionEnd 都会触发；`.hook-lock` 做了 30 秒去重
3. **PTY 模式下 Hook 的 stdin 为空** — 输出从 `task-output-${SESSION_ID}.txt` 读取，而非 stdin
4. **tee 管道竞态** — Hook 等待 1 秒让 pipe flush 完成后再读取输出
5. **Meta 新鲜度检查** — Hook 验证 meta 文件时间（<2h）和 session ID，避免误发旧任务通知
6. **Agent Teams 成本** — 多 Agent 任务 token 消耗大幅增加；务必使用 `--max-budget-usd`
7. **速率限制** — Claude Code 有每日速率限制（UTC 11:00 重置）；Stop hook 仍会以 `status=done` 触发，看似成功

## Prompt 技巧

详见 [Prompt 指南](references/prompt-guide.md)，包含成本控制、Agent Teams、worktree 隔离、自定义子 Agent 和 MCP 集成的示例和最佳实践。

## 许可证

MIT
