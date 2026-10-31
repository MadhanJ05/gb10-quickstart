# shellcheck shell=bash
# Shared helpers for the GB10 quickstart scripts. Each script sources this file; don't run it directly.

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$KIT_ROOT/logs"
LOG_FILE=""
N_PASS=0
N_WARN=0
N_FAIL=0

# ---------- output ----------
pass()    { N_PASS=$((N_PASS + 1)); echo "  PASS  $*"; }
warn()    { N_WARN=$((N_WARN + 1)); echo "  WARN  $*"; }
fail()    { N_FAIL=$((N_FAIL + 1)); echo "  FAIL  $*"; }
info()    { echo "  INFO  $*"; }
todo()    { echo "  TODO  $*"; }
hint()    { echo "        fix: $*"; }
section() { echo; echo "== $*"; }
die()     { echo >&2; echo "ERROR: $*" >&2; exit 1; }

# Quote arguments for display the way you'd type them.
_q() {
  local a out=""
  for a in "$@"; do
    if [[ $a =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then out+="$a "; else out+="'${a//\'/\'\\\'\'}' "; fi
  done
  echo "${out% }"
}

# Show a command, then run it.
run() { echo "  \$ $(_q "$@")"; "$@"; }

# Ask yes/no. --yes (ASSUME_YES=1) answers yes; with no terminal to ask, the answer is no.
confirm() {
  [[ ${ASSUME_YES:-0} == 1 ]] && return 0
  if [[ ! -t 0 ]]; then echo "  (no terminal to ask: re-run with --yes to proceed)"; return 1; fi
  local ans=""
  read -r -p "$1 [y/N] " ans || true
  [[ $ans == [yY]* ]]
}

# ---------- logging: everything printed also goes to logs/<name>-<timestamp>.log, untruncated ----------
start_log() {
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/$1-$(date +%Y%m%d-%H%M%S)-$$.log"
  exec 3>&1 4>&2
  exec > >(tee -a "$LOG_FILE") 2>&1
  _TEE_PID=$!
  trap _on_exit EXIT
  trap 'echo "!! failed (exit $?) at ${BASH_SOURCE[0]##*/}:$LINENO: $BASH_COMMAND" >&2' ERR
  echo "Log: $LOG_FILE"
}
_on_exit() {
  local rc=$?
  _finish_log
  exit "$rc"
}
_finish_log() {
  echo "Full log: $LOG_FILE"
  exec 1>&3 2>&4
  wait "$_TEE_PID" 2>/dev/null || true
}

# ---------- detection (all read-only) ----------
first_line() { awk 'NR==1'; }

# os_field ID | VERSION_ID | VERSION_CODENAME | PRETTY_NAME
os_field() { { grep -E "^$1=" /etc/os-release 2>/dev/null || true; } | first_line | cut -d= -f2- | tr -d '"'; }

driver_version() { { nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || true; } | first_line | tr -d ' '; }
driver_major() {
  local v
  v=$(driver_version); v=${v%%.*}
  if [[ $v =~ ^[0-9]+$ ]]; then echo "$v"; else echo 0; fi
}
cuda_version() {
  { nvidia-smi 2>/dev/null || true; } | { grep -oE 'CUDA Version: [0-9]+\.[0-9]+' || true; } \
    | { grep -oE '[0-9.]+$' || true; } | first_line
}
gpu_name() { { nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || true; } | first_line; }
gpu_cc()   { { nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null || true; } | first_line | tr -d ' '; }

find_uv() {
  local c
  for c in "$(command -v uv 2>/dev/null || true)" "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv"; do
    if [[ -n $c && -x $c ]]; then echo "$c"; return 0; fi
  done
  return 1
}

# Where a Python interpreter's headers live, and whether Python.h is there. Same lookup as Triton's own
# build step (triton/runtime/build.py), including its swap of Debian's 'posix_local' scheme for 'posix_prefix'.
py_include_dir() {
  "$1" -c '
import sysconfig
s = sysconfig.get_default_scheme()
print(sysconfig.get_paths(scheme="posix_prefix" if s == "posix_local" else s)["include"])' 2>/dev/null
}
has_py_headers() { local d; d=$(py_include_dir "$1") || return 1; [[ -f $d/Python.h ]]; }

# Tailscale state, read without sudo. Empty output = not installed, or tailscaled not running.
_ts_json() {
  { tailscale status --json 2>/dev/null || true; } | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if sys.argv[1] == "state":
    print(d.get("BackendState", ""))
else:
    print((d.get("Self") or {}).get("DNSName", "").rstrip("."))
' "$1" 2>/dev/null || true
}
ts_backend_state() { _ts_json state; }
ts_dns_name()      { _ts_json dns; }
ts_ipv4()          { { tailscale ip -4 2>/dev/null || true; } | first_line; }

# unit_state is-active ssh.socket  -> active / inactive / ...
unit_state() { systemctl "$1" "$2" 2>/dev/null || true; }
load_state() { systemctl show -p LoadState --value "$1" 2>/dev/null || true; }
SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)
unmasked_sleep_targets() {
  local t
  for t in "${SLEEP_TARGETS[@]}"; do
    if [[ $(load_state "$t") != masked ]]; then echo "$t"; fi
  done
}

require_aarch64() {
  local a
  a=$(uname -m)
  [[ $a == aarch64 ]] || die "This script is for ARM64 (aarch64) machines such as the GB10 / DGX Spark; this one is '$a'. The cu130 ARM64 install and the reference numbers don't apply to x86."
}
