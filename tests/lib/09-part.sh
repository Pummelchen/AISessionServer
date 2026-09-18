# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_BIN:-}" ] && command -v sqlite3 >/dev/null 2>&1; then
  bdir="$SCRATCH/backup-${RUN}"
  rm -rf "$bdir"; mkdir -p "$bdir"
  bport="${CHATBOX_BACKUP_PORT:-8796}"
  bdb="$bdir/board.sqlite"
  btok="$bdir/token"
  printf '%s\n' "$TOKEN" > "$btok"
  "$CHATBOX_BIN" --port "$bport" --db "$bdb" --token-file "$btok" > "$bdir/server.log" 2>&1 &
  bpid=$!
  bready=0
  for _ in $(seq 1 50); do
    if ! kill -0 "$bpid" 2>/dev/null; then break; fi
    if curl -fsS "http://127.0.0.1:$bport/health?token=$TOKEN" >/dev/null 2>&1; then bready=1; break; fi
    sleep 0.2
  done
  if [ "$bready" = 1 ]; then
    bk() { _bk="$1"; shift; curl -sS --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" \
      "http://127.0.0.1:$bport/$_bk" "$@"; }
    # A board with something in it, written just now, so its rows are still in the WAL.
    bk register --data-urlencode "id=it-$RUN-bk-a" --data-urlencode "node=node-bk" \
      --data-urlencode "repos=example.test/$RUN/bk" >/dev/null
    bk register --data-urlencode "id=it-$RUN-bk-b" --data-urlencode "node=node-bk" >/dev/null
    bk message --data-urlencode "from=it-$RUN-bk-a" --data-urlencode "to=it-$RUN-bk-b" \
      --data-urlencode "body=backup-$RUN" >/dev/null
    bsig="select (select count(*) from agents)||'/'||(select count(*) from messages)||'/'||(select count(*) from deliveries)"
    bsrc="$(sqlite3 "$bdb" "$bsig;")"
    equals "the backup fixture has rows to copy" "$bsrc" "2/1/1"

    # The incident itself, measured rather than assumed: the main file is still a 4 KB header
    # and the rows are in `-wal`, so a hand copy of it is not a database. If a checkpoint has
    # already folded them in, the fixture did not reproduce the trap and the checks that depend
    # on it say so instead of passing for the wrong reason.
    cp "$bdb" "$bdir/hand.sqlite"
    if sqlite3 "$bdir/hand.sqlite" "select count(*) from messages;" >/dev/null 2>&1; then
      printf '  skip  the hand copy of a live WAL database is empty (this board had checkpointed)\n'
    else
      ok "the hand copy of the live main file is not a database"
      bhand="$("$CHATBOX_BIN" --verify-backup "$bdir/hand.sqlite" 2>&1)"; bhandrc=$?
      equals "and verification refuses it" "$bhandrc" "1"
      contains "and says why" "$bhand" "not a usable board"
    fi

    # A real backup of a live board, verified against the board it came from.
    bout="$("$CHATBOX_BIN" --db "$bdb" --backup "$bdir/good.sqlite" 2>&1)"; brc=$?
    equals "a backup of a live board succeeds" "$brc" "0"
    contains "it names the board it copied" "$bout" "source: $bdb"
    contains "it names the copy" "$bout" "backup: $bdir/good.sqlite"
    contains "and says nothing below the snapshot was lost" "$bout" "(nothing below this was lost)"
    equals "the copy holds the rows that were only in the WAL" \
      "$(sqlite3 "$bdir/good.sqlite" "$bsig;")" "$bsrc"
    contains "verification accepts the copy" \
      "$("$CHATBOX_BIN" --verify-backup "$bdir/good.sqlite" 2>&1)" "backup ok"
    contains "and accepts it against its source" \
      "$("$CHATBOX_BIN" --db "$bdb" --verify-backup "$bdir/good.sqlite" 2>&1)" "compared with: $bdb"

    # A copy *at rest* is still a board and has to verify: a checkpointed file, a restored one and
    # the `sqlite3 .backup` copy Deployment names as the alternative all have their rows in the main
    # file. Verification reads such a file as an immutable snapshot, so it writes no `-shm` beside
    # a backup nobody is using — which is what makes it work on a read-only mount.
    cp "$bdir/good.sqlite" "$bdir/at-rest.sqlite"
    sqlite3 "$bdir/at-rest.sqlite" "PRAGMA journal_mode=WAL; PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
    sqlite3 "$bdir/at-rest.sqlite" ".backup '$bdir/viacli.sqlite'" >/dev/null 2>&1
    # At rest means no sidecar files: that is the state a copy on a shelf or a read-only mount is in.
    rm -f "$bdir/at-rest.sqlite-shm" "$bdir/at-rest.sqlite-wal" "$bdir/viacli.sqlite-shm" "$bdir/viacli.sqlite-wal"
    for bcase in at-rest viacli; do
      bfile="$bdir/$bcase.sqlite"
      bout2="$("$CHATBOX_BIN" --verify-backup "$bfile" 2>&1)"; brc2=$?
      equals "a $bcase copy verifies" "$brc2" "0"
      contains "and the $bcase copy reports its counts" "$bout2" "agents="
      if [ -e "$bfile-shm" ] || [ -e "$bfile-wal" ]; then
        no "verifying the $bcase copy writes nothing beside it" "a sidecar file appeared"
      else
        ok "verifying the $bcase copy writes nothing beside it"
      fi
    done

    # A live board keeps moving while it is copied, and the copy is a *snapshot*: it legitimately
    # holds fewer rows than the board a moment later. The command must not call that a failure —
    # it did, because the comparison re-read the board after the copy, so a backup taken under a
    # writer failed almost every time.
    #
    # The race has to be one the buggy code cannot win, or a green result proves nothing: a fixture
    # of a few rows is copied in microseconds, so the window is too small to hit. The bulk rows make
    # the copy take long enough to be certain, and the board is checked to have grown while the
    # backups ran, so a run where the writers finished first cannot pass quietly.
    sqlite3 "$bdb" "INSERT INTO messages (thread_id,created_at,sender,repo,subject,body,recipients)
      WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<120)
      SELECT 1,'2020-01-01T00:00:00Z','bulk','-','bulk',hex(zeroblob(10000)),'' FROM c;" >/dev/null 2>&1
    bcount0="$(sqlite3 "$bdb" "select count(*) from messages;")"
    (
      i=0
      while [ "$i" -lt 4000 ]; do
        bk message --data-urlencode "from=it-$RUN-bk-a" --data-urlencode "to=it-$RUN-bk-b" \
          --data-urlencode "body=race-a-$RUN-$i" >/dev/null 2>&1
        i=$((i + 1))
      done
    ) &
    bw_a=$!
    (
      i=0
      while [ "$i" -lt 4000 ]; do
        bk message --data-urlencode "from=it-$RUN-bk-a" --data-urlencode "to=it-$RUN-bk-b" \
          --data-urlencode "body=race-b-$RUN-$i" >/dev/null 2>&1
        i=$((i + 1))
      done
    ) &
    bw_b=$!
    bslow=0
    for n in 1 2 3 4 5 6; do
      "$CHATBOX_BIN" --db "$bdb" --backup "$bdir/race-$n.sqlite" >/dev/null 2>&1 || bslow=$((bslow + 1))
    done
    kill "$bw_a" "$bw_b" 2>/dev/null
    wait "$bw_a" "$bw_b" 2>/dev/null
    bcount1="$(sqlite3 "$bdb" "select count(*) from messages;")"
    equals "six backups under a writer all succeed" "$bslow" "0"
    if [ "${bcount1:-0}" -gt "${bcount0:-0}" ]; then
      ok "and the board was still growing while they ran"
    else
      no "and the board was still growing while they ran" "it stayed at ${bcount0:-?}"
    fi
    rm -f "$bdir"/race-*.sqlite

    # The copy is never silently replaced: overwriting yesterday's only good backup is worse than
    # an error message.
    bagain="$("$CHATBOX_BIN" --db "$bdb" --backup "$bdir/good.sqlite" 2>&1)"; bagainrc=$?
    if [ "$bagainrc" -ne 0 ]; then
      ok "an existing backup is not overwritten"
    else
      no "an existing backup is not overwritten" "it exited 0: $(snip "$bagain")"
    fi
    contains "and the refusal says why" "$bagain" "already exists"

    # A store that *refuses* the insert is not a missing thread. The two are told apart by the
    # statement's own result code, and answering "no such thread" for a locked or blocked store
    # would send the sender off to open a duplicate thread. A trigger that aborts one insert makes
    # that refusal deterministic.
    bthread2="$(bk message --data-urlencode "from=it-$RUN-bk-a" --data-urlencode "to=it-$RUN-bk-b" \
      --data-urlencode "subject=blocked-$RUN" --data-urlencode "body=blocked-$RUN" | sed -n 's/^thread: //p')"
    if [ -n "$bthread2" ]; then
      ok "the blocked-insert fixture opened a thread"
    else
      no "the blocked-insert fixture opened a thread" "no thread id came back"
    fi
    sqlite3 "$bdb" "CREATE TRIGGER IF NOT EXISTS block_insert BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT,'blocked by the suite'); END;" >/dev/null 2>&1
    blocked_status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -G -X POST \
      --data-urlencode "token=$TOKEN" --data-urlencode "from=it-$RUN-bk-a" \
      --data-urlencode "thread=$bthread2" --data-urlencode "body=must not store" "http://127.0.0.1:$bport/message")"
    equals "a store that refuses the insert is a 500, not a missing thread" "$blocked_status" "500"
    equals "and nothing was written by it" \
      "$(sqlite3 "$bdb" "select count(*) from messages where body='must not store';")" "0"
    # And the thread is still there, so the advice would have been wrong as well.
    equals "the thread it named still exists" \
      "$(sqlite3 "$bdb" "select count(*) from threads where id=$bthread2;")" "1"
    sqlite3 "$bdb" "DROP TRIGGER IF EXISTS block_insert;" >/dev/null 2>&1
    bafter_block="$(bk message --data-urlencode "from=it-$RUN-bk-a" --data-urlencode "thread=$bthread2" \
      --data-urlencode "body=stored after the trigger went")"
    contains "and a reply stores again once the store is willing" "$bafter_block" "ok posted"

    # A credential write that did not happen must not be reported as one: an operator told "revoked"
    # about a token that is still live has lost a security control, and a secret printed for a
    # credential that was never stored can never authenticate. Triggers make both refusals
    # deterministic, and the same board proves the writes work again once the store is willing.
    sqlite3 "$bdb" "CREATE TRIGGER IF NOT EXISTS block_token_insert BEFORE INSERT ON tokens BEGIN SELECT RAISE(ABORT,'blocked by the suite'); END;" >/dev/null 2>&1
    btstatus="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -G -X POST \
      --data-urlencode "token=$TOKEN" --data-urlencode "node=node-blocked" "http://127.0.0.1:$bport/token")"
    equals "an issuance the store refuses is a 500" "$btstatus" "500"
    btrefused="$(curl -sS --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" \
      --data-urlencode "node=node-blocked" "http://127.0.0.1:$bport/token")"
    contains "and it says nothing was issued" "$btrefused" "not stored"
    lacks "and no secret is printed for a credential that was not stored" "$btrefused" "secret:"
    sqlite3 "$bdb" "DROP TRIGGER IF EXISTS block_token_insert;" >/dev/null 2>&1
    btgood="$(curl -sS --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" \
      --data-urlencode "node=node-blocked" "http://127.0.0.1:$bport/token")"
    contains "and a credential is issued once the store is willing" "$btgood" "ok credential issued"
    btid="$(field "$btgood" id)"
    sqlite3 "$bdb" "CREATE TRIGGER IF NOT EXISTS block_token_update BEFORE UPDATE ON tokens BEGIN SELECT RAISE(ABORT,'blocked by the suite'); END;" >/dev/null 2>&1
    brev="$(curl -sS --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" \
      --data-urlencode "id=$btid" "http://127.0.0.1:$bport/token/revoke")"
    contains "a revocation the store refuses is not reported as one" "$brev" "did not run"
    lacks "and never claims the credential was revoked" "$brev" "ok revoked"
    equals "and the credential is still live in the store" \
      "$(sqlite3 "$bdb" "select count(*) from tokens where id='$btid' and (revoked_at is null or revoked_at='');")" "1"
    sqlite3 "$bdb" "DROP TRIGGER IF EXISTS block_token_update;" >/dev/null 2>&1
    brev2="$(curl -sS --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" \
      --data-urlencode "id=$btid" "http://127.0.0.1:$bport/token/revoke")"
    contains "and the revocation works once the store is willing" "$brev2" "ok revoked"

    # An acknowledgement is a read cursor, and the route is the one answer a caller can check. The
    # three ack UPDATEs were run with `store.run` (which returns -1 on failure) and then reported
    # `sqlite3_changes()` regardless. A store that refused the UPDATE was answered `ok acked 0` under
    # HTTP 200 — a success, and a count indistinguishable from "there was nothing left to ack" — while
    # the mail stayed unread. `sqlite3_changes()` is not even a documented value to read after a
    # failed statement (measured on this machine: an aborted UPDATE leaves it at 0, discarding the
    # preceding statement's count), which is the reason the code must not read it at all.
    bk register --data-urlencode "id=it-$RUN-bk-ack" --data-urlencode "node=node-bk" >/dev/null
    backsent="$(bk message --data-urlencode "from=it-$RUN-bk-a" --data-urlencode "to=it-$RUN-bk-ack" \
      --data-urlencode "body=ack-$RUN")"
    backmid="$(field "$backsent" message)"
    if [ -n "$backmid" ]; then
      ok "the ack fixture has an unread delivery to acknowledge"
    else
      no "the ack fixture has an unread delivery to acknowledge" "$(snip "$backsent")"
    fi
    sqlite3 "$bdb" "CREATE TRIGGER IF NOT EXISTS block_ack_update BEFORE UPDATE ON deliveries BEGIN SELECT RAISE(ABORT,'blocked by the suite'); END;" >/dev/null 2>&1
    backstatus="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -G -X POST \
      --data-urlencode "token=$TOKEN" --data-urlencode "id=it-$RUN-bk-ack" \
      --data-urlencode "message=$backmid" "http://127.0.0.1:$bport/ack")"
    equals "an acknowledgement the store refuses is a 500" "$backstatus" "500"
    backrefused="$(curl -sS --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" \
      --data-urlencode "id=it-$RUN-bk-ack" --data-urlencode "message=$backmid" "http://127.0.0.1:$bport/ack")"
    lacks "and is not reported as a successful acknowledgement" "$backrefused" "ok acked"
    contains "and it says nothing was acknowledged" "$backrefused" "nothing was acknowledged"
    equals "and the mail it could not stamp is still unread" \
      "$(sqlite3 "$bdb" "select count(*) from deliveries where agent='it-$RUN-bk-ack' and (acked_at is null or acked_at='');")" "1"
    # All three forms go through the same statement result, so all three have to fail the same way:
    # a fix that guarded only the form this check happens to use would still answer `ok acked 0`
    # about the other two, and `--all` is the form the wake loop's fallback and `ack --all` use.
    backtid="$(field "$backsent" thread)"
    equals "the all=1 form is refused too" \
      "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -G -X POST \
         --data-urlencode "token=$TOKEN" --data-urlencode "id=it-$RUN-bk-ack" \
         --data-urlencode "all=1" "http://127.0.0.1:$bport/ack")" "500"
    equals "and the thread form is refused too" \
      "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -G -X POST \
         --data-urlencode "token=$TOKEN" --data-urlencode "id=it-$RUN-bk-ack" \
         --data-urlencode "thread=$backtid" "http://127.0.0.1:$bport/ack")" "500"
    equals "and none of the three stamped anything" \
      "$(sqlite3 "$bdb" "select count(*) from deliveries where agent='it-$RUN-bk-ack' and (acked_at is null or acked_at='');")" "1"
    sqlite3 "$bdb" "DROP TRIGGER IF EXISTS block_ack_update;" >/dev/null 2>&1
    backok="$(curl -sS --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" \
      --data-urlencode "id=it-$RUN-bk-ack" --data-urlencode "message=$backmid" "http://127.0.0.1:$bport/ack")"
    contains "and the acknowledgement lands once the store is willing" "$backok" "ok acked 1 for it-$RUN-bk-ack"
    backagain="$(curl -sS --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" \
      --data-urlencode "id=it-$RUN-bk-ack" --data-urlencode "message=$backmid" "http://127.0.0.1:$bport/ack")"
    contains "and acking it twice reports the work the second call really did" "$backagain" "ok acked 0 for it-$RUN-bk-ack"

    # The send path is one write. A delivery the store refuses used to be ignored: the message was
    # stored, the sender was told `delivered_to`, and no delivery row existed — unreachable mail that
    # `--prune` deliberately never removes, announced as a delivery. A registration whose INSERT was
    # refused was answered "ok registered" with the empty identity a re-read found.
    txsent="$(bk message --data-urlencode "from=it-$RUN-bk-a" --data-urlencode "to=it-$RUN-bk-b" \
      --data-urlencode "body=tx-$RUN")"
    contains "the transaction fixture sends a message" "$txsent" "ok posted"
    sqlite3 "$bdb" "CREATE TRIGGER IF NOT EXISTS block_delivery_insert BEFORE INSERT ON deliveries BEGIN SELECT RAISE(ABORT,'blocked by the suite'); END;" >/dev/null 2>&1
    txstatus="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" \
      --data-urlencode "from=it-$RUN-bk-a" --data-urlencode "to=it-$RUN-bk-b" \
      --data-urlencode "body=tx-blocked-$RUN" "http://127.0.0.1:$bport/message")"
    equals "a delivery the store refuses is a 500" "$txstatus" "500"
    equals "and the message it could not deliver was rolled back" \
      "$(sqlite3 "$bdb" "select count(*) from messages where body='tx-blocked-$RUN';")" "0"
    equals "and no delivery row was orphaned by it" \
      "$(sqlite3 "$bdb" "select count(*) from deliveries d where not exists (select 1 from messages m where m.id=d.message_id);")" "0"
    sqlite3 "$bdb" "DROP TRIGGER IF EXISTS block_delivery_insert;" >/dev/null 2>&1
    txsent2="$(bk message --data-urlencode "from=it-$RUN-bk-a" --data-urlencode "to=it-$RUN-bk-b" \
      --data-urlencode "body=tx-after-$RUN")"
    contains "and the send works once the store is willing" "$txsent2" "ok posted"
    sqlite3 "$bdb" "CREATE TRIGGER IF NOT EXISTS block_agent_insert BEFORE INSERT ON agents BEGIN SELECT RAISE(ABORT,'blocked by the suite'); END;" >/dev/null 2>&1
    txreg="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" \
      --data-urlencode "id=it-$RUN-bk-blocked" --data-urlencode "node=node-bk" "http://127.0.0.1:$bport/register")"
    equals "a registration the store refuses is a 500" "$txreg" "500"
    equals "and the refused registration stored nothing" \
      "$(sqlite3 "$bdb" "select count(*) from agents where id='it-$RUN-bk-blocked';")" "0"
    sqlite3 "$bdb" "DROP TRIGGER IF EXISTS block_agent_insert;" >/dev/null 2>&1
    txreg2="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" \
      --data-urlencode "id=it-$RUN-bk-blocked" --data-urlencode "node=node-bk" "http://127.0.0.1:$bport/register")"
    equals "and registration works once the store is willing" "$txreg2" "200"

    # A structurally valid copy that is simply older: only the comparison can see it, so both
    # halves are asserted — accepted alone, refused against its source.
    cp "$bdir/good.sqlite" "$bdir/stale.sqlite"
    sqlite3 "$bdir/stale.sqlite" "DELETE FROM messages;" >/dev/null 2>&1
    contains "a copy that is merely valid passes the structural check" \
      "$("$CHATBOX_BIN" --verify-backup "$bdir/stale.sqlite" 2>&1)" "backup ok"
    bstale="$("$CHATBOX_BIN" --db "$bdb" --verify-backup "$bdir/stale.sqlite" 2>&1)"; bstalertc=$?
    equals "but is refused when compared with the board it names" "$bstalertc" "1"
    contains "and the refusal names the table and both fingerprints" "$bstale" \
      "messages: 0:0:0.0 in the copy,"
    contains "naming the board it compared with" "$bstale" "in $bdb"

    # A copy of the same *size* that is a different board: one message dropped and another added
    # leaves every count equal, which is all `--verify-backup` compared before this - it answered
    # "compared with: …" and exit 0 for a copy that was not current. The fingerprint (rows, highest
    # rowid, sum of rowids) is what tells them apart.
    # A *fresh* backup, because `good.sqlite` was taken before the section added its later messages:
    # the point of this fixture is a copy whose counts match the board *now*, which is the state in
    # which the old count-only comparison said "compared with" and exit 0.
    rm -f "$bdir/swapbase.sqlite" "$bdir/swapped.sqlite"
    "$CHATBOX_BIN" --db "$bdb" --backup "$bdir/swapbase.sqlite" >/dev/null 2>&1
    cp "$bdir/swapbase.sqlite" "$bdir/swapped.sqlite"
    sqlite3 "$bdir/swapped.sqlite" "DELETE FROM messages WHERE id=(SELECT MAX(id) FROM messages);
      INSERT INTO messages (thread_id,created_at,sender,repo,subject,body,reply_to,recipients,origin)
      VALUES (1,'2020-01-01T00:00:00Z','z','-','s','replacement',0,'x','');" >/dev/null 2>&1
    bswapa="$(sqlite3 "$bdir/swapped.sqlite" "select count(*) from messages;")"
    bswapb="$(sqlite3 "$bdb" "select count(*) from messages;")"
    equals "the tampered fixture has the same message count as the board" "$bswapa" "$bswapb"
    bswap="$("$CHATBOX_BIN" --db "$bdb" --verify-backup "$bdir/swapped.sqlite" 2>&1)"; bswaprc=$?
    equals "a copy with the same counts but different rows is refused" "$bswaprc" "1"
    contains "and the refusal shows the fingerprint that differs" "$bswap" "messages: "

    # Empty and short copies, which is what the incident left behind.
    : > "$bdir/zero.sqlite"
    bzero="$("$CHATBOX_BIN" --verify-backup "$bdir/zero.sqlite" 2>&1)"; bzerorc=$?
    equals "a zero-byte file is refused" "$bzerorc" "1"
    contains "and is named as unusable" "$bzero" "not a usable board"
    sqlite3 "$bdir/notables.sqlite" "PRAGMA user_version=0;" >/dev/null 2>&1
    bnt="$("$CHATBOX_BIN" --verify-backup "$bdir/notables.sqlite" 2>&1)"; bntrc=$?
    equals "a valid but table-less 4 KB database is refused" "$bntrc" "1"
    contains "and is named as unusable too" "$bnt" "not a usable board"
    head -c 1024 "$bdir/good.sqlite" > "$bdir/short.sqlite"
    bshort="$("$CHATBOX_BIN" --verify-backup "$bdir/short.sqlite" 2>&1)"; bshortrc=$?
    equals "a truncated copy is refused" "$bshortrc" "1"
    contains "and is named as unusable as well" "$bshort" "not a usable board"
    printf 'this is not a database\n' > "$bdir/text.sqlite"
    equals "a text file is refused" \
      "$("$CHATBOX_BIN" --verify-backup "$bdir/text.sqlite" >/dev/null 2>&1; echo $?)" "1"

    # Verification reads, and never creates what it was asked to check.
    bmiss="$("$CHATBOX_BIN" --verify-backup "$bdir/absent.sqlite" 2>&1)"; bmissrc=$?
    equals "a missing copy is refused" "$bmissrc" "1"
    contains "and the refusal says it does not exist" "$bmiss" "does not exist"
    if [ -e "$bdir/absent.sqlite" ]; then
      no "verifying a missing file does not create it" "the file now exists"
    else
      ok "verifying a missing file does not create it"
    fi

    # Usage: an operator mode that guesses which board to copy is worse than one that refuses.
    bnodbp="$("$CHATBOX_BIN" --backup "$bdir/guess.sqlite" 2>&1)"; bnodbrc=$?
    equals "a backup without an explicit board is refused" "$bnodbrc" "2"
    contains "and says it will not guess" "$bnodbp" "refusing to guess which board"
    bnosrc="$("$CHATBOX_BIN" --db "$bdir/nosuch.sqlite" --backup "$bdir/none.sqlite" 2>&1)"; bnosrcrc=$?
    equals "a board that does not exist is refused" "$bnosrcrc" "1"
    contains "and the refusal names the path" "$bnosrc" "$bdir/nosuch.sqlite does not exist"
    if [ -e "$bdir/none.sqlite" ]; then
      no "and nothing was created at the destination" "the file now exists"
    else
      ok "and nothing was created at the destination"
    fi
    bnotboard="$("$CHATBOX_BIN" --db "$bdir/text.sqlite" --backup "$bdir/fromtext.sqlite" 2>&1)"; bnotboardrc=$?
    equals "a source that is not a board is refused" "$bnotboardrc" "1"
    contains "and says it is not a board" "$bnotboard" "is not a usable board"
    equals "the two modes are not combinable" \
      "$("$CHATBOX_BIN" --db "$bdb" --backup "$bdir/never.sqlite" --verify-backup "$bdir/good.sqlite" \
          >/dev/null 2>&1; echo $?)" "2"
  else
    no "the backup fixture server started" "no answer on $bport (is the port taken?)"
  fi
  kill "$bpid" 2>/dev/null
  wait "$bpid" 2>/dev/null
else
  printf '  skip  backup verification (needs CHATBOX_BIN and sqlite3)\n'
fi

# ---------------------------------------------------------------------------
# 22. An inbox that is truncated says so (TRK-21)
# `GET /inbox` carries at most 200 messages, newest first. A session that falls behind therefore
# stops being told about its older unread mail — silently, which is the one thing a durable
# delivery queue cannot do. The answer now states how many deliveries match and how many of them
# it is showing, in the text and in the JSON form, so a reader can tell "that is everything" from
# "that is a page".
# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_DB:-}" ] && [ -f "$CHATBOX_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  BULK="it-$RUN-bulk"
  SMALL="it-$RUN-small-inbox"
  QUIET="it-$RUN-quiet-inbox"

  # Two messages: the answer must state the count and say nothing about a page it is not showing.
  post /message --data-urlencode "from=$A" --data-urlencode "to=$SMALL" --data-urlencode "body=small-$RUN" >/dev/null
  post /message --data-urlencode "from=$A" --data-urlencode "to=$SMALL" --data-urlencode "body=small2-$RUN" >/dev/null
  smallinbox="$(get /inbox "id=$SMALL")"
  contains "an inbox that fits states its count" "$smallinbox" "inbox for $SMALL — 2 message(s) unread"
  lacks "and does not claim to be hiding anything" "$smallinbox" "older one(s) are not"

  # A backlog larger than the cap, written straight to the store so the fixture is deterministic
  # and does not cost 205 round trips.
  # The sender is tagged with the run: this board is the long-lived one the README points at, and a
  # second run that reused the literal `bulk` would find the previous run's 205 messages and stamp a
  # delivery for each of them.
  bsender="bulk-$RUN"
  bthread="$(sqlite3 "$CHATBOX_DB" "INSERT INTO threads (repo,subject,created_at,created_by,last_at) VALUES ('example.test/$RUN/bulk','bulk $RUN','2020-01-01T00:00:00Z','bulk','2020-01-01T00:00:00Z'); SELECT last_insert_rowid();")"
  sqlite3 "$CHATBOX_DB" "
    INSERT INTO messages (thread_id,created_at,sender,repo,subject,body,recipients)
    WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<205)
    SELECT $bthread,'2020-01-01T00:00:00Z','$bsender','example.test/$RUN/bulk','bulk','bulk-'||i,'$BULK' FROM c;
    INSERT INTO deliveries (message_id,agent,created_at)
    SELECT id,'$BULK','2020-01-01T00:00:00Z' FROM messages WHERE sender='$bsender';" >/dev/null 2>&1
  equals "the bulk fixture holds 205 deliveries" \
    "$(sqlite3 "$CHATBOX_DB" "select count(*) from deliveries where agent='$BULK';")" "205"

  capped="$(get /inbox "id=$BULK")"
  contains "a full page states how many it is showing" "$capped" \
    "inbox for $BULK — 200 of 205 message(s) unread"
  contains "and how many are not listed" "$capped" "5 older one(s) are not"
  equals "and the page really holds the cap, no more" \
    "$(printf '%s\n' "$capped" | grep -c '^  from: ')" "200"
  cappedj="$(get /inbox "id=$BULK&json=1")"
  contains "the json form states what is shown" "$cappedj" '"shown": 200'
  contains "and what matched" "$cappedj" '"matching": 205'
  contains "and still carries the messages" "$cappedj" '"messages": ['
  equals "and all of them" "$(printf '%s\n' "$cappedj" | grep -c '"acked"')" "200"

  # The cap is a window, not a loss: everything is still there, and acking the backlog clears it.
  post /ack --data-urlencode "id=$BULK" --data-urlencode "all=1" >/dev/null
  equals "the whole backlog is ackable in one call" "$(get /inbox "id=$BULK")" "inbox for $BULK: empty"
  contains "and all=1 counts the same rows" "$(get /inbox "id=$BULK&all=1")" \
    "inbox for $BULK — 200 of 205 message(s) (including read)"

  # An empty inbox still answers JSON when JSON was asked for, with the counts it has.
  emptyj="$(get /inbox "id=$QUIET&json=1")"
  contains "an empty inbox answers json" "$emptyj" '"shown": 0'
  contains "with a matching count of zero" "$emptyj" '"matching": 0'
  contains "and an empty message list" "$emptyj" '"messages": ['
else
  printf '  skip  the inbox cap report (needs CHATBOX_DB and sqlite3)\n'
fi

# ---------------------------------------------------------------------------
# 24. Exactly Content-Length bytes are the body (TRK-23)
# A request that sent *more* than it declared had the surplus folded into its parameters, so bytes
# belonging to no request could set one; a request that sent *less* was answered with nothing at
# all, and the sender could not tell a truncated report from a slow server. Both need a raw socket:
# curl has no way to declare one length and send another.
# ---------------------------------------------------------------------------
cbhost="${URL#*://}"; cbhost="${cbhost%%/*}"; cbport="${cbhost##*:}"
if command -v nc >/dev/null 2>&1 && [ -n "$cbport" ] && [ "$cbport" -eq "$cbport" ] 2>/dev/null; then
  # A body that stops short of what it announced: the server must say so, and store nothing.
  msgs_before24="$(get /health | sed -n 's/^messages: //p')"
  tbody="POST /message?token=$TOKEN HTTP/1.1\r\nHost: chatbox\r\nContent-Length: 60\r\n\r\nfrom=x&body=short"
  truncated24="$(printf '%b' "$tbody" | nc -w 5 127.0.0.1 "$cbport" 2>/dev/null)"
  contains "a body shorter than Content-Length is answered" "$truncated24" "400 Bad Request"
  contains "and the answer says nothing was stored" "$truncated24" "nothing was stored"
  if [ -n "$msgs_before24" ]; then
    equals "a truncated request stores no message" \
      "$(get /health | sed -n 's/^messages: //p')" "$msgs_before24"
  else
    no "a truncated request stores no message" "the message count could not be read"
  fi

  # Exactly the declared bytes are the body, and not one more: the surplus is neither body nor
  # parameter. The declared length is computed from `from=exact-<run>&body=ok`, and the `&to=phantom`
  # behind it belongs to nothing. The sender carries the run so a second run on the same board cannot
  # match the previous one's row.
  ex24_body="from=exact-$RUN&body=ok"
  ex24_len="${#ex24_body}"
  oversend="POST /message?token=$TOKEN HTTP/1.1\r\nHost: chatbox\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: $ex24_len\r\n\r\n$ex24_body&to=phantom"
  surplus24="$(printf '%b' "$oversend" | nc -w 5 127.0.0.1 "$cbport" 2>/dev/null)"
  contains "a request that sends more than it declared is answered" "$surplus24" "ok posted"
  contains "the declared bytes are the body it stored" "$surplus24" "delivered_to: (nobody)"
  lacks "and the surplus is not a parameter" "$surplus24" "phantom"
  if [ -n "${CHATBOX_DB:-}" ] && command -v sqlite3 >/dev/null 2>&1; then
    equals "the stored row holds the declared body and nothing after it" \
      "$(sqlite3 "$CHATBOX_DB" "select count(*) from messages where sender='exact-$RUN' and body='ok' and recipients='';")" "1"
  fi
else
  printf '  skip  raw Content-Length handling (needs nc and a URL with an explicit port)\n'
fi

# ---------------------------------------------------------------------------
# 25. A refusal is printed *and* signalled (TRK-31)
# The client handed curl's status straight through and invoked curl without `-f`, so a 404 printed
# the server's answer and exited 0: a script — or a harness hook, which can only see an exit status —
# could not tell a refused request from a successful one. The body still has to reach the reader
# unchanged, and a transport failure has to stay distinguishable from a refusal.
