#!/bin/bash
# Claude Code Stop Hook: 任务完成后通知 AGI
# 触发时机: Stop (生成停止) + SessionEnd (会话结束)
# 支持 Agent Teams: lead 完成后自动触发

set -uo pipefail

LOG="$HOME/.claude-code-results/hook.log"
RESULT_DIR="$HOME/.claude-code-results"
OPENCLAW_BIN="$HOME/.npm-global/bin/openclaw"

mkdir -p "$RESULT_DIR"

log() { echo "[$(date -Iseconds)] $*" >> "$LOG"; }

log "=== Hook fired ==="

# ---- 读 stdin ----
if [ -t 0 ]; then
    log "stdin is tty, skip"
elif [ -e /dev/stdin ]; then
    INPUT=$(cat || true)
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "unknown"' 2>/dev/null || echo "unknown")

# ---- 构造 meta 文件路径 ----
META_FILE="${RESULT_DIR}/task-meta-${SESSION_ID}.json"

# ---- 函数: 构建 Telegram 消息 ----
build_telegram_message() {
    local task_name="$1"
    local meta_file="$2"
    local task_output="$3"
    
    # 提取信息
    local project_dir=""
    local duration=""
    local agent_teams_enabled="false"
    local agents_info=""
    local test_summary=""
    local features_done=""
    local exit_code_val="0"
    
    # 从 meta 文件提取
    if [ -f "$meta_file" ]; then
        project_dir=$(jq -r '.workdir // ""' "$meta_file" 2>/dev/null || echo "")
        agent_teams_enabled=$(jq -r '.agent_teams // false' "$meta_file" 2>/dev/null || echo "false")
        exit_code_val=$(jq -r '.exit_code // 0' "$meta_file" 2>/dev/null || echo "0")
        
        # 计算耗时
        local started=$(jq -r '.started_at // ""' "$meta_file" 2>/dev/null || echo "")
        local completed=$(jq -r '.completed_at // ""' "$meta_file" 2>/dev/null || echo "")
        if [ -n "$started" ] && [ -n "$completed" ]; then
            local start_ts=$(date -d "$started" +%s 2>/dev/null || echo 0)
            local end_ts=$(date -d "$completed" +%s 2>/dev/null || echo 0)
            if [ "$start_ts" -gt 0 ] && [ "$end_ts" -gt 0 ]; then
                local elapsed=$(( end_ts - start_ts ))
                local mins=$(( elapsed / 60 ))
                local secs=$(( elapsed % 60 ))
                duration="${mins}m${secs}s"
            fi
        fi
    fi
    
    # 从 task output 提取
    if [ -f "$task_output" ] && [ -s "$task_output" ]; then
        agents_info=$(grep -iE '(agent|developer|testing).*\|.*✅' "$task_output" 2>/dev/null | head -6 || true)
        test_summary=$(grep -iE '(tests? (passed|failed)|test_|pytest|✅.*test|tests passing)' "$task_output" 2>/dev/null | tail -5 || true)
        features_done=$(grep -E '✅' "$task_output" 2>/dev/null | grep -ivE 'agent|developer' | head -10 || true)
    fi
    
    # 构建消息
    local status_emoji="✅"
    [ "$exit_code_val" != "0" ] && status_emoji="❌"
    
    local msg="${status_emoji} *Claude Code 任务完成*

📋 *任务:* \`${task_name}\`"
    
    [ -n "$project_dir" ] && msg="${msg}
📂 *路径:* \`${project_dir}\`"
    
    [ -n "$duration" ] && msg="${msg}
⏱ *耗时:* ${duration}"
    
    [ "$exit_code_val" != "0" ] && msg="${msg}
⚠️ *Exit Code:* ${exit_code_val}"
    
    if [ "$agent_teams_enabled" = "true" ]; then
        msg="${msg}

👥 *Agent Teams:* 已启用"
        if [ -n "$agents_info" ]; then
            local agents_list=$(echo "$agents_info" | sed 's/|//g; s/  */ /g; s/^ //; s/ $//' | while IFS= read -r line; do echo "  • $line"; done)
            msg="${msg}
${agents_list}"
        fi
    fi
    
    if [ -n "$test_summary" ]; then
        local test_lines=$(echo "$test_summary" | head -5 | while IFS= read -r line; do echo "  • $line"; done)
        msg="${msg}

🧪 *测试结果:*
${test_lines}"
    fi
    
    if [ -n "$features_done" ]; then
        local feat_list=$(echo "$features_done" | head -8 | sed 's/|//g; s/  */ /g; s/^ //; s/ $//' | while IFS= read -r line; do echo "  $line"; done)
        msg="${msg}
${feat_list}"
    fi
    
    # 生成的文件列表
    if [ -n "$project_dir" ] && [ -d "$project_dir" ]; then
        local file_tree=$(find "$project_dir" -maxdepth 3 -type f \
            ! -path '*/venv/*' ! -path '*/__pycache__/*' ! -path '*/.git/*' ! -path '*.pyc' \
            2>/dev/null | sort | sed "s|${project_dir}/||" | head -20 | while IFS= read -r f; do echo "  📄 $f"; done)
        if [ -n "$file_tree" ]; then
            msg="${msg}

📁 *项目文件:*
${file_tree}"
        fi
    fi
    
    echo "$msg"
}

# ---- 函数: 构建回调消息 ----
build_callback_message() {
    local task_name="$1"
    local duration="$2"
    local output="$3"
    local prefix="$4"  # "回调" 或 ""
    
    local status_emoji="✅"
    local prefix_text="🔔 *Claude Code 任务完成${prefix}*"
    [ -n "$prefix" ] && prefix_text="🔔 *Claude Code 任务完成${prefix}*"
    
    local msg="${prefix_text}

📋 *任务:* \`${task_name}\`
📊 *状态:* ${status_emoji} 完成"
    
    [ -n "$duration" ] && msg="${msg}
⏱ *耗时:* ${duration}"
    
    local summary=$(echo "$output" | head -c 500 | tr '\n' ' ')
    [ -n "$summary" ] && msg="${msg}

📝 *摘要:* ${summary}"
    
    echo "$msg"
}

# ---- 函数: 发送 Telegram 消息 ----
send_telegram_message() {
    local target="$1"
    local message="$2"
    local account="${3:-}"
    
    if [ -z "$target" ] || [ -z "$message" ]; then
        return 1
    fi
    
    local cmd=("$OPENCLAW_BIN" message send --channel telegram --target "$target" --message "$message")
    [ -n "$account" ] && cmd+=(--account "$account")
    
    "${cmd[@]}" 2>/dev/null
}

log "session=$SESSION_ID cwd=$CWD event=$EVENT"

# ---- 防重复：只处理第一个事件（Stop），跳过后续的 SessionEnd ----
LOCK_FILE="${RESULT_DIR}/.hook-lock"
LOCK_AGE_LIMIT=30  # 30秒内重复触发视为同一任务

if [ -f "$LOCK_FILE" ]; then
    LOCK_TIME=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE=$(( NOW - LOCK_TIME ))
    if [ "$AGE" -lt "$LOCK_AGE_LIMIT" ]; then
        log "Duplicate hook within ${AGE}s, skipping"
        exit 0
    fi
fi
touch "$LOCK_FILE"

# ---- 读取 Claude Code 输出 ----
OUTPUT=""

# 等待 tee 管道 flush（hook 可能在 pipe 写完前触发）
sleep 1

# 来源1: task-output-${SESSION_ID}.txt (dispatch 脚本 tee 写入)
TASK_OUTPUT="${RESULT_DIR}/task-output-${SESSION_ID}.txt"
if [ -f "$TASK_OUTPUT" ] && [ -s "$TASK_OUTPUT" ]; then
    OUTPUT=$(tail -c 4000 "$TASK_OUTPUT")
    log "Output from task-output-${SESSION_ID}.txt (${#OUTPUT} chars)"
fi

# 来源2: /tmp/claude-code-output-${SESSION_ID}.txt
TMP_OUTPUT="/tmp/claude-code-output-${SESSION_ID}.txt"
if [ -z "$OUTPUT" ] && [ -f "$TMP_OUTPUT" ] && [ -s "$TMP_OUTPUT" ]; then
    OUTPUT=$(tail -c 4000 "$TMP_OUTPUT")
    log "Output from ${TMP_OUTPUT} (${#OUTPUT} chars)"
fi

# 来源3: 工作目录
if [ -z "$OUTPUT" ] && [ -n "$CWD" ] && [ -d "$CWD" ]; then
    FILES=$(ls -1t "$CWD" 2>/dev/null | head -20 | tr '\n' ', ')
    OUTPUT="Working dir: ${CWD}\nFiles: ${FILES}"
    log "Output from dir listing"
fi

# ---- 读取任务元数据 ----
TASK_NAME="unknown"
TELEGRAM_GROUP=""
CHAT_ID=""

if [ -f "$META_FILE" ]; then
    TASK_NAME=$(jq -r '.task_name // "unknown"' "$META_FILE" 2>/dev/null || echo "unknown")
    TELEGRAM_GROUP=$(jq -r '.telegram_group // ""' "$META_FILE" 2>/dev/null || echo "")
    CHAT_ID=$(jq -r '.chat_id // ""' "$META_FILE" 2>/dev/null || echo "")
    CALLBACK_GROUP=$(jq -r '.callback_group // ""' "$META_FILE" 2>/dev/null || echo "")
    CALLBACK_DM=$(jq -r '.callback_dm // ""' "$META_FILE" 2>/dev/null || echo "")
    CALLBACK_ACCOUNT=$(jq -r '.callback_account // ""' "$META_FILE" 2>/dev/null || echo "")
    log "Meta: task=$TASK_NAME group=$TELEGRAM_GROUP chat_id=$CHAT_ID callback_group=$CALLBACK_GROUP callback_dm=$CALLBACK_DM callback_account=$CALLBACK_ACCOUNT"
fi

# ---- 检查是否是有效的 dispatch 任务 ----
# 有效条件：task-meta-${SESSION_ID}.json 存在且 session_id 匹配
if [ ! -f "$META_FILE" ]; then
    log "No task-meta-${SESSION_ID}.json, skipping (non-dispatch run)"
    exit 0
fi

META_SESSION=$(jq -r '.session_id // ""' "$META_FILE" 2>/dev/null || echo "")
if [ -z "$META_SESSION" ]; then
    log "No session_id in meta, skipping (non-dispatch run)"
    exit 0
fi

# 检查 session_id 是否匹配
if [ "$META_SESSION" != "$SESSION_ID" ] && [ "$SESSION_ID" != "unknown" ]; then
    log "Session mismatch: meta=$META_SESSION, current=$SESSION_ID, skipping"
    exit 0
fi

# ---- 如果没有有效的 telegram 目标，跳过通知 ----
if [ -z "$TELEGRAM_GROUP" ] && [ -z "$CHAT_ID" ]; then
    log "No valid telegram target, skipping notification"
fi

# ---- 写入结果 JSON ----
jq -n \
    --arg sid "$SESSION_ID" \
    --arg ts "$(date -Iseconds)" \
    --arg cwd "$CWD" \
    --arg event "$EVENT" \
    --arg output "$OUTPUT" \
    --arg task "$TASK_NAME" \
    --arg group "$TELEGRAM_GROUP" \
    '{session_id: $sid, timestamp: $ts, cwd: $cwd, event: $event, output: $output, task_name: $task, telegram_group: $group, status: "done"}' \
    > "${RESULT_DIR}/latest.json" 2>/dev/null

log "Wrote latest.json"

# ---- 方式1: 直接发 Telegram 消息 ----
# 优先级: CHAT_ID (当前会话) > TELEGRAM_GROUP (指定群组)

SEND_SUCCESS=false

# 构建消息（复用）
FULL_MSG=$(build_telegram_message "$TASK_NAME" "$META_FILE" "$TASK_OUTPUT")

# 先尝试发送到 CHAT_ID（当前会话/私聊）
if [ -n "$CHAT_ID" ] && [ -x "$OPENCLAW_BIN" ]; then
    send_telegram_message "$CHAT_ID" "$FULL_MSG" && {
        log "Sent rich notification to chat_id $CHAT_ID"
        SEND_SUCCESS=true
    } || log "Failed to send to chat_id $CHAT_ID"
fi

# 如果 CHAT_ID 发送失败，尝试 TELEGRAM_GROUP
if [ "$SEND_SUCCESS" = false ] && [ -n "$TELEGRAM_GROUP" ] && [ -x "$OPENCLAW_BIN" ]; then
    send_telegram_message "$TELEGRAM_GROUP" "$FULL_MSG" && {
        log "Sent rich Telegram message to $TELEGRAM_GROUP"
        SEND_SUCCESS=true
    } || log "Telegram send to group failed"
fi

    # ---- 回调通知: 发到调用者 agent 的群（如果不同于通知群）----
    if [ -n "$CALLBACK_GROUP" ] && [ "$CALLBACK_GROUP" != "$TELEGRAM_GROUP" ]; then
        CALLBACK_MSG=$(build_callback_message "$TASK_NAME" "$DURATION" "$OUTPUT" "回调")
        send_telegram_message "$CALLBACK_GROUP" "$CALLBACK_MSG" && log "Sent callback to agent group $CALLBACK_GROUP" || log "Callback to $CALLBACK_GROUP failed"
    fi

    # ---- DM 回调: 通过指定 bot account 发 DM 给调用者 ----
    if [ -n "$CALLBACK_DM" ]; then
        CALLBACK_MSG=$(build_callback_message "$TASK_NAME" "$DURATION" "$OUTPUT" "")
        send_telegram_message "$CALLBACK_DM" "$CALLBACK_MSG" "$CALLBACK_ACCOUNT" && log "Sent DM callback to $CALLBACK_DM (account=${CALLBACK_ACCOUNT:-default})" || log "DM callback to $CALLBACK_DM failed"
    fi

# ---- 方式2: 如果发送失败，写入 pending-wake.json ----
# 支持多条记录，包含 META_FILE 路径
if [ "$SEND_SUCCESS" = false ]; then
    WAKE_FILE="${RESULT_DIR}/pending-wake.json"
    
    # 读取现有记录（如果是数组）
    EXISTING_ITEMS="[]"
    if [ -f "$WAKE_FILE" ]; then
        EXISTING_ITEMS=$(jq '.' "$WAKE_FILE" 2>/dev/null || echo "[]")
    fi
    
    # 添加新记录
    NEW_ITEM=$(jq -n \
        --arg task "$TASK_NAME" \
        --arg group "$TELEGRAM_GROUP" \
        --arg chat_id "$CHAT_ID" \
        --arg meta "$META_FILE" \
        --arg session_id "$SESSION_ID" \
        --arg ts "$(date -Iseconds)" \
        --arg summary "$(echo "$OUTPUT" | head -c 500 | tr '\n' ' ')" \
        '{task_name: $task, session_id: $session_id, telegram_group: $group, chat_id: $chat_id, meta_file: $meta, timestamp: $ts, summary: $summary, processed: false}')
    
    # 合并数组并写入
    echo "$EXISTING_ITEMS" | jq --argjson item "$NEW_ITEM" '. + [$item]' > "$WAKE_FILE" 2>/dev/null
    
    log "Wrote pending-wake.json (total items: $(jq 'length' "$WAKE_FILE" 2>/dev/null || echo 1))"
else
    log "Notification sent successfully, skipping pending-wake"
fi

GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
HOOK_TOKEN=""

# 从 config 文件读取 webhook token
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
if [ -f "$OPENCLAW_CONFIG" ]; then
    HOOK_TOKEN=$(jq -r '.hooks.token // ""' "$OPENCLAW_CONFIG" 2>/dev/null || echo "")
fi

WAKE_TEXT="[CLAUDE_CODE_DONE] task=${TASK_NAME} status=done group=${TELEGRAM_GROUP:-none} ts=$(date -Iseconds)"

if [ -n "$HOOK_TOKEN" ]; then
    (
      HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
          "http://localhost:${GATEWAY_PORT}/hooks/wake" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer ${HOOK_TOKEN}" \
          -d "{\"text\":\"${WAKE_TEXT}\",\"mode\":\"now\"}" 2>/dev/null)

      if [ "$HTTP_CODE" = "200" ]; then
          log "Wake event sent via /hooks/wake (HTTP $HTTP_CODE)"
      else
          log "Wake failed (HTTP $HTTP_CODE), trying DM fallback"
          # Fallback: 直接发 Telegram DM 给 Master
          CALLBACK_DM=""
          if [ -f "$META_FILE" ]; then
              CALLBACK_DM=$(jq -r '.callback_dm // ""' "$META_FILE" 2>/dev/null || echo "")
          fi
          DM_TARGET="${CALLBACK_DM:-8009709280}"
          timeout 10 "$OPENCLAW_BIN" message send \
              --channel telegram \
              --target "$DM_TARGET" \
              --message "🔔 $WAKE_TEXT" </dev/null >>"$LOG" 2>&1 && \
              log "Sent DM fallback to $DM_TARGET" || \
              log "DM fallback also failed"
      fi
    ) &
    log "Dispatching async wake notification via /hooks/wake"
else
    log "No hook token found, skipping wake notification"
fi

log "=== Hook completed ==="
exit 0
