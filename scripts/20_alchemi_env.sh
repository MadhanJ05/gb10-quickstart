#!/usr/bin/env bash
# 20_alchemi_env.sh: install NVIDIA ALCHEMI (nvalchemi-toolkit) with MACE + cuEquivariance into <dir>/.venv,
# user-level (no sudo), the way we verified it on a Dell Pro Max GB10. Safe to re-run.
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NVALCHEMI_VERSION=${NVALCHEMI_VERSION:-0.2.0}
EXTRAS="cu13,mace,aimnet,ase,pymatgen"
TOOLKIT_REPO=https://github.com/NVIDIA/nvalchemi-toolkit.git
UV_INSTALLER=https://astral.sh/uv/install.sh

usage() {
  cat <<EOF
Usage: bash scripts/20_alchemi_env.sh [--dir DIR] [--managed-python] [--check] [--yes]

Installs nvalchemi-toolkit $NVALCHEMI_VERSION [$EXTRAS] plus plotext<6, matplotlib, pandas and scipy,
on CUDA 13 (cu130) PyTorch, into DIR/.venv. Then clones the toolkit source at the matching tag into
DIR/nvalchemi-toolkit (for the examples), copies its Claude Code agent skills into DIR/.claude/skills,
and checks the GPU. No sudo.

  --dir DIR          where .venv, nvalchemi-toolkit/ and .claude/skills go (default: current directory)
  --managed-python   build the venv on uv's own Python 3.12, which ships Python.h, so you don't need
                     'sudo apt install python3.12-dev'
  --check            report what's installed and what would be done; change nothing
  --yes              don't ask before installing uv or the packages

Environment: NVALCHEMI_VERSION=0.2.0 (default; the version we verified) or 'latest' (untested).
EOF
}

DIR=$PWD; MANAGED=0; CHECK_ONLY=0; ASSUME_YES=0
while (( $# )); do
  case $1 in
    --dir) [[ $# -ge 2 ]] || die "--dir needs a path"; DIR=$2; shift ;;
    --dir=*) DIR=${1#--dir=} ;;
    --managed-python) MANAGED=1 ;;
    --check) CHECK_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
DIR=$(realpath -m "$DIR")
VENV=$DIR/.venv
PY=$VENV/bin/python
CLONE=$DIR/nvalchemi-toolkit
SKILLS=$DIR/.claude/skills
if [[ $NVALCHEMI_VERSION == latest ]]; then PIN=""; else PIN="==$NVALCHEMI_VERSION"; fi
PKGS=("nvalchemi-toolkit[$EXTRAS]$PIN" "plotext<6" matplotlib pandas scipy)
if (( MANAGED )); then PY_DESC="uv-managed Python 3.12 (ships its own headers)"; else PY_DESC="system /usr/bin/python3.12"; fi

venv_home() { awk -F' *= *' '$1 == "home" {print $2}' "$VENV/pyvenv.cfg" 2>/dev/null || true; }
installed_version() { "$PY" -c 'import importlib.metadata as m; print(m.version("nvalchemi-toolkit"))' 2>/dev/null || true; }
headers_fix() {
  hint "sudo apt install -y python3.12-dev     (run it yourself, then re-run this script)"
  hint "or, without sudo: re-run with --managed-python (uv's Python ships its own headers)"
}

start_log 20_alchemi_env
if (( CHECK_ONLY )); then echo "GB10 quickstart: ALCHEMI environment (check only: changes nothing)"
else echo "GB10 quickstart: ALCHEMI environment"; fi
cat <<EOF

Plan (target: $DIR)
  1. Preflight: aarch64, NVIDIA driver 580+, git/curl/gcc, Python 3.12 headers
  2. uv: use the one on this machine, or install it (official installer, user-level, ~/.local/bin)
  3. venv: $VENV on $PY_DESC
  4. Packages: dry run, then install: ${PKGS[*]}
     (torch cu130 build; about 9 GB on disk, several GB of downloads on a fresh machine)
  5. Clone NVIDIA/nvalchemi-toolkit at the tag matching the installed version -> $CLONE
  6. Copy the toolkit's Claude Code agent skills -> $SKILLS
  7. GPU check: matmul on CUDA + one torch.compile (Triton) kernel
EOF

# ---------------------------------------------------------------------------------------------
section "1. Preflight"
require_aarch64
pass "CPU arch: aarch64"
drv=$(driver_version)
if (( $(driver_major) >= 580 )); then pass "NVIDIA driver $drv (CUDA $(cuda_version))"
else fail "NVIDIA driver ${drv:-not found}: the cu130 PyTorch wheels need driver 580 or newer"; fi
for t in git curl gcc; do
  if command -v "$t" >/dev/null; then pass "$t: $(command -v "$t")"
  else
    fail "$t not found"
    if [[ $t == gcc ]]; then hint "sudo apt install -y build-essential   (Triton compiles a small C file at first use)"
    else hint "sudo apt install -y $t"; fi
  fi
done

if [[ -x $PY ]]; then
  if has_py_headers "$PY"; then pass "Python headers for the existing venv ($(venv_home)): $(py_include_dir "$PY")/Python.h"
  else fail "Python.h missing for the existing venv's Python ($(venv_home))"; headers_fix; fi
elif (( MANAGED )); then
  info "Python headers: uv-managed Python ships them (checked again after the venv is created)"
elif [[ ! -x /usr/bin/python3.12 ]]; then
  fail "/usr/bin/python3.12 not found"; hint "re-run with --managed-python"
elif has_py_headers /usr/bin/python3.12; then
  pass "Python headers: $(py_include_dir /usr/bin/python3.12)/Python.h"
else
  fail "Python.h missing for /usr/bin/python3.12. Without it the first torch.compile/Triton call dies with an InductorError."
  headers_fix
fi
if (( N_FAIL )); then
  if (( CHECK_ONLY )); then info "check mode: continuing the report anyway"
  else die "Preflight failed: fix the FAIL items above and re-run. Nothing was installed."; fi
fi

# ---------------------------------------------------------------------------------------------
section "2. uv"
UV=$(find_uv || true)
if [[ -n $UV ]]; then
  pass "$("$UV" --version) at $UV"
elif (( CHECK_ONLY )); then
  todo "uv not installed: would run the official installer ($UV_INSTALLER) into ~/.local/bin"
else
  info "uv not found. Installing it with uv's official installer: $UV_INSTALLER"
  info "(user-level, into ~/.local/bin; it also adds ~/.local/bin to PATH in your shell profile)"
  confirm "Install uv now?" || die "Cancelled; nothing installed."
  tmp=$(mktemp -d)
  run curl -LsSf -o "$tmp/uv-install.sh" "$UV_INSTALLER"
  run sh "$tmp/uv-install.sh"
  UV=$(find_uv) || die "The uv installer finished but no uv binary was found in ~/.local/bin"
  pass "$("$UV" --version) installed at $UV"
fi

# ---------------------------------------------------------------------------------------------
section "3. Virtual environment"
if [[ -x $PY ]]; then
  pyver=$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
  [[ $pyver == 3.12 ]] || die "$VENV uses Python $pyver, not 3.12. Move it away or choose another --dir."
  pass "venv exists: $VENV (Python $pyver, base Python in $(venv_home))"
elif (( CHECK_ONLY )); then
  todo "would create $VENV on $PY_DESC"
else
  mkdir -p "$DIR"
  if (( MANAGED )); then run "$UV" venv --seed --managed-python --python 3.12 "$VENV"
  else run "$UV" venv --seed --python /usr/bin/python3.12 "$VENV"; fi
  if has_py_headers "$PY"; then
    pass "venv created (base Python in $(venv_home)); Python.h at $(py_include_dir "$PY")"
  else
    fail "venv created, but Python.h is missing for $(venv_home)"; headers_fix
    die "Stopping before the big download."
  fi
fi

# ---------------------------------------------------------------------------------------------
section "4. Packages"
installed=""
if [[ -x $PY ]]; then installed=$(installed_version); fi
if (( CHECK_ONLY )); then
  if [[ -n $installed ]]; then info "nvalchemi-toolkit $installed is installed (the kit pins $NVALCHEMI_VERSION); a real run re-checks every package"
  else todo "would install: ${PKGS[*]}"; fi
else
  UVPIP=("$UV" pip install --python "$PY" --torch-backend cu130 --index-strategy unsafe-best-match)
  dry=$(mktemp)
  run "${UVPIP[@]}" --dry-run "${PKGS[@]}" 2>&1 | tee "$dry"
  # uv marks additions/removals with ' + '/' - '. A line with ' ~ ' is a same-version reinstall: uv does
  # that for nvidia-cusparselt-cu13 on every run here, harmlessly. Nothing to add or remove = installed.
  if grep -q "Would make no changes" "$dry" || ! grep -qE '^ [+-] ' "$dry"; then
    pass "all packages already installed at the resolved versions; nothing to do"
  else
    confirm "Install the packages listed above?" || die "Cancelled. The venv is in place; packages not installed."
    run "${UVPIP[@]}" "${PKGS[@]}"
  fi
  installed=$(installed_version)
  [[ -n $installed ]] || die "nvalchemi-toolkit is not importable after the install; see the log."
  pass "nvalchemi-toolkit $installed installed. Key versions:"
  "$PY" - <<'PY'
from importlib.metadata import PackageNotFoundError, version
for p in ["nvalchemi-toolkit", "nvalchemi-toolkit-ops", "torch", "mace-torch", "cuequivariance",
          "cuequivariance-ops-torch-cu13", "aimnet", "warp-lang", "ase", "numpy", "plotext"]:
    try:
        v = version(p)
    except PackageNotFoundError:
        v = "(not installed)"
    print(f"        {p:32s} {v}")
PY
fi

# ---------------------------------------------------------------------------------------------
section "5. Toolkit source (examples) at the matching tag"
if [[ -z $installed ]]; then
  todo "after the install: clone $TOOLKIT_REPO at v<installed version> -> $CLONE"
else
  tag="v$installed"
  if [[ -d $CLONE/.git ]]; then
    cur=$(git -C "$CLONE" describe --tags --exact-match 2>/dev/null || true)
    if [[ $cur == "$tag" ]]; then
      pass "$CLONE is at $tag"
    elif (( CHECK_ONLY )); then
      todo "$CLONE is at '${cur:-a non-release commit}'; would check out $tag"
    elif [[ -n $(git -C "$CLONE" status --porcelain) ]]; then
      die "$CLONE has local changes and isn't at $tag. Commit or stash them (or move the folder), then re-run."
    else
      if ! git -C "$CLONE" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        depth=()
        if [[ $(git -C "$CLONE" rev-parse --is-shallow-repository) == true ]]; then depth=(--depth 1); fi
        run git -C "$CLONE" fetch "${depth[@]}" origin "refs/tags/$tag:refs/tags/$tag"
      fi
      run git -C "$CLONE" -c advice.detachedHead=false checkout "$tag"
      pass "$CLONE is now at $tag"
    fi
  elif [[ -e $CLONE ]]; then
    die "$CLONE exists but isn't a git clone. Move it away and re-run."
  elif (( CHECK_ONLY )); then
    todo "would clone $TOOLKIT_REPO at $tag -> $CLONE"
  else
    run git -c advice.detachedHead=false clone --depth 1 --branch "$tag" "$TOOLKIT_REPO" "$CLONE"
    pass "cloned at $tag"
  fi
fi

# ---------------------------------------------------------------------------------------------
section "6. ALCHEMI agent skills for Claude Code"
src=$CLONE/.claude/skills
if [[ ! -d $src ]]; then
  if [[ -d $CLONE ]]; then warn "the toolkit has no .claude/skills at this tag; skipping"
  else todo "after cloning: copy the toolkit's skills -> $SKILLS"; fi
else
  n_new=0; n_same=0
  for s in "$src"/*; do
    [[ -e $s ]] || continue
    name=$(basename "$s")
    if [[ ! -e $SKILLS/$name ]]; then
      if (( CHECK_ONLY )); then todo "would copy skill: $name"
      else mkdir -p "$SKILLS"; cp -r "$s" "$SKILLS/$name"; n_new=$((n_new + 1)); fi
    elif diff -rq "$s" "$SKILLS/$name" >/dev/null 2>&1; then
      n_same=$((n_same + 1))
    else
      warn "skill '$name' differs from the toolkit's copy; left as is (delete $SKILLS/$name and re-run to refresh)"
    fi
  done
  if (( ! CHECK_ONLY )) || (( n_same )); then pass "skills in $SKILLS: $n_new copied, $n_same already up to date"; fi
fi

# ---------------------------------------------------------------------------------------------
section "7. GPU check"
if (( CHECK_ONLY )); then
  info "skipped in check mode"
elif run "$PY" "$KIT_ROOT/scripts/gpu_check.py"; then
  pass "GPU check passed: CUDA matmul + torch.compile/Triton kernel"
else
  fail "GPU check failed (error above)"
  hint "an InductorError mentioning gcc/driver.c means missing Python headers; see docs/TROUBLESHOOTING.md"
fi

# ---------------------------------------------------------------------------------------------
section "Summary"
echo "  $N_PASS PASS, $N_WARN WARN, $N_FAIL FAIL"
if (( N_FAIL )); then exit 1; fi
if (( CHECK_ONLY )); then echo "  Check mode: nothing was changed."; exit 0; fi
cat <<EOF
  ALCHEMI is ready in $DIR
    activate:    source $VENV/bin/activate
    smoke test:  bash $KIT_ROOT/scripts/30_smoke_test.sh --dir $DIR
    examples:    $CLONE/examples
    skills:      $SKILLS   (start Claude Code in $DIR to use them)
EOF
