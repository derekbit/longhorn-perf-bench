#!/bin/bash
# Logging helpers and small generic retry/poll utilities shared by all
# longhorn-perf-bench scripts.

# All log_* helpers write to stderr (not stdout) on purpose: several
# functions in lib/*.sh are called via command substitution (e.g.
# `PODS=$(wait_for_fio_pods_completed)`) to capture a return value on
# stdout, and any progress messages on stdout would otherwise silently leak
# into that captured value.
log_info()  { echo "ℹ️  $*" >&2; }
log_step()  { echo "⚙️  $*" >&2; }
log_wait()  { echo "⏳ $*" >&2; }
log_ok()    { echo "✅ $*" >&2; }
log_warn()  { echo "⚠️  $*" >&2; }
log_error() { echo "❌ $*" >&2; }
log_run()   { echo "🏃🏃🏃 $*" >&2; }

# die <message> - print an error and exit the whole script with status 1.
die() {
    log_error "$*"
    exit 1
}

# retry_cmd <retries> <interval_seconds> <description> <command...>
#
# Runs <command...> (with stdout/stderr silenced) until it succeeds or the
# retry budget is exhausted. Replaces the many hand-rolled "for ((i=1..N))"
# retry loops that used to be duplicated throughout run.sh.
retry_cmd() {
    local retries="$1"; shift
    local interval="$1"; shift
    local desc="$1"; shift

    local attempt
    for ((attempt = 1; attempt <= retries; attempt++)); do
        if "$@" >/dev/null 2>&1; then
            log_ok "${desc} (attempt ${attempt}/${retries})"
            return 0
        fi
        log_warn "${desc} failed (attempt ${attempt}/${retries}), retrying in ${interval}s..."
        sleep "$interval"
    done

    log_error "${desc} failed after ${retries} attempts."
    return 1
}

# poll_until <retries> <interval_seconds> <description> <check_fn> [args...]
#
# Calls `<check_fn> [args...]` repeatedly (no output silencing, the check
# function is expected to be quiet on its own) until it returns success (0)
# or the retry budget is exhausted.
poll_until() {
    local retries="$1"; shift
    local interval="$1"; shift
    local desc="$1"; shift
    local check_fn="$1"; shift

    local attempt
    for ((attempt = 1; attempt <= retries; attempt++)); do
        if "$check_fn" "$@"; then
            return 0
        fi
        sleep "$interval"
    done

    log_error "Timed out waiting for: ${desc}"
    return 1
}
