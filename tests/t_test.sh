#!/usr/bin/env bash
# Tests for timer/t — the append-only time ledger.
# Each test runs a copy of t in its tmpdir so ledgers land there, not next to the real script.

SRC="$PROJECT_ROOT/t"

setup() {
    cp "$SRC" "$PWD/t"
    T="$PWD/t"
}

# write a raw ledger file for report/checkpoint tests
ledger() { # name, then rows
    local name="$1"; shift
    { echo "timestamp,event,minutes,note"; printf '%s\n' "$@"; } > "$PWD/$name.csv"
}

last_row() { tail -n 1 "$PWD/$1.csv"; }

# ---- start ----

test_start_with_project_creates_ledger_with_header() {
    run "$T" start marklauter/Kingo
    assert_success
    assert_stdout_eq "started marklauter-kingo"
    assert_equal "timestamp,event,minutes,note" "$(head -n 1 marklauter-kingo.csv)"
    [[ "$(last_row marklauter-kingo)" =~ ^[0-9T:+-]+,start,,$ ]] || fail "bad start row: $(last_row marklauter-kingo)"
}

test_header_written_only_once() {
    "$T" start a/b >/dev/null
    "$T" stop >/dev/null
    "$T" start a/b >/dev/null
    assert_equal 1 "$(grep -c '^timestamp,' a-b.csv)"
    assert_equal 4 "$(wc -l < a-b.csv | tr -d ' ')"
}

test_start_takes_project_from_https_origin() {
    git init -q repo && git -C repo remote add origin https://github.com/MarkLauter/Kingo.git
    run bash -c "cd repo && '$T' start"
    assert_success
    assert_stdout_eq "started marklauter-kingo"
}

test_start_takes_project_from_ssh_origin() {
    git init -q repo && git -C repo remote add origin git@github.com:marklauter/kingo.git
    run bash -c "cd repo && '$T' start working on parser"
    assert_success
    assert_stdout_eq "started marklauter-kingo"
    assert_equal '"working on parser"' "$(last_row marklauter-kingo | cut -d, -f4-)"
}

test_start_outside_repo_without_project_fails() {
    run "$T" start
    assert_failure
    assert_stderr_contains "pass owner/repo"
    [[ ! -e "-.csv" ]] || fail "wrote a ledger for an unknown project"
}

test_start_stops_the_running_project() {
    "$T" start a/b >/dev/null
    run "$T" start c/d
    assert_success
    assert_line 0 "stopped a-b"
    assert_line 1 "started c-d"
    assert_equal stop "$(last_row a-b | cut -d, -f2)"
}

# ---- descriptions ----

test_start_and_stop_record_descriptions() {
    "$T" start a/b fixing auth bug >/dev/null
    "$T" stop "done, merged" >/dev/null
    run tail -n 2 a-b.csv
    assert_stdout_contains ',start,,"fixing auth bug"'
    assert_stdout_contains ',stop,,"done, merged"'
}

test_description_quotes_are_escaped() {
    "$T" start a/b 'said "hi"' >/dev/null
    assert_equal '"said ""hi"""' "$(last_row a-b | cut -d, -f4-)"
}

test_description_newlines_are_flattened() {
    "$T" start a/b "$(printf 'line1\nline2')" >/dev/null
    assert_equal 2 "$(wc -l < a-b.csv | tr -d ' ')"
    assert_equal '"line1 line2"' "$(last_row a-b | cut -d, -f4-)"
}

test_description_of_2000_chars_is_accepted() {
    run "$T" start a/b "$(printf 'a%.0s' {1..2000})"
    assert_success
}

test_description_over_2000_chars_is_rejected_and_not_logged() {
    run "$T" start a/b "$(printf 'a%.0s' {1..2001})"
    assert_failure
    assert_stderr_contains "limit is 2000"
    [[ ! -e a-b.csv ]] || fail "logged a rejected description"
}

# ---- stop / status ----

test_stop_with_nothing_running() {
    run "$T" stop
    assert_success
    assert_stdout_eq "no timer running"
}

test_status_with_nothing_running() {
    run "$T" status
    assert_success
    assert_stdout_eq "no timer running"
}

test_status_shows_running_project() {
    "$T" start a/b >/dev/null
    run "$T" status
    assert_success
    assert_stdout_eq "a-b running 0 min"
}

# ---- adjust ----

test_adjust_records_signed_minutes_and_reason() {
    "$T" adjust +90 "forgot to start" a/b >/dev/null
    "$T" adjust -30 "double counted" a/b >/dev/null
    run tail -n 2 a-b.csv
    assert_stdout_contains ',adjust,90,"forgot to start"'
    assert_stdout_contains ',adjust,-30,"double counted"'
}

test_adjust_without_reason_fails() {
    run "$T" adjust 30
    assert_failure
    assert_stderr_contains "usage: t adjust"
}

test_adjust_with_non_numeric_minutes_fails() {
    run "$T" adjust 1h "reason" a/b
    assert_failure
    assert_stderr_contains "usage: t adjust"
    [[ ! -e a-b.csv ]] || fail "logged an invalid adjust"
}

# ---- report ----

test_report_sums_sessions_and_adjustments() {
    ledger a-b \
        "2026-01-01T09:00:00-04:00,start,," \
        "2026-01-01T10:30:00-04:00,stop,," \
        "2026-01-01T11:00:00-04:00,adjust,30,\"x\""
    run "$T" report a/b
    assert_success
    assert_stdout_match '^a-b +2\.00 h$'
}

test_report_lists_every_project() {
    ledger a-b "2026-01-01T09:00:00-04:00,adjust,60,"
    ledger c-d "2026-01-01T09:00:00-04:00,adjust,120,"
    run "$T" report
    assert_success
    assert_line 0 "$(printf '%-40s %8.2f h' a-b 1)"
    assert_line 1 "$(printf '%-40s %8.2f h' c-d 2)"
}

test_report_ignores_rows_before_last_checkpoint() {
    ledger a-b \
        "2026-01-01T09:00:00-04:00,adjust,999," \
        "2026-01-01T10:00:00-04:00,checkpoint,60.00,\"balance carried forward\"" \
        "2026-01-01T11:00:00-04:00,start,," \
        "2026-01-01T11:30:00-04:00,stop,,"
    run "$T" report a/b
    assert_stdout_match '^a-b +1\.50 h$'
}

# ---- checkpoint ----

test_checkpoint_carries_balance_forward() {
    ledger a-b \
        "2026-01-01T09:00:00-04:00,start,," \
        "2026-01-01T10:00:00-04:00,stop,," \
        "2026-01-01T10:05:00-04:00,adjust,15,"
    run "$T" checkpoint a/b
    assert_success
    assert_stdout_eq "checkpoint a-b at 75.00 min"
    "$T" adjust -15 "fix" a/b >/dev/null
    run "$T" report a/b
    assert_stdout_match '^a-b +1\.00 h$'
}

test_checkpoint_refuses_while_running() {
    "$T" start a/b >/dev/null
    run "$T" checkpoint a/b
    assert_failure
    assert_stderr_contains "stop it first"
    assert_equal start "$(last_row a-b | cut -d, -f2)"
}

test_checkpoint_without_ledger_fails() {
    run "$T" checkpoint a/b
    assert_failure
    assert_stderr_contains "no ledger for a-b"
}

# ---- usage ----

test_unknown_command_prints_usage() {
    run "$T" bogus
    assert_status 1
    assert_stdout_contains "t start [owner/repo]"
}
