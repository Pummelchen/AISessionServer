# 33. Federation — one hop to a peer (TRK-17)
# One board may be given a peer. A message it accepts for a repo no session here claims is
# forwarded to that peer, which stores it as a thread of its own; a message that already arrived
# from another board is stored and never passed on, which is what makes a loop impossible rather
# than merely unlikely. Every check below runs against a real second board, because the properties
# that matter — the hop list, the credential the peer sees, what the peer actually stored — are not
# visible from one process.
# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ]; then
  fbport="${CHATBOX_FED_PORT:-9395}"         # the board that forwards
  pbport="${CHATBOX_FED_PEER_PORT:-9396}"    # the peer, which owns the repo
  cbport="${CHATBOX_FED_SCOPED_PORT:-9397}"  # a board whose peer credential is scoped
  xbport="${CHATBOX_FED_DOWN_PORT:-9398}"    # a board whose peer is not listening
  sbport="${CHATBOX_FED_SLOW_PORT:-9399}"    # a board whose peer accepts and says nothing
  hport="${CHATBOX_FED_HOLD_PORT:-9400}"     # the listener that accepts and says nothing
  deadport="${CHATBOX_FED_DEAD_PORT:-9401}"  # nothing listens here
  rport="${CHATBOX_FED_REFUSE_PORT:-9402}"   # for flag refusals, which exit at once
  lbport="${CHATBOX_FED_LEGACY_PORT:-9403}"  # a board whose database predates the origin column

  fb="http://127.0.0.1:$fbport"
  pb="http://127.0.0.1:$pbport"
  cb="http://127.0.0.1:$cbport"
  xb="http://127.0.0.1:$xbport"
  sb="http://127.0.0.1:$sbport"
  lb="http://127.0.0.1:$lbport"

  FA="it-$RUN-fed-sender"
  FO="it-$RUN-fed-owner"
  FC="it-$RUN-fed-scoped-sender"
  FX="it-$RUN-fed-down-sender"
  FS="it-$RUN-fed-slow-sender"
  FED_REPO="example.test/$RUN/fed-peer"
  FED_LOCAL="example.test/$RUN/fed-local"
  fedmark="fedmark-$RUN"

  ftok="$SCRATCH/fed-${RUN}.token"
  printf '%s\n' "$TOKEN" > "$ftok"
  chmod 600 "$ftok" 2>/dev/null
  # The peer credential is the peer's bootstrap credential, and a bootstrap credential in `ps` is the
  # other board's full operator key: the fixture passes it in a file (`--peer-token-file`), which is
  # what the README recommends, so every forwarding check below also pins that path.
  fpeertok="$SCRATCH/fed-peer-token-${RUN}"
  printf '%s\n' "$TOKEN" > "$fpeertok"
  chmod 600 "$fpeertok" 2>/dev/null

  fed_start() { # name, port, extra args...
    _n="$1"; _p="$2"; shift 2
    "$CHATBOX_BIN" --port "$_p" --db "$SCRATCH/fed-$_n-${RUN}.sqlite" --token-file "$ftok" "$@" \
      > "$SCRATCH/fed-$_n-${RUN}.log" 2>&1 &
    fedpids="$fedpids $!"
  }
  # Ready means the board *this section started* is answering, not that something answers on that
  # port. A fixture from an earlier cell or an earlier run that leaked keeps the port and answers
  # /health with the same token, and a section that mistook it for its own would run its checks
  # against a different binary — the one way a matrix cell can pass for a reason that has nothing to
  # do with the mutant. The banner in this board's own log is the proof: it is printed when the
  # listener is ready, and a port that was taken leaves "cannot listen on <port>" there instead.
  fed_wait() { # base, port, fixture name -> 0 once the board we started answers
    _i=0
    while [ "$_i" -lt 60 ]; do
      if curl -fsS "$1/health?token=$TOKEN" >/dev/null 2>&1 \
         && grep -q "chatbox listening on port $2" "$SCRATCH/fed-$3-${RUN}.log" 2>/dev/null; then
        return 0
      fi
      sleep 0.2; _i=$((_i + 1))
    done
    return 1
  }
  # A fixture board must not outlive the section that started it. Killing a cell is how this suite is
  # interrupted, and a leaked board would hold its port for every later cell — which is exactly the
  # confusion `fed_wait` above exists to catch, so it is worth not creating it in the first place.
  fed_cleanup() {
    for _fp in $fedpids; do kill "$_fp" 2>/dev/null; done
    [ -n "${slowpid:-}" ] && kill "$slowpid" 2>/dev/null
    [ -n "${ncpid:-}" ] && kill "$ncpid" 2>/dev/null
    [ -n "${redirpid:-}" ] && kill "$redirpid" 2>/dev/null
    [ -n "${fakepid:-}" ] && kill "$fakepid" 2>/dev/null
    [ -n "${bigpid:-}" ] && kill "$bigpid" 2>/dev/null
    [ -n "${concpid:-}" ] && kill "$concpid" 2>/dev/null
    return 0
  }
  trap 'fed_cleanup' EXIT INT TERM
  fed_post() { # base, path, token, then curl data args
    _b="$1"; _pth="$2"; _t="$3"; shift 3
    curl -sS --max-time 20 -G -X POST "$@" --data-urlencode "token=$_t" "$_b$_pth"
  }
  fed_get() { # base, path, token, then curl data args
    _b="$1"; _pth="$2"; _t="$3"; shift 3
    curl -sS --max-time 20 -G "$@" --data-urlencode "token=$_t" "$_b$_pth"
  }
  fed_status() { # base, path, token, then curl data args -> HTTP status
    _b="$1"; _pth="$2"; _t="$3"; shift 3
    curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -G -X POST "$@" \
      --data-urlencode "token=$_t" "$_b$_pth"
  }
  fed_refuse() { # description, the phrase the refusal must carry, then the extra args
    _d="$1"; _phrase="$2"; shift 2
    "$CHATBOX_BIN" --port "$rport" --db "$SCRATCH/fed-refuse-${RUN}.sqlite" --token-file "$ftok" "$@" \
      > "$SCRATCH/fed-refuse-${RUN}.log" 2>&1 &
    _rp=$!
    # Same as the negative-window refusal above: the exit is waited for, not assumed. The flat
    # second this used to spend was the only difference from the startup-refusal checks that use a
    # 3-second poll - and it reported two refusals as "it started anyway" in one loaded run.
    _rw=0
    while [ "$_rw" -lt 30 ] && kill -0 "$_rp" 2>/dev/null; do
      sleep 0.1
      _rw=$((_rw + 1))
    done
    if kill -0 "$_rp" 2>/dev/null; then
      no "$_d" "it started anyway: $(head -1 "$SCRATCH/fed-refuse-${RUN}.log")"
      kill "$_rp" 2>/dev/null
      wait "$_rp" 2>/dev/null
    else
      wait "$_rp" 2>/dev/null; _rrc=$?
      # The exit status is part of the answer: a process that printed the phrase and exited 1 (a
      # crash, a different refusal path) is not this refusal, and the old check accepted it.
      if [ "$_rrc" -eq 2 ]; then
        ok "$_d"
      else
        no "$_d" "exit=$_rrc, not the refusal code 2: $(head -1 "$SCRATCH/fed-refuse-${RUN}.log")"
      fi
    fi
    contains "$_d — and the refusal names it" "$(cat "$SCRATCH/fed-refuse-${RUN}.log")" "$_phrase"
  }

  : > "$SCRATCH/fed-empty-${RUN}"
  chmod 600 "$SCRATCH/fed-empty-${RUN}" 2>/dev/null
  fedpids=""
  fed_start fed "$fbport" --peer "http://127.0.0.1:$pbport" --peer-token-file "$fpeertok" --max-hops 4
  fed_start peer "$pbport" --server-id fed-peer
  fed_start down "$xbport" --peer "http://127.0.0.1:$deadport" --peer-token "$TOKEN"
fi

