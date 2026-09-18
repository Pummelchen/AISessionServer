#!/bin/sh
# tests/protocol.sh — end-to-end regression tests for the chatbox HTTP API.
#
# Runs against a LIVE server; it does not start one. Point it at a disposable
# instance (the CI workflow does exactly that) — it writes real rows:
#
#   ./chatbox --port 8787 --db tests/.scratch/ci.sqlite --token-file tests/.scratch/token &
#   CHATBOX_URL=http://127.0.0.1:8787 CHATBOX_TOKEN=$(cat tests/.scratch/token) \
#     sh tests/protocol.sh
#
# Every id and repo key it uses is prefixed with a per-run tag, so concurrent
# runs never collide with each other or with real data. It still refuses to talk
# to a non-loopback host unless you insist, so pointing it at the shared board by
# accident is not possible.
#
# POSIX sh + curl only, exactly like the client itself: no jq, no bash 4, no
# python. Exits 0 only when every check passes, so CI goes red on a regression
# instead of quietly green.
#
# Design rule for this file: a check must be able to FAIL for the reason its
# description claims. An assertion that would also hold on an error body, on an
# empty response, or on a response produced by a different code path is a bug in
# the test. Each mutation of the server sources that this suite claims to catch must
# turn it red.
#
# Deliberately NOT covered, because curl cannot express them and both were
# reviewed by hand: whether the server closes the socket after responding, and how
# it treats a client that half-closes its write side and keeps reading. The second
# is why the long-poll path does not treat a clean end-of-stream as abandonment.

set -u

URL="${CHATBOX_URL:-http://127.0.0.1:8787}"
TOKEN="${CHATBOX_TOKEN:-}"

# ---------------------------------------------------------------------------
# Safety: these tests write to the board. Keep them on a throwaway server.
# ---------------------------------------------------------------------------
case "$URL" in
  *127.0.0.1*|*localhost*|*'[::1]'*) ;;
  *)
    if [ "${CHATBOX_ALLOW_REMOTE:-0}" != "1" ]; then
      printf 'refusing to run against %s: these tests write agents, threads and messages.\n' "$URL" >&2
      printf 'Start a disposable server on loopback, or set CHATBOX_ALLOW_REMOTE=1 to accept the mess.\n' >&2
      exit 2
    fi
    ;;
esac

# Per-run namespace.
RUN="t$$.$(date +%s)"
A="it-$RUN-app"
B="it-$RUN-lib"
C="it-$RUN-second-owner"
D="it-$RUN-multi"
E="it-$RUN-single"
W="it-$RUN-waiter"
W2="it-$RUN-waiter-idle"
W3="it-$RUN-waiter-read-only"
C2="it-$RUN-cred2-session"
C3="it-$RUN-cred3-session"
C4="it-$RUN-cred4-session"
C5="it-$RUN-cred2-legacy"
C6="it-$RUN-ack-all"
SB="it-$RUN-stale"
SS="it-$RUN-stale-sender"
SB2="it-$RUN-fixture-ok"
SB3="it-$RUN-fixture-forced"
SB4="it-$RUN-fixture-norepo"
SB5="it-$RUN-fixture-spelling"
WV="it-$RUN-watch"
WS="it-$RUN-watch-sender"
REPO_APP="example.test/$RUN/app"
REPO_LIB="example.test/$RUN/lib"
REPO_NONE="example.test/$RUN/nobody"
REPO_ONE="example.test/$RUN/one"
REPO_TWO="example.test/$RUN/two"
REPO_ALIAS="example.test/$RUN/alias"

pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() {
  fail=$((fail + 1))
  printf '  FAIL  %s\n' "$1"
  if [ $# -gt 1 ]; then printf '        %s\n' "$2"; fi
  return 0
}
# Trim a response to one readable line for failure messages.
snip() { printf '%s' "$1" | tr '\n' '~' | cut -c1-300; }

contains() { # description, haystack, needle
  if [ -z "$2" ]; then
    no "$1" "empty response — transport failure, or the server returned nothing"
  else
    case "$2" in
      *"$3"*) ok "$1" ;;
      *) no "$1" "expected to contain [$3], got [$(snip "$2")]" ;;
    esac
  fi
}

lacks() { # description, haystack, needle
  if [ -z "$2" ]; then
    no "$1" "empty response — transport failure, or the server returned nothing"
  else
    case "$2" in
      *"$3"*) no "$1" "expected NOT to contain [$3], got [$(snip "$2")]" ;;
      *) ok "$1" ;;
    esac
  fi
}

equals() { # description, actual, expected
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$3], got [$2]"; fi
}

# ---------------------------------------------------------------------------
# Bounded execution
# A check that waits for a delivery has a legitimate reason to block, but only
# until the delivery arrives. When it never does — which is exactly what a broken
# routing change looks like — the client sits out its whole capped wait, and a
# `--wait 99999` case caps at the server's 300 seconds. macOS ships no `timeout`,
# so this is the small one the suite needs: run the command with a deadline and
# report 124 when it passed. The green path returns in a second or two.
# ---------------------------------------------------------------------------
kill_tree() { # pid — children first, so a killed client leaves no curl holding a poll
  for _kt in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$_kt"; done
  kill -TERM "$1" 2>/dev/null
}

deadline() { # seconds, then command; prints the output, 124 if the deadline passed
  _dl="$1"; shift
  _dout="$SCRATCH/deadline-${RUN}.$$"
  : > "$_dout"
  "$@" > "$_dout" 2>&1 &
  _dpid=$!
  ( sleep "$_dl"; kill_tree "$_dpid" ) >/dev/null 2>&1 &
  _dwatch=$!
  wait "$_dpid" 2>/dev/null
  _drc=$?
  kill_tree "$_dwatch" 2>/dev/null
  wait "$_dwatch" 2>/dev/null
  # A shell reports a signal death as 128+signal; normalise it to the timeout code
  # so the caller can tell "never answered" apart from "answered with an error".
  [ "$_drc" -ge 128 ] && _drc=124
  cat "$_dout"
  rm -f "$_dout"
  return "$_drc"
}

# ---------------------------------------------------------------------------
# HTTP helpers — same shape as chatbox-cli.sh, so the tests exercise the same
# query-string/Bearer paths real clients use.
# ---------------------------------------------------------------------------
qs() { # append the token to a query string
  if [ -n "$TOKEN" ]; then
    if [ -n "${1:-}" ]; then printf '%s&token=%s' "$1" "$TOKEN"; else printf 'token=%s' "$TOKEN"; fi
  else
    printf '%s' "${1:-}"
  fi
}

get() { # path [query]
  _q="$(qs "${2:-}")"
  curl -sS --max-time 20 "${URL}${1}${_q:+?$_q}"
}

bare_url() { # path-with-query, no credential appended
  printf '%s%s' "$URL" "$1"
}

url_for() { # path [query] -> a full URL, for checks that need curl's -w
  _q="$(qs "${2:-}")"
  printf '%s%s%s' "$URL" "$1" "${_q:+?$_q}"
}

scoped_get() { # path-with-query, credential -> body
  curl -sS --max-time 20 -H "Authorization: Bearer $2" "${URL}${1}"
}

scoped_get_status() { # path-with-query, credential -> HTTP status
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -H "Authorization: Bearer $2" "${URL}${1}"
}

scoped_post() { # path, credential, then curl data args
  _p="$1"; _t="$2"; shift 2
  curl -sS --max-time 20 -G -X POST "$@" -H "Authorization: Bearer $_t" "${URL}${_p}"
}

scoped_status_post() { # path, credential, then curl data args -> HTTP status
  _p="$1"; _t="$2"; shift 2
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -G -X POST "$@" \
    -H "Authorization: Bearer $_t" "${URL}${_p}"
}

code_of() { # path [query] -> HTTP status
  _q="$(qs "${2:-}")"
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "${URL}${1}${_q:+?$_q}"
}

post() { # path, then curl data args
  _p="$1"
  shift
  if [ -n "$TOKEN" ]; then
    curl -sS --max-time 20 -G -X POST "$@" --data-urlencode "token=$TOKEN" "${URL}${_p}"
  else
    curl -sS --max-time 20 -G -X POST "$@" "${URL}${_p}"
  fi
}

status_post() { # path, then curl data args -> HTTP status
  _p="$1"
  shift
  if [ -n "$TOKEN" ]; then
    curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -G -X POST "$@" \
      --data-urlencode "token=$TOKEN" "${URL}${_p}"
  else
    curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -G -X POST "$@" "${URL}${_p}"
  fi
}

bearer_post() { # path, then curl data args -> uses the header, not ?token=
  _p="$1"
  shift
  curl -sS --max-time 20 -G -X POST "$@" -H "Authorization: Bearer $TOKEN" "${URL}${_p}"
}

field() { # response, key -> first matching "key: value"
  printf '%s' "$1" | sed -n "s/^$2: //p" | head -n 1
}

jsonnum() { # JSON listing, key -> the number the hand-built prefix reports
  # `jsonRows` writes `{"shown": N, "matching": M, "<key>": [` ahead of the pretty-printed
  # array, so both counts are on the first line, before any row value could be read as one.
  printf '%s' "$1" | sed -n "s/.*\"$2\": \([0-9][0-9]*\).*/\1/p" | head -n 1
}

# Scratch space for the checks that have to run something in the background.
#
# Paths built from $0 are *relative* when the suite is invoked as `sh tests/protocol.sh`,
# and a relative path stops resolving the moment a check runs something from inside a
# fixture checkout — section 19 runs the client exactly that way, from a throwaway git
# repository, and section 18 runs the server binary. Resolve them against the directory
# the suite was started in, once, so every check sees the same absolute path no matter
# where it runs from.
abspath() { # path -> absolute, based on the starting directory
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  if _abs="$(cd "$(dirname "$1")" 2>/dev/null && pwd)"; then
          printf '%s/%s' "$_abs" "$(basename "$1")"
        else
          printf '%s' "$1"
        fi ;;
  esac
}
SCRATCH="$(abspath "${CHATBOX_SCRATCH:-$(dirname "$0")/.scratch}")"
mkdir -p "$SCRATCH" 2>/dev/null || SCRATCH="."
CLI="$(abspath "${CHATBOX_CLI:-$(dirname "$0")/../chatbox-cli.sh}")"
SUITE_LIB="$(dirname "$0")/lib"
# The suite's own files, as a list: the entry and every sourced part, in the order they run.
SUITE_SELF="$0"
for _f in "$SUITE_LIB"/*.sh; do
  [ -f "$_f" ] && SUITE_SELF="$SUITE_SELF $_f"
done
if [ -n "${CHATBOX_BIN:-}" ]; then CHATBOX_BIN="$(abspath "$CHATBOX_BIN")"; fi

printf 'chatbox protocol tests\n  server: %s\n  run:    %s\n\n' "$URL" "$RUN"

# ---------------------------------------------------------------------------
# The suite binds these ports itself; one already held is not detected by the sections.
# A fixture that cannot bind exits ("Address already in use"), the section's readiness probe is then
# answered by whatever holds the port, and the checks measure a server this suite did not start - an
# orphaned fixture from a run that died mid-section, or an operator's board started on a port the
# runbook did not warn about. Fail here, before the first check, naming the port.
# ---------------------------------------------------------------------------
if [ -z "${CHATBOX_ALLOW_HELD_PORTS:-}" ]; then
  # The *effective* port for each fixture, so an override is what gets probed: the matrix runs
  # several cells at once, each in its own port band, and probing the file's defaults would trip on
  # the other cells' fixtures.
  held=""
  # Every fixture default, collected from the entry and each sourced part.
  held_specs=""
  for _f in $SUITE_SELF; do
    held_specs="$held_specs $(grep -o 'CHATBOX_[A-Z_]*PORT:-[0-9][0-9]*' "$_f")"
  done
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    _pname="${spec%%:*}"
    _pdef="${spec#*:-}"
    _ptest=""
    eval "_ptest=\${$_pname:-$_pdef}"
    if curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:$_ptest/" 2>/dev/null; then held="$held $_ptest"; fi
  done <<EOF
$(printf '%s' "$held_specs" | tr ' ' '\n' | grep -v '^$' | sort -u)
EOF
  if [ -n "$held" ]; then
    printf 'FATAL: the suite binds these ports itself and they are already answering:%s\n' "$held" >&2
    printf '  stop what holds them (an orphaned fixture from a run that was interrupted,\n' >&2
    printf '  or a board started on a fixture port), or set CHATBOX_ALLOW_HELD_PORTS=1 to\n' >&2
    printf '  run anyway - the sections that use them will then measure the wrong server.\n' >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# The suite is split into sourced parts so no file grows past the project's 500-line rule.
# Each part is sourced in order, exactly as the one-file version ran it, and the explicit
# source directives let `shellcheck -x` analyse the suite as the one program it is.
# shellcheck source=lib/01-part.sh
. "$SUITE_LIB/01-part.sh"
# shellcheck source=lib/02-part.sh
. "$SUITE_LIB/02-part.sh"
# shellcheck source=lib/03-part.sh
. "$SUITE_LIB/03-part.sh"
# shellcheck source=lib/04-part.sh
. "$SUITE_LIB/04-part.sh"
# shellcheck source=lib/05-part.sh
. "$SUITE_LIB/05-part.sh"
# shellcheck source=lib/06-part.sh
. "$SUITE_LIB/06-part.sh"
# shellcheck source=lib/07-part.sh
. "$SUITE_LIB/07-part.sh"
# shellcheck source=lib/08-part.sh
. "$SUITE_LIB/08-part.sh"
# shellcheck source=lib/09-part.sh
. "$SUITE_LIB/09-part.sh"
# shellcheck source=lib/10-part.sh
. "$SUITE_LIB/10-part.sh"
# shellcheck source=lib/11-part.sh
. "$SUITE_LIB/11-part.sh"
# shellcheck source=lib/12-part.sh
. "$SUITE_LIB/12-part.sh"
# shellcheck source=lib/13-part.sh
. "$SUITE_LIB/13-part.sh"
# shellcheck source=lib/14-part.sh
. "$SUITE_LIB/14-part.sh"
# shellcheck source=lib/15-part.sh
. "$SUITE_LIB/15-part.sh"
# shellcheck source=lib/16-part.sh
. "$SUITE_LIB/16-part.sh"
# shellcheck source=lib/17-part.sh
. "$SUITE_LIB/17-part.sh"
