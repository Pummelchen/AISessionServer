# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ] && command -v sqlite3 >/dev/null 2>&1; then
  st55port="${CHATBOX_STORE_PORT:-8775}"
  st55db="$SCRATCH/store-${RUN}.sqlite"
  st55tok="$SCRATCH/store-${RUN}.token"
  rm -f "$st55db" "$st55db-wal" "$st55db-shm"
  printf '%s\n' "$TOKEN" > "$st55tok"
  chmod 600 "$st55tok" 2>/dev/null
  # A real board first, so the file has the tables the migration reads.
  "$CHATBOX_BIN" --port "$st55port" --db "$st55db" --token-file "$st55tok" \
    > "$SCRATCH/store-${RUN}.first.log" 2>&1 &
  st55pid=$!
  for _ in $(seq 1 50); do
    if kill -0 "$st55pid" 2>/dev/null \
       && curl -fsS "http://127.0.0.1:$st55port/health?token=$TOKEN" >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
  kill "$st55pid" 2>/dev/null; wait "$st55pid" 2>/dev/null
  # Hold the write lock for longer than the board's 5 s busy timeout, then start it.
  ( printf 'BEGIN IMMEDIATE;\nUPDATE agents SET node = node;\n'; sleep 14 ) | sqlite3 "$st55db" >/dev/null 2>&1 &
  st55lock=$!
  sleep 0.5
  "$CHATBOX_BIN" --port "$st55port" --db "$st55db" --token-file "$st55tok" \
    > "$SCRATCH/store-${RUN}.log" 2>&1 &
  st55srv=$!
  for _ in $(seq 1 250); do
    kill -0 "$st55srv" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$st55srv" 2>/dev/null; then
    no "a board that cannot take the write lock does not start" "it was still running after 25s"
    kill "$st55srv" 2>/dev/null
  else
    wait "$st55srv" 2>/dev/null; st55rc=$?
    equals "a board that cannot take the write lock does not start" "$st55rc" "1"
  fi
  kill "$st55lock" 2>/dev/null; wait "$st55lock" 2>/dev/null
  contains "and the log says the store was locked" "$(cat "$SCRATCH/store-${RUN}.log")" "database is locked"
  contains "and names the statement that could not run" "$(cat "$SCRATCH/store-${RUN}.log")" "in UPDATE deliveries"
  rm -f "$st55db" "$st55db-wal" "$st55db-shm" "$st55tok" "$SCRATCH/store-${RUN}.log" \
        "$SCRATCH/store-${RUN}.first.log"
else
  printf '  skip  the un-preparable store (needs CHATBOX_BIN and sqlite3)\n'
fi

# ---------------------------------------------------------------------------
# This run's scratch is disposable and is removed here.
# Every path above is named with $RUN, so the files this run created can be found by that name.
# tests/.scratch grew without bound before this - 1.9 GB and 123,531 files after a few days of runs,
# of which gitleaks spent 71 s scanning 1.34 GB of TLS fixture key material (task #0013).
# ---------------------------------------------------------------------------
if [ -n "${SCRATCH:-}" ] && [ "$SCRATCH" != "." ]; then
  find "$SCRATCH" -maxdepth 1 -name "*-${RUN}*" -exec rm -rf {} + 2>/dev/null
fi

# ---------------------------------------------------------------------------
# 56. The flags that answer questions answer them
# `--help` and `--version` were refused as unknown flags (`unknown flag '--help' - refusing to start
# rather than ignore it`, exit 2), and the deployment path is rebuild-and-pkill, which can leave the
# old binary serving - so the two ways to ask "what is this, and how do I run it" were both closed.
# They answer now, before anything listens *and before the store is opened*: answering them after the
# store would open the configured database (and, on a board that needed it, tighten the live file's
# mode) just to print a string.
# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ]; then
  # Bounded on purpose: a regression that ignores the flag does not refuse, it *starts a board* on
  # the default port and runs for ever - which is how the first cut of this check hung the suite and
  # left a mutant listening on 8787. Two seconds is generous for a process that only prints a string,
  # and a process still alive at the end of it is a failure with its own code (99).
  q56() { # the question flag -> stdout, with the exit status in $?; 99 means "it did not answer"
    _qout="$SCRATCH/question-${RUN}.out"
    "$CHATBOX_BIN" --db "$SCRATCH/version-${RUN}.sqlite" "$1" > "$_qout" 2>&1 &
    _qp=$!
    _qw=0
    while [ "$_qw" -lt 20 ] && kill -0 "$_qp" 2>/dev/null; do
      sleep 0.1
      _qw=$((_qw + 1))
    done
    if kill -0 "$_qp" 2>/dev/null; then
      kill "$_qp" 2>/dev/null
      wait "$_qp" 2>/dev/null
      _qrc=99
    else
      wait "$_qp" 2>/dev/null; _qrc=$?
    fi
    cat "$_qout"
    return "$_qrc"
  }
  # Neither may touch a database: `--db` on the command line is otherwise opened (and created) by the
  # store, which is a side effect an operator asking for a version string must not get.
  rm -f "$SCRATCH/version-${RUN}.sqlite" "$SCRATCH/version-${RUN}.sqlite-wal" "$SCRATCH/version-${RUN}.sqlite-shm"
  ver56="$(q56 --version)"; vrc56=$?
  equals "--version answers with exit 0" "$vrc56" "0"
  contains "and names the build it is" "$ver56" "build:"
  help56="$(q56 --help)"; hrc56=$?
  equals "--help answers with exit 0" "$hrc56" "0"
  contains "and prints the flags" "$help56" "--prune"
  if [ -e "$SCRATCH/version-${RUN}.sqlite" ]; then
    no "and neither opens (or creates) the database they were pointed at" "the file is there"
  else
    ok "and neither opens (or creates) the database they were pointed at"
  fi
  # The running board names the build too, in its banner and in /health: that is where an operator
  # looks after a rollback.
  contains "the board reports its build in /health" "$(get /health)" "build:"
  # The product version is single-sourced in the repository's VERSION file. The expected value is
  # read from that file rather than written again here - a second declaration in a test is a defect
  # (§1.3): every bump would fail a test that is not about the version.
  verfile56="$(dirname "$CLI")/VERSION"
  if [ -f "$verfile56" ]; then
    ver56v="$(tr -d '[:space:]' < "$verfile56")"
    contains "and --version names the released version" "$ver56" "build: $ver56v "
    contains "and /health names the released version" "$(get /health)" "build: $ver56v "
  else
    printf '  skip  the version identity (no VERSION file at the repository root)\n'
  fi
else
  printf '  skip  the question flags (needs CHATBOX_BIN)\n'
fi

# ---------------------------------------------------------------------------
# 57. A peer-chosen value cannot forge a line in a read answer
# The identity fields a session registers (node, agent, harness, session, ip), a message's subject,
# its sender, its recipients and its repo are all peer text, and every one is interpolated into
# answers whose shape *is* lines. A value carrying a line break therefore paints lines of its own
# into a listing an agent reads. `oneLine` is the server's treatment; these checks pin that it is
# applied on every echo, and that it covers a Unicode line separator as well as CR/LF. Every marker
# carries $RUN so a match cannot come from another run's or another section's text.
# ---------------------------------------------------------------------------
m57="z$RUN"
eid57="it-$RUN-echo"
# A U+2028 (LS) is a line separator but not a Cc/Cf control, so the id rule accepts it - the echo is
# what has to neutralise it. It is built with the octal bytes because a literal would be invisible
# and editor-dependent.
rid57="it-$RUN-recip$(printf '\342\200\250')x"
reg57="$(post /register --data-urlencode "id=$eid57" \
  --data-urlencode "node=$(printf 'n%s\nX%s' "$m57" "$m57")" \
  --data-urlencode "agent=$(printf 'a%s\nY%s' "$m57" "$m57")" \
  --data-urlencode "harness=$(printf 'h%s\nZ%s' "$m57" "$m57")" \
  --data-urlencode "session=$(printf 's%s\nW%s' "$m57" "$m57")" \
  --data-urlencode "ip=$(printf '1.2.3.4\nV%s' "$m57")")"
contains "register flattens a newline in the identity it echoes" "$reg57" \
  "node: n$m57 X$m57  agent: a$m57 Y$m57  session: s$m57 W$m57"
contains "and in the ip and harness lines" "$reg57" "ip: 1.2.3.4 V$m57  harness: h$m57 Z$m57"
peers57="$(get /peers)"
contains "peers flattens the registered agent and node" "$peers57" "(a$m57 Y$m57 on n$m57 X$m57)"
contains "peers flattens the ip, session and harness" "$peers57" "ip: 1.2.3.4 V$m57  session: s$m57 W$m57  harness: h$m57 Z$m57"
reg57b="$(post /register --data-urlencode "id=$rid57")"
contains "register flattens a U+2028 in the id it echoes" "$reg57b" "id: it-$RUN-recip x"
msg57="$(post /message --data-urlencode "from=$eid57" --data-urlencode "to=$rid57" --data-urlencode "body=hello")"
contains "delivered_to flattens a U+2028 in a recipient id" "$msg57" "delivered_to: it-$RUN-recip x"
# The subject travels into inbox, thread and threads. It is sent *to* the echoing session so the
# inbox path is exercised too, and its marker is per-run.
subj57="$(printf 's%s\nFORGED%s' "$m57" "$m57")"
send57="$(post /message --data-urlencode "from=$rid57" --data-urlencode "to=$eid57" \
  --data-urlencode "subject=$subj57" --data-urlencode "body=body")"
tid57="$(field "$send57" thread)"
contains "inbox flattens a newline in the subject" "$(get /inbox "id=$eid57")" "subject: s$m57 FORGED$m57"
contains "thread flattens a newline in the subject" "$(get /thread "id=$tid57")" "subject: s$m57 FORGED$m57"
contains "threads flattens a newline in the subject" "$(get /threads)" "s$m57 FORGED$m57"
subj57b="$(printf 'u%s\342\200\250FORGED%s' "$m57" "$m57")"
post /message --data-urlencode "from=$rid57" --data-urlencode "to=$eid57" \
  --data-urlencode "subject=$subj57b" --data-urlencode "body=body" >/dev/null
contains "inbox flattens a U+2028 in the subject" "$(get /inbox "id=$eid57")" "subject: u$m57 FORGED$m57"

# ---------------------------------------------------------------------------
# 58. The inbox listing and the prune reply-clear are answered by indexes
# The long-poll path asks for `agent = ?` ordered by message id every 0.25 s, and `--prune` clears
# `reply_to` once per candidate message. Without an index the first sorts the whole matching backlog
# in a temp b-tree and the second is a full scan of `messages` per pruned row. The plans are read
# from the board the suite has been writing to, so they are the plans a real, populated board gets.
# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_DB:-}" ] && command -v sqlite3 >/dev/null 2>&1 && [ -f "$CHATBOX_DB" ]; then
  inbox58="$(sqlite3 "$CHATBOX_DB" "EXPLAIN QUERY PLAN SELECT m.id AS id FROM deliveries d JOIN messages m ON m.id = d.message_id WHERE d.agent = 'x' AND (d.acked_at IS NULL OR d.acked_at = '') ORDER BY d.message_id DESC LIMIT 200")"
  equals "the inbox listing does not sort its backlog in a temp b-tree" \
    "$(printf '%s\n' "$inbox58" | grep -c 'TEMP B-TREE')" "0"
  contains "because the deliveries are ordered by an index" "$inbox58" "idx_del_inbox"
  reply58="$(sqlite3 "$CHATBOX_DB" "EXPLAIN QUERY PLAN UPDATE messages SET reply_to=0 WHERE reply_to=5")"
  equals "clearing a pruned message's replies does not scan the messages table" \
    "$(printf '%s\n' "$reply58" | grep -c 'SCAN messages')" "0"
  contains "because reply_to is indexed" "$reply58" "idx_msg_reply"
else
  printf '  skip  the inbox/prune index plans (needs CHATBOX_DB and sqlite3)\n'
fi

# ---------------------------------------------------------------------------
# 59. One message cannot fan out past the stated recipient ceiling
# The send path writes one delivery row per recipient, so the list a request may name needs a
# ceiling of its own rather than one implied by the envelope size. The board states it in /health.
# ---------------------------------------------------------------------------
contains "the board reports its recipient ceiling" "$(get /health)" "recipients per message: 500"
big59="$(seq 1 501 | paste -sd, -)"
equals "a send past the recipient ceiling is refused" \
  "$(status_post /message --data-urlencode "from=$A" --data-urlencode "to=$big59" \
      --data-urlencode "body=x")" "400"
contains "and the refusal names the ceiling" \
  "$(post /message --data-urlencode "from=$A" --data-urlencode "to=$big59" \
      --data-urlencode "body=x")" "too many recipients"
# At the ceiling it still works, so the check above is a ceiling and not a blanket refusal. The
# send is to the same session 500 times, deduplicated to one real recipient.
ok59="$(seq 1 500 | paste -sd, -)"
contains "a send exactly at the ceiling is accepted" \
  "$(post /message --data-urlencode "from=$A" --data-urlencode "to=$ok59" \
      --data-urlencode "body=ceiling-$RUN")" "ok posted"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%s: %d passed, %d failed\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0

