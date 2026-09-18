# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ] && command -v sqlite3 >/dev/null 2>&1; then
  c43port="${CHATBOX_REPLY_PORT:-8798}"
  c43base="http://127.0.0.1:$c43port"
  c43db="$SCRATCH/reply-participants-${RUN}.sqlite"
  c43tok="$SCRATCH/reply-participants-${RUN}.token"
  rm -f "$c43db" "$c43db-wal" "$c43db-shm"
  printf '%s\n' "$TOKEN" > "$c43tok"
  chmod 600 "$c43tok" 2>/dev/null
  "$CHATBOX_BIN" --port "$c43port" --db "$c43db" --token-file "$c43tok" \
    > "$SCRATCH/reply-participants-${RUN}.log" 2>&1 &
  c43pid=$!
  c43ready=0
  for _ in $(seq 1 50); do
    if curl -fsS --max-time 2 "$c43base/health?token=$TOKEN" >/dev/null 2>&1; then c43ready=1; break; fi
    sleep 0.2
  done
  if [ "$c43ready" = 1 ]; then
    c43() { # path, then curl data arguments
      _c43p="$1"; shift
      curl -sS --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" "$c43base/$_c43p" "$@"
    }
    c43_alice="it-$RUN-comma-alice"
    # The stranger's id is the *tail* of the owner's id, so splitting the owner's id yields the
    # stranger exactly - which is the whole defect. The other fragment names no session at all.
    c43_victim="it-$RUN-victim"
    c43_owner="it-$RUN-owner,$c43_victim"
    c43 register --data-urlencode "id=$c43_alice" --data-urlencode "node=node-alice" >/dev/null
    c43 register --data-urlencode "id=$c43_victim" --data-urlencode "node=node-victim" >/dev/null
    # The id with the comma owns a repo, so a repo-routed message reaches it as *one* recipient.
    c43 register --data-urlencode "id=$c43_owner" --data-urlencode "node=node-owner" \
      --data-urlencode "repos=example.test/$RUN/comma" >/dev/null
    c43_first="$(c43 message --data-urlencode "from=$c43_alice" \
      --data-urlencode "repo=example.test/$RUN/comma" --data-urlencode "subject=comma-$RUN" \
      --data-urlencode "body=first-$RUN")"
    c43_tid="$(field "$c43_first" thread)"
    equals "a repo-routed message reaches the id that contains a comma" \
      "$(field "$c43_first" delivered_to)" "$c43_owner"
    c43_reply="$(c43 message --data-urlencode "from=$c43_alice" \
      --data-urlencode "thread=$c43_tid" --data-urlencode "body=reply-$RUN")"
    equals "and a reply answers exactly that participant" \
      "$(field "$c43_reply" delivered_to)" "$c43_owner"
    equals "so a fragment of the id is not a recipient" \
      "$(sqlite3 "$c43db" "select count(*) from deliveries where agent='it-$RUN-owner';")" "0"
    equals "and neither is the session that shares its tail" \
      "$(curl -sS --max-time 20 "$c43base/inbox?id=$c43_victim&all=1&token=$TOKEN" | grep -c "reply-$RUN")" "0"
    # ... while the participant really does hold it: the two checks above must not be passing
    # because the reply reached nobody.
    equals "while the participant holds it" \
      "$(curl -sS --max-time 20 "$c43base/inbox?id=$c43_owner&all=1&token=$TOKEN" | grep -c "reply-$RUN")" "1"

    # A participant who is in the conversation only because it was *sent* the message - reached by
    # name, with no repo involved - has no row in `messages.sender`. Its delivery row is the only
    # record that it took part, so a participants query that forgot the delivery half would answer
    # nobody. (The repo-routed case above cannot see that, because the owner is also a repo owner.)
    c43_bob="it-$RUN-comma-bob"
    c43 register --data-urlencode "id=$c43_bob" --data-urlencode "node=node-bob" >/dev/null
    c43_direct="$(c43 message --data-urlencode "from=$c43_alice" --data-urlencode "to=$c43_bob" \
      --data-urlencode "subject=direct-$RUN" --data-urlencode "body=direct-$RUN")"
    c43_dtid="$(field "$c43_direct" thread)"
    c43_dreply="$(c43 message --data-urlencode "from=$c43_alice" \
      --data-urlencode "thread=$c43_dtid" --data-urlencode "body=direct-reply-$RUN")"
    equals "a reply reaches a participant that was only sent the message" \
      "$(field "$c43_dreply" delivered_to)" "$c43_bob"
    equals "and that participant holds it" \
      "$(curl -sS --max-time 20 "$c43base/inbox?id=$c43_bob&all=1&token=$TOKEN" | grep -c "direct-reply-$RUN")" "1"

    # Grow the same conversation to ~30 MB of bodies, written straight into the database. A reply
    # must not read them: the old path materialised the whole thread to collect names - measured at
    # 36 MB of server RSS growth on this fixture - where the participants query grows it by 1 MB.
    # The bound is an order of magnitude either side of those two numbers.
    sqlite3 "$c43db" "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<4000)
      INSERT INTO messages (thread_id,created_at,sender,repo,subject,body,reply_to,recipients,origin)
      SELECT $c43_tid,'2020-01-01T00:00:00Z','$c43_alice','','bulk',printf('%.8000c','x'),0,'$c43_owner','' FROM c;" >/dev/null 2>&1
    c43_rows="$(sqlite3 "$c43db" "select count(*) from messages where thread_id=$c43_tid;")"
    if [ "${c43_rows:-0}" -gt 4000 ]; then
      ok "the reply fixture has a conversation large enough to measure ($c43_rows messages)"
    else
      no "the reply fixture has a conversation large enough to measure" \
         "only ${c43_rows:-0} messages"
    fi
    c43_before="$(ps -o rss= -p "$c43pid" 2>/dev/null | tr -d ' ')"; c43_before="${c43_before:-0}"
    c43_big="$(c43 message --data-urlencode "from=$c43_alice" \
      --data-urlencode "thread=$c43_tid" --data-urlencode "body=big-reply-$RUN")"
    c43_after="$(ps -o rss= -p "$c43pid" 2>/dev/null | tr -d ' ')"; c43_after="${c43_after:-0}"
    contains "a reply into the large conversation still lands" "$c43_big" "ok posted"
    c43_growth=$((c43_after - c43_before))
    if [ "$c43_growth" -lt 10240 ]; then
      ok "and it does not materialise the conversation it answers (${c43_growth}KB for $c43_rows messages)"
    else
      no "and it does not materialise the conversation it answers" \
         "${c43_growth}KB of RSS growth for $c43_rows messages"
    fi
  else
    no "the reply-participants fixture started" "no answer on $c43base"
  fi
  kill "$c43pid" 2>/dev/null
  wait "$c43pid" 2>/dev/null
  # The fixture is ~30 MB; scratch is not a dumping ground.
  rm -f "$c43db" "$c43db-wal" "$c43db-shm" "$c43tok"
else
  printf '  skip  reply participants (needs CHATBOX_BIN and sqlite3)\n'
fi

# ---------------------------------------------------------------------------
# 44. The request log is a record, and a peer cannot write into it
# The line was `chatbox: METHOD PATH -> STATUS`: no time, no peer, no principal, and nothing about the
# ids an action touched. After an incident an operator could not order events, attribute an
# authentication failure, or say which credential was issued or revoked. And because the request
# target was echoed verbatim, a target carrying a bare LF let one request write a line of its own into
# that record - the same bytes reached the 404 body.
# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_SERVER_LOG:-}" ] && [ -f "${CHATBOX_SERVER_LOG:-}" ]; then
  log44="$CHATBOX_SERVER_LOG"
  curl -sS --max-time 20 "$URL/health?token=$TOKEN" >/dev/null
  log44_line="$(tail -n 5 "$log44" | grep 'GET /health -> 200' | tail -n 1)"
  case "$log44_line" in
    "chatbox: "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z*" principal=bootstrap")
      ok "a log line carries a timestamp, the peer, the route and the principal" ;;
    *) no "a log line carries a timestamp, the peer, the route and the principal" \
         "got [$(snip "$log44_line")]" ;;
  esac
  contains "the peer that asked is named" "$log44_line" "127.0.0.1"
  curl -sS --max-time 20 "$URL/health" >/dev/null
  contains "a refused request is attributed to no credential" \
    "$(tail -n 5 "$log44" | grep 'GET /health -> 401' | tail -n 1)" "principal=denied"

  # A scoped credential is named by its machine and its credential id - never its secret.
  log44_issued="$(post /token --data-urlencode "node=node-logprobe" --data-urlencode "namespaces=*")"
  log44_tok="$(field "$log44_issued" secret)"
  log44_id="$(field "$log44_issued" id)"
  if [ -n "$log44_tok" ] && [ -n "$log44_id" ]; then
    scoped_get /health "$log44_tok" >/dev/null
    contains "a scoped request names the machine and the credential" \
      "$(tail -n 5 "$log44" | grep 'GET /health -> 200' | tail -n 1)" \
      "node=node-logprobe token=$log44_id"
    contains "and issuing a credential is an audited action" \
      "$(tail -n 20 "$log44" | grep 'audit credential issued' | tail -n 1)" "id=$log44_id"
    lacks "and the log never contains the secret" "$(tail -n 40 "$log44")" "$log44_tok"
  else
    no "a log-probe credential was issued" "$(snip "$log44_issued")"
  fi

  log44_reg="it-$RUN-log-audit"
  post /register --data-urlencode "id=$log44_reg" --data-urlencode "node=node-log-audit" >/dev/null
  contains "a registration is audited with what was stored" \
    "$(tail -n 10 "$log44" | grep 'audit registered' | tail -n 1)" "id=$log44_reg node=node-log-audit"
  log44_sent="$(post /message --data-urlencode "from=$log44_reg" --data-urlencode "to=$B" \
    --data-urlencode "body=logaudit-$RUN")"
  log44_tid="$(field "$log44_sent" thread)"
  log44_msg="$(tail -n 10 "$log44" | grep 'audit message' | tail -n 1)"
  contains "a stored message is audited with its thread" "$log44_msg" "thread=$log44_tid"
  contains "and its sender and recipient count" "$log44_msg" "from=$log44_reg recipients=1"
  post /token/revoke --data-urlencode "id=$log44_id" >/dev/null
  contains "a revocation is audited" \
    "$(tail -n 10 "$log44" | grep 'audit credential revoked' | tail -n 1)" "id=$log44_id"

  # A request line is not a place for control bytes: one request must not be able to write a line of
  # its own into the record. A bare LF inside the target is what did it; `nc` is how a client sends
  # one at all, because curl encodes it.
  if command -v nc >/dev/null 2>&1; then
    log44_port="$(printf '%s' "$URL" | sed -n 's|.*:\([0-9][0-9]*\)$|\1|p')"
    log44_inj="$(printf 'GET /x\nFORGEDBYCLIENT HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n' \
      | nc -w 2 127.0.0.1 "$log44_port" 2>/dev/null)"
    contains "a request line with a control byte is refused" "$log44_inj" "400"
    lacks "and the refusal does not echo it back" "$log44_inj" "FORGEDBYCLIENT"
    contains "while the log records it flattened onto one line" \
      "$(tail -n 5 "$log44" | grep 'GET /x' | tail -n 1)" "GET /x FORGEDBYCLIENT"
    equals "and the log gains no line of the peer's making" \
      "$(grep -c '^FORGEDBYCLIENT' "$log44")" "0"
  else
    printf '  skip  the log-injection probe (needs nc)\n'
  fi
else
  printf '  skip  the request log (set CHATBOX_SERVER_LOG)\n'
fi

# ---------------------------------------------------------------------------
# 45. Scoped visibility is answered by indexes, not by scanning the board
# "Which conversations does this machine take part in?" is asked by every scoped read - a thread, a
# reply, the conversation list, the registry - and answered from `messages.sender` and
# `deliveries.node`. Neither had an index, so each scoped request scanned both tables: `deliveries`
# is the fastest-growing table on the board, and the cost rose with the board's history on the queue
# every request shares.
# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ] && command -v sqlite3 >/dev/null 2>&1; then
  sc45port="${CHATBOX_SCOPE_INDEX_PORT:-8799}"
  sc45db="$SCRATCH/scope-index-${RUN}.sqlite"
  sc45tok="$SCRATCH/scope-index-${RUN}.token"
  rm -f "$sc45db" "$sc45db-wal" "$sc45db-shm"
  printf '%s\n' "$TOKEN" > "$sc45tok"
  chmod 600 "$sc45tok" 2>/dev/null
  "$CHATBOX_BIN" --port "$sc45port" --db "$sc45db" --token-file "$sc45tok" \
    > "$SCRATCH/scope-index-${RUN}.log" 2>&1 &
  sc45pid=$!
  sc45ready=0
  for _ in $(seq 1 50); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$sc45port/health?token=$TOKEN" >/dev/null 2>&1; then sc45ready=1; break; fi
    sleep 0.2
  done
  if [ "$sc45ready" = 1 ]; then
    # Enough rows that the planner has a reason to prefer an index, written straight into the
    # database: the question is what the plan looks like, not what the API answers.
    sqlite3 "$sc45db" "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<2000)
      INSERT INTO agents (id,node,agent,repos,registered_at,last_seen)
      SELECT 'a-'||i,'node-'||(i%10),'dsh','','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z' FROM c;" >/dev/null 2>&1
    sqlite3 "$sc45db" "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<2000)
      INSERT INTO messages (thread_id,created_at,sender,repo,subject,body,reply_to,recipients,origin)
      SELECT i%100,'2026-01-01T00:00:00Z','a-'||(i%2000),'','s','b',0,'','' FROM c;" >/dev/null 2>&1
    sqlite3 "$sc45db" "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<2000)
      INSERT INTO deliveries (message_id,agent,created_at,acked_at,node)
      SELECT i,'a-'||(i%2000),'2026-01-01T00:00:00Z','','node-'||(i%10) FROM c;" >/dev/null 2>&1

    sc45_part="SELECT 1 FROM messages m WHERE m.thread_id = 7 AND (m.sender IN (SELECT id FROM agents WHERE node='node-3') OR m.id IN (SELECT d.message_id FROM deliveries d WHERE d.node='node-3')) LIMIT 1"
    sc45_plan="$(sqlite3 "$sc45db" "EXPLAIN QUERY PLAN $sc45_part")"
    equals "a scoped participation check does not scan the messages table" \
      "$(printf '%s\n' "$sc45_plan" | grep -c -e 'SCAN m')" "0"
    equals "and does not scan the deliveries table" \
      "$(printf '%s\n' "$sc45_plan" | grep -c -e 'SCAN d')" "0"
    contains "because the delivery's machine is indexed" "$sc45_plan" "idx_del_node"

    sc45_peers="SELECT a.id FROM agents a WHERE a.node = 'node-3' OR a.id IN (SELECT m.sender FROM messages m WHERE m.thread_id IN (SELECT m.thread_id FROM messages m WHERE m.sender IN (SELECT id FROM agents WHERE node = 'node-3') OR m.id IN (SELECT d.message_id FROM deliveries d WHERE d.node = 'node-3'))) OR a.id IN (SELECT d.agent FROM deliveries d WHERE d.message_id IN (SELECT m.id FROM messages m WHERE m.thread_id IN (SELECT m.thread_id FROM messages m WHERE m.sender IN (SELECT id FROM agents WHERE node = 'node-3') OR m.id IN (SELECT d.message_id FROM deliveries d WHERE d.node = 'node-3')))) ORDER BY a.id LIMIT 10"
    sc45_pplan="$(sqlite3 "$sc45db" "EXPLAIN QUERY PLAN $sc45_peers")"
    equals "and the scoped registry listing scans neither table either" \
      "$(printf '%s\n' "$sc45_pplan" | grep -c -e 'SCAN m' -e 'SCAN d')" "0"
    contains "finding a machine's own sessions by index" "$sc45_pplan" "idx_msg_sender"
  else
    no "the scoped-index fixture started" "no answer on $sc45port"
  fi
  kill "$sc45pid" 2>/dev/null
  wait "$sc45pid" 2>/dev/null
  rm -f "$sc45db" "$sc45db-wal" "$sc45db-shm" "$sc45tok"
else
  printf '  skip  the scoped index plans (needs CHATBOX_BIN and sqlite3)\n'
fi

# ---------------------------------------------------------------------------
# 46. A stop is a stop
# `kill -TERM` used to end the process where it stood: a held long poll and an event stream had their
# sockets cut with no answer, a client could not tell "not stored" from "stored but unanswered" (so a
# retry duplicated a report), and the write-ahead log was left for whoever read the file next.
# `kill -HUP` - what logrotate sends by default - killed the board outright.
# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ]; then
  sig46port="${CHATBOX_SIGNAL_PORT:-8790}"
  sig46base="http://127.0.0.1:$sig46port"
  sig46db="$SCRATCH/signal-${RUN}.sqlite"
  sig46tok="$SCRATCH/signal-${RUN}.token"
  sig46log="$SCRATCH/signal-${RUN}.log"
  sig46pid2=""
  rm -f "$sig46db" "$sig46db-wal" "$sig46db-shm"
  printf '%s\n' "$TOKEN" > "$sig46tok"
  chmod 600 "$sig46tok" 2>/dev/null
  "$CHATBOX_BIN" --port "$sig46port" --db "$sig46db" --token-file "$sig46tok" > "$sig46log" 2>&1 &
  sig46pid=$!
  sig46ready=0
  for _ in $(seq 1 50); do
    if curl -fsS --max-time 2 "$sig46base/health?token=$TOKEN" >/dev/null 2>&1; then sig46ready=1; break; fi
    sleep 0.2
  done
  if [ "$sig46ready" = 1 ]; then
    # Something in the write-ahead log, so the checkpoint has something to fold back.
    curl -sS --max-time 10 -G -X POST --data-urlencode "token=$TOKEN" \
      --data-urlencode "id=it-$RUN-sig" --data-urlencode "node=n-sig" "$sig46base/register" >/dev/null
    curl -sS --max-time 10 -G -X POST --data-urlencode "token=$TOKEN" \
      --data-urlencode "from=it-$RUN-sig" --data-urlencode "to=it-$RUN-sig-peer" \
      --data-urlencode "body=sig-$RUN" "$sig46base/message" >/dev/null
    sig46wal="$(wc -c < "$sig46db-wal" 2>/dev/null | tr -d ' ')"
    if [ "${sig46wal:-0}" -gt 0 ]; then
      ok "the stop fixture has a write-ahead log to fold back (${sig46wal} bytes)"
    else
      no "the stop fixture has a write-ahead log to fold back" "wal=${sig46wal:-absent}"
    fi
    # A held long poll and an event stream: the two answers a stop has to end rather than cut.
    ( curl -sS -o "$SCRATCH/signal-poll-${RUN}.txt" -w '%{http_code}' --max-time 20 \
        "$sig46base/inbox?id=it-$RUN-sig&wait=30&token=$TOKEN" > "$SCRATCH/signal-poll-${RUN}.code" 2>/dev/null ) &
    sig46poll=$!
    ( curl -sS -N --max-time 20 "$sig46base/events?max=30&token=$TOKEN" \
        > "$SCRATCH/signal-sse-${RUN}.txt" 2>/dev/null ) &
    sig46sse=$!
    sleep 1
    kill -TERM "$sig46pid" 2>/dev/null
    wait "$sig46pid" 2>/dev/null; sig46rc=$?
    equals "a stop exits cleanly" "$sig46rc" "0"
    contains "and says so in the log" "$(tail -n 5 "$sig46log")" "shutdown:"
    equals "a held long poll is answered rather than cut" "$(cat "$SCRATCH/signal-poll-${RUN}.code")" "503"
    contains "with a line the client can act on" "$(cat "$SCRATCH/signal-poll-${RUN}.txt")" "shutting down"
    equals "and an event stream ends with a bye" "$(grep -c 'event: bye' "$SCRATCH/signal-sse-${RUN}.txt")" "1"
    contains "saying why" "$(cat "$SCRATCH/signal-sse-${RUN}.txt")" '"reason":"shutdown"'
    equals "the write-ahead log is folded back into the database" \
      "$(wc -c < "$sig46db-wal" 2>/dev/null | tr -d ' ')" "0"
    wait "$sig46poll" "$sig46sse" 2>/dev/null

    # The data has to still be there: a checkpoint that lost a committed write would be worse than
    # leaving the log.
    "$CHATBOX_BIN" --port "$sig46port" --db "$sig46db" --token-file "$sig46tok" > "$sig46log.2" 2>&1 &
    sig46pid2=$!
    sig46ready2=0
    for _ in $(seq 1 50); do
      if curl -fsS --max-time 2 "$sig46base/health?token=$TOKEN" >/dev/null 2>&1; then sig46ready2=1; break; fi
      sleep 0.2
    done
    if [ "$sig46ready2" = 1 ]; then
      equals "and a restarted board still has the message" \
        "$(curl -sS --max-time 10 "$sig46base/inbox?id=it-$RUN-sig-peer&all=1&token=$TOKEN" | grep -c "sig-$RUN")" "1"
      kill -HUP "$sig46pid2" 2>/dev/null
      sleep 1
      if kill -0 "$sig46pid2" 2>/dev/null; then
        ok "a log-rotation signal does not take the board down"
      else
        no "a log-rotation signal does not take the board down" "the process died on SIGHUP"
      fi
      equals "and the board still answers" \
        "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$sig46base/health?token=$TOKEN")" "200"
      kill -TERM "$sig46pid2" 2>/dev/null
      wait "$sig46pid2" 2>/dev/null
    else
      no "the board restarted on the folded database" "no answer on $sig46base"
    fi
  else
    no "the stop fixture started" "no answer on $sig46base"
  fi
  kill "$sig46pid" "$sig46pid2" 2>/dev/null
  wait "$sig46pid" "$sig46pid2" 2>/dev/null
  rm -f "$sig46db" "$sig46db-wal" "$sig46db-shm" "$sig46tok" "$sig46log" "$sig46log.2" \
        "$SCRATCH/signal-poll-${RUN}.txt" "$SCRATCH/signal-poll-${RUN}.code" "$SCRATCH/signal-sse-${RUN}.txt"
else
  printf '  skip  the stop path (needs CHATBOX_BIN)\n'
fi

# ---------------------------------------------------------------------------
# 47. A read that failed is not an empty answer
# `rows()` stepped the statement and returned whatever it had collected, so a read that failed
# part-way answered "no such thread", "inbox empty" or "pruned: 0" — a truncated view presented as
# the truth, with the SQLite error only in the log. The failure is now recorded: a GET whose read
# failed answers 500, a held poll answers 500, a send whose recipient read failed writes nothing, and
# a prune whose read failed rolls back.
#
# The injection is a SQLite **view** over the real table whose column expression raises (SQLite's
# `abs()` overflows on the most negative integer). A view cannot be inserted into, so this exercises
# reads only — which is exactly what the finding is about, and why no write happens after one is
# installed.
# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ] && command -v sqlite3 >/dev/null 2>&1; then
  rf47port="${CHATBOX_READFAIL_PORT:-8779}"
  rf47base="http://127.0.0.1:$rf47port"
  rf47db="$SCRATCH/readfail-${RUN}.sqlite"
  rf47tok="$SCRATCH/readfail-${RUN}.token"
  rf47a="it-$RUN-rf-a"
  rf47b="it-$RUN-rf-b"
  rf47owner="it-$RUN-rf-owner"
  rm -f "$rf47db" "$rf47db-wal" "$rf47db-shm"
  printf '%s\n' "$TOKEN" > "$rf47tok"
  chmod 600 "$rf47tok" 2>/dev/null
  "$CHATBOX_BIN" --port "$rf47port" --db "$rf47db" --token-file "$rf47tok" \
    > "$SCRATCH/readfail-${RUN}.log" 2>&1 &
  rf47pid=$!
  rf47ready=0
  for _ in $(seq 1 50); do
    if curl -fsS --max-time 2 "$rf47base/health?token=$TOKEN" >/dev/null 2>&1; then rf47ready=1; break; fi
    sleep 0.2
  done
  if [ "$rf47ready" = 1 ]; then
    rf47() { _rfp="$1"; shift; curl -sS --max-time 10 -G -X POST --data-urlencode "token=$TOKEN" "$rf47base/$_rfp" "$@"; }
    for _id in "$rf47a" "$rf47b"; do
      rf47 register --data-urlencode "id=$_id" --data-urlencode "node=n-rf" >/dev/null
    done
    rf47sent="$(rf47 message --data-urlencode "from=$rf47a" --data-urlencode "to=$rf47b" \
      --data-urlencode "body=rf-body-$RUN")"
    rf47tid="$(field "$rf47sent" thread)"
    contains "the read-failure fixture has a conversation to read" \
      "$(curl -sS --max-time 10 "$rf47base/thread?id=$rf47tid&token=$TOKEN")" "rf-body-$RUN"

    # Make `messages.body` unreadable: every query that selects it fails, while the table's other
    # columns are still there.
    sqlite3 "$rf47db" "ALTER TABLE messages RENAME TO messages_real;
      CREATE VIEW messages AS SELECT id, thread_id, created_at, sender, repo, subject, abs(-9223372036854775808) AS body, reply_to, recipients, origin FROM messages_real;" >/dev/null 2>&1
    rf47_thread="$(curl -sS --max-time 10 "$rf47base/thread?id=$rf47tid&token=$TOKEN")"
    equals "a thread whose read failed is an error, not an empty thread" \
      "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$rf47base/thread?id=$rf47tid&token=$TOKEN")" "500"
    contains "and the error names the store" "$rf47_thread" "could not be read"
    equals "an inbox whose read failed is an error, not an empty inbox" \
      "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$rf47base/inbox?id=$rf47b&all=1&token=$TOKEN")" "500"
    sqlite3 "$rf47db" "DROP VIEW messages; ALTER TABLE messages_real RENAME TO messages;" >/dev/null 2>&1
    contains "and the same read works again once the store is readable" \
      "$(curl -sS --max-time 10 "$rf47base/thread?id=$rf47tid&token=$TOKEN")" "rf-body-$RUN"

    # A send whose *recipient* read failed must not store mail nobody can be told about.
    rf47 register --data-urlencode "id=$rf47owner" --data-urlencode "node=n-rf" \
      --data-urlencode "repos=example.test/$RUN/rf" >/dev/null
    sqlite3 "$rf47db" "ALTER TABLE agents RENAME TO agents_real;
      CREATE VIEW agents AS SELECT id, node, agent, harness, session, ip, abs(-9223372036854775808) AS repos, note, registered_at, last_seen FROM agents_real;" >/dev/null 2>&1
    rf47_send="$(rf47 message --data-urlencode "from=$rf47a" \
      --data-urlencode "repo=example.test/$RUN/rf" --data-urlencode "body=rf-unresolved-$RUN")"
    contains "a send whose recipients could not be read says so" "$rf47_send" "recipients could not be resolved"
    sqlite3 "$rf47db" "DROP VIEW agents; ALTER TABLE agents_real RENAME TO agents;" >/dev/null 2>&1
    equals "and stores nothing" \
      "$(sqlite3 "$rf47db" "select count(*) from messages where body='rf-unresolved-$RUN';")" "0"
    contains "while a send works again once the store is readable" \
      "$(rf47 message --data-urlencode "from=$rf47a" --data-urlencode "repo=example.test/$RUN/rf" \
         --data-urlencode "body=rf-resolved-$RUN")" "ok posted"
  else
    no "the read-failure fixture started" "no answer on $rf47base"
  fi
  kill "$rf47pid" 2>/dev/null
  wait "$rf47pid" 2>/dev/null

  # The operator mode reads too, and a partial candidate list is not a prune.
  sqlite3 "$rf47db" "ALTER TABLE messages RENAME TO messages_real;
    CREATE VIEW messages AS SELECT abs(-9223372036854775808) AS id, thread_id, created_at, sender, repo, subject, body, reply_to, recipients, origin FROM messages_real;" >/dev/null 2>&1
  rf47_prune="$("$CHATBOX_BIN" --db "$rf47db" --prune 0 2>&1)"; rf47_prc=$?
  if [ "$rf47_prc" -ne 0 ] && printf '%s' "$rf47_prune" | grep -q "rolled back"; then
    ok "a prune whose read failed rolls back and says so"
  else
    no "a prune whose read failed rolls back and says so" \
       "exit=$rf47_prc: $(printf '%s' "$rf47_prune" | head -1)"
  fi
  sqlite3 "$rf47db" "DROP VIEW messages; ALTER TABLE messages_real RENAME TO messages;" >/dev/null 2>&1
  equals "and the message it could not see is still there" \
    "$(sqlite3 "$rf47db" "select count(*) from messages where body='rf-body-$RUN';")" "1"
  rm -f "$rf47db" "$rf47db-wal" "$rf47db-shm" "$rf47tok"
else
  printf '  skip  the read-failure answers (needs CHATBOX_BIN and sqlite3)\n'
fi

# ---------------------------------------------------------------------------
# 48. A flag means what it says
# Every parameter was "on" for any non-empty value, so `all=0` answered with the messages the caller
# had already read and `json=0` answered JSON - each one the opposite of what was written. Nine call
# sites shared that reading, and `ack` is where it did real damage: it tests `all` before `thread`,
# so `ack?all=0&thread=N` - a caller asking for one conversation - marked the whole inbox read.
# ---------------------------------------------------------------------------
