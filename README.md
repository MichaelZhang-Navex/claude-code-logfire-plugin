# Logfire plugin for Claude Code

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that sends OpenTelemetry traces to [Pydantic Logfire](https://logfire.pydantic.dev), giving you full observability into your Claude Code sessions.

Each session becomes a trace with child spans per LLM API call, with full token usage, cost tracking, and conversation history visible in Logfire.

<!-- TODO: add Logfire screenshot here -->

## Installation

### System requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- A [Logfire](https://logfire.pydantic.dev) project with a write token
- `jq` — JSON processing (`brew install jq` on macOS, `apt install jq` on Linux)
- `curl` — sends OTLP/HTTP traces to Logfire
- `xxd` — generates random span IDs (pre-installed on macOS; `apt install xxd` on Linux)
- `shasum` — derives deterministic trace IDs (pre-installed on macOS; part of `perl` on Linux)
- `python3` — optional, used for nanosecond-precision timestamps and ISO date conversion; falls back to second-precision if unavailable

### Install the plugin

From within Claude Code, run:

```
/plugin marketplace add pydantic/claude-code-logfire-plugin
/plugin install logfire-session-capture@pydantic-claude-code-logfire-plugin
```

### Set your Logfire token

```bash
export LOGFIRE_TOKEN="your-logfire-write-token"
```

Add this to your shell profile (`~/.zshrc`, `~/.bashrc`, etc.) so it persists across sessions.

For the EU region:

```bash
export LOGFIRE_BASE_URL="https://logfire-eu.pydantic.dev"
```

| Variable | Required | Default | Description |
|---|---|---|---|
| `LOGFIRE_TOKEN` | Yes | _(none)_ | Logfire write token |
| `LOGFIRE_BASE_URL` | No | `https://logfire-us.pydantic.dev` | Logfire ingest endpoint |
| `LOGFIRE_LOCAL_LOG` | No | `false` | Set to `true` to write JSONL event logs locally |

Without `LOGFIRE_TOKEN`, no traces are sent. The plugin does nothing unless at least one of `LOGFIRE_TOKEN` or `LOGFIRE_LOCAL_LOG` is set.

## What you get

Every Claude Code session produces a trace in Logfire:

```
Claude Code session              <- root span (the full session)
├── chat claude-opus-4-6         <- LLM API call 1
├── chat claude-opus-4-6         <- LLM API call 2
└── chat claude-opus-4-6         <- LLM API call 3
```

Each `chat` child span includes:

- **Token usage** (`gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`)
- **Cost** (`operation.cost` in USD)
- **Messages** (`gen_ai.input.messages`, `gen_ai.output.messages`)
- **Finish reason** (`gen_ai.response.finish_reasons`)

The root span carries the full conversation, so you can inspect the entire session in Logfire's trace view.

## Distributed tracing

If you call Claude Code from a Python application that already uses Logfire or OpenTelemetry, you can link the Claude Code session into your existing trace by passing a `TRACEPARENT` environment variable:

```bash
TRACEPARENT="00-<trace_id>-<parent_span_id>-01" claude --print "your prompt"
```

See [`examples/distributed-tracing.py`](examples/distributed-tracing.py) for a complete example using `logfire` and `subprocess`.

## Local JSONL log

Set `LOGFIRE_LOCAL_LOG=true` to write all hook events as JSON Lines to `.claude/logs/session-events.jsonl` in the project directory. This is off by default.

## How it works

The plugin is a single bash script ([`scripts/log-event.sh`](scripts/log-event.sh)) invoked by Claude Code hooks on every session event. On `Stop` events it parses the transcript file to extract per-API-call data (deduplicating streaming fragments) and sends OTLP/HTTP JSON to Logfire. On `SessionEnd` it sends the root span with the accumulated conversation.

State is persisted in a temp file between hook invocations. The `trace_id` is deterministically derived from `session_id` via SHA-256.

## License

MIT
