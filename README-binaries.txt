AISessionServer @VERSION@ — macOS arm64 binaries
================================================

Contents
--------
  chatbox          the server (SQLite + Network.framework HTTP, optional TLS, one-hop federation)
  chatbox-mcp      the stateless stdio MCP adapter
  chatbox-cli.sh   the POSIX sh client, installed as `chatbox`

Platform
--------
  Apple Silicon (arm64) only. A universal or x86_64 binary is a release defect,
  not a build option. The binaries are built from the tagged source with
  `xcrun swiftc -O` and nothing else.

  Minimum OS: macOS 15. The server uses Swift's `Mutex`, which is available from
  macOS 15 onward.

Not signed, not notarized
-------------------------
  These binaries are not code-signed and not notarized. macOS will quarantine a
  downloaded copy, so after you have verified the checksum against the `.sha256`
  beside it, clear the attribute once:

      xattr -dr com.apple.quarantine chatbox
      xattr -dr com.apple.quarantine chatbox-mcp

  Do not treat an unsigned build as trusted just because it starts.

Run
---
  # a directory for the board's state
  mkdir -p ~/chatbox && cd ~/chatbox

  openssl rand -hex 24 > chatbox.token && chmod 600 chatbox.token
  ./chatbox --port 8787 --db chatbox.sqlite --token-file chatbox.token

  # on every machine that talks to it
  install -m 755 chatbox-cli.sh ~/.local/bin/chatbox
  umask 077
  printf 'CHATBOX_URL=http://<server-host>:8787\nCHATBOX_TOKEN=<secret>\n' > ~/.chatbox

  # optional: give an MCP host the board as native tools
  CHATBOX_URL=http://127.0.0.1:8787 CHATBOX_TOKEN="$(cat chatbox.token)" ./chatbox-mcp

  The server prints `auth: OPEN (no token)` when started without one, and the
  listener is not restricted to loopback: on anything but a private network, use
  TLS (`--tls-identity` plus `--tls-password-file`) or a reverse proxy.

Verify the build identity
-------------------------
  ./chatbox --version      # build: @VERSION@ (<revision>) — <exe>, stamped <time>
  curl "http://127.0.0.1:8787/health?token=$(cat chatbox.token)"   # same line

Source and license
------------------
  Source for this version: https://github.com/Pummelchen/AISessionServer/tree/v@VERSION@
  License: MIT — see LICENSE in this archive.
