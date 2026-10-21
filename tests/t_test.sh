#!/usr/bin/env bash
# Tests for timer/t — the append-only time ledger.
# Each test runs a copy of t in its tmpdir so ledgers land there, not next to the real script.

SRC="$PROJECT_ROOT/t"

setup() {
    cp "$SRC" "$PWD/t"
    T="$PWD/t"
}

# write a raw ledger file for report/checkpoint tests
ledger() { # client/project, then rows
    local name="$1"; shift
    mkdir -p "ledger/$(dirname "$name")"
    { echo "timestamp,event,minutes,note"; printf '%s\n' "$@"; } > "$PWD/ledger/$name.csv"
}

last_row() { tail -n 1 "$PWD/ledger/$1.csv"; }

# ---- start ----

test_start_creates_ledger_with_header() {
    run "$T" start NACM Pipes
    assert_success
    assert_stdout_eq "started nacm/pipes"
    assert_equal "timestamp,event,minutes,note" "$(head -n 1 ledger/nacm/pipes.csv)"
    [[ ! -e nacm ]] || fail "wrote the ledger next to the script"
    [[ "$(last_row nacm/pipes)" =~ ^[0-9T:+-]+,start,,$ ]] || fail "bad start row: $(last_row nacm/pipes)"
}

test_header_written_only_once() {
    "$T" start a b >/dev/null
    "$T" stop >/dev/null
    "$T" start a b >/dev/null
    assert_equal 1 "$(grep -c '^timestamp,' ledger/a/b.csv)"
    assert_equal 4 "$(wc -l < ledger/a/b.csv | tr -d ' ')"
}

test_start_without_client_fails() {
    run "$T" start
    assert_failure
    assert_stderr_contains "pass a client name"
    [[ ! -e ledger ]] || fail "wrote a ledger without a client"
}

test_start_without_project_fails() {
    run "$T" start nacm
    assert_failure
    assert_stderr_contains "pass a project name"
    [[ ! -e ledger ]] || fail "wrote a ledger without a project"
}

test_start_rejects_path_characters_in_names() {
    run "$T" start ../x b
    assert_failure
    assert_stderr_contains "pass a client name"
    run "$T" start a b/c
    assert_failure
    assert_stderr_contains "pass a project name"
}

test_start_stops_the_running_project() {
    "$T" start a b >/dev/null
    run "$T" start c d
    assert_success
    assert_line 0 "stopped a/b"
    assert_line 1 "started c/d"
    assert_equal stop "$(last_row a/b | cut -d, -f2)"
}

test_projects_of_one_client_have_separate_ledgers() {
    "$T" start nacm pipes >/dev/null
    "$T" start nacm PO-1234 >/dev/null
    assert_file_exists ledger/nacm/pipes.csv
    assert_file_exists ledger/nacm/po-1234.csv
}

# ---- --at ----

test_start_at_records_the_given_time() {
    "$T" start a b --at "2026-01-01 10:45" >/dev/null
    assert_equal "$(date -d '2026-01-01 10:45' -Iseconds)" "$(last_row a/b | cut -d, -f1)"
}

test_at_may_come_before_the_description() {
    "$T" start a b --at "2026-01-01 10:45" "fixing" >/dev/null
    assert_equal '"fixing"' "$(last_row a/b | cut -d, -f4-)"
}

test_stop_at_records_the_given_time() {
    "$T" start a b --at "2026-01-01 09:00" >/dev/null
    "$T" stop --at "2026-01-01 10:30" >/dev/null
    run "$T" report a b
    assert_stdout_match '^a/b +1\.50 h$'
}

test_start_at_stops_the_running_project_at_that_time() {
    "$T" start a b --at "2026-01-01 09:00" >/dev/null
    "$T" start c d --at "2026-01-01 10:00" >/dev/null
    assert_equal "$(date -d '2026-01-01 10:00' -Iseconds),stop,," "$(last_row a/b)"
}

test_at_unreadable_time_fails() {
    run "$T" start a b --at "half past nope"
    assert_failure
    assert_stderr_contains "can't read time"
    [[ ! -e ledger ]] || fail "logged with an unreadable time"
}

test_at_future_time_fails() {
    run "$T" start a b --at "tomorrow"
    assert_failure
    assert_stderr_contains "in the future"
}

test_at_before_last_entry_fails_and_writes_nothing() {
    "$T" start a b --at "2026-01-01 10:00" >/dev/null
    run "$T" start c d --at "2026-01-01 09:00"
    assert_failure
    assert_stderr_contains "a/b has an entry at"
    assert_equal start "$(last_row a/b | cut -d, -f2)"
    [[ ! -e ledger/c/d.csv ]] || fail "started c/d anyway"
}

test_at_without_value_fails() {
    run "$T" start a b --at
    assert_failure
    assert_stderr_contains "usage: --at"
}

# ---- descriptions ----

test_start_and_stop_record_descriptions() {
    "$T" start a b "fixing auth bug" >/dev/null
    "$T" stop "done, merged" >/dev/null
    run tail -n 2 ledger/a/b.csv
    assert_stdout_contains ',start,,"fixing auth bug"'
    assert_stdout_contains ',stop,,"done, merged"'
}

test_description_quotes_are_escaped() {
    "$T" start a b 'said "hi"' >/dev/null
    assert_equal '"said ""hi"""' "$(last_row a/b | cut -d, -f4-)"
}

test_description_newlines_are_flattened() {
    "$T" start a b "$(printf 'line1\nline2')" >/dev/null
    assert_equal 2 "$(wc -l < ledger/a/b.csv | tr -d ' ')"
    assert_equal '"line1 line2"' "$(last_row a/b | cut -d, -f4-)"
}

test_description_of_2000_chars_is_accepted() {
    run "$T" start a b "$(printf 'a%.0s' {1..2000})"
    assert_success
}

test_description_over_2000_chars_is_rejected_and_not_logged() {
    run "$T" start a b "$(printf 'a%.0s' {1..2001})"
    assert_failure
    assert_stderr_contains "limit is 2000"
    [[ ! -e ledger/a/b.csv ]] || fail "logged a rejected description"
}

test_start_rejects_unquoted_description() {
    run "$T" start a b fixing auth bug
    assert_failure
    assert_stderr_contains "quote descriptions"
    [[ ! -e ledger/a/b.csv ]] || fail "logged an unquoted description"
}

test_stop_rejects_unquoted_description() {
    "$T" start a b >/dev/null
    run "$T" stop done and merged
    assert_failure
    assert_stderr_contains "quote descriptions"
    assert_equal start "$(last_row a/b | cut -d, -f2)"
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
    "$T" start a b >/dev/null
    run "$T" status
    assert_success
    assert_stdout_eq "a/b running 0 min"
}

# ---- adjust ----

test_adjust_records_signed_minutes_and_reason() {
    "$T" adjust a b +90 "forgot to start" >/dev/null
    "$T" adjust a b -30 "double counted" >/dev/null
    run tail -n 2 ledger/a/b.csv
    assert_stdout_contains ',adjust,90,"forgot to start"'
    assert_stdout_contains ',adjust,-30,"double counted"'
}

test_adjust_without_reason_fails() {
    run "$T" adjust a b 30
    assert_failure
    assert_stderr_contains "usage: t adjust"
}

test_adjust_with_non_numeric_minutes_fails() {
    run "$T" adjust a b 1h "reason"
    assert_failure
    assert_stderr_contains "usage: t adjust"
    [[ ! -e ledger/a/b.csv ]] || fail "logged an invalid adjust"
}

test_adjust_rejects_unquoted_reason() {
    run "$T" adjust a b -30 double counted
    assert_failure
    assert_stderr_contains "quote descriptions"
    [[ ! -e ledger ]] || fail "logged an unquoted reason"
}

# ---- report ----

test_report_sums_sessions_and_adjustments() {
    ledger a/b \
        "2026-01-01T09:00:00-04:00,start,," \
        "2026-01-01T10:30:00-04:00,stop,," \
        "2026-01-01T11:00:00-04:00,adjust,30,\"x\""
    run "$T" report a b
    assert_success
    assert_stdout_match '^a/b +2\.00 h$'
}

test_report_lists_every_project() {
    ledger a/b "2026-01-01T09:00:00-04:00,adjust,60,"
    ledger c/d "2026-01-01T09:00:00-04:00,adjust,120,"
    run "$T" report
    assert_success
    assert_line 0 "$(printf '%-40s %8.2f h' a/b 1)"
    assert_line 1 "$(printf '%-40s %8.2f h' c/d 2)"
}

test_report_for_a_client_lists_only_its_projects() {
    ledger a/b "2026-01-01T09:00:00-04:00,adjust,60,"
    ledger a/c "2026-01-01T09:00:00-04:00,adjust,30,"
    ledger d/e "2026-01-01T09:00:00-04:00,adjust,120,"
    run "$T" report A
    assert_success
    assert_line 0 "$(printf '%-40s %8.2f h' a/b 1)"
    assert_line 1 "$(printf '%-40s %8.2f h' a/c 0.5)"
    assert_equal 2 "${#lines[@]}"
}

test_report_ignores_rows_before_last_checkpoint() {
    ledger a/b \
        "2026-01-01T09:00:00-04:00,adjust,999," \
        "2026-01-01T10:00:00-04:00,checkpoint,60.00,\"balance carried forward\"" \
        "2026-01-01T11:00:00-04:00,start,," \
        "2026-01-01T11:30:00-04:00,stop,,"
    run "$T" report a b
    assert_stdout_match '^a/b +1\.50 h$'
}

# ---- checkpoint ----

test_checkpoint_carries_balance_forward() {
    ledger a/b \
        "2026-01-01T09:00:00-04:00,start,," \
        "2026-01-01T10:00:00-04:00,stop,," \
        "2026-01-01T10:05:00-04:00,adjust,15,"
    run "$T" checkpoint a b
    assert_success
    assert_stdout_eq "checkpoint a/b at 75.00 min"
    "$T" adjust a b -15 "fix" >/dev/null
    run "$T" report a b
    assert_stdout_match '^a/b +1\.00 h$'
}

test_checkpoint_refuses_while_running() {
    "$T" start a b >/dev/null
    run "$T" checkpoint a b
    assert_failure
    assert_stderr_contains "stop it first"
    assert_equal start "$(last_row a/b | cut -d, -f2)"
}

test_checkpoint_without_ledger_fails() {
    run "$T" checkpoint a b
    assert_failure
    assert_stderr_contains "no ledger for a/b"
}

# ---- usage ----

test_unknown_command_prints_usage() {
    run "$T" bogus
    assert_status 1
    assert_stdout_contains "t start <client> <project>"
}
