# Optional tools on ARM64, no sudo, checksum-verified

Both CLIs publish `linux_arm64` builds with a SHA-256 checksum file. The snippets download both, verify the checksum,
and install into `~/.local/bin`. Each one runs in a child shell (`bash -eu <<'EOF'`), so an error can't close your
terminal (see [TROUBLESHOOTING.md #17](TROUBLESHOOTING.md#17-pasting-a-snippet-that-starts-with-set--e-closes-your-terminal)).

The version lookup uses GitHub's API, which allows 60 requests per hour per IP. On busy hackathon Wi-Fi you may hit
that limit; the snippet then stops with "rate limit". Set the version by hand, e.g. `GH_VER=2.103.3 bash -eu <<'EOF'`.

## GitHub CLI (`gh`)

Tested as written on our GB10 (installed v2.103.3).

```bash
bash -eu <<'EOF'
mkdir -p ~/.local/bin
D=$(mktemp -d)
if [ -z "${GH_VER:-}" ]; then
  curl -fsSL -o "$D/latest.json" https://api.github.com/repos/cli/cli/releases/latest || true
  GH_VER=$(grep -m1 '"tag_name"' "$D/latest.json" 2>/dev/null | cut -d'"' -f4 | sed 's/^v//') || true
  [ -n "$GH_VER" ] || { echo "GitHub API lookup failed (rate limit?). Set GH_VER=<version> and retry."; exit 1; }
fi
curl -fsSL -o "$D/gh.tar.gz"     "https://github.com/cli/cli/releases/download/v${GH_VER}/gh_${GH_VER}_linux_arm64.tar.gz"
curl -fsSL -o "$D/checksums.txt" "https://github.com/cli/cli/releases/download/v${GH_VER}/gh_${GH_VER}_checksums.txt"
SUM=$(grep " gh_${GH_VER}_linux_arm64.tar.gz$" "$D/checksums.txt" | cut -d' ' -f1)
[ -n "$SUM" ]
echo "$SUM  $D/gh.tar.gz" | sha256sum -c -
tar -xzf "$D/gh.tar.gz" -C "$D"
install -m 755 "$D/gh_${GH_VER}_linux_arm64/bin/gh" ~/.local/bin/gh
~/.local/bin/gh --version
EOF
```

Log in (interactive; your own terminal):

```bash
~/.local/bin/gh auth login --hostname github.com --git-protocol https --web
```

The token goes into the desktop keyring, which may be unreadable from SSH-only sessions. Untested workaround:
add `--insecure-storage` (stores the token in plain text in `~/.config/gh/hosts.yml`).

## Brev CLI (`brev`)

Tested as written on our GB10 (we first installed v0.6.337 this way). The binary is about 50 MB.

```bash
bash -eu <<'EOF'
mkdir -p ~/.local/bin
D=$(mktemp -d)
if [ -z "${BREV_VER:-}" ]; then
  curl -fsSL -o "$D/latest.json" https://api.github.com/repos/brevdev/brev-cli/releases/latest || true
  BREV_VER=$(grep -m1 '"tag_name"' "$D/latest.json" 2>/dev/null | cut -d'"' -f4 | sed 's/^v//') || true
  [ -n "$BREV_VER" ] || { echo "GitHub API lookup failed (rate limit?). Set BREV_VER=<version> and retry."; exit 1; }
fi
curl -fsSL -o "$D/brev.tar.gz"   "https://github.com/brevdev/brev-cli/releases/download/v${BREV_VER}/brev-cli_${BREV_VER}_linux_arm64.tar.gz"
curl -fsSL -o "$D/checksums.txt" "https://github.com/brevdev/brev-cli/releases/download/v${BREV_VER}/brev-cli_${BREV_VER}_checksums.txt"
SUM=$(grep " brev-cli_${BREV_VER}_linux_arm64.tar.gz$" "$D/checksums.txt" | cut -d' ' -f1)
[ -n "$SUM" ]
echo "$SUM  $D/brev.tar.gz" | sha256sum -c -
tar -xzf "$D/brev.tar.gz" -C "$D" brev
install -m 755 "$D/brev" ~/.local/bin/brev
ls -l ~/.local/bin/brev
EOF
```

Brev's official `install-latest.sh` also installs to `~/.local/bin` without sudo, but it **doesn't verify checksums**.

Log in with `brev login`; `brev ls` lists your instances and is free. **Creating or starting an instance bills until you
stop it.**
