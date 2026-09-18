# ---------------------------------------------------------------------------
if [ -n "${CHATBOX_BIN:-}" ] && [ -x "${CHATBOX_BIN:-}" ] && command -v openssl >/dev/null 2>&1; then
  tlsdir="$SCRATCH/tls-${RUN}"
  tlsport="${CHATBOX_TLS_PORT:-8792}"
  rm -rf "$tlsdir"; mkdir -p "$tlsdir"
  # The machine's own address, if it has one, so the certificate is valid for the
  # off-loopback call below as well as for 127.0.0.1. Without it that call fails
  # verification and the check silently degrades to a skip.
  LANIP_TLS="$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | head -1)"
  TLS_SAN="IP:127.0.0.1,DNS:localhost"
  [ -n "$LANIP_TLS" ] && TLS_SAN="$TLS_SAN,IP:$LANIP_TLS"
  # Written as a `-config` file rather than with `-addext`, because the openssl on a
  # macOS runner is LibreSSL and has no `-addext` at all.
  cat > "$tlsdir/san.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = 127.0.0.1
[v3]
subjectAltName = $TLS_SAN
basicConstraints = critical,CA:TRUE
CNF
  printf 'tls-%s\n' "$RUN" > "$tlsdir/pw"
  chmod 600 "$tlsdir/pw"
  printf '%s\n' "$TOKEN" > "$tlsdir/token"
  if openssl req -x509 -newkey rsa:2048 -keyout "$tlsdir/key.pem" -out "$tlsdir/cert.pem" \
       -days 2 -nodes -config "$tlsdir/san.cnf" >/dev/null 2>&1 &&
     openssl pkcs12 -export -out "$tlsdir/id.p12" -inkey "$tlsdir/key.pem" -in "$tlsdir/cert.pem" \
       -passout "file:$tlsdir/pw" >/dev/null 2>&1; then
    ok "the TLS fixture built a certificate and a PKCS#12 identity"
    tlsbase="https://127.0.0.1:$tlsport"
    # A short idle deadline so the check below can prove it covers a connection that never even
    # finishes the handshake — the case that used to hold a connection slot for ever.
    "$CHATBOX_BIN" --port "$tlsport" --db "$tlsdir/tls.sqlite" --token-file "$tlsdir/token" \
      --idle-timeout 2 \
      --tls-identity "$tlsdir/id.p12" --tls-password-file "$tlsdir/pw" > "$tlsdir/server.log" 2>&1 &
    tlspid=$!
    tlsready=0
    for _ in $(seq 1 50); do
      if curl -fsS --max-time 3 --cacert "$tlsdir/cert.pem" "$tlsbase/health?token=$TOKEN" >/dev/null 2>&1; then
        tlsready=1; break
      fi
      sleep 0.2
    done
    tls_curl() { curl -sS --max-time 8 --cacert "$tlsdir/cert.pem" "$@"; }
    # curl's exit code as well as its status, because "no HTTP response" (000) is what
    # a closed port, a wrong protocol, a client-side TLS problem and a failed
    # verification all look like — on its own it cannot fail for the reason a check
    # claims. 60 is a verification failure, 52/56 a server that will not speak HTTP.
    curl_code() { # curl args -> exit:http_code
      _cc="$(curl -sS -o /dev/null -w '%{http_code}' "$@" 2>/dev/null)"; _ccrc=$?
      printf '%s:%s' "$_ccrc" "$_cc"
    }
    LANPORT="$(printf '%s' "$URL" | sed -n 's|.*:\([0-9][0-9]*\)$|\1|p')"
    if [ "$tlsready" = 1 ]; then
      ok "a TLS listener answers https"
      contains "health reports the transport it is serving" \
        "$(tls_curl "$tlsbase/health?token=$TOKEN")" "transport: tls"
      # The certificate has to be *verified*, not merely presented: without the CA
      # curl stops at the handshake with its own verification-failure code (60).
      equals "the certificate is verified rather than waved through" \
        "$(curl_code --max-time 5 "$tlsbase/health?token=$TOKEN")" "60:000"
      # A connection that opens TCP and never speaks TLS is not `.ready`, so it is not a request
      # either — but it is a socket the server is holding. The deadline has to cover it, or a silent
      # peer occupies a connection slot for ever (`--max-connections` bounds the count, and this is
      # what keeps a slot from being held by nothing at all).
      ( sleep 8 | nc -w 6 127.0.0.1 "$tlsport" >/dev/null 2>&1 ) &
      silent_tls=$!
      sleep 4
      contains "the idle deadline covers a connection that never finishes a handshake" \
        "$(cat "$tlsdir/server.log")" "idle connection closed after 2s"
      kill "$silent_tls" 2>/dev/null
      wait "$silent_tls" 2>/dev/null

      # The refusal branch holds a socket too, and `.ready` arrives only after the handshake, so a
      # peer refused *at* the ceiling and then silent would sit in `.preparing` for ever: the ceiling
      # bounded the connections that behaved, not the ones that did not. A second server with a
      # ceiling of one and the same two-second deadline, because the fixture above uses the default
      # 256 and would need 257 sockets to reach its limit.
      ceilsrvport="${CHATBOX_TLS_CEILING_PORT:-8788}"
      "$CHATBOX_BIN" --port "$ceilsrvport" --db "$tlsdir/ceiling.sqlite" --token-file "$tlsdir/token" \
        --idle-timeout 2 --max-connections 1 \
        --tls-identity "$tlsdir/id.p12" --tls-password-file "$tlsdir/pw" > "$tlsdir/ceiling.log" 2>&1 &
      ceilpid=$!
      ceilready=0
      for _ in $(seq 1 50); do
        if curl -fsS --max-time 3 --cacert "$tlsdir/cert.pem" \
             "https://127.0.0.1:$ceilsrvport/health?token=$TOKEN" >/dev/null 2>&1; then ceilready=1; break; fi
        sleep 0.2
      done
      if [ "$ceilready" = 1 ]; then
        # The one slot, held by a long poll, so the next connection is refused.
        ( curl -sS --max-time 15 --cacert "$tlsdir/cert.pem" -o /dev/null \
            "https://127.0.0.1:$ceilsrvport/inbox?id=it-$RUN-ceil-holder&wait=12&token=$TOKEN" ) &
        ceilhold=$!
        sleep 1
        # ... and a refused peer that opens TCP and never speaks TLS. It never becomes `.ready`, so
        # only the deadline can close it.
        ( sleep 20 | nc -w 15 127.0.0.1 "$ceilsrvport" >/dev/null 2>&1 ) &
        ceilstall=$!
        sleep 0.5
        # A second one while the first is still in flight: the ceiling of one applies to refusals too,
        # or a peer can open them faster than the deadline closes them and there is no ceiling at all.
        ( sleep 6 | nc -w 5 127.0.0.1 "$ceilsrvport" >/dev/null 2>&1 ) &
        ceilstall2=$!
        sleep 4
        contains "a refused connection that never speaks is closed on the deadline" \
          "$(cat "$tlsdir/ceiling.log")" "refused connection closed after 2s"
        contains "and the number of refusals in flight is bounded too" \
          "$(cat "$tlsdir/ceiling.log")" "refused without an answer"
        kill "$ceilstall" "$ceilstall2" "$ceilhold" 2>/dev/null
        wait "$ceilstall" "$ceilstall2" "$ceilhold" 2>/dev/null
      else
        no "the refusal-ceiling fixture started" "no answer on $ceilsrvport"
      fi
      kill "$ceilpid" 2>/dev/null
      wait "$ceilpid" 2>/dev/null

      # And plain HTTP does not reach a TLS listener, so the port cannot be downgraded.
      # 52 and 56 are the two shapes of "the server answered nothing HTTP-shaped";
      # which one appears depends on the TLS stack, so both are accepted.
      case "$(curl_code --max-time 5 "http://127.0.0.1:$tlsport/health?token=$TOKEN")" in
        52:000|56:000) ok "plain HTTP does not reach a TLS listener" ;;
        *) no "plain HTTP does not reach a TLS listener" \
             "got [$(curl_code --max-time 5 "http://127.0.0.1:$tlsport/health?token=$TOKEN")], wanted 52:000 or 56:000" ;;
      esac
      # The version floor is asserted as a property rather than as a line of code, and
      # by the *reason* the client was turned away rather than by a missing status code:
      # a "no response" is also what a curl whose TLS backend has 1.1 compiled out
      # returns, without ever reaching the server. A protocol-version alert is the
      # server refusing, and an openssl that cannot offer 1.1 at all is reported as a
      # skip rather than counted as a pass.
      floor_out="$(curl -sS --max-time 8 --tls-max 1.1 --cacert "$tlsdir/cert.pem" \
        "$tlsbase/health?token=$TOKEN" 2>&1)"
      case "$floor_out" in
        *"alert protocol version"*)
          ok "a client offering only TLS 1.1 is refused by the server" ;;
        *"no protocols"*|*"unsupported protocol"*)
          printf '  skip  TLS 1.1 floor (this curl cannot offer 1.1, so it cannot observe the refusal)\n' ;;
        *)
          no "a client offering only TLS 1.1 is refused by the server" \
            "got [$(printf '%s' "$floor_out" | head -1)]" ;;
      esac
      equals "the same client at TLS 1.2 is served" \
        "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 --tls-max 1.2 \
            --cacert "$tlsdir/cert.pem" "$tlsbase/health?token=$TOKEN" 2>/dev/null)" "200"
      # A registration over TLS, because the board working matters more than the
      # health check answering.
      contains "the board works over TLS" \
        "$(tls_curl -G -X POST "$tlsbase/register" --data-urlencode "token=$TOKEN" \
            --data-urlencode "id=it-$RUN-tls" --data-urlencode "node=node-tls" 2>/dev/null)" "ok registered"

      # The shipped client honours the CA, and refuses the certificate without it.
      if [ -f "$CLI" ]; then
        contains "the client talks TLS when it is given the CA" \
          "$(CHATBOX_CONFIG=/nonexistent CHATBOX_URL="$tlsbase" CHATBOX_TOKEN="$TOKEN" \
             CHATBOX_CACERT="$tlsdir/cert.pem" sh "$CLI" health 2>&1)" "ok chatbox up"
        # Naming a CA while pointing at plain http would send the token in the clear
        # with every appearance of being encrypted, so the client refuses rather than
        # letting curl ignore the option.
        mix_out="$(CHATBOX_CONFIG=/nonexistent CHATBOX_URL="http://127.0.0.1:$tlsport" \
          CHATBOX_TOKEN="$TOKEN" CHATBOX_CACERT="$tlsdir/cert.pem" sh "$CLI" health 2>&1)"; mix_rc=$?
        if [ "$mix_rc" -ne 0 ] && printf '%s' "$mix_out" | grep -q CACERT; then
          ok "the client refuses a CA paired with a plain http URL"
        else
          no "the client refuses a CA paired with a plain http URL" \
            "exit=$mix_rc: $(printf '%s' "$mix_out" | head -1)"
        fi
        nocert="$(CHATBOX_CONFIG=/nonexistent CHATBOX_URL="$tlsbase" CHATBOX_TOKEN="$TOKEN" \
          sh "$CLI" health 2>&1)"; nocert_rc=$?
        # Not merely "it failed": a usage error, a missing shell or an unreachable host
        # also fail, so the refusal has to name the certificate.
        if [ "$nocert_rc" -ne 0 ] && printf '%s' "$nocert" | grep -qi certificate; then
          ok "the client refuses a certificate it cannot verify"
        else
          no "the client refuses a certificate it cannot verify" \
            "exit=$nocert_rc: $(printf '%s' "$nocert" | head -1)"
        fi
      fi

      # Issuing a credential off loopback is only a clear-text crossing when the
      # listener is plain, so TLS has to silence that warning rather than repeat it.
      if [ -n "$LANIP_TLS" ]; then
        tls_issue="$(tls_curl -G -X POST "https://$LANIP_TLS:$tlsport/token" \
          --data-urlencode "token=$TOKEN" --data-urlencode "node=node-tls-lan" 2>/dev/null)"
        # The tuple matters: the credential really was issued (so the silence means
        # something), and the same call to the *plain* listener from the same address
        # does warn — otherwise this would pass because the address was unreachable.
        contains "a credential issued off loopback over TLS really is issued" \
          "$tls_issue" "ok credential issued"
        lacks "issuing a secret off loopback over TLS does not warn about cleartext" \
          "$tls_issue" "no TLS"
        if [ -n "$LANPORT" ]; then
          plain_issue="$(curl -sS --max-time 20 -G -X POST --data-urlencode "token=$TOKEN" \
            "http://$LANIP_TLS:$LANPORT/token" --data-urlencode "node=node-plain-lan" 2>/dev/null)"
          contains "the plain listener does warn about cleartext from the same address" \
            "$plain_issue" "non-loopback"
        else
          printf '  skip  plain-listener control (could not read the port from %s)\n' "$URL"
        fi
      else
        printf '  skip  TLS cleartext warning (no non-loopback address found)\n'
      fi
    else
      no "a TLS listener answers https" "no answer on $tlsbase: $(head -1 "$tlsdir/server.log")"
    fi
    kill "$tlspid" 2>/dev/null
    wait "$tlspid" 2>/dev/null

    # Fail closed. Each of these has to stop the server *before* it listens, so the
    # check is the exit status as well as the absence of a listener. Run in the
    # background and probed with kill -0: a server that wrongly started would
    # otherwise sit in the foreground for ever.
    tls_refuse() { # label, port, then the TLS arguments
      _lbl="$1"; _p="$2"; shift 2
      "$CHATBOX_BIN" --port "$_p" --db "$tlsdir/refuse-$_p.sqlite" --token-file "$tlsdir/token" \
        "$@" > "$tlsdir/refuse-$_p.log" 2>&1 &
      _rpid=$!
      # Poll rather than sleep a fixed second: a correct refusal exits at once, and a
      # server that is merely slow to reach exit(2) must not be reported as one that
      # started.
      _rwaited=0
      while [ "$_rwaited" -lt 30 ] && kill -0 "$_rpid" 2>/dev/null; do
        sleep 0.1
        _rwaited=$((_rwaited + 1))
      done
      if kill -0 "$_rpid" 2>/dev/null; then
        no "$_lbl" "it started anyway: $(head -1 "$tlsdir/refuse-$_p.log")"
        kill "$_rpid" 2>/dev/null
        wait "$_rpid" 2>/dev/null
      else
        wait "$_rpid" 2>/dev/null; _rrc=$?
        # Falsifiable: the refusal is exit 2 *and* a diagnostic naming the flag.
        # A server that died for an unrelated reason — an unwritable database, an
        # unreadable token file — would otherwise be indistinguishable from one that
        # refused TLS, and the check would pass without proving anything.
        if [ "$_rrc" -eq 2 ] && grep -q -- "--tls" "$tlsdir/refuse-$_p.log"; then
          ok "$_lbl"
        else
          no "$_lbl" "exit=$_rrc: $(head -1 "$tlsdir/refuse-$_p.log")"
        fi
      fi
    }
    tls_refuse "an identity path that cannot be read stops the server" "$((tlsport + 1))" \
      --tls-identity "$tlsdir/does-not-exist.p12"
    tls_refuse "a wrong identity password stops the server" "$((tlsport + 2))" \
      --tls-identity "$tlsdir/id.p12" --tls-password-file "$tlsdir/cert.pem"
    tls_refuse "a file that is not an identity stops the server" "$((tlsport + 3))" \
      --tls-identity "$tlsdir/cert.pem"
    tls_refuse "a password without an identity is refused" "$((tlsport + 4))" \
      --tls-password-file "$tlsdir/pw"
    # Present but unusable is the dangerous one: it looks like a TLS request and
    # used to serve plain HTTP.
    tls_refuse "an identity flag with no usable value stops the server" "$((tlsport + 5))" \
      --tls-identity ""
    # The two spellings that used to be ignored outright and leave the board in the
    # clear: `--flag=value`, and a flag nobody recognises.
    tls_refuse "the --flag=value spelling is read, not ignored" "$((tlsport + 6))" \
      --tls-identity="$tlsdir/does-not-exist.p12" --tls-password-file "$tlsdir/pw"
    # Deliberately on its own: adding --tls-password-file would trip the
    # "TLS flag with no usable value" guard as well and hide whether unknown flags are
    # refused at all. Alone, the only thing standing between this and a cleartext board
    # is the unknown-flag check.
    tls_refuse "a misspelled TLS flag stops the server" "$((tlsport + 7))" \
      --tls-identiy "$tlsdir/id.p12"
    tls_refuse "a flag given twice stops the server" "$((tlsport + 9))" \
      --tls-identity "$tlsdir/id.p12" --tls-password-file "$tlsdir/pw" \
      --tls-identity "$tlsdir/id.p12"
    # A bundle with more than one identity makes the choice arbitrary, and the arbitrary
    # one is presented *with its private key*. macOS can build such a bundle and openssl
    # cannot, so this half is skipped where `security` is missing rather than passing
    # quietly.
    two_ready=0
    if command -v security >/dev/null 2>&1; then
      twokc="$tlsdir/two.keychain"
      security create-keychain -p "$RUN" "$twokc" >/dev/null 2>&1
      security unlock-keychain -p "$RUN" "$twokc" >/dev/null 2>&1
      security import "$tlsdir/cert.pem" -k "$twokc" -T /usr/bin/security >/dev/null 2>&1
      security import "$tlsdir/key.pem" -k "$twokc" -T /usr/bin/security -P "" >/dev/null 2>&1
      openssl req -x509 -newkey rsa:2048 -keyout "$tlsdir/key2.pem" -out "$tlsdir/cert2.pem" \
        -days 2 -nodes -config "$tlsdir/san.cnf" >/dev/null 2>&1
      security import "$tlsdir/cert2.pem" -k "$twokc" -T /usr/bin/security >/dev/null 2>&1
      security import "$tlsdir/key2.pem" -k "$twokc" -T /usr/bin/security -P "" >/dev/null 2>&1
      security export -k "$twokc" -t identities -f pkcs12 -P "$(cat "$tlsdir/pw")" \
        -o "$tlsdir/two.p12" >/dev/null 2>&1
      [ -s "$tlsdir/two.p12" ] && two_ready=1
      security delete-keychain "$twokc" >/dev/null 2>&1
    fi
    if [ "$two_ready" = 1 ]; then
      tls_refuse "a bundle holding two identities is refused" "$((tlsport + 8))" \
        --tls-identity "$tlsdir/two.p12" --tls-password-file "$tlsdir/pw"
    else
      printf '  skip  two-identity bundle (needs macOS security(1))\n'
    fi
    # TLS is opt-in, so none of the above may have disturbed the plain listener.
    equals "a server without --tls-identity still serves plain HTTP" "$(code_of /health)" "200"
  else
    no "the TLS fixture built a certificate and a PKCS#12 identity" "openssl failed in $tlsdir"
  fi
else
  printf '  skip  TLS transport (needs CHATBOX_BIN and openssl)\n'
fi

# ---------------------------------------------------------------------------
# 14. Own-repo verification (TRK-05)
# Ownership is self-declared, so the client checks the claim on the machine that
# actually has the repository: it derives the key from the checkout's git remotes
# and refuses one it cannot see. The server is still never asked to read a
# filesystem, and a claim it never saw is a claim it cannot vouch for.
#
# The interesting cases are all in the *shape* of a remote, not in the happy path:
# a scheme with a port, an `@` inside a path, a remote reachable at more than one
# URL, and a claim that is merely a prefix of a real one.
