if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ]; then

  if fed_wait "$fb" "$fbport" fed && fed_wait "$pb" "$pbport" peer && fed_wait "$xb" "$xbport" down; then
    # ---- what each board says about itself ----
    contains "a board with no peer says so" "$(fed_get "$pb" /health "$TOKEN")" "peer: none"
    contains "the peer board names itself" "$(fed_get "$pb" /health "$TOKEN")" \
      "peer: none (this board is fed-peer, accepts up to 4 hops)"
    contains "the forwarding board names its peer" "$(fed_get "$fb" /health "$TOKEN")" \
      "peer: http://127.0.0.1:$pbport"
    # The forwarding board was started without --server-id, so its name is the machine's. The only
    # honest check is that the name it reports is the name the peer stamps on the message.
    fedname="$(fed_get "$fb" /health "$TOKEN" | sed -n 's/.*(this board is \([^,]*\).*/\1/p')"
    if [ -n "$fedname" ]; then
      ok "a board started without --server-id still has a name"
    else
      no "a board started without --server-id still has a name" \
        "health said [$(snip "$(fed_get "$fb" /health "$TOKEN")")]"
    fi
    contains "and the banner says what it forwards" "$(cat "$SCRATCH/fed-fed-${RUN}.log")" \
      "federation: forwarding to http://127.0.0.1:$pbport"

    fed_post "$fb" /register "$TOKEN" --data-urlencode "id=$FA" --data-urlencode "node=node-fed-a" \
      --data-urlencode "repos=$FED_LOCAL" >/dev/null
    fed_post "$pb" /register "$TOKEN" --data-urlencode "id=$FO" --data-urlencode "node=node-fed-b" \
      --data-urlencode "repos=$FED_REPO" >/dev/null

    # ---- the forward itself ----
    # The body is chosen so a field that travelled wrongly would be visibly wrong: `+` is what a
    # form decoder turns into a space if it is not escaped, `&` and `=` are what a form encoder
    # gets wrong if it joins fields by hand, and the two lines prove nothing was flattened.
    FEDBODY="one $fedmark + plus & ampersand = equals % percent ünïcode
two lines, nothing special"
    fsent="$(fed_post "$fb" /message "$TOKEN" --data-urlencode "from=$FA" \
      --data-urlencode "repo=$FED_REPO" --data-urlencode "subject=federated $RUN" \
      --data-urlencode "body=$FEDBODY")"
    contains "a repo nobody here owns is forwarded to the peer" "$fsent" \
      "forwarded_to: http://127.0.0.1:$pbport (ok)"
    contains "and the board's log records what it did" "$(cat "$SCRATCH/fed-fed-${RUN}.log")" \
      "forwarded to http://127.0.0.1:$pbport"
    contains "and the message is stored locally first" "$fsent" "ok posted"
    finbox="$(fed_get "$pb" /inbox "$TOKEN" --data-urlencode "id=$FO" --data-urlencode "all=1")"
    contains "the peer received the message" "$finbox" "$FEDBODY"
    contains "attributed to the original sender" "$finbox" "from: $FA"
    contains "under the repo it was sent for" "$finbox" "repo: $FED_REPO"
    equals "exactly one copy reached the peer" "$(printf '%s' "$finbox" | grep -c "$fedmark")" "1"
    contains "and the inbox names the board it came from, where a session reads it" "$finbox" \
      "from: $FA (via $fedname)"

    ftid="$(printf '%s' "$finbox" | sed -n 's/.*thread \([0-9][0-9]*\).*/\1/p' | head -n 1)"
    if [ -n "$ftid" ]; then
      contains "the peer marks where the message came from" \
        "$(fed_get "$pb" /thread "$TOKEN" --data-urlencode "id=$ftid")" "(via $fedname)"
    else
      no "the peer marks where the message came from" "no thread id in [$(snip "$finbox")]"
    fi
    # A message the peer accepted itself carries no such mark, so the mark means something.
    lresp="$(fed_post "$pb" /message "$TOKEN" --data-urlencode "from=$FO" \
      --data-urlencode "repo=$FED_REPO" --data-urlencode "subject=local $RUN" \
      --data-urlencode "body=local-body-$fedmark")"
    ltid="$(field "$lresp" thread)"
    if [ -n "$ltid" ]; then
      lacks "a message the peer accepted itself is not marked as forwarded" \
        "$(fed_get "$pb" /thread "$TOKEN" --data-urlencode "id=$ltid")" "(via "
    else
      no "a message the peer accepted itself is not marked as forwarded" "say said [$(snip "$lresp")]"
    fi

    # ---- what is deliberately not forwarded ----
    own="$(fed_post "$fb" /message "$TOKEN" --data-urlencode "from=$FA" \
      --data-urlencode "repo=$FED_LOCAL" --data-urlencode "body=owned here $RUN")"
    contains "a message for a repo this board owns is not forwarded" "$own" "ok posted"
    lacks "and the response does not claim a forward" "$own" "forwarded_to:"
    explicit="$(fed_post "$fb" /message "$TOKEN" --data-urlencode "from=$FA" \
      --data-urlencode "to=$FO" --data-urlencode "repo=$FED_REPO" --data-urlencode "body=explicit-$fedmark")"
    contains "a message with explicit recipients is stored" "$explicit" "ok posted"
    contains "and reaches the id that was named" "$explicit" "delivered_to: $FO"
    lacks "and is local routing, never forwarded" "$explicit" "forwarded_to:"
    fedthread="$(field "$fsent" thread)"
    rep="$(fed_post "$fb" /message "$TOKEN" --data-urlencode "from=$FA" \
      --data-urlencode "thread=$fedthread" --data-urlencode "body=a-follow-up-$fedmark")"
    contains "a reply into a local thread is stored" "$rep" "ok posted"
    lacks "and is not forwarded, because the peer has no such conversation" "$rep" "forwarded_to:"

    # ---- loops: a message that came from another board is never passed on ----
    hop="$(fed_post "$fb" /message "$TOKEN" --data-urlencode "from=$FA" \
      --data-urlencode "repo=$FED_REPO" --data-urlencode "hop=other-board" \
      --data-urlencode "body=relayed-$fedmark")"
    contains "a message that came from another board is stored" "$hop" "ok posted"
    contains "and is not passed on" "$hop" \
      "forward: not sent — this message came from another board (other-board)"
    equals "and no copy of it reached the peer" \
      "$(fed_get "$pb" /inbox "$TOKEN" --data-urlencode "id=$FO" --data-urlencode "all=1" \
          | grep -c "relayed-$fedmark")" "0"

    # ---- the hop list is untrusted input ----
    equals "a hop list with an empty entry is refused" \
      "$(fed_status "$fb" /message "$TOKEN" --data-urlencode "from=$FA" \
          --data-urlencode "repo=$FED_REPO" --data-urlencode "hop=one," \
          --data-urlencode "body=x")" "400"
    hopnl="one
two"
    hopbad="$(fed_post "$fb" /message "$TOKEN" --data-urlencode "from=$FA" \
      --data-urlencode "repo=$FED_REPO" --data-urlencode "hop=$hopnl" --data-urlencode "body=x")"
    contains "a hop id with a line break is refused" "$hopbad" "a board id is one line"
    too="$(fed_post "$fb" /message "$TOKEN" --data-urlencode "from=$FA" \
      --data-urlencode "repo=$FED_REPO" --data-urlencode "hop=one,two,three,four,five" \
      --data-urlencode "body=x")"
    contains "a hop list over the limit is refused" "$too" "hop names 5 boards"
    contains "and the refusal states the limit in force" "$too" "the limit here is 4"
    equals "a board id of Unicode whitespace is refused as a hop" \
      "$(fed_status "$fb" /message "$TOKEN" --data-urlencode "from=$FA" \
          --data-urlencode "repo=$FED_REPO" --data-urlencode "hop=$(printf '\342\200\250')" \
          --data-urlencode "body=x")" "400"
    equals "a hop entry that is only a space is refused" \
      "$(fed_status "$fb" /message "$TOKEN" --data-urlencode "from=$FA" \
          --data-urlencode "repo=$FED_REPO" --data-urlencode "hop= " --data-urlencode "body=x")" "400"
    contains "and an empty hop is still no hop at all" \
      "$(fed_post "$fb" /message "$TOKEN" --data-urlencode "from=$FA" \
          --data-urlencode "repo=$FED_REPO" --data-urlencode "hop=" --data-urlencode "body=empty-hop $fedmark")" \
      "forwarded_to:"
    atlimit="$(fed_post "$fb" /message "$TOKEN" --data-urlencode "from=$FA" \
      --data-urlencode "repo=$FED_REPO" --data-urlencode "hop=one,two,three,four" \
      --data-urlencode "body=x")"
    contains "a hop list exactly at the limit is accepted" "$atlimit" "ok posted"
    contains "and is still not forwarded" "$atlimit" "forward: not sent"

    # ---- the peer credential is a bootstrap credential there ----
    scoped="$(fed_post "$pb" /token "$TOKEN" --data-urlencode "node=node-fed-b" \
      --data-urlencode "namespaces=*" | sed -n 's/^secret: //p')"
    if [ -n "$scoped" ]; then
      fed_start scoped "$cbport" --peer "http://127.0.0.1:$pbport" --peer-token "$scoped" --max-hops 1
      if fed_wait "$cb" "$cbport" scoped; then
        csc="$(fed_post "$cb" /message "$TOKEN" --data-urlencode "from=$FC" \
          --data-urlencode "repo=$FED_REPO" --data-urlencode "body=scoped-$fedmark")"
        contains "a scoped peer credential is refused by the peer's own rule" "$csc" \
          "forward failed: http://127.0.0.1:$pbport answered 403"
        contains "and the refusal is the peer's, not a guess" "$csc" "forbidden"
        contains "and the message is still stored here" "$csc" "ok posted"
        lacks "and the sender is not told the message arrived" "$csc" "forwarded_to:"
        # A scoped credential speaks for its own machine's sessions, so the same credential does
        # forward a session the peer knows on that machine. Both halves matter: without this one,
        # "refused" could be a blanket rule rather than the credential model it is.
        fed_post "$pb" /register "$TOKEN" --data-urlencode "id=$FC" --data-urlencode "node=node-fed-b" >/dev/null
        known="$(fed_post "$cb" /message "$TOKEN" --data-urlencode "from=$FC" \
          --data-urlencode "repo=$FED_REPO" --data-urlencode "body=scoped-known-$fedmark")"
        contains "but forwards a session of the credential's own machine" "$known" \
          "forwarded_to: http://127.0.0.1:$pbport (ok)"
        ctwo="$(fed_post "$cb" /message "$TOKEN" --data-urlencode "from=$FC" \
          --data-urlencode "repo=$FED_REPO" --data-urlencode "hop=one,two" --data-urlencode "body=x")"
        contains "the board's own --max-hops is believed, not the default" "$ctwo" "the limit here is 1"
        contains "and it refuses the two-board list" "$ctwo" "hop names 2 boards"
      else
        no "the scoped-credential fixture started" "no answer on $cb"
      fi
    else
      no "a scoped credential was issued for the federation fixture" "no secret in the response"
    fi

    # ---- a peer that is not listening ----
    if curl -sS --max-time 2 "http://127.0.0.1:$deadport/" >/dev/null 2>&1; then
      no "the dead-peer fixture port is free" "something is listening on $deadport"
    else
      ok "the dead-peer fixture port is free"
    fi
    xsent="$(fed_post "$xb" /message "$TOKEN" --data-urlencode "from=$FX" \
      --data-urlencode "repo=$FED_REPO" --data-urlencode "body=down-$fedmark")"
    contains "a peer that cannot be reached is reported as failed" "$xsent" \
      "forward failed: http://127.0.0.1:$deadport"
    contains "and the failure carries a transport reason, not a status code" "$xsent" "— error:"
    lacks "and the sender is not told the message arrived" "$xsent" "forwarded_to:"
    contains "and the message stays on the board that accepted it" "$xsent" "ok posted"
    contains "and the failure is in the board's log, where an operator looks" \
      "$(cat "$SCRATCH/fed-down-${RUN}.log")" "could not be forwarded to http://127.0.0.1:$deadport"
    contains "from where it can be read back" \
      "$(fed_get "$xb" /thread "$TOKEN" --data-urlencode "id=$(field "$xsent" thread)")" "down-$fedmark"

    # ---- a peer that accepts and says nothing does not hold up the board ----
    # This is the property the forward queue exists for. A forward done on the serial queue would
    # make every other request on this board wait for a peer that is never going to answer.
    if command -v nc >/dev/null 2>&1; then
      # The request is captured, not discarded: the timing checks below are only meaningful if a
      # forward was really in flight, and the bytes this listener received are the proof.
      sleep 60 | nc -k -l "$hport" > "$SCRATCH/fed-slow-conn-${RUN}.txt" 2>&1 &
      ncpid=$!
      sleep 0.5
      # Confirm something is really holding the port before claiming a peer that says nothing.
      # Without this the property below could pass on a refused connection, which is a different
      # code path entirely.
      curl -sS --max-time 1 "http://127.0.0.1:$hport/" >/dev/null 2>&1
      heldrc=$?
      if [ "$heldrc" = 28 ]; then
        ok "the silent peer is holding the port open"
      else
        no "the silent peer is holding the port open" "curl to $hport returned $heldrc, wanted 28"
      fi
      fed_start slow "$sbport" --peer "http://127.0.0.1:$hport" --peer-token "$TOKEN"
      if fed_wait "$sb" "$sbport" slow; then
        ( fed_post "$sb" /message "$TOKEN" --data-urlencode "from=$FS" \
            --data-urlencode "repo=$FED_REPO" --data-urlencode "body=slow-$fedmark" \
            > "$SCRATCH/fed-slow-${RUN}.txt" 2>&1 ) &
        slowpid=$!
        sleep 1.5
        fedt0=$(date +%s)
        fedhealth="$(curl -sS --max-time 4 "$sb/health?token=$TOKEN")"
        fedt1=$(date +%s)
        contains "the forward actually reached the silent peer" \
          "$(cat "$SCRATCH/fed-slow-conn-${RUN}.txt" 2>/dev/null)" "POST /message"
        contains "a board is still answering while a forward is in flight" "$fedhealth" "ok chatbox up"
        if [ "$((fedt1 - fedt0))" -le 2 ]; then
          ok "and it answers promptly rather than waiting on the peer"
        else
          no "and it answers promptly rather than waiting on the peer" \
            "took $((fedt1 - fedt0))s while a forward was outstanding"
        fi
        # ---- three forwards to the same silent peer are in flight at once ----
        # The forward queue is concurrent. Three sends to a peer that never answers each reach the
        # board's 10s deadline and log a "could not be forwarded" line: three of them together when
        # the queue is concurrent, one every 10s when it is serial. Counting the board's own log
        # lines after a bounded wait for three tells the two apart without timing the scheduler, and
        # it needs only nc -k, which this fixture already proved works on the CI runner.
        #
        # The forward sent above by the prompt check is still in flight and will log its own line.
        # Wait for that line first: if it lands inside the window below, it is counted as one of the
        # three and a serial queue looks concurrent (the matrix cell went GREEN on exactly that).
        _concbasewait=0
        while [ "$(grep -c 'could not be forwarded' "$SCRATCH/fed-slow-${RUN}.log" 2>/dev/null)" -lt 1 ] \
              && [ "$_concbasewait" -lt 40 ]; do
          sleep 0.5
          _concbasewait=$((_concbasewait + 1))
        done
        _concbefore="$(grep -c 'could not be forwarded' "$SCRATCH/fed-slow-${RUN}.log" 2>/dev/null)"
        _concbefore="${_concbefore:-0}"
        for _ci in 1 2 3; do
          ( fed_post "$sb" /message "$TOKEN" --data-urlencode "from=$FS" \
              --data-urlencode "repo=$FED_REPO" --data-urlencode "body=conc$_ci-$fedmark" \
              > /dev/null 2>&1 ) &
        done
        _concwaited=0
        while [ "$(grep -c 'could not be forwarded' "$SCRATCH/fed-slow-${RUN}.log" 2>/dev/null)" \
                -lt "$((_concbefore + 3))" ] && [ "$_concwaited" -lt 36 ]; do
          sleep 0.5
          _concwaited=$((_concwaited + 1))
        done
        _conclines="$(grep -c 'could not be forwarded' "$SCRATCH/fed-slow-${RUN}.log" 2>/dev/null)"
        _concdelta=$((_conclines - _concbefore))
        if [ "$_concdelta" -ge 2 ]; then
          ok "three forwards to one peer run concurrently, not one every 10s"
        else
          no "three forwards to one peer run concurrently, not one every 10s" \
            "logged $_concdelta of 3 in 18s; a serial queue logs 1"
        fi
        kill "$slowpid" 2>/dev/null
        wait "$slowpid" 2>/dev/null
      else
        no "the silent-peer fixture started" "no answer on $sb"
      fi
      kill "$ncpid" 2>/dev/null
      wait "$ncpid" 2>/dev/null
    else
      printf '  skip  a peer that accepts and says nothing (needs nc)\n'
    fi


    # ---- a peer that redirects must not be reported as a delivery ----
    # `URLSession` follows redirects by default, so an http→https peer would answer this board's
    # POST with a GET somewhere else; a final 2xx there is what this board would report as
    # `forwarded_to … (ok)`, which is silent loss announced as a delivery. The forward session
    # refuses the redirect, so the 3xx is the answer.
    if command -v nc >/dev/null 2>&1; then
      redirport="${CHATBOX_FED_REDIR_PORT:-9404}"
      redirbase="http://127.0.0.1:$((redirport + 1))"
      # The responder sends the 302 and then *holds* the connection. Without the hold, nc exits
      # while the POST body is still unread, the kernel answers with a reset, and the board reports
      # a transport failure instead of the redirect this check is about — a race that made this
      # check flaky, not a property of the server.
      { printf 'HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:%s/landing\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' "$((redirport + 1))"; sleep 3; } \
        | nc -k -l "$redirport" >/dev/null 2>&1 &
      redirpid=$!
      sleep 0.5
      # A *connect* would consume the single response the pipe holds, so readiness is the listener
      # process being alive rather than a probe.
      if kill -0 "$redirpid" 2>/dev/null; then
        ok "the redirecting peer is listening"
      else
        no "the redirecting peer is listening" "nc exited on port $redirport"
      fi
      fed_start redir "$((redirport + 1))" --peer "http://127.0.0.1:$redirport" --peer-token "$TOKEN"
      if fed_wait "$redirbase" "$((redirport + 1))" redir; then
        redir="$(fed_post "$redirbase" /message "$TOKEN" --data-urlencode "from=$FX" \
          --data-urlencode "repo=$FED_REPO" --data-urlencode "body=redirected-$fedmark")"
        contains "a redirecting peer is reported as a failure" "$redir" "answered 302"
        contains "and names where it was sent instead" "$redir" \
          "redirected to http://127.0.0.1:$((redirport + 1))/landing"
        lacks "and never claims the message arrived" "$redir" "forwarded_to:"
      else
        no "the redirecting-peer fixture started" "no answer on $redirbase"
      fi
      kill "$redirpid" 2>/dev/null
      wait "$redirpid" 2>/dev/null
    else
      printf '  skip  a redirecting peer (needs nc)\n'
    fi

    # ---- a 2xx from a host that is not a board must not be reported as a delivery ----
    # The sender is told `forwarded_to … (ok)`, which only the board's own success line can mean. A
    # fronting proxy, a captive portal or a mis-pointed --peer answers 2xx to anything, and the old
    # code reported every 2xx as delivered without reading the answer.
    if command -v nc >/dev/null 2>&1; then
      fakeport="${CHATBOX_FED_FAKE_PORT:-9411}"
      fakebase="http://127.0.0.1:$((fakeport + 2))"
      { printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 19\r\nConnection: close\r\n\r\nhello from a proxy\n'; sleep 3; } \
        | nc -k -l "$fakeport" >/dev/null 2>&1 &
      fakepid=$!
      sleep 0.5
      if kill -0 "$fakepid" 2>/dev/null; then
        ok "the non-board peer is listening"
      else
        no "the non-board peer is listening" "nc exited on port $fakeport"
      fi
      fed_start fake "$((fakeport + 2))" --peer "http://127.0.0.1:$fakeport" --peer-token "$TOKEN"
      if fed_wait "$fakebase" "$((fakeport + 2))" fake; then
        fake="$(fed_post "$fakebase" /message "$TOKEN" --data-urlencode "from=$FX" \
          --data-urlencode "repo=$FED_REPO" --data-urlencode "body=fake-$fedmark")"
        contains "a 2xx that is not a chatbox answer is a failure" "$fake" "not like a chatbox board"
        contains "and it reports what the host actually said" "$fake" "hello from a proxy"
        lacks "and never claims the message arrived" "$fake" "forwarded_to:"
        contains "and the message stays on the board that accepted it" "$fake" "ok posted"
      else
        no "the non-board-peer fixture started" "no answer on $fakebase"
      fi
      kill "$fakepid" 2>/dev/null
      wait "$fakepid" 2>/dev/null
    else
      printf '  skip  a non-board peer (needs nc)\n'
    fi

    # ---- a peer that streams more than a chatbox answer is cut off, not buffered whole ----
    # Only the first line is ever read, but the old dataTask buffered the entire body first, and the
    # peer chooses how large that is. The delegate cancels past the cap, so the sender is told the
    # answer was too large rather than the board allocating whatever the peer sent.
    if command -v nc >/dev/null 2>&1; then
      bigport="${CHATBOX_FED_BIG_PORT:-9408}"
      bigbase="http://127.0.0.1:$((bigport + 1))"
      { printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 10000000\r\nConnection: close\r\n\r\n'; head -c 200000 /dev/zero | tr '\0' 'A'; sleep 2; } \
        | nc -k -l "$bigport" >/dev/null 2>&1 &
      bigpid=$!
      sleep 0.5
      if kill -0 "$bigpid" 2>/dev/null; then
        ok "the streaming peer is listening"
      else
        no "the streaming peer is listening" "nc exited on port $bigport"
      fi
      fed_start big "$((bigport + 1))" --peer "http://127.0.0.1:$bigport" --peer-token "$TOKEN"
      if fed_wait "$bigbase" "$((bigport + 1))" big; then
        big="$(fed_post "$bigbase" /message "$TOKEN" --data-urlencode "from=$FX" \
          --data-urlencode "repo=$FED_REPO" --data-urlencode "body=huge-$fedmark")"
        contains "an oversized peer answer is refused, not buffered" "$big" "longer than 65536 bytes"
        lacks "and never claims the message arrived" "$big" "forwarded_to:"
      else
        no "the streaming-peer fixture started" "no answer on $bigbase"
      fi
      kill "$bigpid" 2>/dev/null
      wait "$bigpid" 2>/dev/null
    else
      printf '  skip  a streaming peer (needs nc)\n'
    fi

    # ---- a board that predates the origin column gains it ----
    legdb="$SCRATCH/fed-legacy-${RUN}.sqlite"
    rm -f "$legdb" "$legdb-wal" "$legdb-shm"
    if command -v sqlite3 >/dev/null 2>&1 && sqlite3 "$legdb" \
       "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id INTEGER, created_at TEXT, sender TEXT, repo TEXT, subject TEXT, body TEXT, reply_to INTEGER, recipients TEXT);" >/dev/null 2>&1; then
      fed_start legacy "$lbport" --server-id fed-legacy
      if fed_wait "$lb" "$lbport" legacy; then
        equals "a board built before the origin column gains it" \
          "$(sqlite3 "$legdb" "select count(*) from pragma_table_info('messages') where name='origin';")" "1"
        contains "and can still store a message" \
          "$(fed_post "$lb" /message "$TOKEN" --data-urlencode "from=$FX" \
              --data-urlencode "repo=$FED_REPO" --data-urlencode "body=legacy-$fedmark")" "ok posted"
      else
        no "the legacy-database fixture started" \
          "$(head -2 "$SCRATCH/fed-legacy-${RUN}.log" | tr '\n' '~')"
      fi
    else
      printf '  skip  the origin-column migration (needs sqlite3)\n'
    fi

    # ---- a peer that cannot be used is refused at startup, not discovered later ----
    fed_refuse "--peer-token without --peer is refused" "means nothing without --peer" \
      --peer-token secret
    fed_refuse "--peer that is not a URL is refused" "must be an http(s) URL" --peer not-a-url
    fed_refuse "--peer with a query is refused" "names a board, not a request" --peer "http://h:1/?x=1"
    fed_refuse "--peer with no value is refused" "needs a board URL" --peer=
    fed_refuse "--max-hops below one is refused" "must be between 1 and 64" --max-hops 0
    fed_refuse "--max-hops above the ceiling is refused" "must be between 1 and 64" --max-hops 65
    fed_refuse "--server-id with a comma is refused" "and no comma" --server-id "a,b"
    fed_refuse "--server-id with a control byte is refused" "control or format characters" \
      --server-id "$(printf 'a\rb')"
    fed_refuse "--server-id with a leading space is refused, not repaired" "no whitespace" \
      --server-id " board-a"
    fed_refuse "an unknown flag is still refused" "unknown flag" --peer-tokens secret
    fed_refuse "--server-id of Unicode whitespace is refused" \
      "no whitespace, control or format characters" --server-id "$(printf '\342\200\250')"
    fed_refuse "--server-id with an invisible format character is refused" \
      "no whitespace, control or format characters" --server-id "$(printf 'board\342\200\213x')"
    fed_refuse "--peer with credentials in the URL is refused" "must not carry credentials" \
      --peer "http://alice:s3cret@127.0.0.1:1"
    fed_refuse "--peer with an impossible port is refused" "port between 1 and 65535" \
      --peer "http://127.0.0.1:99999"
    fed_refuse "--peer-token with a line break is refused" "must be one line" \
      --peer "http://127.0.0.1:1" --peer-token "$(printf 'tok\r\nX-Injected: yes')"
    # This one is deliberately aimed at the port fed_refuse itself is starting on: a peer that names
    # the board it is configuring is this board, and a forward to it could only be a duplicate.
    fed_refuse "--peer naming this board is refused" "names this board" \
      --peer "http://127.0.0.1:$rport" --peer-token x
    fed_refuse "--peer-token-file with no path is refused" "names no file" --peer-token-file=
    fed_refuse "--peer-token-file on a missing file is refused" "cannot read --peer-token-file" \
      --peer "http://127.0.0.1:1" --peer-token-file "$SCRATCH/fed-no-such-${RUN}"
    fed_refuse "--peer-token-file on an empty file is refused" "is empty" \
      --peer "http://127.0.0.1:1" --peer-token-file "$SCRATCH/fed-empty-${RUN}"
    fed_refuse "and giving both a peer token and a peer token file is refused" "not both" \
      --peer "http://127.0.0.1:1" --peer-token x --peer-token-file "$fpeertok"
  else
    no "the federation fixture started" "no answer on $fb, $pb or $xb"
  fi

  for fp in $fedpids; do kill "$fp" 2>/dev/null; done
  for fp in $fedpids; do wait "$fp" 2>/dev/null; done
  # The same cleanup the EXIT trap runs, called here as well so the end of the section does not
  # depend on the trap (and so it is visibly invoked rather than only reached through a signal).
  fed_cleanup
else
  printf '  skip  federation (set CHATBOX_BIN to the built server)\n'
fi

# ---------------------------------------------------------------------------
# 34. An empty credential flag must not start an open board
# `argValue` cannot tell "flag absent" from "flag given nothing", so `--token "$SECRET"` with SECRET
# unset came up fully open — every route as bootstrap, no diagnostic — and `--token-file ""` had the
# same hole. This is the one failure a bearer-token board must never have, because nothing about the
# running board says it happened. Open mode is asked for by name (`--token open`) or by passing no
# token flag at all, and the empty *file* case was already refused.
# ---------------------------------------------------------------------------
