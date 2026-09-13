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
# the test. Each mutation of chatbox.swift that this suite claims to catch must
# turn it red.

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

bearer_post() { # path, then curl data args -> uses the header, not ?token=
  _p="$1"
  shift
  curl -sS --max-time 20 -G -X POST "$@" -H "Authorization: Bearer $TOKEN" "${URL}${_p}"
}

field() { # response, key -> first matching "key: value"
  printf '%s' "$1" | sed -n "s/^$2: //p" | head -n 1
}

printf 'chatbox protocol tests\n  server: %s\n  run:    %s\n\n' "$URL" "$RUN"

# ---------------------------------------------------------------------------
# 1. Reachability, and the auth mode the rest of the suite depends on
# ---------------------------------------------------------------------------
if ! curl -sS --max-time 20 -o /dev/null "$URL/health" 2>/dev/null; then
  printf 'FATAL: cannot reach %s — start the server first.\n' "$URL" >&2
  exit 2
fi

anon="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/health")"
auth_open=0

if [ "$anon" = "200" ]; then
  # An open board answers /health without a token. That is exactly the state a
  # server lands in when --token-file is unreadable, and it silently disables the
  # auth regression this suite exists to pin — so it is a hard failure unless the
  # caller says they meant it.
  if [ "${CHATBOX_EXPECT_OPEN:-0}" = "1" ]; then
    auth_open=1
    printf 'auth: OPEN — allowed because CHATBOX_EXPECT_OPEN=1\n'
  else
    printf 'FATAL: %s serves /health without a token.\n' "$URL" >&2
    printf 'An open board cannot exercise the auth regression this suite pins.\n' >&2
    printf 'Fix the server (usually an unreadable --token-file), or set CHATBOX_EXPECT_OPEN=1\n' >&2
    printf 'to test an open board deliberately.\n' >&2
    exit 2
  fi
else
  printf 'auth: token required\n'
fi

# Pins the fixed bug: the token in the query string used to be ignored (401).
contains "health via query-string token" "$(get /health)" "ok chatbox up"
contains "health via Authorization: Bearer" \
  "$(curl -sS --max-time 20 -H "Authorization: Bearer $TOKEN" "$URL/health")" "ok chatbox up"
contains "health reports the agent count" "$(get /health)" "agents:"
contains "health reports the message count" "$(get /health)" "messages:"

if [ "$auth_open" = 0 ]; then
  equals "missing token is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/health")" "401"
  contains "missing token explains itself" \
    "$(curl -sS --max-time 20 "$URL/health")" "unauthorized"
  equals "wrong query token is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/health?token=not-the-token")" "401"
  equals "wrong bearer token is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -H 'Authorization: Bearer nope' "$URL/health")" "401"
  equals "a bad token is rejected on another route too" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/peers?token=not-the-token")" "401"
  equals "an unauthenticated write is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$URL/message?from=x&body=y")" "401"
fi

# ---------------------------------------------------------------------------
# 2. Usage, /help, and unknown routes
# The 404 body embeds the usage text, so a status assertion is the only thing
# that distinguishes the real route from the fallback.
# ---------------------------------------------------------------------------
equals "GET / is 200" "$(code_of /)" "200"
contains "GET / teaches the protocol" "$(get /)" "harness-independent session chatbox"
contains "GET / documents register" "$(get /)" "POST /register"
lacks "GET / is not the 404 fallback" "$(get /)" "not found"
equals "GET /help is 200" "$(code_of /help)" "200"
lacks "GET /help is not the 404 fallback" "$(get /help)" "not found"
equals "an unknown route is 404" "$(code_of /no-such-route)" "404"
contains "an unknown route reports not found" "$(get /no-such-route)" "not found"

# ---------------------------------------------------------------------------
# 3. Registration, aliases, and the ownership registry
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

# Upsert contract: supplied fields change, an omitted repos= is preserved.
# Asserting the change matters — otherwise a re-register that silently does
# nothing at all would pass too.
post /register --data-urlencode "id=$A" --data-urlencode "node=node-a-renamed" \
  --data-urlencode "agent=dsh" --data-urlencode "harness=DeepSeek Harness v2" \
  --data-urlencode "note=carries a note" >/dev/null
peers2="$(get /peers)"
peers2_json="$(get /peers "json=1")"
contains "re-registering updates supplied fields" "$peers2" "node-a-renamed"
# Read the stored value from json=1: /peers only prints the harness line when ip
# or session is set, so asserting against the plain-text view would pass or fail
# for a display reason rather than a storage reason.
contains "re-registering updates the harness" "$peers2_json" "DeepSeek Harness v2"
contains "re-registering without repos preserves ownership" "$peers2" "$REPO_APP"
contains "note is stored" "$peers2_json" "carries a note"

# The repo= alias, and a session that declares more than one repo.
post /register --data-urlencode "id=$E" --data-urlencode "node=node-e" \
  --data-urlencode "repo=$REPO_ALIAS" >/dev/null
contains "register accepts repo= as a single-value alias" "$(get /peers)" "$REPO_ALIAS"

post /register --data-urlencode "id=$D" --data-urlencode "node=node-d" \
  --data-urlencode "repos=$REPO_ONE,$REPO_TWO" >/dev/null
peers3="$(get /peers)"
contains "a session may declare several repos (first)" "$peers3" "$REPO_ONE"
contains "a session may declare several repos (second)" "$peers3" "$REPO_TWO"

# ---------------------------------------------------------------------------
# 4. Routing by repo key
# ---------------------------------------------------------------------------
subj="probe $RUN"
sent="$(post /message --data-urlencode "from=$A" --data-urlencode "repo=$REPO_LIB" \
  --data-urlencode "subject=$subj" --data-urlencode "body=first message for $RUN")"
contains "saying by repo key posts" "$sent" "ok posted"
contains "the repo key is echoed" "$sent" "repo: $REPO_LIB"
equals "the declared owner is resolved from the repo key" "$(field "$sent" delivered_to)" "$B"

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
contains "the owner sees the repo it was routed by" "$inbox_b" "repo: $REPO_LIB"
contains "the message is marked UNREAD" "$inbox_b" "UNREAD"

# A message for a repo nobody owns must be stored, reported, and delivered to
# nobody — assert the delivery, not just the note text.
orphan="$(post /message --data-urlencode "from=$A" --data-urlencode "repo=$REPO_NONE" \
  --data-urlencode "subject=orphan $RUN" --data-urlencode "body=nobody owns this")"
contains "an unowned repo is reported" "$orphan" "nobody has registered as an owner"
equals "an unowned repo delivers to nobody" "$(field "$orphan" delivered_to)" "(nobody)"

# The second repo of a multi-repo session.
multi="$(post /message --data-urlencode "from=$A" --data-urlencode "repo=$REPO_TWO" \
  --data-urlencode "subject=multi $RUN" --data-urlencode "body=second repo of a pair")"
equals "routing finds a session by its second declared repo" "$(field "$multi" delivered_to)" "$D"

# A repo declared through the repo= registration alias.
alias_msg="$(post /message --data-urlencode "from=$A" --data-urlencode "repo=$REPO_ALIAS" \
  --data-urlencode "subject=alias $RUN" --data-urlencode "body=registered with repo=")"
equals "a repo registered with repo= routes" "$(field "$alias_msg" delivered_to)" "$E"

# ---------------------------------------------------------------------------
# 5. Threads, reply routing, inherited repo
# Pins two fixed bugs: a reply resolved to no recipients, and it lost the repo.
# ---------------------------------------------------------------------------
rep="$(post /message --data-urlencode "from=$B" --data-urlencode "thread=$TID" \
  --data-urlencode "body=reply for $RUN")"
contains "a reply posts" "$rep" "ok posted"
# Exact set, so a reply that also re-delivers to its own sender is caught.
equals "a reply reaches exactly the other participant" "$(field "$rep" delivered_to)" "$A"
contains "a reply inherits the thread repo when repo is omitted" "$rep" "repo: $REPO_LIB"
equals "a reply stays in the same thread" "$(field "$rep" thread)" "$TID"

th="$(get /thread "id=$TID")"
contains "the thread shows the opener" "$th" "first message for $RUN"
contains "the thread shows the reply" "$th" "reply for $RUN"
contains "the thread names the participants" "$th" "$A"
contains "the thread list finds it by repo" "$(get /threads "repo=$REPO_LIB")" "[$TID]"

# The inherited repo must be persisted on the row, not merely echoed back.
contains "the reply's stored repo is the inherited one" \
  "$(get /inbox "id=$A&all=1")" "repo: $REPO_LIB"

# reply_to is recorded and shown.
rr="$(post /message --data-urlencode "from=$A" --data-urlencode "thread=$TID" \
  --data-urlencode "reply_to=$MID" --data-urlencode "body=quoted reply for $RUN")"
contains "reply_to is accepted" "$rr" "ok posted"
contains "reply_to is shown in the thread view" "$(get /thread "id=$TID")" "(reply to $MID)"

# ---------------------------------------------------------------------------
# 6. The sender is never its own recipient
# A must own the repo it sends to, or the filter is unreachable and this check
# proves nothing. C becomes a second owner of REPO_APP, which A also owns.
# ---------------------------------------------------------------------------
post /register --data-urlencode "id=$C" --data-urlencode "node=node-c" \
  --data-urlencode "agent=codex" --data-urlencode "harness=Codex" \
  --data-urlencode "repos=$REPO_APP" >/dev/null

self_subj="self $RUN"
selfmsg="$(post /message --data-urlencode "from=$A" --data-urlencode "repo=$REPO_APP" \
  --data-urlencode "subject=$self_subj" --data-urlencode "body=sent by an owner of the target repo")"
# Exact set: A and C own REPO_APP, so only C may receive it.
equals "a sender is excluded from its own repo's owners" "$(field "$selfmsg" delivered_to)" "$C"
lacks "the sender has no delivery from its own message" "$(get /inbox "id=$A")" "$self_subj"
lacks "the sender has no delivery even including read" "$(get /inbox "id=$A&all=1")" "$self_subj"
# A *does* hold other deliveries, so the two checks above are not vacuous.
contains "the sender still holds deliveries it should have" "$(get /inbox "id=$A&all=1")" "reply for $RUN"

# ---------------------------------------------------------------------------
# 7. Read cursors and acknowledgements
# ---------------------------------------------------------------------------
# Ack scoping: C was never sent MID, so acking it must not touch B's delivery.
contains "acking a message you were not sent is accepted" \
  "$(post /ack --data-urlencode "id=$C" --data-urlencode "message=$MID")" "for $C"
contains "another session's ack does not clear your inbox" "$(get /inbox "id=$B")" "$subj"

contains "ack by message id" \
  "$(post /ack --data-urlencode "id=$B" --data-urlencode "message=$MID")" "for $B"
lacks "an acked message leaves the unread inbox" "$(get /inbox "id=$B")" "$subj"
contains "an acked message stays in the full inbox" "$(get /inbox "id=$B&all=1")" "$subj"

# Acking B's whole thread must not mark A's delivery of the reply as read.
contains "ack by thread id" \
  "$(post /ack --data-urlencode "id=$B" --data-urlencode "thread=$TID")" "ok acked"
contains "acking a thread does not clear another participant" \
  "$(get /inbox "id=$A")" "reply for $RUN"

contains "ack by thread clears it for that participant" \
  "$(post /ack --data-urlencode "id=$A" --data-urlencode "thread=$TID")" "ok acked"
lacks "the thread is now read for that participant" "$(get /inbox "id=$A")" "reply for $RUN"
contains "the thread is still there with all=1" "$(get /inbox "id=$A&all=1")" "reply for $RUN"

# ---------------------------------------------------------------------------
# 8. Client-facing aliases and request bodies
# ---------------------------------------------------------------------------
direct="$(post /say --data-urlencode "from=$A" --data-urlencode "to=$B" \
  --data-urlencode "subject=direct $RUN" --data-urlencode "body=direct message for $RUN")"
contains "the /say alias posts" "$direct" "ok posted"
equals "an explicit to= recipient is honoured" "$(field "$direct" delivered_to)" "$B"

to_multi="$(post /message --data-urlencode "from=$A" --data-urlencode "to=$B,$C" \
  --data-urlencode "body=two explicit recipients for $RUN")"
equals "to= accepts several comma-separated ids" "$(field "$to_multi" delivered_to)" "$B, $C"

reg_from="$(post /register --data-urlencode "from=$C" --data-urlencode "node=node-c" \
  --data-urlencode "agent=codex" --data-urlencode "repos=$REPO_APP")"
contains "register accepts from= as an id alias" "$reg_from" "id: $C"

contains "inbox accepts for= as an id alias" "$(get /inbox "for=$E")" "inbox for $E"
contains "ack accepts agent= as an id alias" \
  "$(post /ack --data-urlencode "agent=$E" --data-urlencode "message=$MID")" "for $E"

say_id="$(post /message --data-urlencode "id=$A" --data-urlencode "to=$B" \
  --data-urlencode "body=id alias check for $RUN")"
contains "message accepts id= as a from alias" "$say_id" "ok posted"

# Bearer auth on a write, and the documented raw-text body.
bearer="$(bearer_post /message --data-urlencode "from=$A" --data-urlencode "to=$B" \
  --data-urlencode "body=bearer write for $RUN")"
contains "a POST accepts the Authorization header" "$bearer" "ok posted"

raw="$(curl -sS --max-time 20 -X POST -H "Authorization: Bearer $TOKEN" \
  --data "rawbody-$RUN" "${URL}/say?from=$A&to=$B")"
contains "a raw text body is accepted" "$raw" "ok posted"

json_body="$(curl -sS --max-time 20 -X POST -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data "{\"from\":\"$A\",\"to\":\"$B\",\"body\":\"jsonbody-$RUN\"}" "${URL}/message")"
contains "a JSON body is accepted" "$json_body" "ok posted"
contains "the JSON body text is stored" "$(get /inbox "id=$B&all=1")" "jsonbody-$RUN"

# ---------------------------------------------------------------------------
# 9. Structured output
# ---------------------------------------------------------------------------
contains "peers supports json=1" "$(get /peers "json=1")" '"id"'
contains "peers json carries the run id" "$(get /peers "json=1")" "$A"
contains "thread supports json=1" "$(get /thread "id=$TID&json=1")" '"thread_id"'
contains "inbox supports json=1" "$(get /inbox "id=$B&all=1&json=1")" '"acked"'
contains "threads supports json=1" "$(get /threads "repo=$REPO_LIB&json=1")" '"repo"'

# ---------------------------------------------------------------------------
# 10. Parameter validation
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
