#!/bin/sh
# release.sh — the repository's release driver. RELEASE.md is the standard; this script is the
# mechanical part of it. macOS only, because the product is macOS/arm64 only.
#
#   ./release.sh --check     verify the version mirrors agree with VERSION (CI runs this)
#   ./release.sh --sync      write the mirrors from VERSION (one edit plus one command)
#   ./release.sh             dry run: gates, arm64 build, package, checksums, notes. Nothing is
#                            tagged, pushed or published.
#   ./release.sh --publish   the same, then tag vX.Y.Z and publish on GitHub. Explicit flag only.
#
# Nothing here fetches a model, dataset or dependency to make a gate pass; a gate that cannot run
# stops the release instead. Never terminate a process you did not start: a competing build is a
# refusal, not a kill.
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
REPO_SLUG="Pummelchen/AISessionServer"
NAME="AISessionServer"
PLATFORM="macos-arm64"
HOST_PORT=8860

die() { printf 'release: FATAL: %s\n' "$1" >&2; exit 1; }
note() { printf 'release: %s\n' "$1"; }

# --- identity -----------------------------------------------------------------------------------

version() {
    [ -f "$ROOT/VERSION" ] || die "no VERSION file at the repository root"
    _v="$(tr -d '[:space:]' < "$ROOT/VERSION")"
    # The repository's scheme is major.minor (X.Y): there is no patch component, so a fix that
    # ships bumps the minor. A three-part value is refused rather than truncated.
    case "$_v" in
        *[!0-9.]*|*..*|.*|*.) die "VERSION '$_v' must be X.Y (digits and one dot)" ;;
    esac
    _maj="${_v%%.*}"
    _min="${_v#*.}"
    case "$_min" in
        *.*) die "VERSION '$_v' must be X.Y, not X.Y.Z" ;;
    esac
    [ -n "$_maj" ] && [ -n "$_min" ] || die "VERSION '$_v' must be X.Y"
    printf '%s' "$_v"
}

source_mirror() { # the version literal in the server source
    sed -n 's/^let productVersion = "\([^"]*\)".*/\1/p' "$ROOT/src/chatbox/Support.swift" | head -1
}

mcp_mirror() { # the version literal in the MCP adapter
    sed -n 's/.*"serverInfo": \["name": "chatbox", "version": "\([^"]*\)"\].*/\1/p' \
        "$ROOT/src/chatbox-mcp/chatbox-mcp.swift" | head -1
}

cmd_check() {
    _v="$(version)"
    _s="$(source_mirror)"
    _m="$(mcp_mirror)"
    [ -n "$_s" ] || die "could not read the version mirror in src/chatbox/Support.swift"
    [ -n "$_m" ] || die "could not read the version mirror in src/chatbox-mcp/chatbox-mcp.swift"
    [ "$_s" = "$_v" ] || die "VERSION is $_v but the server says $_s — run ./release.sh --sync"
    [ "$_m" = "$_v" ] || die "VERSION is $_v but the MCP adapter says $_m — run ./release.sh --sync"
    note "version identity: VERSION = $_v, both mirrors agree"
}

cmd_sync() {
    _v="$(version)"
    # BSD sed (macOS); this repository is macOS-only, so no GNU/BSD branch is needed.
    sed -i '' "s/^let productVersion = \"[^\"]*\"/let productVersion = \"$_v\"/" \
        "$ROOT/src/chatbox/Support.swift"
    sed -i '' \
        "s/\"serverInfo\": \[\"name\": \"chatbox\", \"version\": \"[^\"]*\"\]/\"serverInfo\": [\"name\": \"chatbox\", \"version\": \"$_v\"]/" \
        "$ROOT/src/chatbox-mcp/chatbox-mcp.swift"
    note "mirrors written from VERSION ($_v); commit the result"
}

# --- preconditions (§1.4) -----------------------------------------------------------------------

preconditions() {
    [ "$(uname -s)" = "Darwin" ] || die "this release is macOS/arm64 only"
    [ "$(uname -m)" = "arm64" ] || die "this host is $(uname -m), not arm64"
    [ "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" = "main" ] || die "releases are cut from main"
    [ -z "$(git -C "$ROOT" status --porcelain)" ] || die "the tree is not clean; commit or stash first"
    if pgrep -x swiftc >/dev/null 2>&1; then die "a swiftc build is running; wait for it"; fi
    if pgrep -f 'chatbox --port' >/dev/null 2>&1; then
        printf 'release: a board is already running (pid(s): %s)\n' "$(pgrep -f 'chatbox --port' | tr '\n' ' ')" >&2
        die "stop it before releasing; this script starts its own"
    fi
    _mb="$(df -m "$ROOT" | awk 'NR==2 {print $4}')"
    [ "$_mb" -ge 2048 ] || die "only ${_mb} MB free; a clean build, the suite and the archive need ~2 GB"
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated as the repository owner"
    note "preconditions: $(sw_vers -productVersion), $(swift --version 2>/dev/null | head -1), ${_mb} MB free, gh authed"
}

# --- gates (§1.5) -------------------------------------------------------------------------------

gate_lint() {
    note "gate: lint"
    xcrun swift-format lint --strict --configuration "$ROOT/.swift-format" \
        "$ROOT"/src/chatbox/*.swift "$ROOT"/src/chatbox-mcp/*.swift
    swiftlint lint --strict --quiet --config "$ROOT/.swiftlint.yml" \
        "$ROOT"/src/chatbox/*.swift "$ROOT"/src/chatbox-mcp/*.swift
    shellcheck -s sh "$ROOT/chatbox-cli.sh"
    shellcheck -s sh "$ROOT/release.sh"
    # The suite is one program split across sourced parts; concatenate it so shellcheck sees the
    # whole program rather than seventeen files that cannot see each other's variables.
    { sed '/^\. .*SUITE_LIB/d' "$ROOT/tests/protocol.sh"; cat "$ROOT"/tests/lib/*.sh; } \
        | shellcheck -s sh -f gcc -
}

gate_build() { # a clean scratch build, with the log scanned for warnings, and the arch asserted
    note "gate: clean arm64 build"
    rm -rf "$DIST/build"
    mkdir -p "$DIST/build"
    xcrun swiftc -O -warnings-as-errors "$ROOT"/src/chatbox/*.swift -o "$DIST/build/chatbox" \
        2> "$DIST/build/chatbox.log"
    xcrun swiftc -O -warnings-as-errors "$ROOT"/src/chatbox-mcp/*.swift -o "$DIST/build/chatbox-mcp" \
        2> "$DIST/build/chatbox-mcp.log"
    for _b in chatbox chatbox-mcp; do
        if [ -s "$DIST/build/$_b.log" ]; then
            cat "$DIST/build/$_b.log" >&2
            die "the $_b build produced diagnostics"
        fi
        _arch="$(lipo -archs "$DIST/build/$_b")"
        [ "$_arch" = "arm64" ] || die "$_b is $_arch, not arm64"
    done
    xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
        -typecheck "$ROOT"/src/chatbox/*.swift
    xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
        -typecheck "$ROOT"/src/chatbox-mcp/*.swift
    note "gate: 0 diagnostics, both binaries arm64, strict typecheck 0/0"
}

gate_suite() { # the full protocol suite, against a disposable server on a scratch database
    note "gate: full protocol suite (this takes about fifteen minutes)"
    rm -rf "$DIST/scratch"
    mkdir -p "$DIST/scratch"
    _tok="$DIST/scratch/token"
    openssl rand -hex 24 > "$_tok"
    chmod 600 "$_tok"
    "$DIST/build/chatbox" --port "$HOST_PORT" --db "$DIST/scratch/release.sqlite" \
        --token-file "$_tok" > "$DIST/scratch/server.log" 2>&1 &
    _srv=$!
    _waited=0
    while [ "$_waited" -lt 60 ]; do
        if curl -fsS "http://127.0.0.1:$HOST_PORT/health?token=$(cat "$_tok")" >/dev/null 2>&1; then
            break
        fi
        sleep 0.2
        _waited=$((_waited + 1))
    done
    if ! kill -0 "$_srv" 2>/dev/null; then
        cat "$DIST/scratch/server.log" >&2
        die "the server did not start"
    fi
    _rc=0
    CHATBOX_URL="http://127.0.0.1:$HOST_PORT" CHATBOX_TOKEN="$(cat "$_tok")" \
    CHATBOX_DB="$DIST/scratch/release.sqlite" CHATBOX_SERVER_LOG="$DIST/scratch/server.log" \
    CHATBOX_BIN="$DIST/build/chatbox" CHATBOX_MCP="$DIST/build/chatbox-mcp" \
        sh "$ROOT/tests/protocol.sh" > "$DIST/scratch/suite.out" 2>&1 || _rc=$?
    kill "$_srv" 2>/dev/null || true
    wait "$_srv" 2>/dev/null || true
    if [ "$_rc" -ne 0 ]; then
        tail -20 "$DIST/scratch/suite.out" >&2
        die "the protocol suite failed (exit $_rc)"
    fi
    _line="$(tail -1 "$DIST/scratch/suite.out")"
    printf 'release: %s\n' "$_line"
    case "$_line" in
        *" 0 failed") ;;
        *) die "the suite did not report 0 failed" ;;
    esac
}

# --- package (§1.6–§1.8) ------------------------------------------------------------------------

package() {
    _v="$1"
    note "package: $NAME-$_v-$PLATFORM.tar.gz"
    _stage="$DIST/stage"
    rm -rf "$_stage"
    mkdir -p "$_stage"
    cp "$DIST/build/chatbox" "$DIST/build/chatbox-mcp" "$ROOT/chatbox-cli.sh" "$ROOT/LICENSE" "$_stage/"
    chmod 755 "$_stage/chatbox" "$_stage/chatbox-mcp" "$_stage/chatbox-cli.sh"
    sed "s/@VERSION@/$_v/g" "$ROOT/README-binaries.txt" > "$_stage/README-binaries.txt"
    _archive="$DIST/$NAME-$_v-$PLATFORM.tar.gz"
    rm -f "$_archive" "$_archive.sha256"
    ( cd "$_stage" && COPYFILE_DISABLE=1 tar -czf "$_archive" \
        chatbox chatbox-mcp chatbox-cli.sh LICENSE README-binaries.txt )
    ( cd "$DIST" && shasum -a 256 "$NAME-$_v-$PLATFORM.tar.gz" > "$NAME-$_v-$PLATFORM.tar.gz.sha256" )
    note "checksum: $(cut -d' ' -f1 < "$_archive.sha256")"
}

notes() { # a publish must carry either the placeholders or the real digest (§1.8)
    _v="$1"
    _src="$ROOT/docs/release-notes-v$_v.md"
    [ -f "$_src" ] || die "no release notes at docs/release-notes-v$_v.md"
    _sha="$(cut -d' ' -f1 < "$DIST/$NAME-$_v-$PLATFORM.tar.gz.sha256")"
    _bytes="$(wc -c < "$DIST/$NAME-$_v-$PLATFORM.tar.gz" | tr -d ' ')"
    _out="$DIST/release-notes-v$_v.md"
    if grep -q 'SHA256_PENDING' "$_src" || grep -q 'ARCHIVE_BYTES_PENDING' "$_src"; then
        sed -e "s/SHA256_PENDING/$_sha/" -e "s/ARCHIVE_BYTES_PENDING/$_bytes/" "$_src" > "$_out"
    else
        grep -q "$_sha" "$_src" || die "the notes quote neither the placeholders nor this digest"
        cp "$_src" "$_out"
    fi
    [ -s "$_out" ] || die "the generated notes are empty"
    printf '%s' "$_out"
}

# --- flows --------------------------------------------------------------------------------------

dry_run() {
    _v="$(version)"
    cmd_check
    preconditions
    gate_lint
    gate_build
    gate_suite
    package "$_v"
    _notes="$(notes "$_v")"
    note "dry run complete; nothing was tagged, pushed or published"
    printf '\nrelease: would run:\n'
    printf '  git tag -a v%s -m "AISessionServer %s"\n' "$_v" "$_v"
    printf '  git push origin v%s\n' "$_v"
    printf '  gh release create v%s dist/%s-%s-%s.tar.gz dist/%s-%s-%s.tar.gz.sha256 \\\n' \
        "$_v" "$NAME" "$_v" "$PLATFORM" "$NAME" "$_v" "$PLATFORM"
    printf '     --repo %s --title "%s %s" --notes-file %s --latest\n' \
        "$REPO_SLUG" "$NAME" "$_v" "$_notes"
}

publish() {
    _v="$(version)"
    cmd_check
    preconditions
    if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$_v" >/dev/null 2>&1; then
        die "tag v$_v already exists"
    fi
    gate_lint
    gate_build
    gate_suite
    package "$_v"
    _notes="$(notes "$_v")"
    _archive="$DIST/$NAME-$_v-$PLATFORM.tar.gz"
    _sum="$DIST/$NAME-$_v-$PLATFORM.tar.gz.sha256"
    note "tagging v$_v and publishing"
    git -C "$ROOT" tag -a "v$_v" -m "$NAME $_v"
    git -C "$ROOT" push origin "v$_v"
    gh release create "v$_v" "$_archive" "$_sum" --repo "$REPO_SLUG" \
        --title "$NAME $_v" --notes-file "$_notes" --latest
    # §1.9 — verify what was published, rather than assuming the command did it: the two assets are
    # there, the published notes quote this digest, and the archive downloads back byte-identical.
    _names="$(gh release view "v$_v" --repo "$REPO_SLUG" --json assets --jq '.assets[].name')"
    for _want in "$NAME-$_v-$PLATFORM.tar.gz" "$NAME-$_v-$PLATFORM.tar.gz.sha256"; do
        case "$_names" in
            *"$_want"*) ;;
            *) die "the release is missing the asset $_want" ;;
        esac
    done
    _want_sha="$(cut -d' ' -f1 < "$_sum")"
    rm -f "$DIST/published.tar.gz"
    gh release download "v$_v" --repo "$REPO_SLUG" --pattern "$NAME-$_v-$PLATFORM.tar.gz" \
        --output "$DIST/published.tar.gz" --clobber
    _got_sha="$(shasum -a 256 "$DIST/published.tar.gz" | cut -d' ' -f1)"
    [ "$_got_sha" = "$_want_sha" ] || die "the downloaded archive hashes to $_got_sha, not $_want_sha"
    _body="$(gh release view "v$_v" --repo "$REPO_SLUG" --json body --jq .body)"
    case "$_body" in
        *"$_want_sha"*) ;;
        *) die "the published notes do not quote the digest $_want_sha" ;;
    esac
    note "published and verified: v$_v, sha256 $_want_sha"
    # `gh release view` has no isLatest field; ask the API for the latest release instead, and compare.
    _latest="$(gh api "repos/$REPO_SLUG/releases/latest" --jq .tag_name)"
    [ "$_latest" = "v$_v" ] || die "the latest release is $_latest, not v$_v"
    gh release view "v$_v" --repo "$REPO_SLUG" --json tagName,isDraft,isPrerelease,assets \
        --jq '"release: \(.tagName) draft=\(.isDraft) prerelease=\(.isPrerelease) assets=\(.assets | length)"'
}

case "${1:---dry-run}" in
    --check) cmd_check ;;
    --sync) cmd_sync ;;
    --dry-run) dry_run ;;
    --publish) publish ;;
    *) die "usage: ./release.sh [--check | --sync | --dry-run | --publish]" ;;
esac
