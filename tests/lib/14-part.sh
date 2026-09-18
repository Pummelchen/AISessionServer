if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ]; then
  authport="${CHATBOX_AUTH_PORT:-9406}"
  : > "$SCRATCH/auth-empty-${RUN}.token"
  chmod 600 "$SCRATCH/auth-empty-${RUN}.token"
  auth_refuse() { # label, the phrase the refusal must carry, then the token arguments
    _lbl="$1"; _phrase="$2"; shift 2
    "$CHATBOX_BIN" --port "$authport" --db "$SCRATCH/auth-${RUN}.sqlite" "$@" \
      > "$SCRATCH/auth-${RUN}.log" 2>&1 &
    _apid=$!
    _aw=0
    while [ "$_aw" -lt 30 ] && kill -0 "$_apid" 2>/dev/null; do
      sleep 0.1; _aw=$((_aw + 1))
    done
    if kill -0 "$_apid" 2>/dev/null; then
      no "$_lbl" "it started anyway: $(head -1 "$SCRATCH/auth-${RUN}.log")"
      kill "$_apid" 2>/dev/null
    else
      ok "$_lbl"
    fi
    wait "$_apid" 2>/dev/null
    contains "$_lbl — and the refusal names the flag" "$(cat "$SCRATCH/auth-${RUN}.log")" "$_phrase"
  }
  auth_refuse "an empty --token is refused rather than opening the board" \
    "--token was given but is empty" --token ""
  auth_refuse "an empty --token-file is refused rather than opening the board" \
    "--token-file was given but names no file" --token-file ""
  auth_refuse "an empty token file is refused rather than opening the board" \
    "is empty — refusing to start an open board" --token-file "$SCRATCH/auth-empty-${RUN}.token"
  # …and the documented way to ask for an open board still works, or this guard would be a
  # behaviour change rather than a hole closed.
  "$CHATBOX_BIN" --port "$((authport + 1))" --db "$SCRATCH/auth-open-${RUN}.sqlite" --token open \
    > "$SCRATCH/auth-open-${RUN}.log" 2>&1 &
  _opid=$!
  _ow=0
  while [ "$_ow" -lt 40 ]; do
    curl -fsS "http://127.0.0.1:$((authport + 1))/health" >/dev/null 2>&1 && break
    sleep 0.2; _ow=$((_ow + 1))
  done
  equals "a board asked for by name (--token open) still starts" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$((authport + 1))/health")" "200"
  contains "and says it is open in the banner" "$(cat "$SCRATCH/auth-open-${RUN}.log")" "auth: OPEN (no token)"
  kill "$_opid" 2>/dev/null
  wait "$_opid" 2>/dev/null
else
  printf '  skip  the credential-flag refusals (set CHATBOX_BIN to the built server)\n'
fi

# ---------------------------------------------------------------------------
# 35. The client's default is loopback, and only loopback
# CHATBOX_URL used to default to one specific private address, so a shell that exported only
# CHATBOX_TOKEN sent a live bearer token to whoever that address belonged to. The default is now
# 127.0.0.1 - the one address that cannot carry the token to another machine - and every other
# machine names its server in ~/.chatbox. The check runs the client with a *stub* `curl` on PATH that
# records what it was asked to fetch and then fails the way an unreachable server does: the real
# thing must never be aimed at whatever happens to be listening on the production default port.
# ---------------------------------------------------------------------------
if [ -f "$CLI" ]; then
  nourl_dir="$SCRATCH/client-nourl-${RUN}"
  nourl_args="$SCRATCH/client-nourl-args-${RUN}.txt"
  rm -rf "$nourl_dir"; mkdir -p "$nourl_dir"
  cat > "$nourl_dir/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$NOURL_ARGS"
exit 7
STUB
  chmod +x "$nourl_dir/curl"
  : > "$nourl_args"
  nourl_rc=0
  env -u CHATBOX_URL -u CHATBOX_TOKEN -u CHATBOX_CACERT CHATBOX_CONFIG=/nonexistent \
    NOURL_ARGS="$nourl_args" PATH="$nourl_dir:$PATH" \
    sh "$CLI" inbox --id "$A" > "$SCRATCH/client-nourl-${RUN}.log" 2>&1 || nourl_rc=$?
  equals "an unset URL is used, not refused - the client has a default" "$nourl_rc" "7"
  contains "and that default is loopback" "$(cat "$nourl_args")" "http://127.0.0.1:8787/"
  lacks "and never a machine-specific address" "$(cat "$nourl_args")" "100.66.125.48"
  lacks "nor is one written into the client at all" "$(cat "$CLI")" "100.66.125.48"
  nourl_help=0
  env -u CHATBOX_URL -u CHATBOX_TOKEN -u CHATBOX_CACERT CHATBOX_CONFIG=/nonexistent \
    NOURL_ARGS="$nourl_args" PATH="$nourl_dir:$PATH" \
    sh "$CLI" help > "$SCRATCH/client-help-${RUN}.log" 2>&1 || nourl_help=$?
  equals "help still works with no server configured" "$nourl_help" "0"
  contains "and names the server it would use" "$(cat "$SCRATCH/client-help-${RUN}.log")" \
    "http://127.0.0.1:8787"
  rm -rf "$nourl_dir"
else
  printf '  skip  the client URL default (set CHATBOX_CLI or keep chatbox-cli.sh in the tree)\n'
fi

# ---------------------------------------------------------------------------
# 36. GET /ui reuses the caller's credential in the URLs it builds
# The page is opened as /ui?token=… and reuses window.location.search on every request it makes. Two
# of those paths already carry a query ('/threads?json=1', '/thread?id=N'), so a naive join produced
# '/threads?json=1?token=…' — which the server reads as one `json` value and no token, i.e. 401 — and
# the read-only view rendered an empty board on every token-protected server. The join is a pure
# function so it can be tested directly, and the URL it builds is then used against the live server.
# ---------------------------------------------------------------------------
if command -v node >/dev/null 2>&1; then
  ui_fn="$SCRATCH/ui-fn-${RUN}.js"
  curl -sS --max-time 10 "$(url_for /ui)" \
    | sed -n '/const withQuery = /,/search.slice(1) : search);/p' > "$ui_fn"
  if [ -s "$ui_fn" ]; then
    ui_js_out="$(node -e "
      $(cat "$ui_fn")
      const cases = [
        ['/threads?json=1', '?token=tok', '/threads?json=1&token=tok'],
        ['/thread?id=3', '?token=tok', '/thread?id=3&token=tok'],
        ['/threads?json=1', '', '/threads?json=1'],
        ['/peers', '?token=tok', '/peers?token=tok']
      ];
      let bad = 0;
      for (const c of cases) {
        const got = withQuery(c[0], c[1]);
        if (got !== c[2]) { console.log('want ' + c[2] + ' got ' + got); bad++; }
      }
      console.log(bad === 0 ? 'ok' : 'bad');
    " 2>&1)"
    contains "the page joins the credential onto a path that already has a query" "$ui_js_out" "ok"
    ui_built="$(node -e "$(cat "$ui_fn"); console.log(withQuery('/threads?json=1', '?token=$TOKEN'));" 2>/dev/null)"
    equals "and the URL the shipped page builds is accepted by the server" \
      "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$URL$ui_built")" "200"
    lacks "and the page no longer builds the two-'?' form it used to" \
      "$(curl -sS --max-time 10 "$(url_for /ui)")" "fetch(path + query)"
  else
    no "the page serves its query-joining function" "no withQuery in the served page"
  fi
else
  printf '  skip  the page query join (needs node)\n'
fi

# ---------------------------------------------------------------------------
# 38. The wake loop acknowledges exactly the messages it was handed
# Acknowledging "everything unread" marked mail read that the page never held — a page the server
# capped at 200, or a message that arrived while the page was being delivered — and mail marked read
# is never delivered again (`chatbox watch` never shows it, and nothing re-queues it). The inbox now
# says which messages it rendered in a response header, and the loop acknowledges those ids one by
# one. A header is structural: a peer's message body cannot add an id to it.
# ---------------------------------------------------------------------------
if [ -f "$CLI" ]; then
  w38="it-$RUN-wake-ack"
  post /register --data-urlencode "id=$w38" --data-urlencode "node=node-w38" >/dev/null
  for w38n in 1 2 3; do
    post /message --data-urlencode "from=$A" --data-urlencode "to=$w38" \
      --data-urlencode "body=w38-$w38n-$RUN" >/dev/null
  done
  w38hdr="$SCRATCH/wake-hdr-${RUN}.txt"
  w38body="$(curl -sS -D "$w38hdr" --max-time 20 "$(url_for /inbox "id=$w38")")"
  w38ids="$(sed -n 's/^[Xx]-[Cc]hatbox-[Uu]nread-[Ii]ds: *//p' "$w38hdr" | tr -d '\r' | head -n 1)"
  w38page="$(printf '%s' "$w38body" | sed -n 's/^\[\([0-9][0-9]*\)\].*/\1/p' | paste -sd, -)"
  equals "the inbox names the messages it rendered" "$w38ids" "$w38page"
  # Handing a page over is not the same as acknowledging it: the read cursor moves when the reader
  # says so, from the ids in the header. A long poll that acked what it rendered would mark mail read
  # at the instant it was sent, so a page the server had capped would lose everything past the cap
  # without ever showing it. The first check keeps the second from being vacuous: the poll has to have
  # seen unread mail before "it is still unread" means anything.
  equals "a long poll hands the unread page over" \
    "$(curl -sS --max-time 20 "$(url_for /inbox "id=$w38&wait=1")" | grep -cE "w38-[123]-$RUN")" "3"
  equals "and a long poll acknowledges nothing on the server's side" \
    "$(get /inbox "id=$w38" | grep -cE "w38-[123]-$RUN")" "3"
  ( CHATBOX_CONFIG=/nonexistent CHATBOX_URL="$URL" CHATBOX_TOKEN="$TOKEN" \
      sh "$CLI" watch --id "$w38" --once --wait 1 --exec 'sleep 2' \
      > "$SCRATCH/wake-${RUN}.log" 2>&1 ) &
  w38pid=$!
  sleep 1
  post /message --data-urlencode "from=$A" --data-urlencode "to=$w38" \
    --data-urlencode "body=w38-late-$RUN" >/dev/null
  wait "$w38pid" 2>/dev/null
  equals "a message that arrived after the page is still unread" \
    "$(get /inbox "id=$w38" | grep -c "w38-late-$RUN")" "1"
  equals "and the three the page held were acknowledged" \
    "$(get /inbox "id=$w38" | grep -cE "w38-[123]-$RUN")" "0"

  # A consumer that keeps failing must not turn the loop into a busy loop. `--exec` does not imply
  # `--once`, and a failed delivery leaves the message unread, so the next poll returns it
  # immediately: without a delay the failing command is re-run and the server re-polled as fast as
  # the shell can go, for ever. The exec writes one byte per invocation, so the size of that file
  # after a fixed window is a direct count of how often the consumer ran. The upper bound is what
  # the fix pins; the lower bound keeps the check from passing when the fixture never fails (a
  # consumer that succeeded would be acknowledged and never run again).
  b24id="it-$RUN-wake-backoff"
  b24count="$SCRATCH/backoff-${RUN}.count"
  b24cmd="$SCRATCH/backoff-${RUN}.sh"
  b24log="$SCRATCH/backoff-${RUN}.log"
  rm -f "$b24count" "$b24cmd"
  post /register --data-urlencode "id=$b24id" --data-urlencode "node=node-b24" >/dev/null
  printf '#!/bin/sh\nprintf x >> "%s"\nexit 1\n' "$b24count" > "$b24cmd"
  post /message --data-urlencode "from=$A" --data-urlencode "to=$b24id" \
    --data-urlencode "body=backoff-$RUN" >/dev/null
  # Unlike the `--once` runs above, this one is continuous, so it has to be killed *as the client*:
  # `( ... ) &` makes `$!` the subshell (whether it execs the client is the shell's choice), and an
  # orphaned wake loop would keep polling the board after the check.
  CHATBOX_CONFIG=/nonexistent CHATBOX_URL="$URL" CHATBOX_TOKEN="$TOKEN" \
    sh "$CLI" watch --id "$b24id" --wait 1 --exec "sh '$b24cmd'" > "$b24log" 2>&1 &
  b24pid=$!
  sleep 7
  kill "$b24pid" 2>/dev/null
  wait "$b24pid" 2>/dev/null
  b24runs="$(wc -c < "$b24count" 2>/dev/null | tr -d ' ')"
  b24runs="${b24runs:-0}"
  if [ "$b24runs" -ge 2 ] && [ "$b24runs" -le 8 ]; then
    ok "a failing consumer is retried with a backoff instead of spun"
  else
    no "a failing consumer is retried with a backoff instead of spun" \
       "$b24runs run(s) of the consumer in 7s (expected 2..8; a tight loop runs hundreds)"
  fi
  equals "and the message it never delivered is still unread" \
    "$(get /inbox "id=$b24id" | grep -c "backoff-$RUN")" "1"
else
  printf '  skip  the wake-loop acknowledgement (set CHATBOX_CLI or keep chatbox-cli.sh in the tree)\n'
fi

# ---------------------------------------------------------------------------
# 39. Every timestamp this server writes is ISO-8601 UTC at second precision
# The database compares timestamps as strings, so the *shape* is part of the storage contract: a
# stamp that is not 20 characters, not UTC or not second-precision sorts wrongly against the rows
# already there (staleness, expiry, retention and reply ordering all read those comparisons). The
# formatter behind it was replaced with a Sendable one, and this is what keeps the shape honest.
# ---------------------------------------------------------------------------
case "$(get /health | sed -n 's/^now: //p')" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
    ok "health's timestamp is ISO-8601 UTC at second precision" ;;
  *) no "health's timestamp is ISO-8601 UTC at second precision" \
       "got [$(get /health | sed -n 's/^now: //p')]" ;;
esac
ts_msg="$(post /message --data-urlencode "from=$A" --data-urlencode "to=$B" --data-urlencode "body=stamp-$RUN")"
case "$(field "$ts_msg" at)" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
    ok "and a stored message's timestamp has the same shape" ;;
  *) no "and a stored message's timestamp has the same shape" "got [$(field "$ts_msg" at)]" ;;
esac
# A local-time formatter would still match the shape above, so UTC is pinned where it is observable:
# the staleness fixture backdates a session with `date -u` and the expiry checks compare stored dates
# against `nowISO()`. Both are already in the suite and fail on a shifted clock.

# ---------------------------------------------------------------------------
# 40. The usage text names the board you are actually talking to
# The public URL used to be a mutable global assigned after the server object was built; it started
# as a hardcoded default, so anything that answered usage before the assignment (or a refactor that
# dropped it) advertised a port nobody was listening on. It is configuration now, and the port in the
# usage text is the port this board serves.
# ---------------------------------------------------------------------------
port40="$(printf '%s' "$URL" | sed -n 's|.*:\([0-9][0-9]*\)$|\1|p')"
case "$(get /)" in
  *":$port40"*) ok "the usage text names the port this board is serving" ;;
  *) no "the usage text names the port this board is serving" \
       "port $port40 not found in [$(snip "$(get /)")]" ;;
esac

# ---------------------------------------------------------------------------
# 41. /health fails closed when the store cannot be read
# A probe that keys on the status code has to be able to see a board that cannot serve a request.
# `health()` built its answer from `store.scalar(...)`, which logs the SQLite error and returns "";
# a failed count therefore arrived as an empty string, "agents: " was printed into an otherwise
# cheerful `ok chatbox up`, and the answer was 200. A monitor would report a board with no readable
# store as healthy — the one thing a health check exists to prevent. The store is made unreadable
# underneath a running board (its schema is dropped), which is deterministic and does not depend on
# the open path: a `--db` that is not a database at all is already refused at startup.
# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ] && command -v sqlite3 >/dev/null 2>&1; then
  hport="${CHATBOX_HEALTH_PORT:-8796}"
  hbase="http://127.0.0.1:$hport"
  hdb="$SCRATCH/health-${RUN}.sqlite"
  htok="$SCRATCH/health-${RUN}.token"
  rm -f "$hdb" "$hdb-wal" "$hdb-shm"
  printf '%s\n' "$TOKEN" > "$htok"
  chmod 600 "$htok" 2>/dev/null
  "$CHATBOX_BIN" --port "$hport" --db "$hdb" --token-file "$htok" > "$SCRATCH/health-${RUN}.log" 2>&1 &
  hpid=$!
  hready=0
  for _ in $(seq 1 50); do
    if curl -fsS "$hbase/health?token=$TOKEN" >/dev/null 2>&1; then hready=1; break; fi
    sleep 0.2
  done
  if [ "$hready" = 1 ]; then
    equals "a board with a readable store answers 200" \
      "$(curl -sS -o /dev/null -w '%{http_code}' "$hbase/health?token=$TOKEN")" "200"
    # The schema the board is serving is removed under it: every count now fails, and `/peers`,
    # `/threads` and `/message` cannot answer either. The status code is the signal.
    sqlite3 "$hdb" "DROP TABLE agents; DROP TABLE threads; DROP TABLE messages;" 2>/dev/null
    equals "a board whose store cannot be read answers 503, not 200" \
      "$(curl -sS -o /dev/null -w '%{http_code}' "$hbase/health?token=$TOKEN")" "503"
    contains "and the answer names the store's own error" \
      "$(curl -sS "$hbase/health?token=$TOKEN")" "no such table"
    lacks "and does not claim the board is up" \
      "$(curl -sS "$hbase/health?token=$TOKEN")" "ok chatbox up"
    # A store failure is not an authentication failure: without a credential the route is still 401,
    # so the 503 is about the board rather than about the request that asked.
    equals "while an unauthenticated probe is still refused" \
      "$(curl -sS -o /dev/null -w '%{http_code}' "$hbase/health")" "401"
  else
    no "the health fixture server started" "no answer on $hbase"
  fi
  kill "$hpid" 2>/dev/null
  wait "$hpid" 2>/dev/null
else
  printf '  skip  the health failure mode (needs CHATBOX_BIN and sqlite3)\n'
fi

# ---------------------------------------------------------------------------
# 42. A value nobody asked for stops the server
# `--port` and `--stale-after` were the two flags that answered a typo with a default:
# `UInt16(argValue("--port", "8787")) ?? 8787` and `Int(staleAfterRaw) ?? 604800`. A client pointed at
# the port on the command line talked to nothing while an unintended port was open, and a misspelt
# presence window silently became seven days, so sessions that had gone quiet were still reported
# active. Every other bounded flag refuses (`--max-body`, `--idle-timeout`, `--max-connections`,
# `--max-rows`, `--max-hops`); these now do too.
#
# The `--port` cases run in `--prune-dry-run` mode deliberately. The flag is parsed before the mode
# branch, so it is the same code path, but a build with the default restored falls back to **8787** -
# the documented default port - and this check must never be the thing that binds it. Operator mode
# exits without listening, so the fallback is observable (a bad exit code) and harmless.
# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ]; then
  p42port="${CHATBOX_BADFLAG_PORT:-8797}"
  p42db="$SCRATCH/badflag-${RUN}.sqlite"
  p42tok="$SCRATCH/badflag-${RUN}.token"
  rm -f "$p42db" "$p42db-wal" "$p42db-shm"
  printf '%s\n' "$TOKEN" > "$p42tok"
  chmod 600 "$p42tok" 2>/dev/null
  badprune() { # label, the flag the refusal must name, then the arguments
    _lbl="$1"; _flag="$2"; shift 2
    _out="$("$CHATBOX_BIN" --db "$p42db" "$@" 2>&1)"; _rc=$?
    if [ "$_rc" -eq 2 ] && printf '%s' "$_out" | grep -q -- "$_flag"; then
      ok "$_lbl"
    else
      no "$_lbl" "exit=$_rc out=[$(snip "$_out")]"
    fi
  }
  badprune "a port that is not a number is refused" --port --prune-dry-run --port 9000o
  badprune "a port above the range is refused" --port --prune-dry-run --port 70000
  badprune "port 0 (an unnamed port) is refused" --port --prune-dry-run --port 0
  badprune "an empty port is refused" --port --prune-dry-run --port ""

  # The window is refused where it would actually be used: at startup, before anything listens. A
  # server that wrongly accepted the value would hold this port, so the check is bounded.
  badstart() { # label, the flag the refusal must name, then the arguments
    _lbl="$1"; _flag="$2"; shift 2
    "$CHATBOX_BIN" --port "$p42port" --db "$p42db" --token-file "$p42tok" "$@" \
      > "$SCRATCH/badflag-${RUN}.log" 2>&1 &
    _bpid=$!
    _bw=0
    while [ "$_bw" -lt 30 ] && kill -0 "$_bpid" 2>/dev/null; do
      sleep 0.1
      _bw=$((_bw + 1))
    done
    if kill -0 "$_bpid" 2>/dev/null; then
      no "$_lbl" "it started anyway: $(head -1 "$SCRATCH/badflag-${RUN}.log")"
      kill "$_bpid" 2>/dev/null
      wait "$_bpid" 2>/dev/null
    else
      wait "$_bpid" 2>/dev/null; _brc=$?
      if [ "$_brc" -eq 2 ] && grep -q -- "$_flag" "$SCRATCH/badflag-${RUN}.log"; then
        ok "$_lbl"
      else
        no "$_lbl" "exit=$_brc: $(head -1 "$SCRATCH/badflag-${RUN}.log")"
      fi
    fi
  }
  badstart "a presence window that is not a number is refused" --stale-after --stale-after abc
  badstart "and a unit suffix is not a number either" --stale-after --stale-after 7d
  badstart "a negative window is still refused" --stale-after --stale-after -1
  # A window that *is* usable still starts, so the checks above are not passing because every
  # window is refused.
  "$CHATBOX_BIN" --port "$p42port" --db "$p42db" --token-file "$p42tok" --stale-after 6 \
    > "$SCRATCH/badflag-ok-${RUN}.log" 2>&1 &
  p42pid=$!
  p42ready=0
  for _ in $(seq 1 50); do
    if curl -fsS "http://127.0.0.1:$p42port/health?token=$TOKEN" >/dev/null 2>&1; then p42ready=1; break; fi
    sleep 0.2
  done
  if [ "$p42ready" = 1 ]; then
    ok "a usable presence window still starts the board"
  else
    no "a usable presence window still starts the board" "no answer on port $p42port"
  fi
  kill "$p42pid" 2>/dev/null
  wait "$p42pid" 2>/dev/null
else
  printf '  skip  the startup flag refusals (needs CHATBOX_BIN)\n'
fi

# ---------------------------------------------------------------------------
# 43. A reply answers the participants, not a text encoding of them
# `messages.recipients` is a comma-joined string, and a session id may itself contain a comma - any
# credential can register one. The reply path re-split that column to find the participants, so an id
# like `owner,victim` became two recipients: a machine that never took part received a delivery row
# for the conversation, and with it read access to it. The same loop read *every message of the
# thread*, bodies included and with no bound, to collect those names, so a 30 MB conversation cost
# 30 MB of memory on the server's only queue. Participants now come from `deliveries` (one row per
# recipient, no delimiter) and no message content is read.
