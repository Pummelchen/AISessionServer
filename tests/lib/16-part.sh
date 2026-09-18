if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ]; then
  fl48port="${CHATBOX_FLAGS_PORT:-8778}"
  fl48base="http://127.0.0.1:$fl48port"
  fl48db="$SCRATCH/flags-${RUN}.sqlite"
  fl48tok="$SCRATCH/flags-${RUN}.token"
  rm -f "$fl48db" "$fl48db-wal" "$fl48db-shm"
  printf '%s\n' "$TOKEN" > "$fl48tok"
  chmod 600 "$fl48tok" 2>/dev/null
  "$CHATBOX_BIN" --port "$fl48port" --db "$fl48db" --token-file "$fl48tok" \
    > "$SCRATCH/flags-${RUN}.log" 2>&1 &
  fl48pid=$!
  fl48ready=0
  for _ in $(seq 1 50); do
    if curl -fsS --max-time 2 "$fl48base/health?token=$TOKEN" >/dev/null 2>&1; then fl48ready=1; break; fi
    sleep 0.2
  done
  if [ "$fl48ready" = 1 ]; then
    fl48() { _flp="$1"; shift; curl -sS --max-time 10 -G -X POST --data-urlencode "token=$TOKEN" "$fl48base/$_flp" "$@"; }
    fl48get() { curl -sS --max-time 10 "$fl48base/$1"; }
    fl48a="it-$RUN-fl-a"
    fl48b="it-$RUN-fl-b"
    for _id in "$fl48a" "$fl48b"; do
      fl48 register --data-urlencode "id=$_id" --data-urlencode "node=n-fl48" >/dev/null
    done
    fl48m1="$(fl48 message --data-urlencode "from=$fl48a" --data-urlencode "to=$fl48b" \
      --data-urlencode "body=fl-one-$RUN")"
    fl48m2="$(fl48 message --data-urlencode "from=$fl48a" --data-urlencode "to=$fl48b" \
      --data-urlencode "body=fl-two-$RUN")"
    fl48t1="$(field "$fl48m1" thread)"
    fl48t2="$(field "$fl48m2" thread)"
    # Two deliveries, both unread: every check below is about the flag only if that is really so.
    equals "the flag fixture has both messages waiting" \
      "$(jsonnum "$(fl48get "inbox?id=$fl48b&all=1&json=1&token=$TOKEN")" matching)" "2"
    if [ -n "$fl48t1" ] && [ -n "$fl48t2" ] && [ "$fl48t1" != "$fl48t2" ]; then
      ok "and they are two separate conversations, so one can be read without the other"
    else
      no "and they are two separate conversations, so one can be read without the other" \
        "thread ids [$(snip "$fl48t1")] and [$(snip "$fl48t2")]"
    fi
    # `all=0` on the ack names one thread; `all` is tested first, so reading `all=0` as "on" marked
    # the whole inbox read - and said so, which is how a caller could see it happen.
    fl48ack="$(fl48 ack --data-urlencode "id=$fl48b" --data-urlencode "all=0" \
      --data-urlencode "thread=$fl48t1")"
    equals "an ack for one thread with all=0 acks that thread and no other" \
      "$fl48ack" "ok acked 1 for $fl48b"
    equals "so the second thread is still unread" \
      "$(jsonnum "$(fl48get "inbox?id=$fl48b&json=1&token=$TOKEN")" matching)" "1"
    # The unread inbox is what the default answers, and `all=0` is a spelling of it - not of "all".
    equals "all=0 does not include the mail that was read" \
      "$(jsonnum "$(fl48get "inbox?id=$fl48b&all=0&json=1&token=$TOKEN")" matching)" "1"
    equals "while all=1 still includes it" \
      "$(jsonnum "$(fl48get "inbox?id=$fl48b&all=1&json=1&token=$TOKEN")" matching)" "2"
    # `json=0` asks for the human answer, and gets it.
    fl48prose="$(fl48get "inbox?id=$fl48b&all=1&json=0&token=$TOKEN")"
    contains "json=0 answers the text listing" "$fl48prose" "inbox for $fl48b"
    lacks "and not the json one" "$fl48prose" '"matching"'
  else
    no "the flag fixture started" "no answer on $fl48base"
  fi
  kill "$fl48pid" 2>/dev/null
  wait "$fl48pid" 2>/dev/null
  rm -f "$fl48db" "$fl48db-wal" "$fl48db-shm" "$fl48tok" "$SCRATCH/flags-${RUN}.log"
else
  printf '  skip  the flag reading (needs CHATBOX_BIN)\n'
fi

# ---------------------------------------------------------------------------
# 49. An empty listing asked for as json is json
# `json=1` is the machine-readable contract of every listing, but the two routes that can answer
# "nothing" - /threads and /token - tested for emptiness first and returned a sentence: "no threads
# yet", "no credentials issued". A caller parsing the answer got a syntax error where the truth was
# "there are none", and an empty scoped listing is the state a credential is in most of the time.
# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ]; then
  js49port="${CHATBOX_JSON_PORT:-8777}"
  js49base="http://127.0.0.1:$js49port"
  js49db="$SCRATCH/json-${RUN}.sqlite"
  js49tok="$SCRATCH/json-${RUN}.token"
  rm -f "$js49db" "$js49db-wal" "$js49db-shm"
  printf '%s\n' "$TOKEN" > "$js49tok"
  chmod 600 "$js49tok" 2>/dev/null
  "$CHATBOX_BIN" --port "$js49port" --db "$js49db" --token-file "$js49tok" \
    > "$SCRATCH/json-${RUN}.log" 2>&1 &
  js49pid=$!
  js49ready=0
  for _ in $(seq 1 50); do
    if curl -fsS --max-time 2 "$js49base/health?token=$TOKEN" >/dev/null 2>&1; then js49ready=1; break; fi
    sleep 0.2
  done
  if [ "$js49ready" = 1 ]; then
    js49() { _jp="$1"; shift; curl -sS --max-time 10 -G -X POST --data-urlencode "token=$TOKEN" "$js49base/$_jp" "$@"; }
    js49get() { curl -sS --max-time 10 "$js49base/$1"; }

    # A board with nothing on it at all: the empty answer is still the machine-readable one.
    js49_threads="$(js49get "threads?json=1&token=$TOKEN")"
    contains "an empty thread listing asked for as json is an object" "$js49_threads" '"threads"'
    equals "with nothing matched" "$(jsonnum "$js49_threads" matching)" "0"
    lacks "and not the sentence a human would read" "$js49_threads" "no threads"
    js49_tokens="$(js49get "token?json=1&token=$TOKEN")"
    contains "an empty credential listing asked for as json is an object" "$js49_tokens" '"tokens"'
    lacks "and not the sentence either" "$js49_tokens" "no credentials"
    # The prose forms are unchanged: this fix is about which answer wins, not about what a human is
    # told when there is nothing to show.
    contains "while the text thread listing is still text" "$(js49get "threads?token=$TOKEN")" "no threads yet"
    contains "and the text credential listing is still text" "$(js49get "token?token=$TOKEN")" "no credentials issued"

    # A board with a conversation on it, read by a credential scoped to a machine that is in none:
    # the listing is empty for a reason, and the answer for it is still JSON.
    js49a="it-$RUN-js-a"
    js49b="it-$RUN-js-b"
    for _id in "$js49a" "$js49b"; do
      js49 register --data-urlencode "id=$_id" --data-urlencode "node=n-js49" >/dev/null
    done
    js49_sent="$(js49 message --data-urlencode "from=$js49a" --data-urlencode "to=$js49b" \
      --data-urlencode "body=js-$RUN")"
    equals "the json fixture has a conversation the scoped caller is not in" \
      "$(jsonnum "$(js49get "threads?json=1&token=$TOKEN")" matching)" "1"
    contains "so the conversation is really there to be hidden" "$js49_sent" "ok posted"
    js49_issued="$(js49 token --data-urlencode "node=n-js49-stranger" --data-urlencode "namespaces=*")"
    js49_secret="$(field "$js49_issued" secret)"
    if [ -n "$js49_secret" ]; then
      js49_scoped="$(curl -sS --max-time 10 -H "Authorization: Bearer $js49_secret" "$js49base/threads?json=1")"
      contains "a scoped listing with nothing to show is an object" "$js49_scoped" '"threads"'
      equals "with nothing matched, not a parse error" "$(jsonnum "$js49_scoped" matching)" "0"
      lacks "and no prose where json was asked for" "$js49_scoped" "no threads"
      js49 revoke --data-urlencode "id=$(field "$js49_issued" id)" >/dev/null
    else
      no "a scoped credential was issued for the json fixture" "$(snip "$js49_issued")"
    fi
  else
    no "the json fixture started" "no answer on $js49base"
  fi
  kill "$js49pid" 2>/dev/null
  wait "$js49pid" 2>/dev/null
  rm -f "$js49db" "$js49db-wal" "$js49db-shm" "$js49tok" "$SCRATCH/json-${RUN}.log"
else
  printf '  skip  the empty json listings (needs CHATBOX_BIN)\n'
fi

# ---------------------------------------------------------------------------
# 50. The history is not world-readable
# Every file this process creates is message history - the database, the write-ahead log beside it,
# and a `--backup` copy - and all three were created under the inherited umask (022 on most
# machines), i.e. readable by every other user on the host. The umask is now 077, and a database that
# was already there under a looser mode is tightened rather than inherited.
# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ]; then
  md50port="${CHATBOX_MODE_PORT:-8776}"
  md50base="http://127.0.0.1:$md50port"
  md50db="$SCRATCH/mode-${RUN}.sqlite"
  md50copy="$SCRATCH/mode-${RUN}.copy.sqlite"
  md50tok="$SCRATCH/mode-${RUN}.token"
  md50log1="$SCRATCH/mode-${RUN}.log"
  md50log2="$SCRATCH/mode-${RUN}.log2"
  if [ "$(uname -s)" = "Darwin" ]; then
    md50_mode() { stat -f '%Lp' "$1" 2>/dev/null || printf '?'; }
  else
    md50_mode() { stat -c '%a' "$1" 2>/dev/null || printf '?'; }
  fi
  rm -f "$md50db" "$md50db-wal" "$md50db-shm" "$md50copy" "$md50tok"
  printf '%s\n' "$TOKEN" > "$md50tok"
  chmod 600 "$md50tok" 2>/dev/null
  "$CHATBOX_BIN" --port "$md50port" --db "$md50db" --token-file "$md50tok" > "$md50log1" 2>&1 &
  md50pid=$!
  md50ready=0
  for _ in $(seq 1 50); do
    if curl -fsS --max-time 2 "$md50base/health?token=$TOKEN" >/dev/null 2>&1; then md50ready=1; break; fi
    sleep 0.2
  done
  if [ "$md50ready" = 1 ]; then
    # One write, so that the write-ahead log exists to be looked at.
    curl -sS --max-time 10 -G -X POST --data-urlencode "token=$TOKEN" \
      --data-urlencode "id=it-$RUN-md" --data-urlencode "node=n-md" "$md50base/register" >/dev/null
    equals "a board the server creates is for its owner only" "$(md50_mode "$md50db")" "600"
    if [ -f "$md50db-wal" ]; then
      equals "and so is the write-ahead log beside it" "$(md50_mode "$md50db-wal")" "600"
    else
      no "and so is the write-ahead log beside it" "there is no $md50db-wal to check"
    fi
  else
    no "the file-mode fixture started" "no answer on port $md50port"
  fi
  kill "$md50pid" 2>/dev/null
  wait "$md50pid" 2>/dev/null

  # A database created earlier, under the old default, is tightened rather than inherited.
  if [ -f "$md50db" ]; then
    chmod 644 "$md50db"
    equals "the fixture really starts from a loosened database" "$(md50_mode "$md50db")" "644"
    "$CHATBOX_BIN" --port "$md50port" --db "$md50db" --token-file "$md50tok" > "$md50log2" 2>&1 &
    md50pid2=$!
    md50ready2=0
    for _ in $(seq 1 50); do
      if curl -fsS --max-time 2 "$md50base/health?token=$TOKEN" >/dev/null 2>&1; then md50ready2=1; break; fi
      sleep 0.2
    done
    if [ "$md50ready2" = 1 ]; then
      equals "a board that was already there is tightened, not inherited" "$(md50_mode "$md50db")" "600"
      contains "and the start says so in the log" "$(cat "$md50log2")" \
        "tightened $md50db from mode 644 to 600"
    else
      no "the loosened-database fixture restarted" "no answer on port $md50port"
    fi
    kill "$md50pid2" 2>/dev/null
    wait "$md50pid2" 2>/dev/null
  else
    no "there is a database to loosen" "no $md50db"
  fi

  # A backup is the same history in another file, and it is written by VACUUM INTO rather than by
  # SQLite's own file creation, so the umask is what has to cover it.
  rm -f "$md50copy"
  md50_backup="$("$CHATBOX_BIN" --db "$md50db" --backup "$md50copy" 2>&1)"; md50_brc=$?
  if [ "$md50_brc" -eq 0 ] && [ -f "$md50copy" ]; then
    equals "a backup copy is not world-readable either" "$(md50_mode "$md50copy")" "600"
  else
    no "a backup copy is not world-readable either" "exit=$md50_brc: $(snip "$md50_backup")"
  fi
  rm -f "$md50db" "$md50db-wal" "$md50db-shm" "$md50copy" "$md50tok" "$md50log1" "$md50log2"
else
  printf '  skip  the file modes (needs CHATBOX_BIN)\n'
fi

# ---------------------------------------------------------------------------
# 51. The client's credential is not an argument, the environment beats the config file, and every
#     value in a query is encoded
# The client put the token in the query of every read and the body of every write, so `ps` showed it
# to every other user on the machine; it sourced ~/.chatbox *over* the environment, so
# `CHATBOX_URL=http://staging chatbox say` posted to the file's board instead, with no warning; it
# pasted ids into the URL raw, so an id with a space or an `&` - which the server accepts - either
# made curl refuse the whole URL ("Malformed input", exit 3) or quietly turned the rest of the query
# into a different request; and it parsed `--all` for every command but never sent it on `ack`, so
# the one documented way to clear an inbox answered "pass message=<id>, thread=<id> or all=1".
# ---------------------------------------------------------------------------
if [ -f "$CLI" ]; then
  cl51dir="$SCRATCH/client-req-${RUN}"
  cl51rec="$SCRATCH/client-req-args-${RUN}.txt"
  cl51cfg="$SCRATCH/client-req-cfg-${RUN}"
  cl51authcopy="$SCRATCH/client-req-auth-${RUN}.txt"
  rm -rf "$cl51dir" "$cl51authcopy"
  mkdir -p "$cl51dir"
  cat > "$cl51dir/curl" <<'STUB'
#!/bin/sh
# A stand-in for curl. It records what it was asked to do, and it looks at any config file it was
# handed (`-K`): the one thing that must never be an argument is the credential.
printf 'ARGV %s\n' "$*" >> "$CL51_REC"
_prev=""
for _a in "$@"; do
  if [ "$_prev" = "-K" ]; then
    printf 'AUTHFILE %s mode=%s\n' "$_a" \
      "$(stat -f '%Lp' "$_a" 2>/dev/null || stat -c '%a' "$_a" 2>/dev/null)" >> "$CL51_REC"
    cp "$_a" "$CL51_AUTHCOPY" 2>/dev/null
  fi
  _prev="$_a"
done
exit 7
STUB
  chmod +x "$cl51dir/curl"
  : > "$cl51rec"
  cl51_secret="tk-51-${RUN}-secret"
  printf 'export CHATBOX_URL=http://from-file.invalid:1\nexport CHATBOX_TOKEN=tk-from-file\n' > "$cl51cfg"
  cl51_rc=0
  CHATBOX_URL="http://wanted.invalid:2" CHATBOX_TOKEN="$cl51_secret" \
    CHATBOX_CONFIG="$cl51cfg" CL51_REC="$cl51rec" CL51_AUTHCOPY="$cl51authcopy" \
    PATH="$cl51dir:$PATH" sh "$CLI" inbox --id "a b&c" \
    > "$SCRATCH/client-req-${RUN}.log" 2>&1 || cl51_rc=$?
  equals "the stub transport fails the way an unreachable server does" "$cl51_rc" "7"
  contains "the board named in the environment is the one used" "$(cat "$cl51rec")" \
    "http://wanted.invalid:2/inbox"
  lacks "and the board named in the config file is not used at all" "$(cat "$cl51rec")" "from-file.invalid"
  contains "an id with a space and an ampersand is percent-encoded" "$(cat "$cl51rec")" "id=a%20b%26c"
  contains "the credential travels in a curl config file" "$(cat "$cl51rec")" "ARGV -K "
  lacks "so no argument carries it" "$(grep '^ARGV' "$cl51rec")" "$cl51_secret"
  contains "the config file is readable only by its owner" "$(grep '^AUTHFILE' "$cl51rec")" "mode=600"
  contains "and carries the bearer header rather than a query parameter" "$(cat "$cl51authcopy")" \
    "Authorization: Bearer $cl51_secret"
  cl51_authpath="$(sed -n 's/^AUTHFILE \([^ ]*\) .*/\1/p' "$cl51rec" | head -1)"
  if [ -n "$cl51_authpath" ] && [ ! -f "$cl51_authpath" ]; then
    ok "and it is removed when the client exits"
  else
    no "and it is removed when the client exits" "still there: $(snip "$cl51_authpath")"
  fi
  rm -rf "$cl51dir" "$cl51authcopy"

  # The same three properties against a real board: an id the server accepts, with a space and an
  # `&` in it, is addressable; two unread messages can be cleared with `ack --all`; and the ack
  # without any of message/thread/all still refuses, so the fix did not make every ack global.
  cl51port="${CHATBOX_CLIENT_PORT:-8774}"
  cl51base="http://127.0.0.1:$cl51port"
  cl51db="$SCRATCH/client-req-${RUN}.sqlite"
  cl51tok="$SCRATCH/client-req-${RUN}.token"
  rm -f "$cl51db" "$cl51db-wal" "$cl51db-shm"
  printf '%s\n' "$TOKEN" > "$cl51tok"
  chmod 600 "$cl51tok" 2>/dev/null
  "$CHATBOX_BIN" --port "$cl51port" --db "$cl51db" --token-file "$cl51tok" \
    > "$SCRATCH/client-req-${RUN}.server.log" 2>&1 &
  cl51pid=$!
  cl51ready=0
  for _ in $(seq 1 50); do
    if curl -fsS --max-time 2 "$cl51base/health?token=$TOKEN" >/dev/null 2>&1; then cl51ready=1; break; fi
    sleep 0.2
  done
  if [ "$cl51ready" = 1 ]; then
    cl51odd="it cli $RUN a&b"
    cli51() { CHATBOX_CONFIG=/nonexistent CHATBOX_URL="$cl51base" CHATBOX_TOKEN="$TOKEN" sh "$CLI" "$@"; }
    cli51 register --id "$cl51odd" --node n-cli51 >/dev/null 2>&1
    cli51 register --id "it-cli-$RUN-b" --node n-cli51 >/dev/null 2>&1
    cli51 say --from "it-cli-$RUN-b" --to "$cl51odd" --body "cli-one-$RUN" >/dev/null 2>&1
    cli51 say --from "it-cli-$RUN-b" --to "$cl51odd" --body "cli-two-$RUN" >/dev/null 2>&1
    cl51_inbox="$(cli51 inbox --id "$cl51odd" 2>&1)"; cl51_irc=$?
    equals "a real inbox for an id with a space and an ampersand succeeds" "$cl51_irc" "0"
    contains "and the messages are in it" "$cl51_inbox" "cli-two-$RUN"
    cl51_ack="$(cli51 ack --id "$cl51odd" --all 2>&1)"; cl51_arc=$?
    equals "ack --all succeeds" "$cl51_arc" "0"
    contains "and marks the whole inbox read" "$cl51_ack" "ok acked 2"
    contains "so the inbox is empty afterwards" "$(cli51 inbox --id "$cl51odd" 2>&1)" "empty"
    cl51_bad="$(cli51 ack --id "$cl51odd" 2>&1)"; cl51_brc=$?
    equals "while an ack with no message, thread or all still refuses" "$cl51_brc" "2"
    contains "and names what is missing" "$cl51_bad" "pass message=<id>, thread=<id> or all=1"
  else
    no "the client request-path fixture started" "no answer on $cl51base"
  fi
  kill "$cl51pid" 2>/dev/null
  wait "$cl51pid" 2>/dev/null
  rm -f "$cl51db" "$cl51db-wal" "$cl51db-shm" "$cl51tok" "$SCRATCH/client-req-${RUN}.log" \
        "$SCRATCH/client-req-${RUN}.server.log" "$SCRATCH/client-req-args-${RUN}.txt" \
        "$SCRATCH/client-req-cfg-${RUN}"
else
  printf '  skip  the client request path (set CHATBOX_CLI or keep chatbox-cli.sh in the tree)\n'
fi

# ---------------------------------------------------------------------------
# 52. The client is held to the standard's shell checks
# Two shellcheck findings were defects, not opinions: a variable used as a printf *format* (a value
# containing `%` is reinterpreted), and a temporary file the same shell wrote and then read through
# (`rm -f` on the error path, which an interrupt skips). Both are fixed in the shape of the code,
# not waived, and this is the pin: the client parses under `sh -n` and `dash -n`, the two shapes are
# absent, and `shellcheck -s sh` has nothing to say about it except the one documented dynamic
# `source` (SC1090) that cannot be avoided - the client is *meant* to source the operator's config
# file, and its path is a variable.
# ---------------------------------------------------------------------------
if [ -f "$CLI" ]; then
  if sh -n "$CLI" >/dev/null 2>&1; then
    ok "the client parses under sh -n"
  else
    no "the client parses under sh -n" "$(sh -n "$CLI" 2>&1 | head -2 | tr '\n' '~')"
  fi
  if command -v dash >/dev/null 2>&1; then
    if dash -n "$CLI" >/dev/null 2>&1; then
      ok "and under dash -n"
    else
      no "and under dash -n" "$(dash -n "$CLI" 2>&1 | head -2 | tr '\n' '~')"
    fi
  else
    printf '  skip  the dash parse (needs dash)\n'
  fi
  lacks "no printf takes its format from a variable" "$(cat "$CLI")" "printf \"\$_fc_seq\"" 
  lacks "and nothing writes a temporary file it then reads through" "$(cat "$CLI")" "chatbox-canon."
  if command -v shellcheck >/dev/null 2>&1; then
    # No filter: the client's one remaining finding was the dynamic `source` of the operator's own
    # config file, and task #0016 documents that with a `# shellcheck source=` directive rather than
    # excluding the rule here. A new finding of any rule fails this check.
    cl52_sc="$(shellcheck -s sh -f gcc "$CLI" 2>&1 | grep -v '^$')"
    if [ -z "$cl52_sc" ]; then
      ok "shellcheck has nothing to say about the client"
    else
      no "shellcheck has nothing to say about the client" \
        "$(printf '%s' "$cl52_sc" | head -3 | tr '\n' '~')"
    fi
  else
    printf '  skip  shellcheck on the client (needs shellcheck)\n'
  fi
else
  printf '  skip  the client lint (set CHATBOX_CLI or keep chatbox-cli.sh in the tree)\n'
fi

# ---------------------------------------------------------------------------
# 53. No UTF-8 conversion in the sources is force-unwrapped
# `String.data(using:)` returns nil for an encoding it cannot represent, and the code carried 86
# `...data(using: .utf8)!` sites - every log line and every refusal, in both binaries. UTF-8 is
# total, so `Data(s.utf8)` has nothing to unwrap and no `!` to leave behind, and the compiler proves
# it at every site. The check reads the source *under test* when the harness names one: a compiled
# mutant and the base binary are indistinguishable here - the shape exists only in the text - so the
# matrix passes the mutated source in CHATBOX_SRC. Without it the tree's own two sources are checked.
# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_SRC:-}" ]; then
  # A caller (the mutation harness) may name one file, several, or a glob.
  un53_files=""
  for _f in ${CHATBOX_SRC}; do
    case "$_f" in
      *.swift) [ -f "$_f" ] && un53_files="$un53_files $_f" ;;
    esac
  done
else
  un53_root="$(dirname "$CLI")"
  un53_files=""
  for _f in "$un53_root"/src/chatbox/*.swift "$un53_root"/src/chatbox-mcp/*.swift; do
    [ -f "$_f" ] && un53_files="$un53_files $_f"
  done
fi
if [ -n "$un53_files" ]; then
  un53_total=0
  for _f in $un53_files; do
    un53_total=$((un53_total + $(grep -c 'data(using: .utf8)!' "$_f" 2>/dev/null)))
  done
  equals "no UTF-8 conversion in the source under test is force-unwrapped" "$un53_total" "0"
else
  printf '  skip  the UTF-8 unwrap check (a client mutation: the server source is not under test)\n'
fi

# ---------------------------------------------------------------------------
# 54. The suite is held to the same shell checks as the client
# The shell standard is POSIX sh: `sh -n`, `dash -n` and shellcheck. The suite had thirteen findings.
# Three were not style at all - `${@:2}` is a bash/ksh extension that dash refuses with "Bad
# substitution", so three helpers made the suite non-POSIX; two printf formats came from variables;
# five were `[ -n "$(grep ...)" ]`; one credential variable was never used after being issued and one
# cleanup function was only reachable through its trap. All are fixed in the shape of the code, and
# this is the pin - the file that is running is the file that is checked.
# ---------------------------------------------------------------------------
sc54_fail=""
for _f in $SUITE_SELF; do
  if ! sh -n "$_f" >/dev/null 2>&1; then
    sc54_fail="$_f: $(sh -n "$_f" 2>&1 | head -2 | tr '\n' '~')"
    break
  fi
done
if [ -z "$sc54_fail" ]; then
  ok "the suite parses under sh -n"
else
  no "the suite parses under sh -n" "$sc54_fail"
fi
if command -v dash >/dev/null 2>&1; then
  sc54_fail=""
  for _f in $SUITE_SELF; do
    if ! dash -n "$_f" >/dev/null 2>&1; then
      sc54_fail="$_f: $(dash -n "$_f" 2>&1 | head -2 | tr '\n' '~')"
      break
    fi
  done
  if [ -z "$sc54_fail" ]; then
    ok "and under dash -n, the standard's second shell"
  else
    no "and under dash -n, the standard's second shell" "$sc54_fail"
  fi
else
  printf '  skip  the dash parse of the suite (needs dash)\n'
fi
if command -v shellcheck >/dev/null 2>&1; then
  # The suite is one program split across sourced parts. ShellCheck analyses each file alone, so it
  # cannot see that the entry's variables and the parts' functions are used by each other. The parts
  # are therefore concatenated back into one program for this check - the same text, in the same
  # order the shell runs it - and the entry's `.` lines are dropped so nothing is analysed twice.
  sc54="$(
    {
      sed '/^\. .*SUITE_LIB/d' "$0"
      cat "$SUITE_LIB"/*.sh
    } | shellcheck -s sh -f gcc - 2>&1 | grep -v '^$'
  )"
  if [ -z "$sc54" ]; then
    ok "shellcheck has nothing to say about the suite"
  else
    no "shellcheck has nothing to say about the suite" \
      "$(printf '%s' "$sc54" | head -3 | tr '\n' '~')"
  fi
else
  printf '  skip  shellcheck on the suite (needs shellcheck)\n'
fi

# ---------------------------------------------------------------------------
# 55. A store that cannot be prepared is not served
# `exec` discarded SQLite's result code and message, so a schema statement, a PRAGMA or the
# deliveries backfill could fail while the board still started - answering 500 to every route, or
# running without the WAL the backup story rests on - and the open refusal printed neither the cause
# nor the failing statement. A held write lock is the reproducible case: the backfill and then the
# key migration cannot take it, and the board has to refuse rather than come up half-migrated.
