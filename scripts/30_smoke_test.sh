#!/usr/bin/env bash
# 30_smoke_test.sh: prove ALCHEMI + MACE really run on the GPU, and that the physics is right.
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODEL=${MACE_MODEL:-medium-mpa-0}

usage() {
  cat <<EOF
Usage: bash scripts/30_smoke_test.sh [--dir DIR] [--full] [--check]

  1. Runs NVIDIA's official example examples/advanced/04_mace_nvt.py with MACE_MODEL_PATH=$MODEL and
     FAILS if it fell back to Lennard-Jones (the example does that quietly, without an error).
  2. Runs scripts/smoke_throughput.py: MACE NVE dynamics of a periodic Cu crystal. Asserts the GPU is
     used, energy drift < 1e-6 eV/atom/step, and equipartition (a 300 K start settles at 120-180 K),
     and prints throughput next to our GB10 reference numbers.

  --dir DIR   folder that holds .venv and nvalchemi-toolkit/ (default: current directory)
  --full      add the slow plain-e3nn runs, 2,048 atoms and 8 x 864 batched (~11 min instead of ~2)
  --check     only check that the environment is in place; don't use the GPU

The first run downloads the MACE-MPA-0 weights (~80 MB) to ~/.cache/mace.
Set MACE_MODEL=<name or path> to try another MACE-MP checkpoint (default: medium-mpa-0).
EOF
}

DIR=$PWD; FULL=0; CHECK_ONLY=0
while (( $# )); do
  case $1 in
    --dir) [[ $# -ge 2 ]] || die "--dir needs a path"; DIR=$2; shift ;;
    --dir=*) DIR=${1#--dir=} ;;
    --full) FULL=1 ;;
    --check) CHECK_ONLY=1 ;;
    --yes|-y) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
DIR=$(realpath -m "$DIR")
PY=$DIR/.venv/bin/python
EXAMPLE=$DIR/nvalchemi-toolkit/examples/advanced/04_mace_nvt.py
if (( FULL )); then MODE="full: e3nn + cuEq, 864 + 2,048 atoms, 8 x 864 batched; ~11 min"
else MODE="quick: cuEq, 864 atoms, 50 warm-up + 300 timed steps"; fi

start_log 30_smoke_test
if (( CHECK_ONLY )); then echo "GB10 quickstart: smoke test (check only: no GPU use)"
else echo "GB10 quickstart: smoke test"; fi
cat <<EOF

Plan (env: $DIR)
  1. Official example 04_mace_nvt.py with MACE_MODEL_PATH=$MODEL: must print 'Using MACE model'
     and must not fall back to Lennard-Jones
  2. MACE NVE throughput + physics checks ($MODE)
EOF

# ---------------------------------------------------------------------------------------------
section "Preflight"
require_aarch64
pass "CPU arch: aarch64"
if [[ -x $PY ]]; then pass "venv: $PY"
else fail "no venv at $DIR/.venv"; hint "bash scripts/20_alchemi_env.sh --dir $DIR   (or pass the right --dir)"; fi
if [[ -f $EXAMPLE ]]; then pass "official example: $EXAMPLE"
else fail "missing $EXAMPLE"; hint "bash scripts/20_alchemi_env.sh --dir $DIR   (clones the toolkit at the matching tag)"; fi
if (( N_FAIL )); then die "Preflight failed; see the fix lines above."; fi
if (( CHECK_ONLY )); then
  echo; echo "  Check mode: environment in place; GPU not used."
  exit 0
fi

# ---------------------------------------------------------------------------------------------
section "1. Official MACE example (looking for the silent Lennard-Jones fallback)"
out=${LOG_FILE%.log}-04_mace_nvt.txt
echo "  \$ MACE_MODEL_PATH=$MODEL $(_q "$PY" "$EXAMPLE")"
if MACE_MODEL_PATH=$MODEL "$PY" "$EXAMPLE" 2>&1 | tee "$out"; then rc=0; else rc=$?; fi
echo
if (( rc == 0 )); then pass "example exited 0"; else fail "example exited with code $rc"; fi
if grep -q "Using MACE model" "$out"; then pass "'Using MACE model' printed"
else fail "'Using MACE model' NOT printed: MACE failed to load"; fi
if grep -qE "Model used +: MACE" "$out"; then pass "'Model used: MACE'"
else fail "the example did not report 'Model used: MACE'"; fi
if grep -qE "Falling back to LJ|Lennard-Jones \(fallback\)|Using LJ model" "$out"; then
  fail "the example fell back to Lennard-Jones: the numbers are NOT from MACE (see docs/TROUBLESHOOTING.md)"
fi
temp_line=$({ grep -E "Inst\. temp" "$out" || true; } | first_line)
if [[ -n $temp_line ]]; then info "example: ${temp_line#"${temp_line%%[![:space:]]*}"}"; fi

# ---------------------------------------------------------------------------------------------
section "2. MACE throughput + physics checks ($MODE)"
args=(--model "$MODEL" --out "$LOG_DIR")
if (( FULL )); then args+=(--full); fi
if run "$PY" "$KIT_ROOT/scripts/smoke_throughput.py" "${args[@]}"; then pass "throughput and physics checks passed"
else fail "throughput/physics checks failed (details above)"; fi

# ---------------------------------------------------------------------------------------------
section "Summary"
echo "  $N_PASS PASS, $N_WARN WARN, $N_FAIL FAIL"
if (( N_FAIL )); then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS. ALCHEMI + MACE run on this GPU, and the physics checks out."
