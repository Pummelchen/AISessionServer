# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ] && command -v sqlite3 >/dev/null 2>&1; then
  pport="${CHATBOX_PRUNE_PORT:-8795}"
  pdb="$SCRATCH/prune-${RUN}.sqlite"
  ptok="$SCRATCH/prune-${RUN}.token"
  printf '%s\n' "$TOKEN" > "$ptok"
  "$CHATBOX_BIN" --port "$pport" --db "$pdb" --token-file "$ptok" > "$SCRATCH/prune-${RUN}.log" 2>&1 &
  ppid=$!
  pready=0
  for _ in $(seq 1 50); do
    if ! kill -0 "$ppid" 2>/dev/null; then break; fi
    if curl -fsS "http://127.0.0.1:$pport/health?token=$TOKEN" >/dev/null 2>&1; then pready=1; break; fi
    sleep 0.2
  done
  if [ "$pready" = 1 ]; then
    # ${@:2} is a bash/ksh extension: dash answers "Bad substitution", so the suite was not POSIX
    # sh at the three helpers that used it. `shift` is the portable spelling.
    pb() { _pb="$1"; shift; curl -sS --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" \
      "http://127.0.0.1:$pport/$_pb" "$@"; }
    pb register --data-urlencode "id=it-$RUN-pr-a" --data-urlencode "node=node-pr" >/dev/null
    pb register --data-urlencode "id=it-$RUN-pr-b" --data-urlencode "node=node-pr" >/dev/null
    # settled: delivered to a, acked.  unread: delivered to a, never acked.
    # partial: delivered to a and b, only a acks.  unsent: no recipient at all.
    pb message --data-urlencode "from=$A" --data-urlencode "to=it-$RUN-pr-a" --data-urlencode "body=settled-$RUN" >/dev/null
    pb message --data-urlencode "from=$A" --data-urlencode "to=it-$RUN-pr-a" --data-urlencode "body=unread-$RUN" >/dev/null
    pb message --data-urlencode "from=$A" --data-urlencode "to=it-$RUN-pr-a,it-$RUN-pr-b" --data-urlencode "body=partial-$RUN" >/dev/null
    pb message --data-urlencode "from=$A" --data-urlencode "body=unsent-$RUN" >/dev/null
    settled="$(sqlite3 "$pdb" "select id from messages where body='settled-$RUN';")"
    settled_thread="$(sqlite3 "$pdb" "select thread_id from messages where body='settled-$RUN';")"
    partial="$(sqlite3 "$pdb" "select id from messages where body='partial-$RUN';")"
    pb ack --data-urlencode "id=it-$RUN-pr-a" --data-urlencode "message=$settled" >/dev/null
    pb ack --data-urlencode "id=it-$RUN-pr-a" --data-urlencode "message=$partial" >/dev/null
    # Old enough for any sane window.
    sqlite3 "$pdb" "UPDATE messages SET created_at='2020-01-01T00:00:00Z'; UPDATE threads SET created_at='2020-01-01T00:00:00Z', last_at='2020-01-01T00:00:00Z';" >/dev/null 2>&1

    snapdb() { # counts *and* the key columns: a rewrite in place must not slip past
      sqlite3 "$pdb" "select (select count(*) from messages)||'/'||(select count(*) from deliveries)||'/'||(select count(*) from threads)||'|'||(select coalesce(group_concat(repos),'') from agents)||'|'||(select coalesce(group_concat(repo),'') from threads)||'|'||(select coalesce(group_concat(repo),'') from messages);"
    }
    # A dry run writes nothing at all — including the schema work every normal start does. The
    # board is made "legacy" (the column a migration would add is dropped) so that a write would
    # show up as a changed file rather than as a row nobody looks at.
    #
    # The copy is made with SQLite's own `.backup`, not `cp`: the board is live and in WAL mode, so
    # the schema can live entirely in the `-wal` and a `cp` of the main file can yield an empty
    # database. That is exactly what happened — the fixture used to hand the prune a file with no
    # tables at all, the guard below only asked "is `expires_at` absent" (true of a file with no
    # `tokens` table too), and the check passed because the *prune* created the schema it was
    # supposed to be migrating. The guard now also requires the table to exist, so the fixture
    # cannot degrade back into that silently.
    legacy_pdb="$SCRATCH/legacy-${RUN}.sqlite"
    rm -f "$legacy_pdb"*
    sqlite3 "$pdb" ".backup '$legacy_pdb'" >/dev/null 2>&1
    sqlite3 "$legacy_pdb" "CREATE TABLE legacy_tokens AS SELECT id,hash,node,namespaces,note,created_at,last_used,revoked_at FROM tokens; DROP TABLE tokens; ALTER TABLE legacy_tokens RENAME TO tokens;" >/dev/null 2>&1
    if [ -f "$legacy_pdb" ] \
       && [ "$(sqlite3 "$legacy_pdb" "select count(*) from sqlite_master where type='table' and name='tokens';")" = "1" ] \
       && [ "$(sqlite3 "$legacy_pdb" "select count(*) from pragma_table_info('tokens') where name='expires_at';")" = "0" ]; then
      # Compared as *schema and rows*, not as file bytes: the board runs in WAL mode, so a write
      # lands in the -wal and the main file can be byte-identical while the database has changed —
      # which is exactly how the first cut of this check passed a dry run that migrated.
      legacy_schema="$(sqlite3 "$legacy_pdb" ".schema" | cksum)"
      legacy_rows="$(sqlite3 "$legacy_pdb" "select count(*) from messages;")"
      "$CHATBOX_BIN" --db "$legacy_pdb" --prune 365 --prune-dry-run >/dev/null 2>&1
      equals "a dry run leaves the schema alone" "$(sqlite3 "$legacy_pdb" ".schema" | cksum)" "$legacy_schema"
      equals "and the rows alone" "$(sqlite3 "$legacy_pdb" "select count(*) from messages;")" "$legacy_rows"
      "$CHATBOX_BIN" --db "$legacy_pdb" --prune 365 >/dev/null 2>&1
      equals "while a real prune migrates the board it is about to change" \
        "$(sqlite3 "$legacy_pdb" "select count(*) from pragma_table_info('tokens') where name='expires_at';")" "1"
    else
      no "the legacy board for the dry-run check was built" \
         "the copy has no tokens table, or still has the column"
    fi

    # A key written under the old rules, so a migration running under the dry run would show up.
    sqlite3 "$pdb" "UPDATE agents SET repos='git@Example.Test:Acme/Thing.git' WHERE id='it-$RUN-pr-a';" >/dev/null 2>&1
    prunebefore="$(snapdb)"
    # A dry run reports what it would do and does nothing at all.
    dry="$("$CHATBOX_BIN" --db "$pdb" --prune 30 --prune-dry-run 2>&1)"
    contains "a dry run says what it would prune" "$dry" "would prune: 1 message(s), 1 thread(s), 1 delivery(ies)"
    contains "a dry run says nothing was removed" "$dry" "nothing was removed"
    equals "a dry run changes nothing at all, keys included" "$(snapdb)" "$prunebefore"

    if [ -n "$settled_thread" ] && [ "$(sqlite3 "$pdb" "select count(*) from threads where id=$settled_thread;")" = "1" ]; then
      ok "the prune fixture has a thread to lose"
    else
      no "the prune fixture has a thread to lose" "settled message thread [$settled_thread]"
    fi
    real="$("$CHATBOX_BIN" --db "$pdb" --prune 30 2>&1)"
    contains "the prune reports what it removed" "$real" "pruned: 1 message(s), 1 thread(s), 1 delivery(ies)"
    equals "the fully-acknowledged old message is gone" \
      "$(sqlite3 "$pdb" "select count(*) from messages where body='settled-$RUN';")" "0"
    equals "its delivery went with it" \
      "$(sqlite3 "$pdb" "select count(*) from deliveries where message_id=$settled;")" "0"
    # The thread that held it, captured before the prune, so this cannot pass by asking about
    # a thread that never existed.
    equals "the thread it left empty went too" \
      "$(sqlite3 "$pdb" "select count(*) from threads where id=$settled_thread;")" "0"
    # The three that must never go.
    equals "an old unacknowledged message is kept" \
      "$(sqlite3 "$pdb" "select count(*) from messages where body='unread-$RUN';")" "1"
    # And its delivery, which is the row that actually holds the mail.
    equals "the unread delivery is kept too" \
      "$(sqlite3 "$pdb" "select count(*) from deliveries where message_id=(select id from messages where body='unread-$RUN') and acked_at is null;")" "1"
    equals "a partly acknowledged message is kept" \
      "$(sqlite3 "$pdb" "select count(*) from messages where body='partial-$RUN';")" "1"
    equals "a message nobody was sent is kept" \
      "$(sqlite3 "$pdb" "select count(*) from messages where body='unsent-$RUN';")" "1"
    # A window that has not passed yet keeps even the settled one.
    pb message --data-urlencode "from=$A" --data-urlencode "to=it-$RUN-pr-a" --data-urlencode "body=fresh-$RUN" >/dev/null
    fresh="$(sqlite3 "$pdb" "select id from messages where body='fresh-$RUN';")"
    pb ack --data-urlencode "id=it-$RUN-pr-a" --data-urlencode "message=$fresh" >/dev/null
    contains "a message inside the window is kept" \
      "$("$CHATBOX_BIN" --db "$pdb" --prune 3650 2>&1)" \
      "pruned: 0 message(s), 0 thread(s), 0 delivery(ies)"
    # Acknowledge the second half of the partial one, and `0` takes it whatever its age. The
    # assertion is about the rows, not a count: `fresh` is fully acknowledged too, so a correct
    # `--prune 0` may take it as well once a wall-clock second has passed, and an exact count
    # would fail on a slow machine for the right behaviour.
    pb ack --data-urlencode "id=it-$RUN-pr-b" --data-urlencode "message=$partial" >/dev/null
    "$CHATBOX_BIN" --db "$pdb" --prune 0 > "$SCRATCH/prunezero-${RUN}.out" 2>&1
    equals "a window of zero takes the newly acknowledged message" \
      "$(sqlite3 "$pdb" "select count(*) from messages where body='partial-$RUN';")" "0"
    equals "the unacknowledged one survives even that" \
      "$(sqlite3 "$pdb" "select count(*) from messages where body='unread-$RUN';")" "1"
    equals "the never-sent one survives even that" \
      "$(sqlite3 "$pdb" "select count(*) from messages where body='unsent-$RUN';")" "1"

    # A thread holding one candidate and one message that must stay: the thread row carries the
    # repo and subject, so deleting it would lose the thread's identity while the reply remained.
    mixed="$(pb message --data-urlencode "from=$A" --data-urlencode "to=it-$RUN-pr-a" \
      --data-urlencode "subject=mixed-$RUN" --data-urlencode "body=mixed-parent-$RUN")"
    mixed_thread="$(field "$mixed" thread)"
    mixed_id="$(field "$mixed" message)"
    pb message --data-urlencode "from=$A" --data-urlencode "to=it-$RUN-pr-a" \
      --data-urlencode "thread=$mixed_thread" --data-urlencode "reply_to=$mixed_id" \
      --data-urlencode "body=mixed-child-$RUN" >/dev/null
    pb ack --data-urlencode "id=it-$RUN-pr-a" --data-urlencode "message=$mixed_id" >/dev/null
    sqlite3 "$pdb" "UPDATE messages SET created_at='2020-01-01T00:00:00Z' WHERE id=$mixed_id;" >/dev/null 2>&1
    "$CHATBOX_BIN" --db "$pdb" --prune 30 >/dev/null 2>&1
    equals "the candidate in a mixed thread goes" \
      "$(sqlite3 "$pdb" "select count(*) from messages where body='mixed-parent-$RUN';")" "0"
    equals "the thread that still holds a message stays" \
      "$(sqlite3 "$pdb" "select count(*) from threads where id=$mixed_thread;")" "1"
    equals "and the reply no longer points at a message that is gone" \
      "$(sqlite3 "$pdb" "select reply_to from messages where body='mixed-child-$RUN';")" "0"
    equals "no delivery outlives its message" \
      "$(sqlite3 "$pdb" "select count(*) from deliveries d where not exists (select 1 from messages m where m.id=d.message_id);")" "0"

    # A delete that fails must change nothing and say so, rather than reporting counts for work
    # it did not do.
    sqlite3 "$pdb" "CREATE TRIGGER refuse_delete BEFORE DELETE ON deliveries BEGIN SELECT RAISE(ABORT,'blocked'); END;" >/dev/null 2>&1
    pb message --data-urlencode "from=$A" --data-urlencode "to=it-$RUN-pr-a" --data-urlencode "body=blocked-$RUN" >/dev/null
    blocked_id="$(sqlite3 "$pdb" "select id from messages where body='blocked-$RUN';")"
    pb ack --data-urlencode "id=it-$RUN-pr-a" --data-urlencode "message=$blocked_id" >/dev/null
    sqlite3 "$pdb" "UPDATE messages SET created_at='2020-01-01T00:00:00Z' WHERE id=$blocked_id;" >/dev/null 2>&1
    blocked_out="$("$CHATBOX_BIN" --db "$pdb" --prune 30 2>&1)"; blocked_rc=$?
    if [ "$blocked_rc" -ne 0 ] && printf '%s' "$blocked_out" | grep -q 'rolled back'; then
      ok "a prune that cannot delete says so and exits non-zero"
    else
      no "a prune that cannot delete says so and exits non-zero" \
        "exit=$blocked_rc: $(printf '%s' "$blocked_out" | head -1)"
    fi
    equals "and it changed nothing" \
      "$(sqlite3 "$pdb" "select count(*) from messages where body='blocked-$RUN';")" "1"
    sqlite3 "$pdb" "DROP TRIGGER refuse_delete;" >/dev/null 2>&1

    # Not reachable from a session, by design.
    equals "there is no /prune route" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
      -G -X POST --data-urlencode "token=$TOKEN" "http://127.0.0.1:$pport/prune")" "404"
    # The 404 is what every unknown path gets, so the guarantee is structural rather than
    # observational: no HTTP handler deletes. This is the check that would notice one being added.
    equals "and none on GET either" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
      "http://127.0.0.1:$pport/prune?token=$TOKEN")" "404"

    # A flag that is present and unusable is a mistake, not a silent start.
    prune_refuses() { # label, then the arguments
      _lbl="$1"; shift
      "$CHATBOX_BIN" --db "$pdb" --port "$((pport + 1))" "$@" > "$SCRATCH/pruneflag-${RUN}.log" 2>&1 &
      _fpid=$!
      _fw=0
      while [ "$_fw" -lt 30 ] && kill -0 "$_fpid" 2>/dev/null; do sleep 0.1; _fw=$((_fw + 1)); done
      if kill -0 "$_fpid" 2>/dev/null; then
        no "$_lbl" "it started a server instead: $(head -1 "$SCRATCH/pruneflag-${RUN}.log")"
        kill "$_fpid" 2>/dev/null; wait "$_fpid" 2>/dev/null
      else
        wait "$_fpid" 2>/dev/null; _frc=$?
        if [ "$_frc" -eq 2 ] && grep -q -- "--prune" "$SCRATCH/pruneflag-${RUN}.log"; then
          ok "$_lbl"
        else
          no "$_lbl" "exit=$_frc: $(head -1 "$SCRATCH/pruneflag-${RUN}.log")"
        fi
      fi
    }
    prune_refuses "a prune window that is not a number is refused" --prune abc
    # The `=` form is present too: testing only for the bare token let `--prune=` fall through to
    # the listener, so an operator who typed a prune got a running board back.
    prune_refuses "an empty inline prune window is refused" --prune=
    prune_refuses "a window beyond the ceiling is refused" --prune 1000000
    prune_refuses "a window exactly at the ceiling is refused when out of range" --prune 36501
    # Without --db the default is ~/chatbox.sqlite, and pruning the wrong board looks exactly
    # like pruning one with nothing to do.
    prune_refuses_no_db() {
      "$CHATBOX_BIN" --prune 30 --port "$((pport + 1))" > "$SCRATCH/prunenodb-${RUN}.log" 2>&1 &
      _npid=$!
      _nw=0
      while [ "$_nw" -lt 30 ] && kill -0 "$_npid" 2>/dev/null; do sleep 0.1; _nw=$((_nw + 1)); done
      if kill -0 "$_npid" 2>/dev/null; then
        no "a prune with no --db is refused" "it started something"
        kill "$_npid" 2>/dev/null; wait "$_npid" 2>/dev/null
      else
        wait "$_npid" 2>/dev/null; _nrc=$?
        if [ "$_nrc" -eq 2 ] && grep -q -- "--db" "$SCRATCH/prunenodb-${RUN}.log"; then
          ok "a prune with no --db is refused"
        else
          no "a prune with no --db is refused" "exit=$_nrc: $(head -1 "$SCRATCH/prunenodb-${RUN}.log")"
        fi
      fi
    }
    prune_refuses_no_db
    # A boolean flag must not swallow the token after it.
    contains "a boolean flag does not consume the next argument" \
      "$("$CHATBOX_BIN" --db "$pdb" --prune-dry-run --prune 30 2>&1)" "would prune:"
    prune_refuses "a negative prune window is refused" --prune -1
    prune_refuses "a prune with no window is refused" --prune ""
    prune_refuses "a bare --prune is refused" --prune
    prune_refuses "--prune-dry-run without --prune is refused" --prune-dry-run
    prune_refuses "--prune-dry-run with a value is refused" --prune=30 --prune-dry-run=1

    # The file has to exist before anything opens it. `sqlite3_open` *creates* a missing file, so a
    # mistyped --db used to produce a brand-new board and a cheerful "pruned: 0 message(s)", and a
    # dry run left that new board behind in a mode whose whole promise is that it changes nothing.
    missing_db="$SCRATCH/prune-missing-${RUN}.sqlite"
    missing_dry="$SCRATCH/prune-missing-dry-${RUN}.sqlite"
    rm -f "$missing_db" "$missing_db-wal" "$missing_db-shm" "$missing_dry" "$missing_dry-wal" "$missing_dry-shm"
    missing_out="$("$CHATBOX_BIN" --db "$missing_db" --prune 30 2>&1)"; missing_rc=$?
    if [ "$missing_rc" -ne 0 ] && printf '%s' "$missing_out" | grep -q "does not exist"; then
      ok "a prune aimed at a path that does not exist is refused"
    else
      no "a prune aimed at a path that does not exist is refused" \
         "exit=$missing_rc: $(printf '%s' "$missing_out" | head -1)"
    fi
    equals "and it does not create the board it was aimed at" \
      "$([ -e "$missing_db" ] && echo created || echo absent)" "absent"
    dry_missing_out="$("$CHATBOX_BIN" --db "$missing_dry" --prune 30 --prune-dry-run 2>&1)"; dry_missing_rc=$?
    if [ "$dry_missing_rc" -ne 0 ] && printf '%s' "$dry_missing_out" | grep -q "does not exist"; then
      ok "and so is a dry run, which used to leave a new board behind"
    else
      no "and so is a dry run, which used to leave a new board behind" \
         "exit=$dry_missing_rc: $(printf '%s' "$dry_missing_out" | head -1)"
    fi
    equals "and the dry run creates nothing either" \
      "$([ -e "$missing_dry" ] && echo created || echo absent)" "absent"

    # A file that exists but is not a board is refused rather than "pruned" to nothing.
    garbage_db="$SCRATCH/prune-garbage-${RUN}.sqlite"
    printf 'not a database\n' > "$garbage_db"
    garbage_before="$(cksum "$garbage_db" | awk '{print $1" "$2}')"
    garbage_out="$("$CHATBOX_BIN" --db "$garbage_db" --prune 30 2>&1)"; garbage_rc=$?
    if [ "$garbage_rc" -ne 0 ] && printf '%s' "$garbage_out" | grep -q "not a usable board"; then
      ok "a prune aimed at a file that is not a board is refused"
    else
      no "a prune aimed at a file that is not a board is refused" \
         "exit=$garbage_rc: $(printf '%s' "$garbage_out" | head -1)"
    fi
    equals "and that file is left exactly as it was" \
      "$(cksum "$garbage_db" | awk '{print $1" "$2}')" "$garbage_before"

    # A dry run must not convert the board it is reading. A read-write open runs
    # `PRAGMA journal_mode=WAL`, so a rollback-journal board would come back as a WAL board with a
    # `-wal` beside it — a mode changing the file it was only supposed to read. The mode, the bytes
    # and the file list are all asserted, because any one of them alone can miss it.
    rollback_db="$SCRATCH/prune-rollback-${RUN}.sqlite"
    rm -f "$rollback_db"*
    sqlite3 "$pdb" ".backup '$rollback_db'" >/dev/null 2>&1
    sqlite3 "$rollback_db" "PRAGMA journal_mode=DELETE;" >/dev/null 2>&1
    # The setup itself leaves a `-shm` behind; the file list has to start clean, or this would
    # measure the fixture rather than the dry run.
    rm -f "$rollback_db"-*
    roll_before="$(cksum "$rollback_db" | awk '{print $1" "$2}')"
    "$CHATBOX_BIN" --db "$rollback_db" --prune 0 --prune-dry-run >/dev/null 2>&1
    roll_after="$(cksum "$rollback_db" | awk '{print $1" "$2}')"
    roll_sidecars=0
    for roll_f in "$rollback_db"-*; do [ -e "$roll_f" ] && roll_sidecars=$((roll_sidecars + 1)); done
    roll_mode="$(sqlite3 "$rollback_db" "PRAGMA journal_mode;" 2>/dev/null)"
    equals "a dry run does not convert the journal mode of the board it reads" "$roll_mode" "delete"
    equals "and leaves it byte-identical" "$roll_after" "$roll_before"
    equals "and leaves no sidecar file beside it" "$roll_sidecars" "0"

    # Two operator modes at once: each runs and exits, so the second was silently dropped.
    # `--backup x --prune 30` copied the board, exited 0 and never pruned, and exit 0 said both had
    # happened.
    conflict_backup="$SCRATCH/prune-conflict-${RUN}.sqlite"
    rm -f "$conflict_backup"
    conflict_out="$("$CHATBOX_BIN" --db "$pdb" --backup "$conflict_backup" --prune 30 2>&1)"; conflict_rc=$?
    if [ "$conflict_rc" -eq 2 ] && printf '%s' "$conflict_out" | grep -q "one operator mode"; then
      ok "two operator modes at once are refused"
    else
      no "two operator modes at once are refused" "exit=$conflict_rc: $(printf '%s' "$conflict_out" | head -1)"
    fi
    equals "and neither of them ran" \
      "$([ -e "$conflict_backup" ] && echo ran || echo neither)" "neither"

    # Flags are validated before a mode acts on them: a bad window used to be ignored by a prune
    # that had already printed success.
    bad_stale_out="$("$CHATBOX_BIN" --db "$pdb" --prune 30 --stale-after abc 2>&1)"; bad_stale_rc=$?
    if [ "$bad_stale_rc" -eq 2 ] && printf '%s' "$bad_stale_out" | grep -q -- "--stale-after"; then
      ok "a bad --stale-after stops a prune rather than being ignored by it"
    else
      no "a bad --stale-after stops a prune rather than being ignored by it" \
         "exit=$bad_stale_rc: $(printf '%s' "$bad_stale_out" | head -1)"
    fi
  else
    no "the prune fixture started a server" "no answer on $pport: $(head -1 "$SCRATCH/prune-${RUN}.log")"
  fi
  kill "$ppid" 2>/dev/null
  wait "$ppid" 2>/dev/null
else
  printf '  skip  retention and pruning (needs CHATBOX_BIN and sqlite3)\n'
fi

# ---------------------------------------------------------------------------
# 19. Registration convenience (TRK-13)
# A registration should be one argument, not five. The client derives the machine's name and
# address from the machine and the agent product from the markers the products set, so
# `chatbox register --repo X` is a complete registration. Every derived value is a *default*: an
# explicit flag wins, and anything that cannot be determined is left empty rather than invented —
# a session id that points at nothing is worse than no session id.
# ---------------------------------------------------------------------------
if [ -f "$CLI" ]; then
  # A checkout to claim, so the verification path runs too.
  rfixture="$SCRATCH/regfixture-${RUN}"
  rm -rf "$rfixture"; mkdir -p "$rfixture"
  git -C "$rfixture" init -q >/dev/null 2>&1
  git -C "$rfixture" remote add origin 'git@github.com:acme/regfixture.git' >/dev/null 2>&1
  # CHATBOX_AGENT makes the derived id deterministic wherever this runs.
  reg_env() { # then the client arguments
    CHATBOX_CONFIG=/nonexistent CHATBOX_URL="$URL" CHATBOX_TOKEN="$TOKEN" CHATBOX_AGENT=probe \
      sh "$CLI" "$@"
  }
  hostshort="$(hostname -s 2>/dev/null || uname -n 2>/dev/null)"
  hostshort="${hostshort%%.*}"

  # The DoD, exactly: one argument.
  bare="$( (cd "$rfixture" && CHATBOX_CONFIG=/nonexistent CHATBOX_URL="$URL" CHATBOX_TOKEN="$TOKEN" \
    CHATBOX_AGENT=probe sh "$CLI" register --repo github.com/acme/regfixture) 2>&1)"
  contains "register with only a repo works" "$bare" "ok registered"
  contains "and derives an id" "$bare" "id: $hostshort-probe"
  contains "and the machine's own name" "$bare" "node: $hostshort"
  contains "and the agent product" "$bare" "agent: probe"
  contains "and claims the repo" "$bare" "repos: github.com/acme/regfixture"
  # Derived, and then *stored*: the registry is where a peer reads it.
  rpeers="$(get /peers)"
  contains "the derived identity is on the board" "$rpeers" "$hostshort-probe"
  contains "with the node it derived" "$rpeers" "probe on $hostshort"
  # An address, when the machine has one. Loopback is not useful to another machine, so the
  # derived value must not be it.
  rbare_ip="$(printf '%s\n' "$bare" | sed -n 's/^ip: \([^ ]*\).*/\1/p')"
  if [ -z "$rbare_ip" ]; then
    printf '  skip  a derived address (this machine has no non-loopback IPv4)\n'
  elif [ "$rbare_ip" = "127.0.0.1" ]; then
    no "a derived address is not loopback" "got $rbare_ip"
  else
    ok "a derived address is not loopback"
  fi

  # Every one of them is a default, not a decision: an explicit flag still wins.
  explicit="$(reg_env register --id chosen --node chosennode --agent chosenagent \
    --session chosensession --ip 10.9.8.7 2>&1)"
  contains "an explicit id wins" "$explicit" "id: chosen"
  contains "an explicit node wins" "$explicit" "node: chosennode"
  contains "an explicit agent wins" "$explicit" "agent: chosenagent"
  contains "an explicit session wins" "$explicit" "session: chosensession"
  contains "an explicit address wins" "$explicit" "ip: 10.9.8.7"

  # The markers the agent products set themselves.
  for marker in "CLAUDECODE=1:claude" "CODEX_HOME=/tmp:codex" "CURSOR_TRACE_ID=x:cursor"; do
    _kv="${marker%%:*}"; _want="${marker#*:}"
    _got="$(env "$_kv" CHATBOX_CONFIG=/nonexistent CHATBOX_URL="$URL" CHATBOX_TOKEN="$TOKEN" \
      sh "$CLI" register --id "m-$_want" --node n 2>&1 | sed -n 's/.*agent: \([^ ]*\).*/\1/p')"
    equals "the $_kv marker is recognised" "$_got" "$_want"
  done
  equals "CHATBOX_AGENT beats the product markers" \
    "$(env CLAUDECODE=1 CHATBOX_AGENT=mine CHATBOX_CONFIG=/nonexistent CHATBOX_URL="$URL" \
        CHATBOX_TOKEN="$TOKEN" sh "$CLI" register --id m-mine --node n 2>&1 | sed -n 's/.*agent: \([^ ]*\).*/\1/p')" \
    "mine"

  # Nothing to go on: the fields are left out rather than guessed. `env -i` clears the DSH_*
  # markers this harness exports, which would otherwise answer for it.
  clean="$(env -i PATH="$PATH" HOME="$HOME" CHATBOX_CONFIG=/nonexistent CHATBOX_URL="$URL" \
    CHATBOX_TOKEN="$TOKEN" sh "$CLI" register --id cleanenv --node n 2>&1)"
  contains "with no markers the agent is left empty, not invented" "$clean" "agent:  "
  # The session is the last field on its line, so this compares the value rather than a
  # substring that an actual session id would also satisfy.
  equals "and so is the session" \
    "$(printf '%s\n' "$clean" | sed -n 's/.*session: //p' | head -1 | sed 's/ *$//')" ""
  # The id is still derived, because the node is still known.
  equals "the id falls back to the node alone when no agent is known" \
    "$(printf '%s\n' "$clean" | sed -n 's/^id: //p')" "cleanenv"

  # The verification the client has always done still applies to a defaulted registration.
  if (cd "$rfixture" && CHATBOX_CONFIG=/nonexistent CHATBOX_URL="$URL" CHATBOX_TOKEN="$TOKEN" \
        CHATBOX_AGENT=probe sh "$CLI" register --repo github.com/other/thing >/dev/null 2>&1); then
    no "a defaulted registration still verifies its claim" "it was accepted"
  else
    ok "a defaulted registration still verifies its claim"
  fi
else
  printf '  skip  registration convenience (needs the client)\n'
fi

# ---------------------------------------------------------------------------
# 20. A reply must name a thread that exists (TRK-19)
# `thread=<id>` used to be taken as the id to write under even when no `threads` row
# carried it: the message was stored, `GET /thread?id=<id>` answered 404 for it, and no
# participant was ever routed to it — mail that looks delivered and can never be read.
# The id is not created on demand either, so a caller cannot squat on a conversation
# number. A refusal must leave *nothing* behind, so the counts and the sender's liveness
# are read either side of it — and a successful post is measured the same way, because
# an instrument that cannot see a write cannot prove the absence of one.
