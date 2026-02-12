#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# log-event.sh -- Dual-mode session event logger
#
# Mode 1 (always): Append JSONL to local log file
# Mode 2 (if LOGFIRE_TOKEN set): Send OTel spans to Logfire via OTLP/HTTP JSON
# ---------------------------------------------------------------------------

LOG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/logs"
LOG_FILE="$LOG_DIR/session-events.jsonl"
DIAG_LOG="$LOG_DIR/diagnostics.jsonl"
mkdir -p "$LOG_DIR"

# --- Diagnostics -----------------------------------------------------------

log_diag() {
  local level="$1" msg="$2"
  shift 2
  local extra=""
  if [ $# -gt 0 ]; then
    extra="$1"
  fi
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local event="${_HOOK_EVENT:-unknown}"
  local sid="${_SESSION_ID:-unknown}"
  if [ -n "$extra" ]; then
    jq -n -c \
      --arg ts "$ts" --arg level "$level" --arg msg "$msg" \
      --arg event "$event" --arg sid "$sid" --arg extra "$extra" \
      '{timestamp:$ts, level:$level, hook_event:$event, session_id:$sid, message:$msg, detail:$extra}' \
      >> "$DIAG_LOG" 2>/dev/null || true
  else
    jq -n -c \
      --arg ts "$ts" --arg level "$level" --arg msg "$msg" \
      --arg event "$event" --arg sid "$sid" \
      '{timestamp:$ts, level:$level, hook_event:$event, session_id:$sid, message:$msg}' \
      >> "$DIAG_LOG" 2>/dev/null || true
  fi
}

trap 'log_diag "error" "Unexpected failure at line $LINENO" "${BASH_COMMAND:-unknown}"' ERR

input=$(cat)

# Stash event/session early for diagnostics context
_HOOK_EVENT=$(echo "$input" | jq -r '.hook_event_name // "unknown"' 2>/dev/null || echo "parse_error")
_SESSION_ID=$(echo "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "parse_error")

if [ "$_HOOK_EVENT" = "parse_error" ] || [ "$_SESSION_ID" = "parse_error" ]; then
  log_diag "error" "Failed to parse hook input JSON" "${input:0:500}"
  exit 1
fi

# macOS date doesn't support %N; detect by checking for literal 'N' in output
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
if [[ "$timestamp" == *N* ]]; then
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
fi

# --- JSONL logging (always) ------------------------------------------------
if ! echo "$input" | jq -c --arg ts "$timestamp" '. + {captured_at: $ts}' >> "$LOG_FILE" 2>/dev/null; then
  log_diag "error" "Failed to write JSONL log entry"
fi

# --- OTel via Logfire (if token set) ---------------------------------------
LOGFIRE_TOKEN="${LOGFIRE_TOKEN:-}"
[ -z "$LOGFIRE_TOKEN" ] && exit 0

LOGFIRE_BASE_URL="${LOGFIRE_BASE_URL:-https://logfire-us.pydantic.dev}"
LOGFIRE_BASE_URL="${LOGFIRE_BASE_URL%/}"
OTLP_ENDPOINT="${LOGFIRE_BASE_URL}/v1/traces"

# --- Helpers ---------------------------------------------------------------

now_nano() {
  # macOS date doesn't support %N; try GNU date, then python3, then fall back
  if date +%s%N 2>/dev/null | grep -qv N; then
    date +%s%N
  elif command -v python3 &>/dev/null; then
    python3 -c 'import time; print(int(time.time()*1e9))'
  else
    echo "$(date +%s)000000000"
  fi
}

random_span_id() {
  # 16 hex chars (8 bytes)
  head -c 8 /dev/urandom | xxd -p | head -c 16
}

trace_id_from_session() {
  # Deterministic 32-hex-char trace ID from session_id via SHA-256
  printf '%s' "$1" | shasum -a 256 | head -c 32
}

send_otlp() {
  local payload="$1"
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -X POST "$OTLP_ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $LOGFIRE_TOKEN" \
    -d "$payload" 2>/dev/null) || {
    log_diag "warn" "curl failed (network/timeout)"
    return 0
  }
  if [ "$http_code" -ge 400 ] 2>/dev/null; then
    log_diag "warn" "OTLP export failed" "http_status=$http_code"
  fi
}

build_otlp_payload() {
  local trace_id="$1" span_id="$2" parent_span_id="$3" name="$4"
  local start_ns="$5" end_ns="$6" attrs_json="$7"

  jq -n -c \
    --arg traceId "$trace_id" \
    --arg spanId "$span_id" \
    --arg parentSpanId "$parent_span_id" \
    --arg name "$name" \
    --arg startNs "$start_ns" \
    --arg endNs "$end_ns" \
    --argjson attrs "$attrs_json" \
    '{
      resourceSpans: [{
        resource: {
          attributes: [
            {key: "service.name", value: {stringValue: "claude-code-plugin"}},
            {key: "service.version", value: {stringValue: "0.2.0"}}
          ]
        },
        scopeSpans: [{
          scope: {name: "claude-code-logfire", version: "0.2.0"},
          spans: [{
            traceId: $traceId,
            spanId: $spanId,
            parentSpanId: $parentSpanId,
            name: $name,
            kind: 1,
            startTimeUnixNano: $startNs,
            endTimeUnixNano: $endNs,
            attributes: $attrs,
            status: {code: 1}
          }]
        }]
      }]
    }'
}

make_attr() {
  local key="$1" val="$2"
  jq -n -c --arg k "$key" --arg v "$val" '{key:$k, value:{stringValue:$v}}'
}

make_int_attr() {
  local key="$1" val="$2"
  jq -n -c --arg k "$key" --arg v "$val" '{key:$k, value:{intValue:$v}}'
}

make_double_attr() {
  local key="$1" val="$2"
  jq -n -c --arg k "$key" --argjson v "$val" '{key:$k, value:{doubleValue:$v}}'
}

# --- Extract fields from input ---------------------------------------------

hook_event=$(echo "$input" | jq -r '.hook_event_name // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')

if [ -z "$hook_event" ] || [ -z "$session_id" ]; then
  log_diag "warn" "Missing hook_event or session_id, skipping OTel export"
  exit 0
fi

trace_id=$(trace_id_from_session "$session_id")
ts_nano=$(now_nano)
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')

STATE_FILE="${TMPDIR:-/tmp}/claude-logfire-${session_id}.json"

# Helper: read parent span ID from state file
read_root_span_id() {
  if [ -f "$STATE_FILE" ]; then
    local rid
    rid=$(jq -r '.root_span_id // empty' "$STATE_FILE" 2>/dev/null)
    if [ -z "$rid" ]; then
      log_diag "warn" "State file exists but root_span_id is empty" "$STATE_FILE"
    fi
    echo "$rid"
  else
    log_diag "warn" "State file missing, no root_span_id available (SessionStart may not have fired)" "$STATE_FILE"
    echo ""
  fi
}

# Helper: persist transcript offset in state file
update_state_last_line() {
  local new_last_line="$1"
  if [ -z "$new_last_line" ] || [ ! -f "$STATE_FILE" ]; then
    return 0
  fi
  if ! jq -c --arg ll "$new_last_line" '.last_line = ($ll | tonumber)' "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null; then
    log_diag "error" "Failed to update last_line in state file"
  else
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
  fi
}

# Helper: extract last assistant response, usage, and model from new transcript lines.
# Returns a JSON object: {response, usage, model} in one pass to avoid reading twice.
extract_transcript_data() {
  local tp="$1"
  if [ -z "$tp" ]; then
    log_diag "warn" "No transcript_path provided for transcript extraction"
    echo '{}'
    return 0
  fi
  if [ ! -f "$tp" ]; then
    log_diag "warn" "Transcript file does not exist" "$tp"
    echo '{}'
    return 0
  fi

  local last_line=0
  if [ -f "$STATE_FILE" ]; then
    last_line=$(jq -r '.last_line // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  else
    log_diag "warn" "State file missing during transcript extraction, reading from line 0"
  fi

  # Stop events can fire a moment before transcript lines are flushed.
  # Retry briefly so the first assistant response is not missed.
  local max_attempts="${TRANSCRIPT_READ_RETRIES:-20}"
  local retry_delay_s="${TRANSCRIPT_READ_DELAY_SECONDS:-0.1}"
  local attempt=0

  while [ "$attempt" -le "$max_attempts" ]; do
    local total_lines
    total_lines=$(wc -l < "$tp" 2>/dev/null | tr -d ' ')

    if [ "$total_lines" -le "$last_line" ]; then
      if [ "$attempt" -lt "$max_attempts" ]; then
        sleep "$retry_delay_s"
        attempt=$((attempt + 1))
        continue
      fi
      log_diag "info" "No new transcript lines since last read" "last_line=$last_line total_lines=$total_lines"
      echo '{}'
      return 0
    fi

    local start_line=$((last_line + 1))

    # Parse only complete lines to avoid transient parse failures during concurrent writes.
    local result
    result=$(sed -n "${start_line},${total_lines}p" "$tp" 2>/dev/null \
      | jq -s -c '
          ([.[] | select(.type=="assistant")] | last) as $msg |
          if $msg == null then
            {found:false}
          else
            {
              found:true,
              response: ([$msg.message.content[]? | select(.type=="text") | .text] | join("\n") | .[0:10000]),
              usage: ($msg.message.usage // null),
              model: ($msg.message.model // null)
            }
          end
        ' 2>/dev/null) || {
      if [ "$attempt" -lt "$max_attempts" ]; then
        sleep "$retry_delay_s"
        attempt=$((attempt + 1))
        continue
      fi
      log_diag "error" "jq/sed pipeline failed during transcript extraction" "last_line=$last_line total_lines=$total_lines file=$tp"
      echo '{}'
      return 0
    }

    # Advance transcript offset only after a successful parse.
    update_state_last_line "$total_lines"

    if [ "$(echo "$result" | jq -r '.found // false' 2>/dev/null)" = "true" ]; then
      echo "$result" | jq -c 'del(.found)'
      return 0
    fi

    # No assistant line in this slice yet; keep waiting briefly for it to appear.
    if [ "$attempt" -lt "$max_attempts" ]; then
      last_line="$total_lines"
      sleep "$retry_delay_s"
      attempt=$((attempt + 1))
      continue
    fi

    log_diag "info" "No assistant data found in new transcript lines" "last_line=$last_line total_lines=$total_lines"
    echo '{}'
    return 0
  done
}

# --- Build span attributes per event type ----------------------------------

case "$hook_event" in
  SessionStart)
    root_span_id=$(random_span_id)
    cwd=$(echo "$input" | jq -r '.cwd // empty')
    model=$(echo "$input" | jq -r '.model // empty')
    source=$(echo "$input" | jq -r '.source // empty')

    # Capture user and terminal info from environment
    term_type="${TERM:-}"
    term_program="${TERM_PROGRAM:-}"
    term_program_version="${TERM_PROGRAM_VERSION:-}"
    shell_name="${SHELL:-}"
    tty_device=$(tty 2>/dev/null || echo "")
    [ "$tty_device" = "not a tty" ] && tty_device=""

    # Snapshot current transcript length so we only read new lines on subsequent hooks
    initial_line=0
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
      initial_line=$(wc -l < "$transcript_path" | tr -d ' ')
    fi

    # Persist state for subsequent hooks (including user/terminal info for root span)
    jq -n -c \
      --arg root_span_id "$root_span_id" \
      --arg start_time "$ts_nano" \
      --arg cwd "$cwd" \
      --arg model "$model" \
      --arg term_program "$term_program" \
      --argjson last_line "$initial_line" \
      '{root_span_id:$root_span_id, start_time:$start_time, cwd:$cwd, model:$model, term_program:$term_program, last_line:$last_line}' \
      > "$STATE_FILE"

    attrs="[$(make_attr "hook.event" "$hook_event")"
    attrs="$attrs,$(make_attr "session.id" "$session_id")"
    attrs="$attrs,$(make_attr "logfire.msg" "session started")"
    attrs="$attrs,$(make_attr "logfire.span_type" "span")"
    [ -n "$cwd" ] && attrs="$attrs,$(make_attr "session.cwd" "$cwd")"
    [ -n "$model" ] && attrs="$attrs,$(make_attr "session.model" "$model")"
    [ -n "$source" ] && attrs="$attrs,$(make_attr "session.source" "$source")"
    [ -n "$term_type" ] && attrs="$attrs,$(make_attr "terminal.type" "$term_type")"
    [ -n "$term_program" ] && attrs="$attrs,$(make_attr "terminal.program" "$term_program")"
    [ -n "$term_program_version" ] && attrs="$attrs,$(make_attr "terminal.program_version" "$term_program_version")"
    [ -n "$shell_name" ] && attrs="$attrs,$(make_attr "user.shell" "$shell_name")"
    [ -n "$tty_device" ] && attrs="$attrs,$(make_attr "terminal.tty" "$tty_device")"
    attrs="$attrs]"

    span_id=$(random_span_id)
    payload=$(build_otlp_payload "$trace_id" "$span_id" "$root_span_id" "session started" "$ts_nano" "$ts_nano" "$attrs")
    send_otlp "$payload"

    # Pending span for the root session span (enables Logfire Live View)
    pending_attrs="[$(make_attr "hook.event" "session")"
    pending_attrs="$pending_attrs,$(make_attr "session.id" "$session_id")"
    pending_attrs="$pending_attrs,$(make_attr "logfire.msg" "claude-code-session")"
    pending_attrs="$pending_attrs,$(make_attr "logfire.span_type" "pending_span")"
    pending_attrs="$pending_attrs,$(make_attr "logfire.pending_parent_id" "0000000000000000")"
    [ -n "$cwd" ] && pending_attrs="$pending_attrs,$(make_attr "session.cwd" "$cwd")"
    [ -n "$model" ] && pending_attrs="$pending_attrs,$(make_attr "session.model" "$model")"
    [ -n "$term_program" ] && pending_attrs="$pending_attrs,$(make_attr "terminal.program" "$term_program")"
    pending_attrs="$pending_attrs]"

    pending_span_id=$(random_span_id)
    pending_payload=$(build_otlp_payload "$trace_id" "$pending_span_id" "$root_span_id" "claude-code-session" "$ts_nano" "$ts_nano" "$pending_attrs")
    send_otlp "$pending_payload"
    ;;

  SessionEnd)
    end_reason=$(echo "$input" | jq -r '.reason // empty')

    if [ -f "$STATE_FILE" ]; then
      state=$(cat "$STATE_FILE")
      root_span_id=$(echo "$state" | jq -r '.root_span_id')
      start_time=$(echo "$state" | jq -r '.start_time')
      cwd=$(echo "$state" | jq -r '.cwd // empty')
      model=$(echo "$state" | jq -r '.model // empty')
      term_program=$(echo "$state" | jq -r '.term_program // empty')
    else
      log_diag "warn" "SessionEnd without state file (no matching SessionStart), using synthetic root span"
      root_span_id=$(random_span_id)
      start_time="$ts_nano"
      cwd=""
      model=""
      term_program=""
    fi

    child_attrs="[$(make_attr "hook.event" "$hook_event")"
    child_attrs="$child_attrs,$(make_attr "session.id" "$session_id")"
    child_attrs="$child_attrs,$(make_attr "logfire.msg" "session ended")"
    child_attrs="$child_attrs,$(make_attr "logfire.span_type" "span")"
    [ -n "$end_reason" ] && child_attrs="$child_attrs,$(make_attr "session.end_reason" "$end_reason")"
    child_attrs="$child_attrs]"

    child_span_id=$(random_span_id)
    child_payload=$(build_otlp_payload "$trace_id" "$child_span_id" "$root_span_id" "session ended" "$ts_nano" "$ts_nano" "$child_attrs")
    send_otlp "$child_payload"

    # Root span covering entire session
    root_attrs="[$(make_attr "hook.event" "session")"
    root_attrs="$root_attrs,$(make_attr "session.id" "$session_id")"
    root_attrs="$root_attrs,$(make_attr "logfire.msg" "claude-code-session")"
    root_attrs="$root_attrs,$(make_attr "logfire.span_type" "span")"
    [ -n "$cwd" ] && root_attrs="$root_attrs,$(make_attr "session.cwd" "$cwd")"
    [ -n "$model" ] && root_attrs="$root_attrs,$(make_attr "session.model" "$model")"
    [ -n "$end_reason" ] && root_attrs="$root_attrs,$(make_attr "session.end_reason" "$end_reason")"
    [ -n "$term_program" ] && root_attrs="$root_attrs,$(make_attr "terminal.program" "$term_program")"
    root_attrs="$root_attrs]"

    root_payload=$(build_otlp_payload "$trace_id" "$root_span_id" "" "claude-code-session" "$start_time" "$ts_nano" "$root_attrs")
    send_otlp "$root_payload"

    rm -f "$STATE_FILE"
    ;;

  UserPromptSubmit)
    root_span_id=$(read_root_span_id)
    prompt=$(echo "$input" | jq -r '.prompt // empty')

    attrs="[$(make_attr "hook.event" "$hook_event")"
    attrs="$attrs,$(make_attr "session.id" "$session_id")"
    attrs="$attrs,$(make_attr "logfire.msg" "user prompt")"
    attrs="$attrs,$(make_attr "logfire.span_type" "span")"
    [ -n "$prompt" ] && attrs="$attrs,$(make_attr "user.prompt" "$prompt")"
    attrs="$attrs]"

    span_id=$(random_span_id)
    payload=$(build_otlp_payload "$trace_id" "$span_id" "$root_span_id" "user prompt" "$ts_nano" "$ts_nano" "$attrs")
    send_otlp "$payload"
    ;;

  Stop|SubagentStop)
    root_span_id=$(read_root_span_id)

    # Extract response, usage, and model from transcript in one pass
    transcript_data=$(extract_transcript_data "$transcript_path")
    response=$(echo "$transcript_data" | jq -r '.response // empty')
    usage_json=$(echo "$transcript_data" | jq -c '.usage // empty')
    response_model=$(echo "$transcript_data" | jq -r '.model // empty')

    if [ "$hook_event" = "SubagentStop" ]; then
      span_name="subagent response"
    else
      span_name="assistant response"
    fi

    attrs="[$(make_attr "hook.event" "$hook_event")"
    attrs="$attrs,$(make_attr "session.id" "$session_id")"
    attrs="$attrs,$(make_attr "logfire.msg" "$span_name")"
    attrs="$attrs,$(make_attr "logfire.span_type" "span")"
    [ -n "$response" ] && attrs="$attrs,$(make_attr "assistant.response" "$response")"

    if [ "$hook_event" = "SubagentStop" ]; then
      agent_type=$(echo "$input" | jq -r '.agent_type // empty')
      [ -n "$agent_type" ] && attrs="$attrs,$(make_attr "agent.type" "$agent_type")"
    fi

    # Add gen_ai and usage attributes if usage data is available
    if [ -n "$usage_json" ] && [ "$usage_json" != "null" ] && [ "$usage_json" != '""' ]; then
      # Standard OTel gen_ai semantic convention attributes
      attrs="$attrs,$(make_attr "gen_ai.system" "anthropic")"
      [ -n "$response_model" ] && attrs="$attrs,$(make_attr "gen_ai.response.model" "$response_model")"

      input_tokens=$(echo "$usage_json" | jq -r '.input_tokens // empty')
      output_tokens=$(echo "$usage_json" | jq -r '.output_tokens // empty')
      cache_creation_input_tokens=$(echo "$usage_json" | jq -r '.cache_creation_input_tokens // empty')
      cache_read_input_tokens=$(echo "$usage_json" | jq -r '.cache_read_input_tokens // empty')
      service_tier=$(echo "$usage_json" | jq -r '.service_tier // empty')
      inference_geo=$(echo "$usage_json" | jq -r '.inference_geo // empty')
      cache_ephemeral_5m=$(echo "$usage_json" | jq -r '.cache_creation.ephemeral_5m_input_tokens // empty')
      cache_ephemeral_1h=$(echo "$usage_json" | jq -r '.cache_creation.ephemeral_1h_input_tokens // empty')

      # gen_ai.usage.* (standard OTel semconv — triggers Logfire token badges)
      [ -n "$input_tokens" ] && attrs="$attrs,$(make_int_attr "gen_ai.usage.input_tokens" "$input_tokens")"
      [ -n "$output_tokens" ] && attrs="$attrs,$(make_int_attr "gen_ai.usage.output_tokens" "$output_tokens")"

      # All raw usage fields from the Anthropic API
      [ -n "$input_tokens" ] && attrs="$attrs,$(make_int_attr "usage.input_tokens" "$input_tokens")"
      [ -n "$output_tokens" ] && attrs="$attrs,$(make_int_attr "usage.output_tokens" "$output_tokens")"
      [ -n "$cache_creation_input_tokens" ] && attrs="$attrs,$(make_int_attr "usage.cache_creation_input_tokens" "$cache_creation_input_tokens")"
      [ -n "$cache_read_input_tokens" ] && attrs="$attrs,$(make_int_attr "usage.cache_read_input_tokens" "$cache_read_input_tokens")"
      [ -n "$service_tier" ] && attrs="$attrs,$(make_attr "usage.service_tier" "$service_tier")"
      [ -n "$inference_geo" ] && attrs="$attrs,$(make_attr "usage.inference_geo" "$inference_geo")"
      [ -n "$cache_ephemeral_5m" ] && attrs="$attrs,$(make_int_attr "usage.cache_creation.ephemeral_5m_input_tokens" "$cache_ephemeral_5m")"
      [ -n "$cache_ephemeral_1h" ] && attrs="$attrs,$(make_int_attr "usage.cache_creation.ephemeral_1h_input_tokens" "$cache_ephemeral_1h")"

      # Calculate operation.cost (USD) for Logfire pricing display
      if [ -n "$input_tokens" ] && [ -n "$output_tokens" ]; then
        input_price=0
        output_price=0
        case "${response_model:-}" in
          *opus*)   input_price="0.000015";  output_price="0.000075" ;;
          *sonnet*) input_price="0.000003";  output_price="0.000015" ;;
          *haiku*)  input_price="0.0000008"; output_price="0.000004" ;;
        esac
        if [ "$input_price" != "0" ]; then
          cost=$(jq -n \
            --argjson input "${input_tokens:-0}" \
            --argjson output "${output_tokens:-0}" \
            --argjson cache_create "${cache_creation_input_tokens:-0}" \
            --argjson cache_read "${cache_read_input_tokens:-0}" \
            --argjson ip "$input_price" \
            --argjson op "$output_price" \
            '($input * $ip) + ($cache_create * $ip * 1.25) + ($cache_read * $ip * 0.1) + ($output * $op)' 2>/dev/null)
          [ -n "$cost" ] && [ "$cost" != "null" ] && attrs="$attrs,$(make_double_attr "operation.cost" "$cost")"
        fi
      fi
    fi

    attrs="$attrs]"

    span_id=$(random_span_id)
    payload=$(build_otlp_payload "$trace_id" "$span_id" "$root_span_id" "$span_name" "$ts_nano" "$ts_nano" "$attrs")
    send_otlp "$payload"
    ;;

  PreToolUse)
    root_span_id=$(read_root_span_id)
    tool_name=$(echo "$input" | jq -r '.tool_name // empty')
    tool_use_id=$(echo "$input" | jq -r '.tool_use_id // empty')
    tool_input=$(echo "$input" | jq -c '.tool_input // empty')

    logfire_msg="tool call"
    [ -n "$tool_name" ] && logfire_msg="tool call: ${tool_name}"

    attrs="[$(make_attr "hook.event" "$hook_event")"
    attrs="$attrs,$(make_attr "session.id" "$session_id")"
    attrs="$attrs,$(make_attr "logfire.msg" "$logfire_msg")"
    attrs="$attrs,$(make_attr "logfire.span_type" "span")"
    [ -n "$tool_name" ] && attrs="$attrs,$(make_attr "tool.name" "$tool_name")"
    [ -n "$tool_use_id" ] && attrs="$attrs,$(make_attr "tool.use_id" "$tool_use_id")"
    [ -n "$tool_input" ] && [ "$tool_input" != '""' ] && attrs="$attrs,$(make_attr "tool.input" "$tool_input")"
    attrs="$attrs]"

    span_id=$(random_span_id)
    payload=$(build_otlp_payload "$trace_id" "$span_id" "$root_span_id" "$logfire_msg" "$ts_nano" "$ts_nano" "$attrs")
    send_otlp "$payload"
    ;;

  PostToolUse)
    root_span_id=$(read_root_span_id)
    tool_name=$(echo "$input" | jq -r '.tool_name // empty')
    tool_use_id=$(echo "$input" | jq -r '.tool_use_id // empty')
    tool_input=$(echo "$input" | jq -c '.tool_input // empty')
    # Truncate tool_response to 10k chars to avoid huge payloads
    tool_response=$(echo "$input" | jq -c '.tool_response // empty' | head -c 10000)

    logfire_msg="tool result"
    [ -n "$tool_name" ] && logfire_msg="tool result: ${tool_name}"

    attrs="[$(make_attr "hook.event" "$hook_event")"
    attrs="$attrs,$(make_attr "session.id" "$session_id")"
    attrs="$attrs,$(make_attr "logfire.msg" "$logfire_msg")"
    attrs="$attrs,$(make_attr "logfire.span_type" "span")"
    [ -n "$tool_name" ] && attrs="$attrs,$(make_attr "tool.name" "$tool_name")"
    [ -n "$tool_use_id" ] && attrs="$attrs,$(make_attr "tool.use_id" "$tool_use_id")"
    [ -n "$tool_input" ] && [ "$tool_input" != '""' ] && attrs="$attrs,$(make_attr "tool.input" "$tool_input")"
    [ -n "$tool_response" ] && [ "$tool_response" != '""' ] && attrs="$attrs,$(make_attr "tool.response" "$tool_response")"
    attrs="$attrs]"

    span_id=$(random_span_id)
    payload=$(build_otlp_payload "$trace_id" "$span_id" "$root_span_id" "$logfire_msg" "$ts_nano" "$ts_nano" "$attrs")
    send_otlp "$payload"
    ;;

  Notification)
    root_span_id=$(read_root_span_id)
    message=$(echo "$input" | jq -r '.message // empty')
    notification_type=$(echo "$input" | jq -r '.notification_type // empty')

    attrs="[$(make_attr "hook.event" "$hook_event")"
    attrs="$attrs,$(make_attr "session.id" "$session_id")"
    attrs="$attrs,$(make_attr "logfire.msg" "notification")"
    attrs="$attrs,$(make_attr "logfire.span_type" "span")"
    [ -n "$message" ] && attrs="$attrs,$(make_attr "notification.message" "$message")"
    [ -n "$notification_type" ] && attrs="$attrs,$(make_attr "notification.type" "$notification_type")"
    attrs="$attrs]"

    span_id=$(random_span_id)
    payload=$(build_otlp_payload "$trace_id" "$span_id" "$root_span_id" "notification" "$ts_nano" "$ts_nano" "$attrs")
    send_otlp "$payload"
    ;;

  *)
    log_diag "info" "Unrecognized hook event, sending generic span" "$hook_event"
    root_span_id=$(read_root_span_id)

    attrs="[$(make_attr "hook.event" "$hook_event")"
    attrs="$attrs,$(make_attr "session.id" "$session_id")"
    attrs="$attrs,$(make_attr "logfire.msg" "$hook_event")"
    attrs="$attrs,$(make_attr "logfire.span_type" "span")"
    attrs="$attrs]"

    span_id=$(random_span_id)
    payload=$(build_otlp_payload "$trace_id" "$span_id" "$root_span_id" "$hook_event" "$ts_nano" "$ts_nano" "$attrs")
    send_otlp "$payload"
    ;;
esac
