if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ]; then
  bigport="${CHATBOX_MAX_PORT:-8793}"
  mbtok="$SCRATCH/mb-${RUN}.token"
  printf '%s\n' "$TOKEN" > "$mbtok"
  "$CHATBOX_BIN" --port "$bigport" --db "$SCRATCH/mb-${RUN}.sqlite" --token-file "$mbtok" \
    --max-body 65536 > "$SCRATCH/mb-${RUN}.log" 2>&1 &
  mbpid=$!
  mbready=0
  # As in 13b: the pid and the board's own banner are what make this the server this section started,
  # so an unrelated listener on 8793 cannot answer the probe on its behalf.
  for _ in $(seq 1 50); do
    if kill -0 "$mbpid" 2>/dev/null \
       && grep -q "chatbox listening on port $bigport" "$SCRATCH/mb-${RUN}.log" 2>/dev/null \
       && curl -fsS "http://127.0.0.1:$bigport/health?token=$TOKEN" >/dev/null 2>&1; then mbready=1; break; fi
    sleep 0.2
  done
  if [ "$mbready" = 1 ]; then
    contains "a raised cap is reported by health" \
      "$(curl -sS --max-time 5 "http://127.0.0.1:$bigport/health?token=$TOKEN")" "max request: 65536 bytes"
    equals "a raised --max-body accepts what the default refused" \
      "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -G -X POST \
          --data-urlencode "token=$TOKEN" "http://127.0.0.1:$bigport/message" \
          --data-urlencode "from=$A" --data-urlencode "to=$B" --data-urlencode "body=$bigbody")" "200"
  else
    no "the raised-cap server started" "no answer on $bigport: $(head -1 "$SCRATCH/mb-${RUN}.log")"
  fi
  kill "$mbpid" 2>/dev/null
  wait "$mbpid" 2>/dev/null

  # A cap too small to hold a request line and its headers would refuse everything, which
  # reads as a broken server rather than a configured one, so it is refused at startup —
  # and the check is bounded, because a server that wrongly started would listen for ever.
  mb_refuses() { # label, then the arguments to pass
    _lbl="$1"; shift
    "$CHATBOX_BIN" --port "$((bigport + 1))" --db "$SCRATCH/mbr-${RUN}.sqlite" \
      --token-file "$mbtok" "$@" > "$SCRATCH/mbr-${RUN}.log" 2>&1 &
    _mrpid=$!
    _mrw=0
    while [ "$_mrw" -lt 30 ] && kill -0 "$_mrpid" 2>/dev/null; do
      sleep 0.1
      _mrw=$((_mrw + 1))
    done
    if kill -0 "$_mrpid" 2>/dev/null; then
      no "$_lbl" "it started anyway: $(head -1 "$SCRATCH/mbr-${RUN}.log")"
      kill "$_mrpid" 2>/dev/null
      wait "$_mrpid" 2>/dev/null
    else
      wait "$_mrpid" 2>/dev/null; _mrrc=$?
      # Exit 2 *and* a diagnostic naming the flag: an unrelated exit-2 path — an unknown
      # flag elsewhere on the line, a bad --stale-after — would otherwise pass as a refusal.
      if [ "$_mrrc" -eq 2 ] && grep -q -- "--max-body" "$SCRATCH/mbr-${RUN}.log"; then
        ok "$_lbl"
      else
        no "$_lbl" "exit=$_mrrc: $(head -1 "$SCRATCH/mbr-${RUN}.log")"
      fi
    fi
  }
  mb_refuses "a cap smaller than a request is refused" --max-body 100
  mb_refuses "a cap that is not a number is refused" --max-body abc
  # The cap is what bounds memory, so a cap that is itself unbounded is not a cap.
  mb_refuses "a cap above the ceiling is refused" --max-body 4194305
  # Every flag here takes a value, so a trailing one is a mistake rather than a default.
  mb_refuses "a flag with no value is refused" --max-body
else
  printf '  skip  configurable size cap (set CHATBOX_BIN to the built server)\n'
fi

# ---------------------------------------------------------------------------
# 17. Repo key normalisation (TRK-09)
# A key that arrived by plain `curl` used to bypass the client's rule entirely, so
# `git@github.com:acme/x.git` and `https://github.com/acme/x` were two repositories and mail
# split between them. The server now applies the identical rule — on register, on send, and
# when filtering threads — and folds the whole key rather than the host alone, because one
# canonical form is the point and a client cannot fold what the server will not.
# ---------------------------------------------------------------------------
KN="it-$RUN-norm"
nbase="example.test/$RUN/norm"
# Three spellings of one repository, registered by three sessions. The path case differs
# too, which host-only folding would have left as a second key.
post /register --data-urlencode "id=$KN-1" --data-urlencode "node=node-norm" \
  --data-urlencode "repo=git@example.test:$RUN/norm.git" >/dev/null
post /register --data-urlencode "id=$KN-2" --data-urlencode "node=node-norm" \
  --data-urlencode "repo=https://Example.Test/$RUN/norm/" >/dev/null
post /register --data-urlencode "id=$KN-3" --data-urlencode "node=node-norm" \
  --data-urlencode "repo=ssh://git@example.test:2222/$RUN/NORM" >/dev/null
norm_peers="$(get /peers)"
# Per agent, not a substring count: three agents each storing a *different* key that happens to
# contain the canonical one would satisfy a count.
agent_repos() { # peers text, id
  printf '%s\n' "$1" | awk -v id="$2" '$0 ~ "^" id " " {seen=1; next} seen && /^  repos: / {sub(/^  repos: /, ""); print; exit}'
}
for _n in 1 2 3; do
  equals "spelling $_n stored the one canonical key" "$(agent_repos "$norm_peers" "$KN-$_n")" "$nbase"
done
lacks "no scheme or userinfo reached the board" "$norm_peers" "git@example.test"
lacks "no port survived into a key" "$norm_peers" "2222"

# A fourth spelling reaches all three owners, which is the whole reason for the rule.
norm_send="$(post /message --data-urlencode "from=$A" \
  --data-urlencode "repo=git@Example.Test:$RUN/NORM.git" --data-urlencode "body=norm $RUN")"
for _n in 1 2 3; do
  contains "a message sent by spelling reaches owner $_n" "$norm_send" "$KN-$_n"
done
# A query string and a fragment are URL syntax, not part of the key.
contains "a query and fragment are dropped from a key" \
  "$(post /message --data-urlencode "from=$A" \
      --data-urlencode "repo=https://example.test/$RUN/norm?ref=main#readme" \
      --data-urlencode "body=q $RUN")" "$KN-1"
# The filter is a key too, so it accepts a spelling rather than silently matching nothing.
contains "threads can be filtered by any spelling" \
  "$(get /threads "repo=GIT@Example.Test:$RUN/NORM.git")" "$nbase"

# The rule itself, input by input. Three spellings agreeing could be luck; a table cannot be.
# The register response echoes the key that was stored, so this needs no database handle.
norm_case() { # input, expected canonical form
  equals "the rule maps '$1' to '$2'" \
    "$(field "$(post /register --data-urlencode "id=it-$RUN-nc" --data-urlencode "node=node-norm" \
        --data-urlencode "repo=$1")" repos)" "$2"
}
norm_case 'git@example.test:Acme/Thing.git' 'example.test/acme/thing'
norm_case 'https://example.test/acme/thing/' 'example.test/acme/thing'
norm_case 'ssh://git@example.test:2222/acme/thing' 'example.test/acme/thing'
norm_case 'https://user:pw@example.test/acme/thing' 'example.test/acme/thing'
norm_case 'https://example.test/group/@scope/thing' 'example.test/group/@scope/thing'
norm_case 'git@lab:acme/thing' 'lab/acme/thing'
norm_case 'HTTPS://Example.Test/Acme/Thing' 'example.test/acme/thing'
norm_case 'example.test/acme/thing?ref=main#readme' 'example.test/acme/thing'
norm_case 'example.test/acme/thing////' 'example.test/acme/thing'
norm_case 'example.test/acme/.git' 'example.test/acme'
norm_case 'example.test/acme/thing.git.git' 'example.test/acme/thing'
# The suffix is matched after folding, so a capitalised `.GIT` is stripped in the same pass —
# otherwise the result would still change on a second canonicalisation.
norm_case 'example.test/acme/thing.GIT' 'example.test/acme/thing'
norm_case 'HTTPS://Example.Test/Acme/Thing.GIT/' 'example.test/acme/thing'

# A namespace is a key, so it is canonical too — written in any case, and checked
# canonically, which is what lets a credential issued before this rule still work.
norm_tok="$(post /token --data-urlencode "node=node-norm-ns" \
  --data-urlencode "namespaces=Example.Test/$RUN/*")"
norm_secret="$(field "$norm_tok" secret)"
contains "a mixed-case namespace is stored canonical" "$(get /token)" "example.test/$RUN/*"
if [ -n "$norm_secret" ]; then
  contains "a scoped credential may claim the canonical key" \
    "$(scoped_post /register "$norm_secret" --data-urlencode "id=$KN-4" \
        --data-urlencode "node=node-norm-ns" --data-urlencode "repo=git@example.test:$RUN/norm.git")" \
    "ok registered"
  contains "and may not claim outside it" \
    "$(scoped_post /register "$norm_secret" --data-urlencode "id=$KN-4" \
        --data-urlencode "node=node-norm-ns" --data-urlencode "repo=example.test/other/thing")" \
    "may not claim"
else
  no "the namespace fixture issued a credential" "$(printf '%s' "$norm_tok" | head -1)"
fi
# An exact-key namespace takes the other branch, and it is the one that stores the key
# itself rather than a prefix — so it needs its own fixture or that branch is untested.
exact_tok="$(post /token --data-urlencode "node=node-norm-exact" \
  --data-urlencode "namespaces=Example.Test/$RUN/Exact")"
exact_secret="$(field "$exact_tok" secret)"
contains "an exact namespace is stored canonical" "$(get /token)" "example.test/$RUN/exact"
if [ -n "$exact_secret" ]; then
  contains "an exact namespace allows the canonical key" \
    "$(scoped_post /register "$exact_secret" --data-urlencode "id=$KN-6" \
        --data-urlencode "node=node-norm-exact" \
        --data-urlencode "repo=GIT@example.test:$RUN/EXACT.git")" "ok registered"
  contains "and not a key that merely starts with it" \
    "$(scoped_post /register "$exact_secret" --data-urlencode "id=$KN-6" \
        --data-urlencode "node=node-norm-exact" --data-urlencode "repo=example.test/$RUN/exactly")" \
    "may not claim"
else
  no "the exact-namespace fixture issued a credential" "$(printf '%s' "$exact_tok" | head -1)"
fi

# A host-wide namespace (`host/*`) was valid before the canonical rule, so it has to stay
# valid — otherwise every credential issued that way stops working on upgrade.
hostns="norm-$RUN.test"
host_tok="$(post /token --data-urlencode "node=node-host-ns" --data-urlencode "namespaces=$hostns/*")"
host_secret="$(field "$host_tok" secret)"
if [ -n "$host_secret" ]; then
  contains "a host-wide namespace still allows a key on that host" \
    "$(scoped_post /register "$host_secret" --data-urlencode "id=$KN-7" \
        --data-urlencode "node=node-host-ns" --data-urlencode "repo=$hostns/anything/at/all")" "ok registered"
  contains "and nothing on another host" \
    "$(scoped_post /register "$host_secret" --data-urlencode "id=$KN-7" \
        --data-urlencode "node=node-host-ns" --data-urlencode "repo=other.test/anything")" "may not claim"
else
  no "the host-wide namespace fixture issued a credential" "$(printf '%s' "$host_tok" | head -1)"
fi
# A namespace is written as a key. One containing `?` or `#`, or ending in a slash, is refused
# rather than reinterpreted: canonicalising it would *widen* what a legacy credential may
# claim, and a credential that quietly claims more than it was issued for is worse than one
# that claims nothing.
for _badns in 'example.test/y?query/*' 'example.test/y#frag/*' 'example.test/y/' 'libfoo'; do
  equals "the unusable namespace '$_badns' is refused" \
    "$(status_post /token --data-urlencode "node=node-badns" --data-urlencode "namespaces=$_badns")" "400"
done
# A claim that names no usable key is a mistake, not a request to keep the stored one.
# `repos=,,` used to reach the update as an empty string, which reads as "preserve" — leaving a
# scoped credential holding a claim its namespaces never allowed.
equals "a claim naming no usable key is refused" \
  "$(scoped_status_post /register "$norm_secret" --data-urlencode "id=$KN-4" \
      --data-urlencode "node=node-norm-ns" --data-urlencode "repos=,,,")" "400"

# A wildcard namespace is still not a licence to claim a pattern as a literal key.
star_tok="$(post /token --data-urlencode "node=node-star" --data-urlencode "namespaces=*")"
star_secret="$(field "$star_tok" secret)"
if [ -n "$star_secret" ]; then
  equals "a '*' namespace cannot claim a pattern key" \
    "$(scoped_status_post /register "$star_secret" --data-urlencode "id=$KN-5" \
        --data-urlencode "node=node-star" --data-urlencode "repo=example.test/$RUN/*")" "400"
else
  no "the wildcard fixture issued a credential" "$(printf '%s' "$star_tok" | head -1)"
fi

# And what is not a key at all is still refused, by the same rule the client uses.
for _junk in 'libfoo' 'example.test/*' 'example.test/a b' '/srv/repo'; do
  equals "a key that is not a key is refused ('$_junk')" \
    "$(status_post /register --data-urlencode "id=$KN-9" --data-urlencode "node=node-norm" \
        --data-urlencode "repo=$_junk")" "400"
done
# A board that has been running carries keys written under the old rules, and routing
# compares the stored value: a session registered as `git@example.test:Acme/Thing.git` would
# stop receiving mail the moment a sender used the canonical spelling. They are migrated at
# startup, which this builds by writing the old shape straight into a scratch database.
if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ] && command -v sqlite3 >/dev/null 2>&1; then
  migport="${CHATBOX_MIG_PORT:-8794}"
  migdb="$SCRATCH/mig-${RUN}.sqlite"
  migtok="$SCRATCH/mig-${RUN}.token"
  migid="it-$RUN-migrated"
  printf '%s\n' "$TOKEN" > "$migtok"
  mig_start() { # log file
    "$CHATBOX_BIN" --port "$migport" --db "$migdb" --token-file "$migtok" > "$1" 2>&1 &
    _mpid=$!
    for _ in $(seq 1 50); do
      # Both: our own process alive *and* answering. A stale server left on the port by
      # something else would answer health while ours logged `listener failed`, and every
      # assertion below would then be about the wrong process.
      if ! kill -0 "$_mpid" 2>/dev/null; then return 1; fi
      if curl -fsS "http://127.0.0.1:$migport/health?token=$TOKEN" >/dev/null 2>&1; then return 0; fi
      sleep 0.2
    done
    return 1
  }
  mig_stop() { kill "$_mpid" 2>/dev/null; wait "$_mpid" 2>/dev/null; }

  if mig_start "$SCRATCH/mig1-${RUN}.log"; then
    curl -sS --max-time 10 -G -X POST --data-urlencode "token=$TOKEN" \
      "http://127.0.0.1:$migport/register" --data-urlencode "id=$migid" \
      --data-urlencode "node=node-mig" --data-urlencode "repo=example.test/$RUN/thing" >/dev/null 2>&1
    # A credential too, or the namespace half of the migration has nothing to rewrite.
    curl -sS --max-time 10 -G -X POST --data-urlencode "token=$TOKEN" \
      "http://127.0.0.1:$migport/token" --data-urlencode "node=node-mig-ns" \
      --data-urlencode "namespaces=example.test/$RUN/*" >/dev/null 2>&1
    mig_stop
    # The shape the old code would have stored — with a **capitalised** `.GIT`, which the rule
    # only strips after folding. A lowercase `.git` is a one-pass fixed point and would hide a
    # canonicaliser that is not idempotent.
    #
    # `user_version` is reset to 0 with them: the marker records that this database has been
    # migrated, and this fixture is modelling a board whose rows predate the marker. The board that
    # ran just above wrote the marker, so without this the (correct) skip would hide the migration.
    sqlite3 "$migdb" "UPDATE agents SET repos='git@Example.Test:Acme/Thing.GIT' WHERE id='$migid'; PRAGMA user_version=0;" >/dev/null 2>&1
    # A thread and a credential, so all three tables are exercised, plus one value in each that
    # is not a key at all and must be left exactly as it is rather than blanked.
    sqlite3 "$migdb" "INSERT INTO threads (id,repo,subject,created_at,created_by,last_at) VALUES (9001,'HTTPS://Example.Test/Acme/Thing.GIT/','mig thread','2026-01-01T00:00:00Z','a','2026-01-01T00:00:00Z');
INSERT INTO threads (id,repo,subject,created_at,created_by,last_at) VALUES (9002,'libfoo','not a key','2026-01-01T00:00:00Z','a','2026-01-01T00:00:00Z');
UPDATE tokens SET namespaces='GitHub.com/Acme/*' WHERE revoked_at IS NULL AND namespaces <> '';" >/dev/null 2>&1
    if mig_start "$SCRATCH/mig2-${RUN}.log"; then
      equals "a key written before the rule is migrated at startup" \
        "$(sqlite3 "$migdb" "select repos from agents where id='$migid';")" "example.test/acme/thing"
      equals "a thread's key is migrated too" \
        "$(sqlite3 "$migdb" "select repo from threads where id=9001;")" "example.test/acme/thing"
      contains "a credential's namespaces are migrated too" \
        "$(sqlite3 "$migdb" "select group_concat(namespaces) from tokens;")" "github.com/acme/*"
      equals "a value that is not a key is left exactly as it was" \
        "$(sqlite3 "$migdb" "select repo from threads where id=9002;")" "libfoo"
      contains "the migration is reported on startup" \
        "$(cat "$SCRATCH/mig2-${RUN}.log")" "normalised:"
      contains "what was left alone is reported too" \
        "$(cat "$SCRATCH/mig2-${RUN}.log")" "left alone"
      equals "the migration records its completion in the database" \
        "$(sqlite3 "$migdb" "PRAGMA user_version;")" "1"
      contains "a canonical message reaches the migrated session" \
        "$(curl -sS --max-time 10 -G -X POST --data-urlencode "token=$TOKEN" \
            "http://127.0.0.1:$migport/message" --data-urlencode "from=$A" \
            --data-urlencode "repo=example.test/acme/thing" --data-urlencode "body=mig $RUN")" "$migid"
      mig_stop
      # Idempotent: a second start has nothing left to rewrite. The `.GIT` above is what makes
      # this able to fail — a non-idempotent canonicaliser rewrites `thing.git` on that pass.
      if mig_start "$SCRATCH/mig3-${RUN}.log"; then
        lacks "the migration rewrites nothing on a second start" \
          "$(cat "$SCRATCH/mig3-${RUN}.log")" "rewritten to the canonical form"
      else
        no "the migration fixture restarted" "no answer on $migport"
      fi
      mig_stop
      # And it is not *run* again either: the completion recorded above means the restart does not
      # re-read the four tables. A non-canonical key written after the migration therefore stays as
      # it is — the writes this server accepts are canonical by construction, so the only way to
      # observe the skip is a row written straight into the database.
      sqlite3 "$migdb" "UPDATE agents SET repos='git@Example.Test:Acme/Thing.GIT' WHERE id='$migid';" >/dev/null 2>&1
      if mig_start "$SCRATCH/mig4-${RUN}.log"; then
        equals "a completed migration is not re-run on the next start" \
          "$(sqlite3 "$migdb" "select repos from agents where id='$migid';")" "git@Example.Test:Acme/Thing.GIT"
      else
        no "the migration fixture restarted" "no answer on $migport"
      fi
      mig_stop
    else
      no "the migration fixture restarted" "no answer on $migport: $(head -1 "$SCRATCH/mig2-${RUN}.log")"
    fi
  else
    no "the migration fixture started" "no answer on $migport: $(head -1 "$SCRATCH/mig1-${RUN}.log")"
    mig_stop
  fi
else
  printf '  skip  key migration (needs CHATBOX_BIN and sqlite3)\n'
fi

# ---------------------------------------------------------------------------
# 18. Retention and pruning (TRK-12)
# Nothing aged out, so a board only grew. `--prune <days>` is an operator command on the
# database: it removes messages that have been delivered, fully acknowledged and are older than
# the window, together with their deliveries and any thread they leave empty. It is not a route
# on the running server, because deleting the record of a cross-repo fix is an operator's
# decision and a session must not be able to hide history.
#
# The rule that matters is the one it must never break: an unacknowledged delivery is the only
# copy of a report, so it is never a candidate however old it is.
