# 1. Reachability, and the auth mode the rest of the suite depends on
# ---------------------------------------------------------------------------
if ! curl -sS --max-time 20 -o /dev/null "$URL/health" 2>/dev/null; then
  printf 'FATAL: cannot reach %s — start the server first.\n' "$URL" >&2
  exit 2
fi

anon="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/health")"
auth_open=0

if [ "$anon" = "200" ]; then
  # An open board answers /health without a token. That is exactly the state a
  # server lands in when --token-file is unreadable, and it silently disables the
  # auth regression this suite exists to pin — so it is a hard failure unless the
  # caller says they meant it.
  if [ "${CHATBOX_EXPECT_OPEN:-0}" = "1" ]; then
    auth_open=1
    printf 'auth: OPEN — allowed because CHATBOX_EXPECT_OPEN=1\n'
  else
    printf 'FATAL: %s serves /health without a token.\n' "$URL" >&2
    printf 'An open board cannot exercise the auth regression this suite pins.\n' >&2
    printf 'Fix the server (usually an unreadable --token-file), or set CHATBOX_EXPECT_OPEN=1\n' >&2
    printf 'to test an open board deliberately.\n' >&2
    exit 2
  fi
else
  printf 'auth: token required\n'
fi

# Pins the fixed bug: the token in the query string used to be ignored (401).
contains "health via query-string token" "$(get /health)" "ok chatbox up"
contains "health via Authorization: Bearer" \
  "$(curl -sS --max-time 20 -H "Authorization: Bearer $TOKEN" "$URL/health")" "ok chatbox up"
contains "health reports the agent count" "$(get /health)" "agents:"
contains "health reports the message count" "$(get /health)" "messages:"
# /health's counts come from the same cache the events feed uses, so a write must move them: a cache
# keyed on the wrong thing would report a number that stopped changing.
_hm_before="$(field "$(get /health)" messages)"
post /message --data-urlencode "from=$A" --data-urlencode "repo=$REPO_APP" \
  --data-urlencode "body=health-cache-$RUN" >/dev/null
_hm_after="$(field "$(get /health)" messages)"
if [ "${_hm_after:-0}" -gt "${_hm_before:-0}" ] 2>/dev/null; then
  ok "and the count is not stale after a write"
else
  no "and the count is not stale after a write" "before=$_hm_before after=$_hm_after"
fi

if [ "$auth_open" = 0 ]; then
  equals "missing token is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/health")" "401"
  contains "missing token explains itself" \
    "$(curl -sS --max-time 20 "$URL/health")" "unauthorized"
  equals "wrong query token is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/health?token=not-the-token")" "401"
  # A credential that differs from the real one in exactly one character, at either end. How long
  # the comparison *takes* is not observable through curl — the noise is orders of magnitude larger
  # than the signal — but what the comparison *covers* is: a helper that compared only a prefix of
  # the secret, or that accepted any string of the right shape, accepts one of these.
  case "$TOKEN" in
    *z) token_tail="${TOKEN%?}y" ;;
    *)  token_tail="${TOKEN%?}z" ;;
  esac
  case "$TOKEN" in
    z*) token_head="y${TOKEN#?}" ;;
    *)  token_head="z${TOKEN#?}" ;;
  esac
  equals "a token differing only in its last character is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/health?token=$token_tail")" "401"
  equals "a token differing only in its first character is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/health?token=$token_head")" "401"
  equals "and the real one still works, so those two are not vacuous" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/health?token=$TOKEN")" "200"
  equals "wrong bearer token is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -H 'Authorization: Bearer nope' "$URL/health")" "401"
  equals "a bad token is rejected on another route too" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/peers?token=not-the-token")" "401"
  equals "an unauthenticated write is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$URL/message?from=x&body=y")" "401"
  # The long-poll route answers later than the others, so it gets its own check.
  equals "an unauthenticated long poll is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/inbox?id=$A&wait=1")" "401"
  equals "a long poll with a wrong token is rejected" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/inbox?id=$A&wait=1&token=not-the-token")" "401"
  # The credential routes are the keys to the board: an anonymous caller must not
  # be able to issue, list or revoke anything. Nothing else pins this.
  equals "an unauthenticated credential issue is refused" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$URL/token?node=x")" "401"
  equals "an unauthenticated credential list is refused" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/token")" "401"
  equals "an unauthenticated revoke is refused" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$URL/token/revoke?id=tk-x")" "401"
  # Sending the same credential both ways is fine; sending two different ones is a
  # client bug and used to be resolved silently in favour of the query parameter.
  equals "an agreeing query token and header are accepted" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -H "Authorization: Bearer $TOKEN" "$URL/health?token=$TOKEN")" "200"
  equals "a query token that contradicts the header is refused" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -H "Authorization: Bearer $TOKEN" "$URL/health?token=not-the-token")" "400"
fi

# ---------------------------------------------------------------------------
# 2. Credentials and the claim allowlist
# The shared token stays a bootstrap credential. A scoped credential belongs to
# one machine, may only claim repos inside its namespaces, may only act as a
# session on that machine, and can be revoked without disturbing anything else
# or restarting the server.
# ---------------------------------------------------------------------------
NS2="example.test/$RUN/team/*"
REPO_TEAM="example.test/$RUN/team/app"
REPO_FOREIGN="github.com/someone/else"

issued2="$(post /token --data-urlencode "node=node-cred2" \
  --data-urlencode "namespaces=$NS2" --data-urlencode "note=second machine")"
issued3="$(post /token --data-urlencode "node=node-cred3" --data-urlencode "namespaces=*")"
contains "a credential can be issued with the bootstrap token" "$issued2" "ok credential issued"
TOK2="$(field "$issued2" secret)"
ID2="$(field "$issued2" id)"
TOK3="$(field "$issued3" secret)"
ID3="$(field "$issued3" id)"
if [ -n "$TOK2" ] && [ -n "$ID2" ] && [ -n "$TOK3" ] && [ -n "$ID3" ]; then
  ok "issuing returns both an id and a secret"
else
  no "issuing returns both an id and a secret" "id2=[$ID2] id3=[$ID3] secrets=${TOK2:+set}/${TOK3:+set}"
fi

# The secret is shown once. Nothing that lists credentials may repeat it.
listing="$(get /token)"
contains "the listing shows the credential id" "$listing" "$ID2"
# A secret issued over loopback never leaves the machine, so there is nothing to
# warn about there. Off loopback it crosses the network in the clear and the
# response has to say so rather than let an operator assume otherwise.
lacks "issuing over loopback does not warn about cleartext" "$issued2" "non-loopback"
LANIP="$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | head -1)"
LANPORT="$(printf '%s' "$URL" | sed -n 's|.*:\([0-9][0-9]*\)$|\1|p')"
if [ -n "$LANIP" ] && [ -n "$LANPORT" ]; then
  lan_issue="$(curl -sS --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" \
    "http://$LANIP:$LANPORT/token" --data-urlencode "node=node-lan" 2>/dev/null)"
  if [ -n "$lan_issue" ]; then
    contains "issuing a secret off loopback warns about cleartext" "$lan_issue" "non-loopback"
  else
    printf '  skip  cleartext warning (server unreachable off loopback)\n'
  fi
else
  printf '  skip  cleartext warning (no non-loopback address found)\n'
fi
contains "the listing shows the machine it belongs to" "$listing" "node-cred2"
lacks "the listing never repeats a secret" "$listing" "$TOK2"
lacks "the json listing never repeats a secret" "$(get /token "json=1")" "$TOK3"
# ... and it is JSON: the format branch on the one route that exposes credentials had no check at
# all, so a body that was neither the json object nor the text listing passed the `lacks` above.
contains "the json credential listing is an object" "$(get /token "json=1")" '"tokens"'
contains "with the count it is showing" "$(get /token "json=1")" '"shown"'
contains "and the count it matched" "$(get /token "json=1")" '"matching"'

# Stored hashed, not in the clear.
if [ -n "${CHATBOX_DB:-}" ] && [ -f "$CHATBOX_DB" ]; then
  if grep -q -e "$TOK2" "$CHATBOX_DB" 2>/dev/null || grep -q -e "$TOK2" "$CHATBOX_DB-wal" 2>/dev/null; then
    no "the secret is not stored in the clear" "found it in $CHATBOX_DB"
  else
    ok "the secret is not stored in the clear"
  fi
else
  printf '  skip  plaintext-credential check (set CHATBOX_DB to pin it)\n'
fi

# On its own machine, inside its namespaces: it works.
contains "a scoped credential registers on its own node" \
  "$(scoped_post /register "$TOK2" --data-urlencode "id=$C2" --data-urlencode "node=node-cred2" \
      --data-urlencode "repos=$REPO_TEAM")" "ok registered"
contains "a scoped credential can act as its own session" \
  "$(scoped_get "/inbox?id=$C2" "$TOK2")" "inbox for $C2"

# A repo key is a name, not a pattern. Allowing one would let a namespace pattern
# such as `acme/*` match *itself* and be claimed as a literal key, which would
# route other owners' mail to whoever claimed it.
equals "a wildcard repo key is refused for the bootstrap credential" \
  "$(status_post /register --data-urlencode "id=$A" --data-urlencode "node=node-a" \
      --data-urlencode "repos=$NS2")" "400"
contains "the wildcard refusal explains itself" \
  "$(post /register --data-urlencode "id=$A" --data-urlencode "node=node-a" \
      --data-urlencode "repos=$NS2")" "not a valid repo key"
equals "a wildcard repo key is refused for a scoped credential" \
  "$(scoped_status_post /register "$TOK2" --data-urlencode "id=$C2" --data-urlencode "node=node-cred2" \
      --data-urlencode "repos=$NS2")" "400"
equals "a namespace pattern cannot be claimed as a literal key" \
  "$(scoped_status_post /register "$TOK2" --data-urlencode "id=$C2" --data-urlencode "node=node-cred2" \
      --data-urlencode "repos=$REPO_TEAM")" "200"

# A claim made by the bootstrap outside a machine's namespaces must not be kept
# alive by that machine re-registering the session: validate what it will own, not
# only what it sent.
post /register --data-urlencode "id=$C5" --data-urlencode "node=node-cred2" \
  --data-urlencode "repos=github.com/victim/private" >/dev/null
contains "the bootstrap can make a claim the scoped credential may not" "$(get /peers)" "github.com/victim/private"
equals "re-registering must not preserve a claim outside the namespaces" \
  "$(scoped_status_post /register "$TOK2" --data-urlencode "id=$C5" --data-urlencode "node=node-cred2")" "403"

# Outside them: refused, and the refusal says why.
foreign="$(scoped_post /register "$TOK2" --data-urlencode "id=$C2" --data-urlencode "node=node-cred2" \
  --data-urlencode "repos=$REPO_FOREIGN")"
equals "a repo outside the namespace is refused" \
  "$(scoped_status_post /register "$TOK2" --data-urlencode "id=$C2" --data-urlencode "node=node-cred2" \
      --data-urlencode "repos=$REPO_FOREIGN")" "403"
contains "the refusal names the allowed namespaces" "$foreign" "$NS2"
equals "another machine's node is refused" \
  "$(scoped_status_post /register "$TOK2" --data-urlencode "id=$C2" --data-urlencode "node=node-elsewhere")" "403"

# A scoped credential cannot speak for a session that belongs to another machine.
contains "a third machine registers a session" \
  "$(scoped_post /register "$TOK3" --data-urlencode "id=$C3" --data-urlencode "node=node-cred3" \
      --data-urlencode "repos=example.test/$RUN/anywhere")" "ok registered"
equals "impersonating another machine's session is refused" \
  "$(scoped_status_post /message "$TOK2" --data-urlencode "from=$C3" --data-urlencode "body=hello")" "403"
equals "acting as an unregistered session is refused" \
  "$(scoped_status_post /message "$TOK2" --data-urlencode "from=it-$RUN-ghost" --data-urlencode "body=hello")" "403"
lacks "a cross-machine refusal does not name the other machine" \
  "$(scoped_post /message "$TOK2" --data-urlencode "from=$C3" --data-urlencode "body=hello")" "node-cred3"
equals "a scoped credential cannot read another machine's inbox" \
  "$(scoped_get_status "/inbox?id=$C3" "$TOK2")" "403"
equals "a scoped credential cannot long-poll another machine's inbox" \
  "$(scoped_get_status "/inbox?id=$C3&wait=1" "$TOK2")" "403"
equals "a scoped credential cannot ack for another machine's session" \
  "$(scoped_status_post /ack "$TOK2" --data-urlencode "id=$C3" --data-urlencode "message=1")" "403"

# The whole point of the board: sending to a repo you do not own still works.
contains "a scoped credential may still send to a repo it does not own" \
  "$(scoped_post /message "$TOK3" --data-urlencode "from=$C3" --data-urlencode "repo=$REPO_TEAM" \
      --data-urlencode "subject=cross-repo $RUN" --data-urlencode "body=whoever owns team/app?")" \
  "ok posted"

# Managing credentials stays with the bootstrap credential.
equals "a scoped credential cannot issue credentials" \
  "$(scoped_status_post /token "$TOK2" --data-urlencode "node=node-x")" "403"
equals "a scoped credential cannot list credentials" "$(scoped_get_status /token "$TOK2")" "403"
equals "a scoped credential cannot revoke credentials" \
  "$(scoped_status_post /token/revoke "$TOK2" --data-urlencode "id=$ID3")" "403"
equals "issuing without a node is refused" "$(status_post /token --data-urlencode "namespaces=*")" "400"

# Revocation is immediate and leaves everything else alone.
contains "a credential can be revoked" "$(post /token/revoke --data-urlencode "id=$ID2")" "ok revoked $ID2"
contains "the revoked credential is told so" "$(scoped_get /health "$TOK2")" "revoked"
equals "the revoked credential gets a 401" "$(scoped_get_status /health "$TOK2")" "401"
equals "another credential is undisturbed" "$(scoped_get_status /health "$TOK3")" "200"
equals "the bootstrap credential is undisturbed" "$(code_of /health)" "200"
contains "the listing marks it revoked" "$(get /token)" "REVOKED"
contains "revocation does not delete what it registered" "$(get /peers)" "$C2"
equals "revoking an unknown credential is a 404" \
  "$(status_post /token/revoke --data-urlencode "id=tk-doesnotexist")" "404"
tmpcred="$(post /token --data-urlencode "node=node-tmp" --data-urlencode "namespaces=*")"
TMPID="$(field "$tmpcred" id)"
contains "a throwaway credential can be revoked" "$(post /token/revoke --data-urlencode "id=$TMPID")" "ok revoked $TMPID"
contains "revoking it again says so rather than pretending" \
  "$(post /token/revoke --data-urlencode "id=$TMPID")" "already revoked"

# The hash that is stored must look like a digest, not like the secret.
if [ -n "${CHATBOX_DB:-}" ] && [ -f "$CHATBOX_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  stored="$(sqlite3 "$CHATBOX_DB" "SELECT hash FROM tokens WHERE id = '$ID3' LIMIT 1" 2>/dev/null)"
  if [ "${#stored}" -eq 64 ] && [ "$stored" != "$TOK3" ]; then
    case "$stored" in
      *[!0-9a-f]*) no "the stored credential value is a hex digest" "got [$stored]" ;;
      *) ok "the stored credential value is a hex digest, not the secret" ;;
    esac
  else
    no "the stored credential value is a hex digest" "got [${stored}]"
  fi
  if command -v shasum >/dev/null 2>&1; then
    equals "the stored digest is exactly SHA-256 of the secret" "$stored" \
      "$(printf '%s' "$TOK3" | shasum -a 256 | cut -d' ' -f1)"
  fi
else
  printf '  skip  stored-digest check (needs CHATBOX_DB and sqlite3)\n'
fi

# Revocation has to reach a wait that is already in flight: a held long poll used
# to keep running to its deadline and hand over messages posted after revocation.
issued4="$(post /token --data-urlencode "node=node-cred4" --data-urlencode "namespaces=$NS2")"
TOK4="$(field "$issued4" secret)"
ID4="$(field "$issued4" id)"
scoped_post /register "$TOK4" --data-urlencode "id=$C4" --data-urlencode "node=node-cred4" \
  --data-urlencode "repos=$REPO_TEAM" >/dev/null
( curl -sS --max-time 30 -o "$SCRATCH/midwait-${RUN}.out" -w '%{http_code}' \
    -H "Authorization: Bearer $TOK4" "$(bare_url "/inbox?id=$C4&wait=20")" \
    > "$SCRATCH/midwait-${RUN}.code" 2>/dev/null ) &
mw_pid=$!
sleep 1
post /token/revoke --data-urlencode "id=$ID4" >/dev/null
scoped_post /message "$TOK3" --data-urlencode "from=$C3" --data-urlencode "to=$C4" \
  --data-urlencode "body=after-revoke-$RUN" >/dev/null
wait "$mw_pid" 2>/dev/null
equals "revoking a credential ends a wait that is already held" "$(cat "$SCRATCH/midwait-${RUN}.code")" "401"
lacks "a revoked waiter is not handed a message posted after revocation" \
  "$(cat "$SCRATCH/midwait-${RUN}.out")" "after-revoke-$RUN"

# ---------------------------------------------------------------------------
# 3. Usage, /help, and unknown routes
# The 404 body embeds the usage text, so a status assertion is the only thing
# that distinguishes the real route from the fallback.
# ---------------------------------------------------------------------------
equals "GET / is 200" "$(code_of /)" "200"
contains "GET / teaches the protocol" "$(get /)" "harness-independent session chatbox"
contains "GET / documents register" "$(get /)" "POST /register"
lacks "GET / is not the 404 fallback" "$(get /)" "not found"
equals "GET /help is 200" "$(code_of /help)" "200"
lacks "GET /help is not the 404 fallback" "$(get /help)" "not found"
equals "an unknown route is 404" "$(code_of /no-such-route)" "404"
contains "an unknown route reports not found" "$(get /no-such-route)" "not found"

# ---------------------------------------------------------------------------
# 4. Registration, aliases, and the ownership registry
# ---------------------------------------------------------------------------
reg="$(post /register \
  --data-urlencode "id=$A" --data-urlencode "node=node-a" \
  --data-urlencode "agent=dsh" --data-urlencode "harness=DeepSeek Harness" \
  --data-urlencode "session=sess-$RUN-a" --data-urlencode "ip=10.0.0.1" \
  --data-urlencode "repos=$REPO_APP")"
contains "register returns ok" "$reg" "ok registered"
contains "register echoes the id" "$reg" "id: $A"
contains "register echoes the declared repo" "$reg" "$REPO_APP"

post /register --data-urlencode "id=$B" --data-urlencode "node=node-b" \
  --data-urlencode "agent=claude" --data-urlencode "harness=Claude Code" \
  --data-urlencode "repos=$REPO_LIB" >/dev/null

peers="$(get /peers)"
contains "peers lists the first session" "$peers" "$A"
contains "peers lists the second session" "$peers" "$B"
contains "peers reports the first ownership" "$peers" "$REPO_APP"
contains "peers reports the second ownership" "$peers" "$REPO_LIB"

# Upsert contract: supplied fields change, an omitted repos= is preserved.
# Asserting the change matters — otherwise a re-register that silently does
# nothing at all would pass too.
post /register --data-urlencode "id=$A" --data-urlencode "node=node-a-renamed" \
  --data-urlencode "agent=dsh" --data-urlencode "harness=DeepSeek Harness v2" \
  --data-urlencode "note=carries a note" >/dev/null
peers2="$(get /peers)"
peers2_json="$(get /peers "json=1")"
contains "re-registering updates supplied fields" "$peers2" "node-a-renamed"
# Read the stored value from json=1: /peers only prints the harness line when ip
# or session is set, so asserting against the plain-text view would pass or fail
# for a display reason rather than a storage reason.
contains "re-registering updates the harness" "$peers2_json" "DeepSeek Harness v2"
contains "re-registering without repos preserves ownership" "$peers2" "$REPO_APP"
contains "note is stored" "$peers2_json" "carries a note"

# The same rule for every other field (TRK-26). A session re-registering to change one thing used
# to lose node, agent, harness, session, ip and note in silence — and the answer echoed the
# *request*, so "session: " was printed while the session was still on the board.
keep="it-$RUN-keep"
post /register --data-urlencode "id=$keep" --data-urlencode "node=node-keep" \
  --data-urlencode "agent=dsh" --data-urlencode "harness=DeepSeek Harness" \
  --data-urlencode "session=sess-$RUN-keep" --data-urlencode "ip=10.9.9.9" \
  --data-urlencode "repos=example.test/$RUN/keep1" --data-urlencode "note=first note" >/dev/null
kept="$(post /register --data-urlencode "id=$keep" --data-urlencode "repos=example.test/$RUN/keep2")"
contains "a re-registration keeps the node it was not given" "$kept" "node: node-keep"
contains "and the agent it was not given" "$kept" "agent: dsh"
contains "and the harness it was not given" "$kept" "harness: DeepSeek Harness"
contains "and the session it was not given" "$kept" "session: sess-$RUN-keep"
contains "and the address it was not given" "$kept" "ip: 10.9.9.9"
contains "while the field it was given changes" "$kept" "repos: example.test/$RUN/keep2"
# Read back from the plain view, so this cannot pass on an echo alone. (The JSON view escapes `/`,
# so a repo key cannot be compared there without knowing that.)
keptpeers="$(get /peers)"
contains "the registry still holds the preserved node" "$keptpeers" "node-keep"
contains "and the preserved session" "$(get /peers "json=1")" "sess-$RUN-keep"
contains "and the repo that was given" "$keptpeers" "example.test/$RUN/keep2"
lacks "and not the one it replaced" "$keptpeers" "example.test/$RUN/keep1"
# An explicit value still wins on the next registration.
changed="$(post /register --data-urlencode "id=$keep" --data-urlencode "session=sess-2-$RUN" \
  --data-urlencode "harness=Codex")"
contains "an explicit field still overwrites the stored one" "$changed" "session: sess-2-$RUN"
contains "and so does an explicit harness" "$changed" "harness: Codex"
if [ -n "${CHATBOX_DB:-}" ] && command -v sqlite3 >/dev/null 2>&1; then
  equals "the note was preserved in the store too" \
    "$(sqlite3 "$CHATBOX_DB" "select note from agents where id='$keep';")" "first note"
fi

# The repo= alias, and a session that declares more than one repo.
post /register --data-urlencode "id=$E" --data-urlencode "node=node-e" \
  --data-urlencode "repo=$REPO_ALIAS" >/dev/null
contains "register accepts repo= as a single-value alias" "$(get /peers)" "$REPO_ALIAS"

post /register --data-urlencode "id=$D" --data-urlencode "node=node-d" \
  --data-urlencode "repos=$REPO_ONE,$REPO_TWO" >/dev/null
peers3="$(get /peers)"
contains "a session may declare several repos (first)" "$peers3" "$REPO_ONE"
contains "a session may declare several repos (second)" "$peers3" "$REPO_TWO"

# ---------------------------------------------------------------------------
# 5. Routing by repo key
# ---------------------------------------------------------------------------
subj="probe $RUN"
sent="$(post /message --data-urlencode "from=$A" --data-urlencode "repo=$REPO_LIB" \
  --data-urlencode "subject=$subj" --data-urlencode "body=first message for $RUN")"
contains "saying by repo key posts" "$sent" "ok posted"
contains "the repo key is echoed" "$sent" "repo: $REPO_LIB"
equals "the declared owner is resolved from the repo key" "$(field "$sent" delivered_to)" "$B"

MID="$(field "$sent" message)"
TID="$(field "$sent" thread)"
if [ -n "$MID" ] && [ -n "$TID" ]; then
  ok "the send response carries message and thread ids"
else
  no "the send response carries message and thread ids" "message=[$MID] thread=[$TID]"
fi

inbox_b="$(get /inbox "id=$B")"
contains "the owner sees the message" "$inbox_b" "$subj"
contains "the owner sees who sent it" "$inbox_b" "from: $A"
contains "the owner sees the repo it was routed by" "$inbox_b" "repo: $REPO_LIB"
contains "the message is marked UNREAD" "$inbox_b" "UNREAD"

# A message for a repo nobody owns must be stored, reported, and delivered to
# nobody — assert the delivery, not just the note text.
orphan="$(post /message --data-urlencode "from=$A" --data-urlencode "repo=$REPO_NONE" \
  --data-urlencode "subject=orphan $RUN" --data-urlencode "body=nobody owns this")"
contains "an unowned repo is reported" "$orphan" "nobody has registered as an owner"
equals "an unowned repo delivers to nobody" "$(field "$orphan" delivered_to)" "(nobody)"

# The second repo of a multi-repo session.
multi="$(post /message --data-urlencode "from=$A" --data-urlencode "repo=$REPO_TWO" \
  --data-urlencode "subject=multi $RUN" --data-urlencode "body=second repo of a pair")"
equals "routing finds a session by its second declared repo" "$(field "$multi" delivered_to)" "$D"

# A repo declared through the repo= registration alias.
alias_msg="$(post /message --data-urlencode "from=$A" --data-urlencode "repo=$REPO_ALIAS" \
  --data-urlencode "subject=alias $RUN" --data-urlencode "body=registered with repo=")"
equals "a repo registered with repo= routes" "$(field "$alias_msg" delivered_to)" "$E"

# ---------------------------------------------------------------------------
# 6. Threads, reply routing, inherited repo
# Pins two fixed bugs: a reply resolved to no recipients, and it lost the repo.
# ---------------------------------------------------------------------------
rep="$(post /message --data-urlencode "from=$B" --data-urlencode "thread=$TID" \
  --data-urlencode "body=reply for $RUN")"
contains "a reply posts" "$rep" "ok posted"
# Exact set, so a reply that also re-delivers to its own sender is caught.
equals "a reply reaches exactly the other participant" "$(field "$rep" delivered_to)" "$A"
contains "a reply inherits the thread repo when repo is omitted" "$rep" "repo: $REPO_LIB"
equals "a reply stays in the same thread" "$(field "$rep" thread)" "$TID"

th="$(get /thread "id=$TID")"
contains "the thread shows the opener" "$th" "first message for $RUN"
contains "the thread shows the reply" "$th" "reply for $RUN"
contains "the thread names the participants" "$th" "$A"
contains "the thread list finds it by repo" "$(get /threads "repo=$REPO_LIB")" "[$TID]"

# The inherited repo must be persisted on the row, not merely echoed back.
contains "the reply's stored repo is the inherited one" \
  "$(get /inbox "id=$A&all=1")" "repo: $REPO_LIB"

# reply_to is recorded and shown.
rr="$(post /message --data-urlencode "from=$A" --data-urlencode "thread=$TID" \
  --data-urlencode "reply_to=$MID" --data-urlencode "body=quoted reply for $RUN")"
contains "reply_to is accepted" "$rr" "ok posted"
contains "reply_to is shown in the thread view" "$(get /thread "id=$TID")" "(reply to $MID)"

# ---------------------------------------------------------------------------
# 7. The sender is never its own recipient
# A must own the repo it sends to, or the filter is unreachable and this check
# proves nothing. C becomes a second owner of REPO_APP, which A also owns.
