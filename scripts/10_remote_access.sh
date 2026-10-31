#!/usr/bin/env bash
# 10_remote_access.sh: make a GB10 / DGX Spark reachable from your laptop (SSH over Tailscale) and stop it
# from suspending itself at the login screen. Idempotent: on a configured machine it changes nothing.
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
Usage: bash scripts/10_remote_access.sh [--check] [--yes] [--no-login]

Checks each item and fixes only what's missing:
  1. OpenSSH server installed, running, enabled at boot
  2. Tailscale installed from its signed apt repo (pkgs.tailscale.com, for your Ubuntu codename)
  3. tailscaled running and enabled at boot
  4. sleep / suspend / hibernate / hybrid-sleep masked (the login screen can otherwise suspend an idle box)
  5. Tailscale logged in: runs 'sudo tailscale up' ONLY if Tailscale reports it needs a login
Then prints the ssh command to use from your laptop.

Run it as your normal user. It calls sudo itself, only for the steps that need doing.
  --check     report and show the plan; change nothing, no sudo
  --yes       don't ask before making changes
  --no-login  never run 'tailscale up' (log in yourself later)
EOF
}

CHECK_ONLY=0; ASSUME_YES=0; NO_LOGIN=0
for a in "$@"; do
  case $a in
    --check) CHECK_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --no-login) NO_LOGIN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

(( EUID != 0 )) || die "Run this as your normal user, not with sudo. It calls sudo itself for the steps that need it."
LOGIN_USER=${USER:-$(id -un)}

ok() { echo "  OK    $*"; }
PLAN=(); ACTIONS=()
plan() { PLAN+=("$1"); ACTIONS+=("$2"); }

# Look at every item; print its state and queue an action for anything missing.
detect() {
  PLAN=(); ACTIONS=()
  local pkg u active=no enabled=no unmasked state

  # 1. SSH (Ubuntu 24.04 often uses socket activation: ssh.socket active, ssh.service idle. Either is fine.)
  pkg=$(dpkg-query -W -f='${Status}' openssh-server 2>/dev/null || true)
  for u in ssh.socket ssh.service; do
    if [[ $(unit_state is-active "$u") == active ]]; then active=yes; fi
    if [[ $(unit_state is-enabled "$u") == enabled ]]; then enabled=yes; fi
  done
  if [[ $pkg != "install ok installed" ]]; then
    todo "OpenSSH server not installed"
    plan "Install OpenSSH server and start it at boot (apt-get install openssh-server; systemctl enable --now ssh)" do_install_ssh
  elif [[ $active != yes || $enabled != yes ]]; then
    todo "OpenSSH installed but not running/enabled (running: $active, enabled: $enabled)"
    plan "Start SSH and enable it at boot (systemctl enable --now ssh)" do_enable_ssh
  else
    ok "SSH server installed, running, starts at boot"
  fi

  # 2. Tailscale package
  if command -v tailscale >/dev/null; then
    ok "Tailscale installed ($(tailscale version 2>/dev/null | first_line))"
  else
    todo "Tailscale not installed"
    plan "Add Tailscale's signed apt repo for Ubuntu '$(os_field VERSION_CODENAME)' and install tailscale" do_install_tailscale
  fi

  # 3. tailscaled service
  if [[ $(unit_state is-active tailscaled) == active && $(unit_state is-enabled tailscaled) == enabled ]]; then
    ok "tailscaled running and enabled at boot"
  else
    todo "tailscaled not running/enabled"
    plan "Start tailscaled and enable it at boot (systemctl enable --now tailscaled)" do_enable_tailscaled
  fi

  # 4. Sleep targets
  unmasked=$(unmasked_sleep_targets | tr '\n' ' ')
  if [[ -z $unmasked ]]; then
    ok "sleep, suspend, hibernate, hybrid-sleep masked"
  else
    todo "not masked: $unmasked"
    plan "Mask sleep/suspend/hibernate/hybrid-sleep so an idle box stays reachable (systemctl mask ...)" do_mask_sleep
  fi

  # 5. Tailscale login. Never re-run 'tailscale up' on a machine that is already up.
  state=$(ts_backend_state)
  if [[ $state == Running ]]; then
    ok "Tailscale logged in"
  elif (( NO_LOGIN )); then
    todo "Tailscale not logged in (state: ${state:-unknown}); leaving it because of --no-login"
  elif [[ -z $state || $state == NeedsLogin || $state == NoState ]]; then
    todo "Tailscale not logged in (state: ${state:-not running yet})"
    plan "Log in to Tailscale: 'sudo tailscale up' prints a link; sign in with the SAME account as your laptop" do_tailscale_up
  else
    todo "Tailscale state is '$state'. Not touching it. If you need it up, run 'sudo tailscale up' yourself with the flags you used before."
  fi
}

# ---------- actions (each one re-checks before acting) ----------
do_install_ssh() {
  run sudo apt-get update
  run sudo apt-get install -y openssh-server
  run sudo systemctl enable --now ssh
}
do_enable_ssh() { run sudo systemctl enable --now ssh; }

do_install_tailscale() {
  if command -v tailscale >/dev/null; then echo "  tailscale already installed"; return 0; fi
  local id code base tmp
  id=$(os_field ID); code=$(os_field VERSION_CODENAME)
  [[ $id == ubuntu && -n $code ]] || die "Automatic Tailscale install is for Ubuntu only (this is ID='$id'). See https://tailscale.com/download/linux"
  base=https://pkgs.tailscale.com/stable/ubuntu/$code
  tmp=$(mktemp -d)
  run curl -fsSL -o "$tmp/tailscale.gpg" "$base.noarmor.gpg" || die "Tailscale has no apt repo for Ubuntu '$code' ($base.noarmor.gpg)"
  run curl -fsSL -o "$tmp/tailscale.list" "$base.tailscale-keyring.list" || die "Couldn't download $base.tailscale-keyring.list"
  grep -q '^deb .*pkgs\.tailscale\.com' "$tmp/tailscale.list" || die "Unexpected content in $base.tailscale-keyring.list; not installing it"
  run sudo install -m 644 "$tmp/tailscale.gpg" /usr/share/keyrings/tailscale-archive-keyring.gpg
  run sudo install -m 644 "$tmp/tailscale.list" /etc/apt/sources.list.d/tailscale.list
  run sudo apt-get update
  run sudo apt-get install -y tailscale
}

do_enable_tailscaled() { run sudo systemctl enable --now tailscaled; }

do_mask_sleep() { run sudo systemctl mask "${SLEEP_TARGETS[@]}"; }

do_tailscale_up() {
  local s="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do   # tailscaled may need a moment after a fresh install
    s=$(ts_backend_state)
    if [[ -n $s && $s != NoState ]]; then break; fi
    sleep 1
  done
  case $s in
    Running)
      echo "  Already logged in; not running 'tailscale up'." ;;
    NeedsLogin|NoState)
      echo "  Open the link below and sign in with the SAME Tailscale account your laptop uses."
      run sudo tailscale up ;;
    *)
      echo "  Tailscale state is '${s:-unreadable}', so not running 'tailscale up' automatically."
      echo "  If you need to log in, run it yourself:  sudo tailscale up" ;;
  esac
}

show_access() {
  section "Connect from your laptop"
  local state ip name
  state=$(ts_backend_state)
  if [[ $state != Running ]]; then
    echo "  Tailscale isn't logged in yet (state: ${state:-unknown}), so there's no address to show."
    return 0
  fi
  ip=$(ts_ipv4); name=$(ts_dns_name)
  echo "  Tailscale IPv4:  $ip"
  echo "  MagicDNS name:   ${name:-(none)}"
  echo
  echo "  On your laptop (Tailscale app running, signed in to the same account):"
  echo "      ssh $LOGIN_USER@$ip"
  if [[ -n $name ]]; then echo "      ssh $LOGIN_USER@${name%%.*}        (MagicDNS short name)"; fi
  echo
  echo "  Teammates: see docs/TEAMMATES.md"
}

# ---------- main ----------
start_log 10_remote_access
if (( CHECK_ONLY )); then echo "GB10 quickstart: remote access (check only: no changes, no sudo)"
else echo "GB10 quickstart: remote access"; fi
if [[ $(uname -m) != aarch64 ]]; then
  echo "Note: this machine is $(uname -m), not aarch64. These steps don't depend on the CPU, but the kit was verified on a GB10 only."
fi

section "Current state"
detect

section "Plan"
if (( ${#ACTIONS[@]} == 0 )); then
  echo "  Nothing to do: already configured."
else
  for i in "${!PLAN[@]}"; do echo "  $((i + 1)). ${PLAN[$i]}"; done
fi

if (( CHECK_ONLY )); then
  if (( ${#ACTIONS[@]} )); then echo; echo "  Check mode: nothing changed. Run without --check to apply."; fi
  show_access
  exit 0
fi

if (( ${#ACTIONS[@]} )); then
  command -v sudo >/dev/null || die "sudo not found; run the steps above as an administrator."
  confirm "Apply the steps above? sudo will ask for your password." || die "Cancelled; nothing changed."
  run sudo -v
  for i in "${!ACTIONS[@]}"; do
    section "Step $((i + 1)): ${PLAN[$i]}"
    "${ACTIONS[$i]}"
  done
  section "Verify"
  detect
  if (( ${#ACTIONS[@]} )); then
    show_access
    die "Some items still need attention (TODO above). The log has the details."
  fi
  echo "  All items configured."
fi
show_access
