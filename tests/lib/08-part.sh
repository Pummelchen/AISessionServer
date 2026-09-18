# ---------------------------------------------------------------------------
T19A="it-$RUN-reply-a"
T19B="it-$RUN-reply-b"
REPO_T19="example.test/$RUN/reply"
GHOST_T19=987654321

t19_msgs() { get /health | sed -n 's/^messages: //p'; }
t19_threads() { get /health | sed -n 's/^threads: //p'; }

post /register --data-urlencode "id=$T19A" --data-urlencode "node=node-reply" \
  --data-urlencode "repos=$REPO_T19" >/dev/null
post /register --data-urlencode "id=$T19B" --data-urlencode "node=node-reply" \
  --data-urlencode "repos=$REPO_T19" >/dev/null

opened19="$(post /message --data-urlencode "from=$T19A" --data-urlencode "repo=$REPO_T19" \
  --data-urlencode "subject=reply fixture $RUN" --data-urlencode "body=opened for $RUN")"
T19TID="$(field "$opened19" thread)"
if [ -n "$T19TID" ]; then
  ok "the reply fixture opened its thread"
else
  no "the reply fixture opened its thread" "$(snip "$opened19")"
fi

# The control: the ordinary reply still lands, in the same thread, so the refusals
# below are not simply every reply being refused.
rep19="$(post /message --data-urlencode "from=$T19B" --data-urlencode "thread=$T19TID" \
  --data-urlencode "body=reply for $RUN")"
contains "a reply into an existing thread still posts" "$rep19" "ok posted"
equals "and stays in that thread" "$(field "$rep19" thread)" "$T19TID"
equals "and is routed to the other participant" "$(field "$rep19" delivered_to)" "$T19A"
# reply_to=0 stays the documented spelling of "no reply"; a marker for message 0 would
# be a reply to nothing.
t19_unquoted="$(post /message --data-urlencode "from=$T19B" --data-urlencode "thread=$T19TID" \
  --data-urlencode "reply_to=0" --data-urlencode "body=unquoted for $RUN")"
contains "reply_to=0 is still accepted as no reply" "$t19_unquoted" "ok posted"
lacks "an unquoted reply carries no reply marker" "$(get /thread "id=$T19TID")" "(reply to 0)"
# Read from the store: the renderer skips reply_to=0 anyway, so the view alone would hide a 0
# that had been stored as a reply to message 0.
if [ -n "${CHATBOX_DB:-}" ] && command -v sqlite3 >/dev/null 2>&1; then
  equals "reply_to=0 is stored as no reply, not as a reply to message 0" \
    "$(sqlite3 "$CHATBOX_DB" "select count(*) from messages where id=$(field "$t19_unquoted" message) and reply_to is null;")" "1"
fi
# A blank thread= stays "no thread": the client sends the parameter on every `say`, so
# empty (or whitespace, which the request parser trims) has to mean "absent" or every
# plain send would be refused.
blank19="$(post /message --data-urlencode "from=$T19A" --data-urlencode "thread= " \
  --data-urlencode "body=blank thread for $RUN")"
contains "a blank thread= opens a new thread rather than failing" "$blank19" "ok posted"
if [ "$(field "$blank19" thread)" != "$T19TID" ] && [ -n "$(field "$blank19" thread)" ]; then
  ok "and it is not the thread that was already open"
else
  no "and it is not the thread that was already open" "$(snip "$blank19")"
fi

msgs19="$(t19_msgs)"
threads19="$(t19_threads)"
# An empty count would make every comparison below hold for the wrong reason.
if [ -n "$msgs19" ] && [ -n "$threads19" ]; then
  ok "the fixture counts are readable"
else
  no "the fixture counts are readable" "messages=[$msgs19] threads=[$threads19]"
fi

# A thread that is not there is refused, and the answer names it.
equals "replying into a thread that does not exist is refused" \
  "$(status_post /message --data-urlencode "from=$T19B" --data-urlencode "thread=$GHOST_T19" \
      --data-urlencode "body=into the void")" "404"
contains "the refusal names the thread it could not find" \
  "$(post /message --data-urlencode "from=$T19B" --data-urlencode "thread=$GHOST_T19" \
      --data-urlencode "body=into the void")" "no thread $GHOST_T19"
# An id the server cannot resolve is a client error, not a silent new thread.
equals "a non-numeric thread is refused" \
  "$(status_post /message --data-urlencode "from=$T19B" --data-urlencode "thread=not-a-number" \
      --data-urlencode "body=x")" "400"
equals "thread=0 is refused rather than opened as a new thread" \
  "$(status_post /message --data-urlencode "from=$T19B" --data-urlencode "thread=0" \
      --data-urlencode "body=x")" "400"
equals "a negative thread is refused" \
  "$(status_post /message --data-urlencode "from=$T19B" --data-urlencode "thread=-3" \
      --data-urlencode "body=x")" "400"
equals "a thread id that overflows an Int64 is refused" \
  "$(status_post /message --data-urlencode "from=$T19B" \
      --data-urlencode "thread=99999999999999999999" --data-urlencode "body=x")" "400"
# The largest id the parser accepts is a *usable* id, not a parse error: nothing has it,
# so the answer is the same 404 any other absent thread gets.
equals "the largest usable thread id is answered, not refused as malformed" \
  "$(status_post /message --data-urlencode "from=$T19B" \
      --data-urlencode "thread=9223372036854775807" --data-urlencode "body=x")" "404"
# reply_to is informational, but it is stored as an integer: a value that is not an id
# used to be dropped to 0 without a word, so the sender was never told.
equals "a reply_to that is not a message id is refused" \
  "$(status_post /message --data-urlencode "from=$T19B" --data-urlencode "thread=$T19TID" \
      --data-urlencode "reply_to=nope" --data-urlencode "body=x")" "400"
# The refusal happens with the other parameter checks, before a thread is opened, so the
# same bad value with no thread= must not leave an empty thread behind on its way out —
# which is what the count check below is looking at.
equals "a bad reply_to is refused before a thread is opened for it" \
  "$(status_post /message --data-urlencode "from=$T19B" --data-urlencode "reply_to=nope" \
      --data-urlencode "body=x")" "400"

# None of that wrote anything.
equals "the refusals stored no message" "$(t19_msgs)" "$msgs19"
equals "the refusals opened no thread" "$(t19_threads)" "$threads19"
equals "the thread a refusal named is still unreadable" "$(code_of /thread "id=$GHOST_T19")" "404"
# ... and an accepted post does move both counts, so the two checks above are known to
# be able to see a write, and the "writes nothing" guarantee is not a server that
# quietly drops every message.
fresh19="$(post /message --data-urlencode "from=$T19A" --data-urlencode "body=new thread $RUN")"
contains "a message without thread= still opens a new thread" "$fresh19" "ok posted"
equals "an accepted post moves the message count" "$(t19_msgs)" "$((msgs19 + 1))"
equals "and opens exactly one thread" "$(t19_threads)" "$((threads19 + 1))"

# The liveness stamp is the one write a refusal could still make, and the API does not
# report it at this resolution, so read it from the store. A refused post must not even
# register the sender as having been here.
if [ -n "${CHATBOX_DB:-}" ] && [ -f "$CHATBOX_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  t19_old="2001-01-01T00:00:00Z"
  sqlite3 "$CHATBOX_DB" "UPDATE agents SET last_seen='$t19_old' WHERE id='$T19B';" >/dev/null 2>&1
  equals "the liveness fixture was backdated" \
    "$(sqlite3 "$CHATBOX_DB" "SELECT last_seen FROM agents WHERE id='$T19B';")" "$t19_old"
  # The status is asserted in the same step, so an unreachable server cannot make the
  # "did not touch it" comparison below pass for the wrong reason.
  equals "the refusal that must not touch liveness is a refusal" \
    "$(status_post /message --data-urlencode "from=$T19B" --data-urlencode "thread=$GHOST_T19" \
        --data-urlencode "body=refused")" "404"
  equals "a refused reply does not even mark the sender as seen" \
    "$(sqlite3 "$CHATBOX_DB" "SELECT last_seen FROM agents WHERE id='$T19B';")" "$t19_old"
  t19_ok="$(post /message --data-urlencode "from=$T19B" --data-urlencode "thread=$T19TID" \
    --data-urlencode "body=accepted")"
  contains "the post that must refresh liveness is accepted" "$t19_ok" "ok posted"
  if [ "$(sqlite3 "$CHATBOX_DB" "SELECT last_seen FROM agents WHERE id='$T19B';")" != "$t19_old" ]; then
    ok "an accepted reply does refresh it"
  else
    no "an accepted reply does refresh it" "still $t19_old"
  fi
else
  printf '  skip  the liveness stamp either side of a refusal (needs CHATBOX_DB and sqlite3)\n'
fi

# ---------------------------------------------------------------------------
# 21. A backup you have not read is not a backup (TRK-25)
# The SQLite file is the service. The trap that produced two 4 KB "backups" on node1 is a copy of
# the main file while the committed rows are still in `-wal`: the copy is a valid-looking empty
# database. `--backup` copies a *live* board with `VACUUM INTO`, which folds the WAL in, and then
# verifies the copy against the board it came from — because a structurally valid copy can still
# be missing rows, and only a comparison can see that. Both ends are exercised: a real backup
# passes, and every copy that is not one — empty, table-less, truncated, text, stale, or created
# by hand from the main file — fails loudly and non-zero.
