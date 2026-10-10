#!/usr/bin/env bash
# crucible — a tiny bash test runner.
#
# Bump CRUCIBLE_VERSION below when cutting a release. See CLAUDE.md for the
# release-bump checklist.
#
# Usage:
#   crucible.sh [--filter <regex>] [<path>...]
#
# With no <path>, discovers *_test.sh under $PWD (recursive).
# With <path>s, each may be a file or directory.
#
# Environment:
#   PROJECT_ROOT   exported to every test (defaults to git toplevel, else $PWD).
#                  Use it inside tests for absolute paths to scripts under test.
#   NO_COLOR=1     disable ANSI colors.
#
# Conventions:
#   - Test files end in _test.sh.
#   - Test functions start with test_.
#   - Optional setup()/teardown() run before/after each test in the same file.
#   - Each test runs in a subshell with cwd set to a fresh tmpdir.
#   - set -e is active inside the test, so a failed assertion (return 1)
#     aborts the test immediately.
#
# Assertions (all return non-zero on failure → abort test under set -e):
#   assert_equal         <expected> <actual> [<msg>]
#   assert_not_equal     <expected> <actual> [<msg>]
#   assert_contains      <haystack> <needle> [<msg>]
#   assert_not_contains  <haystack> <needle> [<msg>]
#   assert_match         <string>   <regex>  [<msg>]
#   assert_empty         <string>            [<msg>]
#   assert_not_empty     <string>            [<msg>]
#   assert_true          <cmd...>                       # cmd must exit 0
#   assert_false         <cmd...>                       # cmd must exit non-zero
#   assert_file_exists   <path>              [<msg>]
#   assert_file_not_exists <path>            [<msg>]
#
# Stdout/stderr capture (first-class):
#   run <cmd> [args...]
#       Runs <cmd>, never failing the test itself, and populates:
#           $status   exit code
#           $stdout   captured stdout (no trailing newline)
#           $stderr   captured stderr (no trailing newline)
#           $output   stdout + stderr (combined, in that order)
#           $lines    array of stdout lines
#
#   assert_status        <expected>                     # checks $status
#   assert_success                                       # status == 0
#   assert_failure                                       # status != 0
#   assert_stdout_eq        <expected>
#   assert_stdout_contains  <needle>
#   assert_stdout_match     <regex>
#   assert_stdout_empty
#   assert_stderr_eq        <expected>
#   assert_stderr_contains  <needle>
#   assert_stderr_match     <regex>
#   assert_stderr_empty
#   assert_line          <n> <expected>                  # ${lines[n]}
#
#   When a run-aware assertion fails, the last captured status/stdout/stderr
#   are dumped automatically — no need to add diagnostic echoes.
#
# Flow control:
#   skip [<reason>]      mark current test as skipped and stop it
#   fail [<msg>]         fail the current test with optional message

CRUCIBLE_VERSION="0.1.0"
#
# The runner uses defensive `${var:-default}` expansions throughout and does
# NOT enable `set -u` globally, so test files won't be poisoned by it. If you
# want strict unset-var checks inside your tests, add `set -u` in setup().

# ---- environment & colors -------------------------------------------------

_crucible_init_env() {
    if [ -z "${PROJECT_ROOT:-}" ]; then
        if PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
            :
        else
            PROJECT_ROOT="$PWD"
        fi
    fi
    export PROJECT_ROOT
}

_crucible_init_colors() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        C_RED=$'\033[31m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_GRAY=$'\033[90m'
        C_RESET=$'\033[0m'
    else
        C_RED="" ; C_GREEN="" ; C_YELLOW="" ; C_GRAY="" ; C_RESET=""
    fi
}

_crucible_init_markers() {
    # Default to Unicode glyphs. Fall back to ASCII when --ascii or
    # CRUCIBLE_ASCII=1 is set (useful on consoles that don't render UTF-8).
    if [ -n "${CRUCIBLE_ASCII:-}" ]; then
        M_PASS="ok"; M_FAIL="FAIL"; M_SKIP="skip"
    else
        M_PASS="✓"; M_FAIL="✗"; M_SKIP="↷"
    fi
}

# ---- run capture state ----------------------------------------------------
# Populated by `run`; consumed by run-aware assertions and the failure dumper.

status=""
stdout=""
stderr=""
output=""
lines=()
_run_called=0

run() {
    local _out _err
    _out=$(mktemp) || { printf 'crucible: mktemp failed\n' >&2; return 1; }
    _err=$(mktemp) || { printf 'crucible: mktemp failed\n' >&2; rm -f "$_out"; return 1; }
    # Disable set -e for the call itself so we always reach the assignments.
    set +e
    "$@" >"$_out" 2>"$_err"
    status=$?
    set -e
    stdout=$(cat "$_out")
    stderr=$(cat "$_err")
    rm -f "$_out" "$_err"
    # Export the latest capture to files in the test tmpdir so the parent
    # runner can dump them in --verbose mode (the subshell can't write back
    # to the parent's $stdout/$stderr/$_run_called directly).
    if [ -n "${_CRUCIBLE_CAPTURE_DIR:-}" ]; then
        printf '%s' "$status" > "$_CRUCIBLE_CAPTURE_DIR/status"
        printf '%s' "$stdout" > "$_CRUCIBLE_CAPTURE_DIR/stdout"
        printf '%s' "$stderr" > "$_CRUCIBLE_CAPTURE_DIR/stderr"
    fi
    if [ -n "$stdout" ] && [ -n "$stderr" ]; then
        output="${stdout}"$'\n'"${stderr}"
    else
        output="${stdout}${stderr}"
    fi
    if [ -n "$stdout" ]; then
        # shellcheck disable=SC2034  # consumed by tests
        mapfile -t lines <<< "$stdout"
    else
        lines=()
    fi
    _run_called=1
    return 0
}

# ---- failure helpers ------------------------------------------------------

_crucible_fail_header() {
    printf '  %sFAIL%s: %s' "$C_RED" "$C_RESET" "$1" >&2
    if [ -n "${2:-}" ]; then printf ' — %s' "$2" >&2; fi
    printf '\n' >&2
}

_crucible_dump_run() {
    [ "$_run_called" = "1" ] || return 0
    {
        printf '    status: %s\n' "$status"
        if [ -z "$stdout" ]; then
            printf '    stdout: (empty)\n'
        else
            printf '    stdout:\n'
            printf '%s\n' "$stdout" | sed 's/^/      /'
        fi
        if [ -z "$stderr" ]; then
            printf '    stderr: (empty)\n'
        else
            printf '    stderr:\n'
            printf '%s\n' "$stderr" | sed 's/^/      /'
        fi
    } >&2
}

_crucible_dump_capture_files() {
    # Used by --verbose on pass: the subshell wrote status/stdout/stderr
    # into $1/ via _CRUCIBLE_CAPTURE_DIR; read them back and dump.
    local dir="$1" st so se
    [ -f "$dir/status" ] || return 0
    st=$(cat "$dir/status")
    so=$(cat "$dir/stdout")
    se=$(cat "$dir/stderr")
    {
        printf '    status: %s\n' "$st"
        if [ -z "$so" ]; then
            printf '    stdout: (empty)\n'
        else
            printf '    stdout:\n'
            printf '%s\n' "$so" | sed 's/^/      /'
        fi
        if [ -z "$se" ]; then
            printf '    stderr: (empty)\n'
        else
            printf '    stderr:\n'
            printf '%s\n' "$se" | sed 's/^/      /'
        fi
    } >&2
}

_crucible_dump_block() {
    # $1 label, $2 content
    if [ -z "$2" ]; then
        printf '    %s: (empty)\n' "$1" >&2
    else
        printf '    %s:\n' "$1" >&2
        printf '%s\n' "$2" | sed 's/^/      /' >&2
    fi
}

# ---- flow control ---------------------------------------------------------

skip() {
    local reason="${1:-}"
    if [ -z "${_CRUCIBLE_SKIP_FILE:-}" ]; then
        # Called outside a test subshell — refuse to exit the parent shell.
        printf 'crucible: skip() called outside a test\n' >&2
        return 1
    fi
    printf '%s' "$reason" > "$_CRUCIBLE_SKIP_FILE"
    exit 77   # special exit code consumed by _crucible_run_file
}

fail() {
    _crucible_fail_header "${1:-explicit fail}"
    return 1
}

# ---- basic assertions -----------------------------------------------------

assert_equal() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [ "$expected" != "$actual" ]; then
        # For multi-line operands, %q produces an unreadable single-line blob.
        # Fall through to the labeled block dumper instead.
        case "$expected$actual" in
            *$'\n'*)
                _crucible_fail_header "values differ" "$msg"
                _crucible_dump_block "expected" "$expected"
                _crucible_dump_block "actual" "$actual"
                ;;
            *)
                _crucible_fail_header "$(printf 'expected %q, got %q' "$expected" "$actual")" "$msg"
                ;;
        esac
        return 1
    fi
}

assert_not_equal() {
    local unexpected="$1" actual="$2" msg="${3:-}"
    if [ "$unexpected" = "$actual" ]; then
        _crucible_fail_header "$(printf 'expected anything but %q' "$unexpected")" "$msg"
        return 1
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    case "$haystack" in
        *"$needle"*) return 0 ;;
    esac
    _crucible_fail_header "$(printf 'expected string to contain %q' "$needle")" "$msg"
    _crucible_dump_block "actual" "$haystack"
    return 1
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    case "$haystack" in
        *"$needle"*)
            _crucible_fail_header "$(printf 'expected string NOT to contain %q' "$needle")" "$msg"
            _crucible_dump_block "actual" "$haystack"
            return 1 ;;
    esac
}

assert_match() {
    local string="$1" regex="$2" msg="${3:-}"
    if ! [[ "$string" =~ $regex ]]; then
        _crucible_fail_header "$(printf 'expected %q to match /%s/' "$string" "$regex")" "$msg"
        return 1
    fi
}

assert_empty() {
    local s="$1" msg="${2:-}"
    if [ -n "$s" ]; then
        _crucible_fail_header "$(printf 'expected empty, got %q' "$s")" "$msg"
        return 1
    fi
}

assert_not_empty() {
    local s="$1" msg="${2:-}"
    if [ -z "$s" ]; then
        _crucible_fail_header "expected non-empty" "$msg"
        return 1
    fi
}

assert_true() {
    if ! "$@"; then
        _crucible_fail_header "$(printf 'expected command to succeed: %s' "$*")"
        return 1
    fi
}

assert_false() {
    if "$@"; then
        _crucible_fail_header "$(printf 'expected command to fail: %s' "$*")"
        return 1
    fi
}

assert_file_exists() {
    local path="$1" msg="${2:-}"
    if [ ! -e "$path" ]; then
        _crucible_fail_header "$(printf 'expected file %q to exist' "$path")" "$msg"
        return 1
    fi
}

assert_file_not_exists() {
    local path="$1" msg="${2:-}"
    if [ -e "$path" ]; then
        _crucible_fail_header "$(printf 'expected file %q to NOT exist' "$path")" "$msg"
        return 1
    fi
}

# ---- run-aware assertions -------------------------------------------------

_require_run() {
    if [ "$_run_called" != "1" ]; then
        _crucible_fail_header "$1 called before run (no run has been called yet in this test)"
        return 1
    fi
}

assert_status() {
    _require_run "assert_status" || return 1
    local expected="$1"
    if [ "$expected" != "$status" ]; then
        _crucible_fail_header "$(printf 'expected status %s, got %s' "$expected" "$status")"
        _crucible_dump_run
        return 1
    fi
}

assert_success() {
    _require_run "assert_success" || return 1
    if [ "$status" != "0" ]; then
        _crucible_fail_header "$(printf 'expected success, got status %s' "$status")"
        _crucible_dump_run
        return 1
    fi
}

assert_failure() {
    _require_run "assert_failure" || return 1
    if [ "$status" = "0" ]; then
        _crucible_fail_header "expected failure, got status 0"
        _crucible_dump_run
        return 1
    fi
}

_assert_stream_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        _crucible_fail_header "$(printf '%s != expected' "$label")"
        _crucible_dump_block "expected" "$expected"
        _crucible_dump_run
        return 1
    fi
}

_assert_stream_contains() {
    local label="$1" needle="$2" actual="$3"
    case "$actual" in
        *"$needle"*) return 0 ;;
    esac
    _crucible_fail_header "$(printf 'expected %s to contain %q' "$label" "$needle")"
    _crucible_dump_run
    return 1
}

_assert_stream_match() {
    local label="$1" regex="$2" actual="$3"
    if ! [[ "$actual" =~ $regex ]]; then
        _crucible_fail_header "$(printf 'expected %s to match /%s/' "$label" "$regex")"
        _crucible_dump_run
        return 1
    fi
}

_assert_stream_empty() {
    local label="$1" actual="$2"
    if [ -n "$actual" ]; then
        _crucible_fail_header "$(printf 'expected %s to be empty' "$label")"
        _crucible_dump_run
        return 1
    fi
}

assert_stdout_eq()        { _require_run "${FUNCNAME[0]}" || return 1; _assert_stream_eq        "stdout" "$1" "$stdout"; }
assert_stdout_contains()  { _require_run "${FUNCNAME[0]}" || return 1; _assert_stream_contains  "stdout" "$1" "$stdout"; }
assert_stdout_match()     { _require_run "${FUNCNAME[0]}" || return 1; _assert_stream_match     "stdout" "$1" "$stdout"; }
assert_stdout_empty()     { _require_run "${FUNCNAME[0]}" || return 1; _assert_stream_empty     "stdout" "$stdout"; }
assert_stderr_eq()        { _require_run "${FUNCNAME[0]}" || return 1; _assert_stream_eq        "stderr" "$1" "$stderr"; }
assert_stderr_contains()  { _require_run "${FUNCNAME[0]}" || return 1; _assert_stream_contains  "stderr" "$1" "$stderr"; }
assert_stderr_match()     { _require_run "${FUNCNAME[0]}" || return 1; _assert_stream_match     "stderr" "$1" "$stderr"; }
assert_stderr_empty()     { _require_run "${FUNCNAME[0]}" || return 1; _assert_stream_empty     "stderr" "$stderr"; }
assert_output_eq()        { _require_run "${FUNCNAME[0]}" || return 1; _assert_stream_eq        "output" "$1" "$output"; }
assert_output_contains()  { _require_run "${FUNCNAME[0]}" || return 1; _assert_stream_contains  "output" "$1" "$output"; }
assert_output_match()     { _require_run "${FUNCNAME[0]}" || return 1; _assert_stream_match     "output" "$1" "$output"; }
assert_output_empty()     { _require_run "${FUNCNAME[0]}" || return 1; _assert_stream_empty     "output" "$output"; }

assert_line() {
    _require_run "assert_line" || return 1
    local n="$1" expected="$2"
    local actual="${lines[$n]:-}"
    if [ "$expected" != "$actual" ]; then
        _crucible_fail_header "$(printf 'line %s: expected %q, got %q' "$n" "$expected" "$actual")"
        _crucible_dump_run
        return 1
    fi
}

# ---- discovery ------------------------------------------------------------

_crucible_discover() {
    local root="${1:-$PWD}"
    if [ -d "$root" ]; then
        find "$root" -name '*_test.sh' -type f | sort
    elif [ -f "$root" ]; then
        printf '%s\n' "$root"
    else
        printf 'crucible: not found: %s\n' "$root" >&2
        return 2
    fi
}

# ---- runner internals -----------------------------------------------------

_crucible_reset_test_functions() {
    local fn
    while IFS= read -r fn; do
        unset -f "$fn" 2>/dev/null || true
    done < <(declare -F | awk '/^declare -f (test_|setup$|teardown$)/ {print $3}')
}

_crucible_list_tests() {
    declare -F | awk '/^declare -f test_/ {print $3}'
}

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAIL_LIST=()

_crucible_list_file() {
    local file="$1" filter="$2"
    _crucible_reset_test_functions
    if ! bash -n "$file" 2>/dev/null; then
        printf '%s%s%s  (syntax error)\n' "$C_RED" "$file" "$C_RESET" >&2
        return
    fi
    # shellcheck disable=SC1090
    source "$file"
    local fn shown=0
    while IFS= read -r fn; do
        if [ -n "$filter" ] && ! [[ "$fn" =~ $filter ]]; then
            continue
        fi
        if [ "$shown" = "0" ]; then
            printf '%s%s%s\n' "$C_GRAY" "$file" "$C_RESET"
            shown=1
        fi
        printf '  %s\n' "$fn"
    done < <(_crucible_list_tests)
}

_crucible_run_file() {
    local file="$1" filter="$2"
    printf '%s%s%s\n' "$C_GRAY" "$file" "$C_RESET"
    _crucible_reset_test_functions

    # Syntax-check the file BEFORE sourcing. Without this, a syntax error
    # (or a top-level `exit N`) silently produces "0 passed" with exit 0,
    # masking broken test files in CI.
    local _synerr
    if ! _synerr=$(bash -n "$file" 2>&1); then
        printf '  %s%s%s %s\n' "$C_RED" "$M_FAIL" "$C_RESET" "(syntax error)"
        printf '    %s\n' "$_synerr" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_LIST+=("$file::<syntax error>")
        return
    fi

    # shellcheck disable=SC1090
    source "$file"

    local fn rc tmp skip_file skip_reason
    while IFS= read -r fn; do
        if [ -n "$filter" ] && ! [[ "$fn" =~ $filter ]]; then
            continue
        fi
        tmp=$(mktemp -d) || { printf 'crucible: mktemp -d failed\n' >&2; exit 1; }
        # One tmpdir per test holds the cwd and the skip-reason file. This
        # halves the per-test mktemp count vs. allocating each separately.
        skip_file="$tmp/.crucible-skip"
        # Reset capture state in the PARENT shell. Subshells inherit these
        # values; modifications inside the subshell don't escape, so each
        # test enters with a clean slate.
        status=""; stdout=""; stderr=""; output=""; lines=(); _run_called=0
        (
            set -e
            cd "$tmp"
            export _CRUCIBLE_SKIP_FILE="$skip_file"
            export _CRUCIBLE_CAPTURE_DIR="$tmp"
            if declare -F setup >/dev/null; then setup; fi
            "$fn"
            if declare -F teardown >/dev/null; then teardown; fi
        )
        rc=$?
        if [ "$rc" = "0" ]; then
            printf '  %s%s%s %s\n' "$C_GREEN" "$M_PASS" "$C_RESET" "$fn"
            if [ "$verbose" = "1" ] && [ -f "$tmp/status" ]; then
                _crucible_dump_capture_files "$tmp"
            fi
            PASS_COUNT=$((PASS_COUNT + 1))
        elif [ "$rc" = "77" ]; then
            skip_reason=$(cat "$skip_file" 2>/dev/null)
            if [ -n "$skip_reason" ]; then
                printf '  %s%s%s %s — %s\n' "$C_YELLOW" "$M_SKIP" "$C_RESET" "$fn" "$skip_reason"
            else
                printf '  %s%s%s %s\n' "$C_YELLOW" "$M_SKIP" "$C_RESET" "$fn"
            fi
            SKIP_COUNT=$((SKIP_COUNT + 1))
        else
            printf '  %s%s%s %s\n' "$C_RED" "$M_FAIL" "$C_RESET" "$fn"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAIL_LIST+=("$file::$fn")
        fi
        rm -rf "$tmp"
    done < <(_crucible_list_tests)
}

# ---- help -----------------------------------------------------------------

_crucible_print_help() {
    cat <<'EOF'
crucible — a tiny bash test runner.

Usage:
  crucible.sh [--filter <regex>] [<path>...]

With no <path>, discovers *_test.sh under $PWD (recursive).
With <path>s, each may be a file or directory.

Options:
  --filter <regex>   run only tests whose function name matches the regex
  --list             list discovered test functions without running them
  -v, --verbose      on pass, also dump captured $status/$stdout/$stderr if run was called
  --ascii            use ASCII markers (ok / FAIL / skip) instead of Unicode
  --version          print version and exit
  -h, --help         show this help and exit

Environment:
  PROJECT_ROOT       exported to tests; defaults to git toplevel, else $PWD.
  NO_COLOR=1         disable ANSI colors.
  CRUCIBLE_ASCII=1   same as --ascii.

Conventions:
  - Test files end in _test.sh.
  - Test functions start with test_.
  - Optional setup()/teardown() run before/after each test in the same file.
  - Each test runs in a subshell with cwd set to a fresh tmpdir.
  - Inside the test, set -e is active: a failed assertion (which returns 1)
    aborts the test immediately.

See README.md for the full assertion catalogue and the `run` capture helper.
EOF
}

# ---- main -----------------------------------------------------------------

verbose=0
list_mode=0

main() {
    local filter=""
    local args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --filter)
                if [ $# -lt 2 ] || [ -z "$2" ] || [[ "$2" == -* ]]; then
                    printf 'crucible: --filter requires a regex argument\n' >&2
                    exit 2
                fi
                filter="$2"; shift 2 ;;
            --filter=*)
                filter="${1#--filter=}"
                if [ -z "$filter" ]; then
                    printf 'crucible: --filter requires a regex argument\n' >&2
                    exit 2
                fi
                shift ;;
            --ascii)
                CRUCIBLE_ASCII=1; shift ;;
            --list)
                list_mode=1; shift ;;
            -v|--verbose)
                verbose=1; shift ;;
            --version)
                printf 'crucible %s\n' "$CRUCIBLE_VERSION"
                exit 0 ;;
            -h|--help)
                _crucible_print_help
                exit 0 ;;
            --) shift; args+=("$@"); break ;;
            -*)
                printf 'crucible: unknown flag: %s\n' "$1" >&2
                exit 2 ;;
            *)
                args+=("$1"); shift ;;
        esac
    done

    _crucible_init_env
    _crucible_init_colors
    _crucible_init_markers

    # Bash leaks _CRUCIBLE_SKIP_FILE into child processes when the parent is
    # itself a crucible test running a child crucible (self-tests / nested
    # invocations). Clear it so skip()'s guard works in the child's parent shell.
    unset _CRUCIBLE_SKIP_FILE

    if [ -n "$filter" ]; then
        # [[ =~ ]] returns 0 on match, 1 on no-match, 2 on regex syntax error.
        # Only treat 2 as invalid. Capture $? immediately to avoid SC2319.
        local _rc
        [[ "" =~ $filter ]] 2>/dev/null
        _rc=$?
        if [ "$_rc" -eq 2 ]; then
            printf 'crucible: invalid --filter regex: %s\n' "$filter" >&2
            exit 2
        fi
    fi

    local files=()
    if [ ${#args[@]} -eq 0 ]; then
        while IFS= read -r f; do files+=("$f"); done < <(_crucible_discover "$PWD")
    else
        local a
        for a in "${args[@]}"; do
            if [ ! -e "$a" ]; then
                printf 'crucible: not found: %s\n' "$a" >&2
                exit 2
            fi
            while IFS= read -r f; do files+=("$f"); done < <(_crucible_discover "$a")
        done
    fi

    if [ ${#files[@]} -eq 0 ]; then
        echo "no tests found"
        exit 0
    fi

    local file
    if [ "$list_mode" = "1" ]; then
        for file in "${files[@]}"; do
            _crucible_list_file "$file" "$filter"
        done
        exit 0
    fi

    for file in "${files[@]}"; do
        _crucible_run_file "$file" "$filter"
    done

    # --filter matching zero tests across all files is almost always a typo
    # in CI — surface it loudly.
    if [ -n "$filter" ] && [ $((PASS_COUNT + FAIL_COUNT + SKIP_COUNT)) -eq 0 ]; then
        printf '\n----\n'
        printf '%sno tests matched filter%s: %s\n' "$C_RED" "$C_RESET" "$filter" >&2
        exit 2
    fi

    printf '\n----\n'
    if [ "$FAIL_COUNT" = "0" ]; then
        printf '%sall passed%s: %d passed' "$C_GREEN" "$C_RESET" "$PASS_COUNT"
        [ "$SKIP_COUNT" -gt 0 ] && printf ', %d skipped' "$SKIP_COUNT"
        printf '\n'
        exit 0
    fi
    printf '%sFAILED%s: %d failed, %d passed' "$C_RED" "$C_RESET" "$FAIL_COUNT" "$PASS_COUNT"
    [ "$SKIP_COUNT" -gt 0 ] && printf ', %d skipped' "$SKIP_COUNT"
    printf '\n'
    local f
    for f in "${FAIL_LIST[@]}"; do
        printf '  - %s\n' "$f"
    done
    exit 1
}

main "$@"
