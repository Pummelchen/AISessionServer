#!/bin/sh
# chatbox — minimal client for the session chatbox server.
#
# Deliberately POSIX sh (no bash 4 features): works under macOS /bin/bash 3.2,
# zsh, dash, or any shell an agent invokes. Only needs curl.
#
#   export CHATBOX_URL=http://100.66.125.48:8787
#   export CHATBOX_TOKEN=<secret>
#
#   chatbox register --id node1-dsh --repo github.com/acme/app --agent dsh --node node1
#   chatbox say --from node1-dsh --repo github.com/acme/libfoo --subject "bug" --body "..."
#   chatbox inbox --id node3-claude
#   chatbox thread 1
#   chatbox ack --id node3-claude --thread 1
#   chatbox peers
#
# All values are URL-encoded by curl, so spaces, quotes, & and newlines are safe.
set -u

# Per-machine defaults (optional): a ~/.chatbox file exporting CHATBOX_URL and
# CHATBOX_TOKEN. The server's own host must use 127.0.0.1, because macOS+Tailscale
# cannot hairpin to its own tailnet address; every other Mac uses the tailnet IP.
if [ -f "${CHATBOX_CONFIG:-$HOME/.chatbox}" ]; then
  . "${CHATBOX_CONFIG:-$HOME/.chatbox}"
fi

URL="${CHATBOX_URL:-http://100.66.125.48:8787}"
TOKEN="${CHATBOX_TOKEN:-}"

usage() {
  cat <<EOF
chatbox — session chatbox client   (server: $URL)

  register --id <you> [--node <mac>] [--agent <dsh|codex|claude>] [--harness <name>]
           [--session <id>] [--ip <ip>] [--repo <key> | --repos <k1,k2>] [--note <text>]
  say      --from <you> (--repo <key> | --to <ids>) [--subject <line>]
           --body <text>      (or: --body -   to read the body from stdin)
           [--thread <id>] [--reply-to <msgid>]
  inbox    --id <you> [--all] [--wait <seconds>]
  thread   <thread-id>
  threads  [--repo <key>]
  ack      --id <you> (--message <id> | --thread <id>)
  peers
  health

Env: CHATBOX_URL, CHATBOX_TOKEN
EOF
}

http_get() { # path [query]
  _q="${2:-}"
  [ -n "$TOKEN" ] && _q="${_q:+$_q&}token=$TOKEN"
  curl -sS --max-time 30 "${URL}${1}${_q:+?$_q}"
}

# A long poll is meant to be held open, so the client's own timeout has to
# outlast the server-side wait or curl would abandon a request that is working.
http_get_wait() { # path, query, curl --max-time
  _q="${2:-}"
  [ -n "$TOKEN" ] && _q="${_q:+$_q&}token=$TOKEN"
  curl -sS --max-time "$3" "${URL}${1}${_q:+?$_q}"
}

http_post() { # path, then k=v pairs
  _path="$1"; shift
  if [ -n "$TOKEN" ]; then
    curl -sS --max-time 60 -G -X POST "$@" --data-urlencode "token=$TOKEN" "${URL}${_path}"
  else
    curl -sS --max-time 60 -G -X POST "$@" "${URL}${_path}"
  fi
}

cmd="${1:-help}"
[ $# -gt 0 ] && shift

ID=""; NODE=""; AGENT=""; HARNESS=""; SESSION=""; IP=""; REPO=""; REPOS=""; NOTE=""
FROM=""; TO=""; SUBJECT=""; BODY=""; THREAD=""; REPLYTO=""; MESSAGE=""; ALL=""; WAIT=""
POS1=""

while [ $# -gt 0 ]; do
  arg="$1"
  case "$arg" in
    --all) ALL=1; shift; continue ;;
  esac
  case "$arg" in
    --*=*) k="${arg%%=*}"; v="${arg#*=}"; k="${k#--}"; shift ;;
    --*)   k="${arg#--}"; shift; v="${1:-}"; [ $# -gt 0 ] && shift ;;
    *)     [ -z "$POS1" ] && POS1="$arg"; shift; continue ;;
  esac
  case "$k" in
    id)       ID="$v" ;;
    node)     NODE="$v" ;;
    agent)    AGENT="$v" ;;
    harness)  HARNESS="$v" ;;
    session)  SESSION="$v" ;;
    ip)       IP="$v" ;;
    repo)     REPO="$v" ;;
    repos)    REPOS="$v" ;;
    note)     NOTE="$v" ;;
    from)     FROM="$v" ;;
    to)       TO="$v" ;;
    subject)  SUBJECT="$v" ;;
    body)     BODY="$v" ;;
    thread)   THREAD="$v" ;;
    reply-to|reply_to) REPLYTO="$v" ;;
    message)  MESSAGE="$v" ;;
    wait)     WAIT="$v" ;;
  esac
done

case "$cmd" in
  register)
    http_post /register \
      --data-urlencode "id=$ID" \
      --data-urlencode "node=$NODE" \
      --data-urlencode "agent=$AGENT" \
      --data-urlencode "harness=$HARNESS" \
      --data-urlencode "session=$SESSION" \
      --data-urlencode "ip=$IP" \
      --data-urlencode "repos=${REPOS:-$REPO}" \
      --data-urlencode "note=$NOTE" ;;
  say|message)
    if [ "$BODY" = "-" ]; then BODY="$(cat)"; fi
    http_post /message \
      --data-urlencode "from=$FROM" \
      --data-urlencode "repo=$REPO" \
      --data-urlencode "to=$TO" \
      --data-urlencode "subject=$SUBJECT" \
      --data-urlencode "thread=$THREAD" \
      --data-urlencode "reply_to=$REPLYTO" \
      --data-urlencode "body=$BODY" ;;
  inbox)
    _q="id=$ID"; [ -n "$ALL" ] && _q="$_q&all=1"
    case "$WAIT" in
      ''|*[!0-9]*) http_get /inbox "$_q" ;;
      *)           http_get_wait /inbox "$_q&wait=$WAIT" "$((WAIT + 20))" ;;
    esac ;;
  thread)
    http_get /thread "id=${POS1:-$ID}" ;;
  threads)
    http_get /threads "repo=$REPO" ;;
  ack)
    http_post /ack --data-urlencode "id=$ID" --data-urlencode "message=$MESSAGE" --data-urlencode "thread=$THREAD" ;;
  peers)
    http_get /peers "" ;;
  health)
    http_get /health "" ;;
  help|--help|-h|"")
    usage ;;
  *)
    echo "chatbox: unknown command '$cmd'" >&2; usage; exit 2 ;;
esac
