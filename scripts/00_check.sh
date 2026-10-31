#!/usr/bin/env bash
# 00_check.sh: read-only health check of a GB10 / DGX Spark box. Changes nothing, never uses sudo.
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
Usage: bash scripts/00_check.sh

Read-only health check for a Dell Pro Max GB10 / NVIDIA DGX Spark: CPU arch, OS, NVIDIA driver and
CUDA, GPU, SSH, Tailscale, sleep settings, Python headers, build tools, uv, free disk.
Prints PASS / WARN / FAIL per item and exits non-zero if anything FAILs. Never changes the system.
(--check and --yes are accepted for consistency with the other scripts and do nothing extra.)
EOF
}
for a in "$@"; do
  case $a in
    --check|--yes|-y) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

start_log 00_check
echo "GB10 quickstart: system check (read-only, changes nothing)"

# ---------------------------------------------------------------------------------------------
section "System"
arch=$(uname -m)
if [[ $arch == aarch64 ]]; then pass "CPU arch: aarch64 (ARM64)"
else warn "CPU arch: $arch. The kit is verified on aarch64 only; 20_ and 30_ will refuse to run."; fi

os_id=$(os_field ID); os_ver=$(os_field VERSION_ID); os_code=$(os_field VERSION_CODENAME); os_pretty=$(os_field PRETTY_NAME)
if [[ $os_id == ubuntu && $os_ver == 24.04 ]]; then pass "OS: $os_pretty ($os_code)"
elif [[ $os_id == ubuntu ]]; then warn "OS: $os_pretty ($os_code). The kit is verified on Ubuntu 24.04 only."
else warn "OS: ${os_pretty:-unknown}. The kit is verified on Ubuntu 24.04 only."; fi
info "Kernel: $(uname -r)"

# ---------------------------------------------------------------------------------------------
section "GPU"
if ! command -v nvidia-smi >/dev/null; then
  fail "nvidia-smi not found: NVIDIA driver missing?"
else
  drv=$(driver_version); cuda=$(cuda_version); name=$(gpu_name); cc=$(gpu_cc)
  if (( $(driver_major) >= 580 )); then pass "NVIDIA driver: $drv (CUDA 13 wheels need 580+)"
  else fail "NVIDIA driver: ${drv:-unknown}. The CUDA 13 (cu130) PyTorch wheels need driver 580 or newer."; fi
  if [[ ${cuda%%.*} == 13 ]]; then pass "CUDA (driver): $cuda"
  else warn "CUDA (driver): ${cuda:-unknown}. The kit installs cu130 wheels and was verified with CUDA 13.0."; fi
  if [[ $cc == 12.1 ]]; then pass "GPU: $name, compute capability $cc (Blackwell sm_121)"
  elif [[ -n $name ]]; then warn "GPU: $name, compute capability ${cc:-unknown}. The kit is verified on the GB10 (12.1) only."
  else fail "nvidia-smi found no GPU"; fi
  info "nvidia-smi shows GPU memory as [N/A] on GB10: memory is unified (shared with the CPU). That's normal."
fi
if command -v nvcc >/dev/null || [[ -x /usr/local/cuda/bin/nvcc ]]; then
  info "nvcc present (not needed by the kit; the pip wheels bring their own CUDA libraries)"
fi

# ---------------------------------------------------------------------------------------------
section "Remote access"
ssh_pkg=$(dpkg-query -W -f='${Status}|${Version}' openssh-server 2>/dev/null || true)
if [[ $ssh_pkg == "install ok installed|"* ]]; then pass "openssh-server installed (${ssh_pkg#*|})"
else fail "openssh-server not installed"; hint "bash scripts/10_remote_access.sh"; fi

svc_a=$(unit_state is-active ssh.service); sock_a=$(unit_state is-active ssh.socket)
svc_e=$(unit_state is-enabled ssh.service); sock_e=$(unit_state is-enabled ssh.socket)
if [[ $svc_a == active || $sock_a == active ]]; then pass "SSH listening (ssh.socket: ${sock_a:-n/a}, ssh.service: ${svc_a:-n/a}; either one is fine)"
else fail "SSH not running"; hint "bash scripts/10_remote_access.sh"; fi
if [[ $svc_e == enabled || $sock_e == enabled ]]; then pass "SSH starts at boot (ssh.socket: ${sock_e:-n/a}, ssh.service: ${svc_e:-n/a})"
else fail "SSH not enabled at boot"; hint "bash scripts/10_remote_access.sh"; fi

if command -v tailscale >/dev/null; then
  pass "tailscale installed ($(tailscale version 2>/dev/null | first_line))"
  ts_a=$(unit_state is-active tailscaled); ts_e=$(unit_state is-enabled tailscaled)
  if [[ $ts_a == active && $ts_e == enabled ]]; then pass "tailscaled running and enabled at boot"
  else fail "tailscaled: ${ts_a:-unknown}/${ts_e:-unknown} (want active/enabled)"; hint "bash scripts/10_remote_access.sh"; fi
  state=$(ts_backend_state)
  if [[ $state == Running ]]; then pass "Tailscale logged in: $(ts_ipv4)  $(ts_dns_name)"
  else fail "Tailscale not logged in (state: ${state:-unknown})"; hint "bash scripts/10_remote_access.sh"; fi
else
  fail "tailscale not installed"; hint "bash scripts/10_remote_access.sh"
fi

unmasked=$(unmasked_sleep_targets | tr '\n' ' ')
if [[ -z $unmasked ]]; then pass "sleep, suspend, hibernate, hybrid-sleep all masked (the box can't doze off)"
else
  warn "not masked: $unmasked. Ubuntu's login screen can suspend an idle box after ~20 min, cutting SSH."
  hint "bash scripts/10_remote_access.sh"
fi
if command -v gsettings >/dev/null; then
  g=$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null || true)
  info "GNOME idle action on AC power: ${g:-unreadable (normal over SSH)}. Informational only: the masked targets above are what block sleep."
fi

# ---------------------------------------------------------------------------------------------
section "Python and build tools (for ALCHEMI)"
if [[ -x /usr/bin/python3.12 ]]; then
  pass "Python: $(/usr/bin/python3.12 -V 2>&1) at /usr/bin/python3.12"
  if has_py_headers /usr/bin/python3.12; then
    pass "Python headers: $(py_include_dir /usr/bin/python3.12)/Python.h"
  else
    fail "Python headers missing (Python.h). The first torch.compile/Triton call, including inside MACE, will crash with an InductorError."
    hint "sudo apt install -y python3.12-dev     (or, no sudo: bash scripts/20_alchemi_env.sh --managed-python)"
  fi
else
  warn "/usr/bin/python3.12 not found"; hint "bash scripts/20_alchemi_env.sh --managed-python"
fi
if command -v gcc >/dev/null; then pass "gcc: $(gcc -dumpfullversion 2>/dev/null || gcc -dumpversion)"
else fail "gcc not found (Triton compiles a small C file at first use)"; hint "sudo apt install -y build-essential"; fi
for t in git curl; do
  if command -v "$t" >/dev/null; then pass "$t: $(command -v "$t")"
  else fail "$t not found"; hint "sudo apt install -y $t"; fi
done
uv_bin=$(find_uv || true)
if [[ -n $uv_bin ]]; then pass "uv: $("$uv_bin" --version 2>/dev/null) at $uv_bin"
else warn "uv not installed (20_alchemi_env.sh installs it, user-level, no sudo)"; fi

# ---------------------------------------------------------------------------------------------
section "Disk"
free_gb=$(df -Pk "$HOME" | awk 'NR==2 {print int($4 / 1048576)}')
if (( free_gb >= 30 )); then pass "free space in \$HOME: ${free_gb} GB (the ALCHEMI venv is about 9 GB)"
else warn "free space in \$HOME: ${free_gb} GB. The ALCHEMI venv is about 9 GB; leave 30 GB to be comfortable."; fi

# ---------------------------------------------------------------------------------------------
section "Summary"
echo "  $N_PASS PASS, $N_WARN WARN, $N_FAIL FAIL"
if (( N_FAIL )); then
  echo "  Fix the FAIL items (each has a 'fix:' line above), then re-run this check."
  exit 1
fi
echo "  All set for the next steps: 10_remote_access.sh (if not already done), 20_alchemi_env.sh, 30_smoke_test.sh."
