# GB10 Quickstart

Four scripts take a **Dell Pro Max GB10** from "just unboxed" to "I can SSH in from my laptop, and NVIDIA ALCHEMI runs
on the GPU".

From the [Cool Orbit](https://github.com/MadhanJ05/cool-orbit) team at the ScienceClaw hackathon (MIT Media Lab, 2026).
We hit every snag in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) on our own GB10 so you don't have to.

| | |
|---|---|
| **Verified on** | Dell Pro Max GB10: aarch64, Ubuntu 24.04.5, NVIDIA driver 580.178.04, CUDA 13.0 |
| **Probably works on** | NVIDIA DGX Spark (same GB10 chip, Ubuntu 24.04-based DGX OS). **Not tested.** If you try it, please open an issue with your `00_check.sh` output. |
| **Not supported** | x86_64. The install scripts stop with a clear message. |

## What you get

- **Remote access.** SSH from your laptop over Tailscale, from any network. The box stops suspending itself at the
  login screen.
- **ALCHEMI on the GPU.** `nvalchemi-toolkit` 0.2.0 with MACE, AIMNet2, ASE and pymatgen on CUDA 13 PyTorch. You also
  get the toolkit's examples at the matching version and its Claude Code agent skills.
- **Proof that it works.** The smoke test fails loudly instead of quietly running the wrong thing. It checks that the
  GPU is used, that MACE really loaded (the official example silently falls back to Lennard-Jones), that energy is
  conserved, and that equipartition holds.
- **Safe scripts.** Each one prints its plan first, has a `--check` mode, changes nothing when re-run on a configured
  box, and writes its full output to `logs/`.

## Quick start

At the GB10 itself (keyboard and monitor, or any terminal on it):

```bash
git clone https://github.com/MadhanJ05/gb10-quickstart.git ~/gb10-quickstart
cd ~/gb10-quickstart
bash scripts/00_check.sh        # read-only: PASS / WARN / FAIL for everything below
```

### 1. Remote access (sudo)

```bash
bash scripts/10_remote_access.sh --check   # what would change (no sudo, no changes)
bash scripts/10_remote_access.sh           # asks for your password, then prints a Tailscale sign-in link
```

Sign in with **the same Tailscale account your laptop uses**, so both devices see each other with no invites. The
script finishes by printing the command for your laptop:

```text
ssh <your-linux-user>@100.x.y.z
```

On the laptop, install the Tailscale app and sign in to that same account. From here on you can work from the laptop.

The script does only what's still missing:
- install and enable OpenSSH
- install Tailscale from its signed apt repo and enable `tailscaled`
- mask sleep, suspend and hibernate (Ubuntu's login screen can otherwise suspend an idle box after about 20 minutes,
  even if your desktop setting says never)
- run `tailscale up`, but only if Tailscale says it needs a login

### 2. Python headers (sudo, once)

```bash
sudo apt install -y python3.12-dev
```

Without these headers, the first `torch.compile`/Triton call crashes with an `InductorError`, and MACE with
cuEquivariance uses Triton. No sudo? Skip this step and add `--managed-python` in step 3. The venv then uses uv's own
Python (3.12.16 for us, a 28 MB download), which ships the headers.

### 3. ALCHEMI environment (no sudo)

```bash
bash scripts/20_alchemi_env.sh --dir ~/my-project
```

This puts three things into `~/my-project`:

- `.venv/`: nvalchemi-toolkit 0.2.0 `[cu13,mace,aimnet,ase,pymatgen]`, PyTorch cu130, `plotext<6`, matplotlib,
  pandas, scipy. It's about 9 GB on disk and several GB to download. (On our box the packages came from uv's cache,
  so we haven't timed a fresh download.)
- `nvalchemi-toolkit/`: NVIDIA's source at tag `v0.2.0`, for the examples.
- `.claude/skills/`: the toolkit's ALCHEMI agent skills for Claude Code.

It installs `uv` (user-level) if needed, shows a dry run before installing, and ends with a GPU check that includes a
`torch.compile` kernel.

### 4. Smoke test (GPU, 1 to 2 minutes)

```bash
bash scripts/30_smoke_test.sh --dir ~/my-project
```

What a good run looks like (ours, trimmed; 76 s end to end):

```text
== 1. Official MACE example (looking for the silent Lennard-Jones fallback)
  PASS  example exited 0
  PASS  'Using MACE model' printed
  PASS  'Model used: MACE'
  INFO  example: Inst. temp.   : 300.5 K  (target = 300 K)

== 2. MACE throughput + physics checks (quick: cuEq, 864 atoms, 50 warm-up + 300 timed steps)
=== Results ===
run                     steps/s  atom-steps/s   ns/day  drift eV/at/step  T_tail K  T_end K  mem GB
cueq 1x864 atoms           12.9        11,108     1.11          2.93e-08     148.4    151.3    1.50

=== Checks ===
PASS  GPU in use: NVIDIA GB10 (compute capability 12.1)
PASS  cueq 1x864 atoms: energy drift 2.9e-08 eV/atom/step (limit 1e-06)
PASS  cueq 1x864 atoms: mean T over the last 50 steps 148 K (expected 120-180 K: equipartition from a 300 K start)
INFO  cueq 1x864 atoms: 11,108 atom-steps/s = 59% of our GB10 reference (18,874)

  RESULT: PASS. ALCHEMI + MACE run on this GPU, and the physics checks out.
```

That run shared the GPU with another job. On an idle GB10, expect about 19,000 atom-steps/s (~22 steps/s). The
script WARNs below 50% of the reference. A slow GPU never FAILs the test; wrong physics or a missing MACE model does.

Then activate the venv with `source ~/my-project/.venv/bin/activate` and browse
`~/my-project/nvalchemi-toolkit/examples/`. To use the ALCHEMI skills, start Claude Code in `~/my-project`.

## Reference numbers (our GB10)

MACE-MPA-0, float32, periodic FCC Cu, NVE, dt = 1 fs, 50 warm-up + 299 timed steps:

| Run | steps/s | atom-steps/s | ns/day | drift (eV/atom/step) | T end | GPU mem |
|---|---:|---:|---:|---:|---:|---:|
| e3nn, 864 atoms | 2.6 | 2,257 | 0.23 | 2.4e-8 | 151 K | 5.6 GB |
| e3nn, 2,048 atoms | 1.1 | 2,231 | 0.09 | 3.2e-8 | 152 K | 13.0 GB |
| **cuEq, 864 atoms** | **21.8** | **18,874** | **1.89** | 2.6e-8 | 151 K | 1.5 GB |
| cuEq, 2,048 atoms | 9.8 | 20,059 | 0.85 | 3.8e-8 | 152 K | 3.4 GB |
| cuEq, 8 x 864 batched | 3.1 | 21,233 | 0.27 each | 4.3e-8 | 155 K | 11.2 GB |

- **Always enable cuEquivariance** (`MACEWrapper.from_checkpoint(..., dtype=torch.float32, enable_cueq=True)`): it's
  8.5x faster and uses about 4x less memory than plain e3nn.
- The GB10 tops out around **20k atom-steps/s** with MACE-medium. Batching ~1k-atom systems adds little.
- These numbers come with two physics checks. Energy drift is about 3e-8 eV/atom/step. A crystal started on perfect
  lattice sites at 300 K settles near **150 K**, as equipartition predicts.

`bash scripts/30_smoke_test.sh --dir ~/my-project --full` runs the whole table. It takes about 11 minutes, mostly for
the slow e3nn runs.

## Scripts

| Script | sudo? | What it does | Options |
|---|---|---|---|
| `00_check.sh` | no | Read-only check: arch, OS, driver/CUDA, GPU, SSH, Tailscale, sleep, Python headers, gcc, uv, disk | |
| `10_remote_access.sh` | asks | SSH + Tailscale + no sleep; prints your laptop's ssh command | `--check` `--yes` `--no-login` |
| `20_alchemi_env.sh` | no | ALCHEMI venv, toolkit source at the matching tag, agent skills, GPU check | `--dir` `--managed-python` `--check` `--yes` |
| `30_smoke_test.sh` | no | Official MACE example (with fallback detection), then throughput + physics checks | `--dir` `--full` `--check` |

All scripts take `-h`. Full, untruncated logs go to `logs/<script>-<timestamp>-<pid>.log`.

The kit pins `nvalchemi-toolkit==0.2.0`, the version we verified. `NVALCHEMI_VERSION=latest` installs a newer one,
which we haven't tested. The dependencies resolved for us to: nvalchemi-toolkit-ops 0.5.0, torch 2.14.1+cu130,
torchvision 0.29.1+cu130, mace-torch 0.3.15, e3nn 0.4.4, cuequivariance 0.13.0, aimnet 0.2.5, warp-lang 1.18.0,
ase 3.29.0, numpy 2.3.5. Yours may get newer patch releases.

## What's verified and what isn't

| Item | Status |
|---|---|
| Every command in the scripts, run by hand on our GB10 | verified |
| `00_check.sh` on our GB10 | verified: 19 PASS, 0 WARN, 0 FAIL |
| `10_remote_access.sh --check` on our (already configured) GB10 | verified: "Nothing to do", no sudo, prints the laptop ssh command |
| `10_remote_access.sh` applying changes on a fresh box | **not run as a script**: each step was run by hand on our GB10 |
| OpenSSH install branch | **untested** (our box already had SSH) |
| `20_alchemi_env.sh` into a fresh folder | verified (packages came from uv's cache, so a fresh download wasn't timed); a re-run changes nothing |
| `20_alchemi_env.sh --managed-python` (no sudo) | verified install + GPU check with an empty Triton cache: Triton compiled its launcher against uv's Python headers. Not tried on a box that lacks `python3.12-dev`, and the smoke test wasn't run on this venv. |
| `30_smoke_test.sh` quick mode | verified: PASS (MACE weights were already cached, so the first-run download wasn't exercised) |
| `30_smoke_test.sh --full` | not re-run through the kit; the table above is from the original Cool Orbit script with the same settings |
| Optional tools snippets ([docs/OPTIONAL_TOOLS.md](docs/OPTIONAL_TOOLS.md)) | verified as written (`gh`, `brev`; checksums OK) |
| NVIDIA DGX Spark | **not tested** |
| Teammate access ([docs/TEAMMATES.md](docs/TEAMMATES.md)) | **not tested** |

## More docs

- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md): every error we hit, with the exact message, the cause and the fix
- [docs/TEAMMATES.md](docs/TEAMMATES.md): sharing the box over Tailscale, logins, sharing the GPU, copy/paste on a Mac
- [docs/OPTIONAL_TOOLS.md](docs/OPTIONAL_TOOLS.md): GitHub CLI and Brev CLI on ARM64 without sudo, checksum-verified

## Credits

Built by the **Cool Orbit** team: AI agents on NVIDIA ALCHEMI that find and cross-check phase-change materials for
cooling orbital AI compute. See [github.com/MadhanJ05/cool-orbit](https://github.com/MadhanJ05/cool-orbit).
`scripts/smoke_throughput.py` is adapted from Cool Orbit's smoke test.

If this kit saved you time, star the repo or tell us in the hackathon channel. Issues and fixes are welcome,
especially reports from DGX Spark owners.

NVIDIA ALCHEMI (`nvalchemi-toolkit`) is NVIDIA's work; this kit only installs and tests it.

## License

[Apache-2.0](LICENSE)
