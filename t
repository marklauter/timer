#!/usr/bin/env bash
# Time tracker. Append-only ledger per client project: ledger/<client>/<project>.csv next to this script.
#   t start <client> <project> ["description"] [--at time]  start timer
#   t stop ["description"] [--at time]                      stop the running timer
#   t status                                                show the running timer
#   t adjust <client> <project> <±minutes> "reason"         correction entry
#   t checkpoint <client> <project>                         carry the balance forward (turn the page)
#   t report [client] [project]                             balance in hours per project
#   --at takes anything `date -d` reads, such as 10:45 or "2026-10-21 10:45", and defaults to now
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ledger="$dir/ledger"

usage() { echo "usage: $1" >&2; echo 'quote descriptions: "like this"' >&2; exit 1; }

part() { # label value -> validated, lowercased; it becomes a folder or file name
  [[ "${2:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "pass a $1 name (letters, digits, . _ -)" >&2; exit 1; }
  echo "$2" | tr '[:upper:]' '[:lower:]'
}

key() { # client project -> client/project
  local c p
  c="$(part client "${1:-}")" && p="$(part project "${2:-}")" && echo "$c/$p"
}

# pull --at out of the arguments; every entry this run writes carries that time
at=
args=()
while (( $# )); do
  if [[ "$1" == --at ]]; then
    (( $# >= 2 )) || usage '--at <time>'
    at="$2"; shift 2
  else
    args+=("$1"); shift
  fi
done
set -- "${args[@]}"

if [[ -n "$at" ]]; then
  stamp="$(date -d "$at" -Iseconds 2>/dev/null)" || { echo "can't read time '$at'" >&2; exit 1; }
  (( $(date -d "$stamp" +%s) <= $(date +%s) )) || { echo "$stamp is in the future" >&2; exit 1; }
else
  stamp="$(date -Iseconds)"
fi

not_before_last() { # name: refuse a time earlier than the ledger's last entry
  local f="$ledger/$1.csv" last
  [[ -f "$f" ]] || return 0
  last="$(tail -n 1 "$f" | cut -d, -f1)"
  [[ "$last" == timestamp ]] && return 0
  (( $(date -d "$last" +%s) <= $(date -d "$stamp" +%s) )) || { echo "$1 has an entry at $last, after $stamp" >&2; exit 1; }
}

log() { # name event [minutes] [note]
  local file="$ledger/$1.csv" note="${4:-}"
  note="${note//[$'\r\n']/ }"
  (( ${#note} <= 2000 )) || { echo "description is ${#note} chars; limit is 2000" >&2; exit 1; }
  mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || echo "timestamp,event,minutes,note" >> "$file"
  [[ -n "$note" ]] && note="\"${note//\"/\"\"}\""
  echo "$stamp,$2,${3:-},$note" >> "$file"
}

is_running() { [[ "$(tail -n 1 "$1" | cut -d, -f2)" == start ]]; }

name_of() { local n="${1#"$ledger"/}"; echo "${n%.csv}"; }

running() { # prints client/project names whose last event is start
  local f
  for f in "$ledger"/*/*.csv; do
    [[ -f "$f" ]] && is_running "$f" && name_of "$f"
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
    (( $# <= 3 )) || usage 't start <client> <project> ["description"] [--at time]'
    name="$(key "${1:-}" "${2:-}")"
    names="$(running)"
    for n in $names "$name"; do not_before_last "$n"; done
    for n in $names; do log "$n" stop; echo "stopped $n"; done
    log "$name" start "" "${3:-}"
    echo "started $name"
    ;;
  stop)
    shift
    (( $# <= 1 )) || usage 't stop ["description"] [--at time]'
    names="$(running)"
    [[ -n "$names" ]] || echo "no timer running"
    for n in $names; do not_before_last "$n"; done
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
    [[ $# -eq 5 && "$4" =~ ^[+-]?[0-9]+(\.[0-9]+)?$ && -n "$5" ]] || usage 't adjust <client> <project> <±minutes> "reason"'
    name="$(key "$2" "$3")"
    log "$name" adjust "${4#+}" "$5"
    echo "adjusted $name by $4 min"
    ;;
  checkpoint)
    name="$(key "${2:-}" "${3:-}")"
    f="$ledger/$name.csv"
    [[ -f "$f" ]] || { echo "no ledger for $name" >&2; exit 1; }
    if is_running "$f"; then echo "$name is running; stop it first" >&2; exit 1; fi
    m="$(balance "$f")"
    log "$name" checkpoint "$m" "balance carried forward"
    echo "checkpoint $name at $m min"
    ;;
  report)
    if [[ -n "${3:-}" ]]; then files=("$ledger/$(key "$2" "$3").csv")
    elif [[ -n "${2:-}" ]]; then files=("$ledger/$(part client "$2")"/*.csv)
    else files=("$ledger"/*/*.csv); fi
    for f in "${files[@]}"; do
      [[ -f "$f" ]] || continue
      printf "%-40s %8.2f h\n" "$(name_of "$f")" "$(awk -v m="$(balance "$f")" 'BEGIN{print m/60}')"
    done
    ;;
  *) sed -n '2,9p' "$0" | sed 's/^# //'; exit 1 ;;
esac
