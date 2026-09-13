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
REPO_APP="example.test/$RUN/app"
REPO_LIB="example.test/$RUN/lib"
REPO_NONE="example.test/$RUN/nobody"

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
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) no "$1" "expected to contain [$3], got [$(snip "$2")]" ;;
  esac
}

lacks() { # description, haystack, needle
  case "$2" in
    *"$3"*) no "$1" "expected NOT to contain [$3], got [$(snip "$2")]" ;;
    *) ok "$1" ;;
  esac
}

equals() { # description, actual, expected
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$3], got [$2]"; fi
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

field() { # response, key -> first matching "key: value"
  printf '%s' "$1" | sed -n "s/^$2: //p" | head -n 1
}

printf 'chatbox protocol tests\n  server: %s\n  run:    %s\n\n' "$URL" "$RUN"

# ---------------------------------------------------------------------------
# 1. Reachability and auth
# ---------------------------------------------------------------------------
if ! curl -sS --max-time 20 -o /dev/null "$URL/health" 2>/dev/null; then
  printf 'FATAL: cannot reach %s — start the server first.\n' "$URL" >&2
  exit 2
fi

anon="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/health")"
auth_open=0
[ "$anon" = "200" ] && auth_open=1
printf 'auth: %s\n' "$([ "$auth_open" = 1 ] && echo 'OPEN — no token configured on the server' || echo 'token required')"

# Pins the fixed bug: the token in the query string used to be ignored (401).
contains "health via query-string token" "$(get /health)" "ok chatbox up"
contains "health via Authorization: Bearer" \
  "$(curl -sS --max-time 20 -H "Authorization: Bearer $TOKEN" "$URL/health")" "ok chatbox up"

if [ "$auth_open" = 0 ]; then
  equals "missing token is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/health")" "401"
  contains "missing token explains itself" \
    "$(curl -sS --max-time 20 "$URL/health")" "unauthorized"
  equals "wrong query token is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/health?token=not-the-token")" "401"
  equals "wrong bearer token is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -H 'Authorization: Bearer nope' "$URL/health")" "401"
else
  printf '  skip  token-rejection checks (server started with --open)\n'
fi

# ---------------------------------------------------------------------------
# 2. Usage and unknown routes
# ---------------------------------------------------------------------------
contains "GET / teaches the protocol" "$(get /)" "harness-independent session chatbox"
contains "usage documents register" "$(get /)" "register"
contains "unknown route reports not found" "$(get /no-such-route)" "not found"
equals "unknown route is 404" "$(code_of /no-such-route)" "404"

# ---------------------------------------------------------------------------
# 3. Registration and the ownership registry
# ---------------------------------------------------------------------------
reg="$(post /register \
  --data-urlencode "id=$A" --data-urlencode "node=node-a" \
  --data-urlencode "agent=dsh" --data-urlencode "harness=DeepSeek Harness" \
  --data-urlencode "session=sess-$RUN-a" --data-urlencode "ip=10.0.0.1" \
  --data-urlencode "repos=$REPO_APP")"
contains "register returns ok" "$reg" "ok registered"
contains "register echoes the id" "$reg" "id: $A"
contains "register echoes the declared repo" "$reg" "$REPO_APP"

post /register --data-urlencode "id=$B" --data-urlencode "node=node-b" \
  --data-urlencode "agent=claude" --data-urlencode "harness=Claude Code" \
  --data-urlencode "repos=$REPO_LIB" >/dev/null

peers="$(get /peers)"
contains "peers lists the first session" "$peers" "$A"
contains "peers lists the second session" "$peers" "$B"
contains "peers reports the first ownership" "$peers" "$REPO_APP"
contains "peers reports the second ownership" "$peers" "$REPO_LIB"

# Upsert contract: omitting repos must not erase ownership.
post /register --data-urlencode "id=$A" --data-urlencode "node=node-a" \
  --data-urlencode "agent=dsh" --data-urlencode "harness=DeepSeek Harness" >/dev/null
contains "re-registering without repos preserves ownership" "$(get /peers)" "$REPO_APP"

# ---------------------------------------------------------------------------
# 4. Routing by repo key
# ---------------------------------------------------------------------------
subj="probe $RUN"
sent="$(post /message --data-urlencode "from=$A" --data-urlencode "repo=$REPO_LIB" \
  --data-urlencode "subject=$subj" --data-urlencode "body=first message for $RUN")"
contains "saying by repo key posts" "$sent" "ok posted"
contains "the repo key is echoed" "$sent" "repo: $REPO_LIB"
contains "the declared owner is resolved from the repo key" "$sent" "delivered_to: $B"

MID="$(field "$sent" message)"
TID="$(field "$sent" thread)"
if [ -n "$MID" ] && [ -n "$TID" ]; then
  ok "the send response carries message and thread ids"
else
  no "the send response carries message and thread ids" "message=[$MID] thread=[$TID]"
fi

inbox_b="$(get /inbox "id=$B")"
contains "the owner sees the message" "$inbox_b" "$subj"
contains "the owner sees who sent it" "$inbox_b" "from: $A"
contains "the message is marked UNREAD" "$inbox_b" "UNREAD"
lacks "the sender is never its own recipient" "$(get /inbox "id=$A")" "$subj"

contains "an unowned repo is reported, not silently dropped" \
  "$(post /message --data-urlencode "from=$A" --data-urlencode "repo=$REPO_NONE" \
      --data-urlencode "subject=orphan $RUN" --data-urlencode "body=nobody owns this")" \
  "nobody has registered as an owner"

# ---------------------------------------------------------------------------
# 5. Threads, reply routing, inherited repo
# Pins two fixed bugs: a reply resolved to no recipients, and it lost the repo.
# ---------------------------------------------------------------------------
rep="$(post /message --data-urlencode "from=$B" --data-urlencode "thread=$TID" \
  --data-urlencode "body=reply for $RUN")"
contains "a reply posts" "$rep" "ok posted"
contains "a reply reaches the thread participant" "$rep" "delivered_to: $A"
contains "a reply inherits the thread repo when repo is omitted" "$rep" "repo: $REPO_LIB"
equals "a reply stays in the same thread" "$(field "$rep" thread)" "$TID"

th="$(get /thread "id=$TID")"
contains "the thread shows the opener" "$th" "first message for $RUN"
contains "the thread shows the reply" "$th" "reply for $RUN"
contains "the thread names the participants" "$th" "$A"
contains "the thread list finds it by repo" "$(get /threads "repo=$REPO_LIB")" "[$TID]"

# ---------------------------------------------------------------------------
# 6. Read cursors and acknowledgements
# ---------------------------------------------------------------------------
contains "ack by message id" \
  "$(post /ack --data-urlencode "id=$B" --data-urlencode "message=$MID")" "for $B"
lacks "an acked message leaves the unread inbox" "$(get /inbox "id=$B")" "$subj"
contains "an acked message stays in the full inbox" "$(get /inbox "id=$B&all=1")" "$subj"

contains "ack by thread id" \
  "$(post /ack --data-urlencode "id=$A" --data-urlencode "thread=$TID")" "ok acked"
lacks "acking a thread clears it for that participant" "$(get /inbox "id=$A")" "reply for $RUN"
contains "the reply is still there with all=1" "$(get /inbox "id=$A&all=1")" "reply for $RUN"

# ---------------------------------------------------------------------------
# 7. Structured output
# ---------------------------------------------------------------------------
contains "peers supports json=1" "$(get /peers "json=1")" '"id"'
contains "peers json carries the run id" "$(get /peers "json=1")" "$A"
contains "thread supports json=1" "$(get /thread "id=$TID&json=1")" '"thread_id"'
contains "inbox supports json=1" "$(get /inbox "id=$B&all=1&json=1")" '"acked"'

# ---------------------------------------------------------------------------
# 8. Parameter validation
# ---------------------------------------------------------------------------
equals "register without id is 400" "$(status_post /register --data-urlencode "node=x")" "400"
contains "register without id says why" \
  "$(post /register --data-urlencode "node=x")" "error: id required"
equals "message without from is 400" "$(status_post /message --data-urlencode "body=x")" "400"
contains "message without from says why" \
  "$(post /message --data-urlencode "body=x")" "error: from required"
equals "message without body is 400" "$(status_post /message --data-urlencode "from=$A")" "400"
contains "message without body says why" \
  "$(post /message --data-urlencode "from=$A")" "error: body"
equals "inbox without id is 400" "$(code_of /inbox)" "400"
equals "thread without id is 400" "$(code_of /thread)" "400"
equals "ack without message or thread is 400" \
  "$(status_post /ack --data-urlencode "id=$A")" "400"
equals "an unknown thread is 404" "$(code_of /thread "id=999999999")" "404"
contains "an unknown thread says so" "$(get /thread "id=999999999")" "no thread"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%s: %d passed, %d failed\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
