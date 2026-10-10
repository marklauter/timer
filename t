#!/usr/bin/env bash
# Time tracker. Append-only ledger per project: ledger/<owner>-<repo>.csv next to this script.
#   t start [owner/repo] ["description"]  start timer (defaults to current git repo's origin)
#   t stop ["description"]                stop the running timer
#   t status                              show the running timer
#   t adjust <±minutes> "reason" [owner/repo]   correction entry
#   t checkpoint [owner/repo]             carry the balance forward (turn the page)
#   t report [owner/repo]                 balance in hours per project (or one project)
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ledger="$dir/ledger"

project() {
  local p="${1:-}"
  if [[ -z "$p" ]]; then
    p="$(git remote get-url origin 2>/dev/null)" || { echo "not in a git repo with an origin; pass owner/repo" >&2; exit 1; }
    p="${p%.git}"
    p="${p#*://*/}"   # https://github.com/owner/repo -> owner/repo
    p="${p#*:}"       # git@github.com:owner/repo     -> owner/repo
  fi
  echo "${p//\//-}" | tr '[:upper:]' '[:lower:]'
}

log() { # name event [minutes] [note]
  local file="$ledger/$1.csv" note="${4:-}"
  note="${note//[$'\r\n']/ }"
  (( ${#note} <= 2000 )) || { echo "description is ${#note} chars; limit is 2000" >&2; exit 1; }
  mkdir -p "$ledger"
  [[ -f "$file" ]] || echo "timestamp,event,minutes,note" >> "$file"
  [[ -n "$note" ]] && note="\"${note//\"/\"\"}\""
  echo "$(date -Iseconds),$2,${3:-},$note" >> "$file"
}

repo_re='^[^/[:space:]]+/[^/[:space:]]+$'

usage() { echo "usage: $1" >&2; echo 'quote descriptions: "like this"' >&2; exit 1; }

is_running() { [[ "$(tail -n 1 "$1" | cut -d, -f2)" == start ]]; }

running() { # prints names whose last event is start
  local f
  for f in "$ledger"/*.csv; do
    [[ -f "$f" ]] && is_running "$f" && basename "$f" .csv
  done
  return 0
}

balance() { # file -> minutes since last checkpoint, plus the checkpoint's carried balance
  local f="$1"
  # tac reads from the end; stop at the last checkpoint instead of scanning the whole file
  { { tac "$f" || true; } | awk -F, '{print} $2=="checkpoint"{exit}' | tac
    if is_running "$f"; then echo "$(date -Iseconds),stop"; fi; } \
    | while IFS=, read -r ts ev min _; do
        case "$ev" in
          start|stop) echo "$ev $(date -d "$ts" +%s)" ;;
          *) echo "$ev $min" ;;
        esac
      done \
    | awk '$1=="start"{s=$2} $1=="stop"&&s{m+=($2-s)/60; s=0} $1=="adjust"||$1=="checkpoint"{m+=$2} END{printf "%.2f", m}'
}

case "${1:-status}" in
  start)
    shift
    p=
    if [[ "${1:-}" =~ $repo_re ]]; then p="$1"; shift; fi
    (( $# <= 1 )) || usage 't start [owner/repo] ["description"]'
    name="$(project "$p")"
    for n in $(running); do log "$n" stop; echo "stopped $n"; done
    log "$name" start "" "${1:-}"
    echo "started $name"
    ;;
  stop)
    shift
    (( $# <= 1 )) || usage 't stop ["description"]'
    names="$(running)"
    [[ -n "$names" ]] || echo "no timer running"
    for n in $names; do log "$n" stop "" "${1:-}"; echo "stopped $n"; done
    ;;
  status)
    names="$(running)"
    [[ -n "$names" ]] || echo "no timer running"
    for n in $names; do
      since="$(tail -n 1 "$ledger/$n.csv" | cut -d, -f1)"
      echo "$n running $(( ($(date +%s) - $(date -d "$since" +%s)) / 60 )) min"
    done
    ;;
  adjust)
    [[ "${2:-}" =~ ^[+-]?[0-9]+(\.[0-9]+)?$ && -n "${3:-}" && $# -le 4 ]] && [[ -z "${4:-}" || "$4" =~ $repo_re ]] || usage 't adjust <±minutes> "reason" [owner/repo]'
    name="$(project "${4:-}")"
    log "$name" adjust "${2#+}" "$3"
    echo "adjusted $name by $2 min"
    ;;
  checkpoint)
    name="$(project "${2:-}")"
    f="$ledger/$name.csv"
    [[ -f "$f" ]] || { echo "no ledger for $name" >&2; exit 1; }
    if is_running "$f"; then echo "$name is running; stop it first" >&2; exit 1; fi
    m="$(balance "$f")"
    log "$name" checkpoint "$m" "balance carried forward"
    echo "checkpoint $name at $m min"
    ;;
  report)
    if [[ -n "${2:-}" ]]; then files=("$ledger/$(project "$2").csv"); else files=("$ledger"/*.csv); fi
    for f in "${files[@]}"; do
      [[ -f "$f" ]] || continue
      printf "%-40s %8.2f h\n" "$(basename "$f" .csv)" "$(awk -v m="$(balance "$f")" 'BEGIN{print m/60}')"
    done
    ;;
  *) sed -n '2,9p' "$0" | sed 's/^# //'; exit 1 ;;
esac
