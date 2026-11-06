#!/usr/bin/env python3
"""Emit one OpenTelemetry span for an Egregore operation, nested in the
harness trace that launched it.

Claude Code (traces beta) hands Bash and hook subprocesses a W3C
TRACEPARENT. When it is present and sampled, and an OTLP/HTTP traces
endpoint is configured, this posts a single span as OTLP/JSON under that
parent. Otherwise it does nothing. It never raises, and callers run it in
the background so it never delays them.

Usage:
  otel_span.py --name egregore.search.find --start-ms N --end-ms N --rc N
               [--attr key=value ...] [--argv -- <original arguments>]
"""

import json
import os
import re
import secrets
import sys
import urllib.parse
import urllib.request

TRACEPARENT_RE = re.compile(r"^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$")
VALUE_FLAGS = ("--kind", "--recent-days", "--after", "--before", "--prefix", "-n",
               "--offset", "--length", "--episode", "--request-id", "--harness", "--cursor")


def _parent():
    match = TRACEPARENT_RE.match(os.environ.get("TRACEPARENT", "").strip().lower())
    if not match:
        return None
    trace_id, span_id, flags = match.groups()
    if not int(flags, 16) & 1:
        return None  # The caller's sampler dropped this trace.
    return trace_id, span_id


def _endpoint():
    explicit = (os.environ.get("EGREGORE_OTLP_TRACES_ENDPOINT")
                or os.environ.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"))
    if explicit:
        return explicit
    protocol = (os.environ.get("OTEL_EXPORTER_OTLP_TRACES_PROTOCOL")
                or os.environ.get("OTEL_EXPORTER_OTLP_PROTOCOL", ""))
    if protocol == "grpc":
        return None  # OTLP/JSON needs an HTTP receiver.
    base = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT") or os.environ.get("BETA_TRACING_ENDPOINT")
    return base.rstrip("/") + "/v1/traces" if base else None


def _headers():
    headers = {"Content-Type": "application/json"}
    for name in ("OTEL_EXPORTER_OTLP_HEADERS", "OTEL_EXPORTER_OTLP_TRACES_HEADERS"):
        for pair in os.environ.get(name, "").split(","):
            if "=" in pair:
                key, value = pair.split("=", 1)
                headers[key.strip()] = urllib.parse.unquote(value.strip())
    return headers


def _value(raw):
    if raw in ("true", "false"):
        return {"boolValue": raw == "true"}
    if re.fullmatch(r"-?\d+", raw):
        return {"intValue": raw}
    return {"stringValue": raw}


def _attributes(pairs):
    return [{"key": k, "value": _value(v)} for k, v in pairs if v != ""]


def _operation_attributes(name, argv):
    """Bounded facts about a search.sh call. Query text, prefixes and paths are
    content, so they follow Claude Code's own gate for tool input."""
    details = os.environ.get("OTEL_LOG_TOOL_DETAILS") == "1"
    pairs, positional, i = [], [], 0
    while i < len(argv):
        arg = argv[i]
        if arg in VALUE_FLAGS:
            if (arg not in ("--episode", "--request-id", "--harness", "--cursor")
                    and (arg != "--prefix" or details) and i + 1 < len(argv)):
                pairs.append(("egregore.search." + arg.lstrip("-").replace("-", "_"), argv[i + 1]))
            i += 2
            continue
        if arg in ("--context-packet", "--private-result"):
            pairs.append(("egregore.search.private_result", "true"))
        elif not arg.startswith("-"):
            positional.append(arg)
        i += 1
    if name.endswith(".open"):
        pairs.append(("egregore.open.sources", str(len(positional))))
        if details:
            pairs.append(("egregore.open.paths", ",".join(positional)))
    elif positional and details:
        pairs.append(("egregore.search.query", positional[0]))
    return pairs


def main(argv):
    parent, endpoint = _parent(), _endpoint()
    if not parent or not endpoint:
        return 0

    opts, attrs, extra, i = {}, [], [], 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--argv":
            extra = argv[i + 1:]
            if extra[:1] == ["--"]:
                extra = extra[1:]
            break
        if arg == "--attr" and i + 1 < len(argv):
            key, _, value = argv[i + 1].partition("=")
            attrs.append((key, value))
        elif arg.startswith("--") and i + 1 < len(argv):
            opts[arg[2:]] = argv[i + 1]
        i += 2

    name = opts.get("name", "egregore.operation")
    attrs.extend(_operation_attributes(name, extra))
    if ("egregore.search.private_result", "true") in attrs:
        # Results went to the model as a private packet; the shell never saw them.
        attrs = [(k, v) for k, v in attrs if k != "egregore.search.results"]
    rc = int(opts.get("rc", "0"))
    trace_id, parent_span_id = parent
    span = {
        "traceId": trace_id,
        "spanId": secrets.token_hex(8),
        "parentSpanId": parent_span_id,
        "name": name,
        "kind": 1,
        "startTimeUnixNano": str(int(opts.get("start-ms", "0")) * 1_000_000),
        "endTimeUnixNano": str(int(opts.get("end-ms", "0")) * 1_000_000),
        "attributes": _attributes(attrs + [("egregore.exit_code", str(rc))]),
        "status": {"code": 1 if rc == 0 else 2},
    }
    resource = [("service.name", "egregore-runtime"), ("service.namespace", "egregore")]
    for pair in os.environ.get("OTEL_RESOURCE_ATTRIBUTES", "").split(","):
        if "=" in pair:
            resource.append(tuple(pair.split("=", 1)))
    body = {"resourceSpans": [{
        "resource": {"attributes": _attributes(resource)},
        "scopeSpans": [{"scope": {"name": "egregore"}, "spans": [span]}],
    }]}
    request = urllib.request.Request(endpoint, data=json.dumps(body).encode(),
                                     headers=_headers(), method="POST")
    try:
        urllib.request.urlopen(request, timeout=2).close()
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
