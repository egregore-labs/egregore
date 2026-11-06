#!/usr/bin/env bash
# Compatibility notice for the retired anonymous feedback transport.
# Do not read configuration, stdin, or local feedback files; never send content.
set -euo pipefail

case "${1:-status}" in
  submit)
    printf '%s\n' '{"status":"skipped","reason":"retired","route":"session_feedback","support_issue_created":false,"notification":"not_sent","notice":"Anonymous feedback is retired. No report was read, stored, or sent. Use the issue workflow to preview and confirm a support report."}' >&2
    ;;
  status|help|--help|-h)
    printf '%s\n' \
      'Anonymous session feedback is retired.' \
      'No report is read, stored, or sent by this command.' \
      'Use the issue workflow to preview and confirm a support report.' \
      'Previously saved local feedback files are unchanged.'
    ;;
  *)
    printf '%s\n' 'Usage: session-report.sh [status|submit|help] (retired; no reports sent)' >&2
    exit 1
    ;;
esac
