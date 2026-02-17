# /// script
# requires-python = ">=3.10"
# dependencies = ["logfire", "python-dotenv"]
# ///
"""
Multi-turn distributed tracing: two sequential Claude Code calls in one trace.

The first call starts a new session; the second resumes it with --resume.
Both appear as child spans under a single orchestrator trace in Logfire.

Usage:
    export LOGFIRE_TOKEN=your-logfire-write-token
    uv run examples/multi-turn-tracing.py
    uv run examples/multi-turn-tracing.py "prompt 1" "prompt 2"
"""

import json
import os
import subprocess
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env", override=True)

import logfire
from opentelemetry import trace
from opentelemetry.context import get_current
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

logfire.configure(service_name="orchestrator")

PLUGIN_DIR = str(Path(__file__).resolve().parent.parent)

DEFAULT_PROMPT_1 = "What are the three primary colors? Answer in one sentence."
DEFAULT_PROMPT_2 = "Now name three secondary colors made by mixing them. One sentence."


def build_traceparent() -> str:
    """Extract W3C TRACEPARENT from the current OTel context."""
    carrier: dict[str, str] = {}
    TraceContextTextMapPropagator().inject(carrier, context=get_current())
    return carrier["traceparent"]


def run_claude(prompt: str, *, resume: str | None = None) -> dict:
    """Run claude with JSON output, returning the parsed response."""
    cmd = ["claude", "-p", "--output-format", "json", "--plugin-dir", PLUGIN_DIR]
    if resume:
        cmd += ["--resume", resume]
    cmd += ["--", prompt]

    env = os.environ.copy()
    env["TRACEPARENT"] = build_traceparent()
    env.pop("CLAUDECODE", None)

    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"claude exited with code {result.returncode}", file=sys.stderr)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        raise SystemExit(result.returncode)

    return json.loads(result.stdout)


def main() -> int:
    prompt_1 = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PROMPT_1
    prompt_2 = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_PROMPT_2

    with logfire.span("orchestrate multi-turn"):
        with logfire.span("call 1: initial question", prompt=prompt_1):
            response_1 = run_claude(prompt_1)
            session_id = response_1["session_id"]
            print(f"[Call 1] {response_1['result']}\n")

        with logfire.span("call 2: follow-up", prompt=prompt_2):
            response_2 = run_claude(prompt_2, resume=session_id)
            print(f"[Call 2] {response_2['result']}\n")

    trace.get_tracer_provider().force_flush()  # type: ignore[union-attr]
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
