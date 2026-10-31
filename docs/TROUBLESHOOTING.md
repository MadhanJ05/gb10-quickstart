# Troubleshooting

Unless marked otherwise, we hit every problem below ourselves on a Dell Pro Max GB10 (Ubuntu 24.04.5, aarch64,
driver 580.178.04, CUDA 13.0). Each entry gives what you see, why it happens, and the fix.

**ALCHEMI / PyTorch**
1. [`InductorError ... gcc ... driver.c` on the first torch.compile / MACE run](#1-inductorerror--gcc--driverc-on-the-first-torchcompile--mace-run)
2. [Wrong PyTorch build or resolver trouble with uv](#2-wrong-pytorch-build-or-resolver-trouble-with-uv)
3. [plotext 6 breaks the toolkit's reporting](#3-plotext-6-breaks-the-toolkits-reporting)
4. [Examples or skills from `main` don't match the installed toolkit](#4-examples-or-skills-from-main-dont-match-the-installed-toolkit)
5. [The MACE example "works" but actually ran Lennard-Jones](#5-the-mace-example-works-but-actually-ran-lennard-jones)
6. [MACE in your own dynamics needs a neighbor-list hook](#6-mace-in-your-own-dynamics-needs-a-neighbor-list-hook)
7. [MACE is slow: turn on cuEquivariance](#7-mace-is-slow-turn-on-cuequivariance)
8. [Warnings you can ignore](#8-warnings-you-can-ignore)
9. [The install is huge](#9-the-install-is-huge)
10. [`uv: command not found` right after installing uv](#10-uv-command-not-found-right-after-installing-uv)

**Remote access**

11. [The box becomes unreachable after ~20 minutes idle](#11-the-box-becomes-unreachable-after-20-minutes-idle)
12. [`ssh.service` is inactive but SSH works](#12-sshservice-is-inactive-but-ssh-works)
13. [Don't re-run `sudo tailscale up` on a logged-in box](#13-dont-re-run-sudo-tailscale-up-on-a-logged-in-box)
14. [Laptop can't reach the box](#14-laptop-cant-reach-the-box)
15. [`gsettings` errors or odd values over SSH](#15-gsettings-errors-or-odd-values-over-ssh)

**Tools**

16. [`gh` login doesn't stick over SSH](#16-gh-login-doesnt-stick-over-ssh)
17. [Pasting a snippet that starts with `set -e` closes your terminal](#17-pasting-a-snippet-that-starts-with-set--e-closes-your-terminal)
18. [Copy/paste from a Mac over SSH](#18-copypaste-from-a-mac-over-ssh)

---

## ALCHEMI / PyTorch

### 1. `InductorError ... gcc ... driver.c` on the first torch.compile / MACE run

**What you see** the first time anything uses Triton (`torch.compile`, cuEquivariance, even inside a MACE example):

```text
torch._inductor.exc.InductorError: CalledProcessError: Command '['/usr/bin/gcc', '.../triton/backends/nvidia/driver.c', ... '-I/usr/include/python3.12']' returned non-zero exit status 1.
```

**Why:** the first time Triton runs, it compiles a small C launcher against the Python headers. Ubuntu doesn't install
those headers by default; they're in `python3.12-dev`.

**Diagnose:**

```bash
echo '#include <Python.h>' | gcc -I/usr/include/python3.12 -fsyntax-only -x c -
# fatal error: Python.h: No such file or directory    <- headers missing
```

**Fix:** `sudo apt install -y python3.12-dev`. Then it works; nothing else needs reinstalling.

No sudo? Build the venv on uv's own Python, which ships its headers:
`bash scripts/20_alchemi_env.sh --managed-python --dir <new folder>`. We tested this on our GB10 with an empty Triton
cache. Triton compiled its launcher against uv's Python headers, because it takes the header path from the running
Python. We couldn't try it on a box that lacks `python3.12-dev`.

Triton saves the compiled launcher in `~/.triton/cache`. So after installing the headers, the fix sticks, and a
deleted cache only means one recompile.

`00_check.sh` and `20_alchemi_env.sh` check for the headers before anything big happens, and `20_alchemi_env.sh`
ends with a `torch.compile` test that catches this.

### 2. Wrong PyTorch build or resolver trouble with uv

**What you see:** `torch.cuda.is_available()` is `False`, `torch.version.cuda` isn't `13.x`, or uv fails to resolve.

**Why:** uv handles extra package indexes differently from pip. Instructions written for pip (only
`--extra-index-url https://download.pytorch.org/whl/cu130`) don't carry over to uv reliably.

**Fix:** use the flags from the toolkit's own install guide (this is what `20_alchemi_env.sh` runs):

```bash
uv pip install --torch-backend cu130 --index-strategy unsafe-best-match \
  'nvalchemi-toolkit[cu13,mace,aimnet,ase,pymatgen]==0.2.0' 'plotext<6' matplotlib pandas scipy
```

Add `--dry-run` first to see the plan; it takes about 2 seconds.

### 3. plotext 6 breaks the toolkit's reporting

**Why:** nvalchemi-toolkit 0.2.0 doesn't pin `plotext`. plotext 6 removed `clf()`, which the toolkit's reporting code
calls, so you get an `AttributeError` about `clf` when it tries to draw. (The toolkit's `main` branch already pins
`plotext<6`.)

**Fix:** install `'plotext<6'` alongside the toolkit (the kit does).

### 4. Examples or skills from `main` don't match the installed toolkit

**Why:** the GitHub `main` branch is ahead of the PyPI release: it pins an unreleased ops version and has different
agent skills and examples. Examples from `main` can call APIs your installed version doesn't have.

**Fix:** check out the tag that equals the installed version:

```bash
.venv/bin/python -c "import nvalchemi; print(nvalchemi.__version__)"     # 0.2.0
git -C nvalchemi-toolkit checkout v0.2.0
```

`20_alchemi_env.sh` clones at the matching tag automatically, and copies that tag's `.claude/skills`.

UMA note: in v0.2.0 the UMA extra is plain `uma` (there's no `uma-cu13`), and it conflicts with MACE. Put it in its
**own** venv.

### 5. The MACE example "works" but actually ran Lennard-Jones

**What you see:** `examples/advanced/04_mace_nvt.py` finishes without an error, but it loads MACE inside a
`try/except` and quietly falls back to a Lennard-Jones potential if anything goes wrong. In that case the output
contains:

```text
Failed to load MACE (<the real error>). Falling back to LJ.
...
  Model used    : Lennard-Jones (fallback)
```

or, if `MACE_MODEL_PATH` isn't set at all:

```text
Using LJ model (set MACE_MODEL_PATH=/path/to/model.pt to use MACE)
```

**Fix:** run it with a model name and check the output:

```bash
MACE_MODEL_PATH=medium-mpa-0 .venv/bin/python nvalchemi-toolkit/examples/advanced/04_mace_nvt.py
# must contain:  Using MACE model from medium-mpa-0
# and:           Model used    : MACE
```

The first run downloads the MACE-MPA-0 weights (~80 MB) to `~/.cache/mace`. A good run does 100 NVT steps of a
9-atom water cluster and ends near the 300 K target. `30_smoke_test.sh` runs this and fails if it fell back.

### 6. MACE in your own dynamics needs a neighbor-list hook

MACE needs a neighbor list rebuilt before every force evaluation. Build the hook from the model's own config:

```python
from nvalchemi.dynamics.base import DynamicsStage
from nvalchemi.hooks import NeighborListHook

md.register_hook(NeighborListHook(model.model_config.neighbor_config, stage=DynamicsStage.BEFORE_COMPUTE))
```

For periodic systems also add `WrapPeriodicHook(stage=DynamicsStage.AFTER_POST_UPDATE)`.
`scripts/smoke_throughput.py` is a complete working example.

### 7. MACE is slow: turn on cuEquivariance

```python
model = MACEWrapper.from_checkpoint("medium-mpa-0", device=torch.device("cuda"),
                                    dtype=torch.float32, enable_cueq=True)
```

On the GB10 (864-atom Cu, NVE): plain e3nn ran 2.6 steps/s using 5.6 GB; with cuEquivariance, 21.8 steps/s using 1.5 GB.
That's **8.5x faster with about 4x less memory**.

### 8. Warnings you can ignore

These show up on a working GB10 setup and are harmless:

```text
WARNING:cuequivariance_ops.triton.cache_manager:Failed to get GPU information from pynvml: Not Supported. Using default values for NVIDIA GB10.
```
```text
Warp 1.18.0 initialized:
   CUDA Toolkit 13.4, Driver 13.0
```
(Warp bundles a newer CUDA toolkit than the driver reports; it works.)
```text
FutureWarning: `torch.jit.script` is deprecated. Please switch to `torch.compile` or `torch.export`.
FutureWarning: `torch.jit.load` is deprecated. Please switch to `torch.export`.
```
```text
Using medium MPA-0 model as default MACE-MP model, to use previous (before 3.10) default model please specify 'medium' as model argument
```
```text
mace/modules/models.py:85: UserWarning: To copy construct from a tensor, it is recommended to use sourceTensor.detach().clone() or sourceTensor.detach().clone().requires_grad_(True), rather than torch.tensor(sourceTensor).
```
```text
GPU information: NVIDIA GB10, 12, 1, 128, 48, 140, 1700
```

Also: `nvidia-smi` shows GPU memory as `[N/A]`. The GB10 has 121 GiB of **unified** memory shared by CPU and GPU.
Use `torch.cuda.max_memory_allocated()` or `nvidia-smi`'s process list instead.

### 9. The install is huge

The venv is about 9 GB (~200 packages). PhysicsNeMo's cu13 extra pulls in the RAPIDS stack (cudf, cuml, cupy, DALI).
The examples here don't use it, and it does no harm. Leave about 30 GB free.

Re-running the same `uv pip install` reinstalls `nvidia-cusparselt-cu13` every time, at the same version. uv shows it
as `~ nvidia-cusparselt-cu13==0.8.1`. It's harmless, and `20_alchemi_env.sh` treats it as "nothing to do".

### 10. `uv: command not found` right after installing uv

The installer puts `uv` in `~/.local/bin` and adds that to `PATH` in your shell profile, which only applies to **new**
shells. Open a new terminal, or run `export PATH="$HOME/.local/bin:$PATH"`. The kit's scripts find `~/.local/bin/uv`
either way.

---

## Remote access

### 11. The box becomes unreachable after ~20 minutes idle

**Why:** Ubuntu's login screen (GDM) has its own power settings and can suspend an idle machine after about 20 minutes
when nobody is logged in at the desktop, even if your own desktop setting says "never".

**Fix:** block sleep at the system level (`10_remote_access.sh` does this):

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
# check: systemctl show -p LoadState sleep.target suspend.target hibernate.target hybrid-sleep.target   -> masked x4
# undo:  sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

### 12. `ssh.service` is inactive but SSH works

Ubuntu 24.04 often uses socket activation: `ssh.socket` listens on port 22 and starts sshd per connection, so
`ssh.service` can show `inactive`. Either one being active is fine; `00_check.sh` accepts both.

If SSH isn't installed at all: `sudo apt install -y openssh-server && sudo systemctl enable --now ssh`
(`10_remote_access.sh` does this; our box already had SSH, so that branch is untested).

### 13. Don't re-run `sudo tailscale up` on a logged-in box

Running `tailscale up` again without the flags used the first time can error or reset settings. Check first:

```bash
tailscale status        # lists your devices if you're logged in
tailscale ip -4         # your 100.x address
```

`10_remote_access.sh` only runs `tailscale up` when Tailscale reports `NeedsLogin`, and never on a box that's already up.

### 14. Laptop can't reach the box

- The Tailscale app on the laptop is running and signed in to the **same account** as the box (or the box has been
  shared with you; see [TEAMMATES.md](TEAMMATES.md)).
- `tailscale status` on both sides lists the other device.
- If the MagicDNS name doesn't resolve, use the `100.x.y.z` IP from `tailscale ip -4` on the box.
- Still nothing after ~20 idle minutes? See [11](#11-the-box-becomes-unreachable-after-20-minutes-idle).

### 15. `gsettings` errors or odd values over SSH

`gsettings` reads your desktop session's settings; over SSH it may fail or show defaults. That doesn't matter once the
sleep targets are masked (11). `00_check.sh` reports it for information only.

---

## Tools

### 16. `gh` login doesn't stick over SSH

`gh auth login` stores the token in the desktop keyring, which may be locked or unreachable in an SSH-only session.
**Untested fix:** `gh auth login --insecure-storage`. It stores the token in plain text in `~/.config/gh/hosts.yml`,
readable by anyone who can log in as your user. Install steps: [OPTIONAL_TOOLS.md](OPTIONAL_TOOLS.md).

### 17. Pasting a snippet that starts with `set -e` closes your terminal

`set -e` in your interactive shell makes the **first failing command close the shell**, and with it your SSH session.
Run such snippets in a child shell instead: `bash -eu <<'EOF' ... EOF` (as [OPTIONAL_TOOLS.md](OPTIONAL_TOOLS.md) does).

### 18. Copy/paste from a Mac over SSH

Claude Code and other full-screen terminal apps capture mouse drags. See
[TEAMMATES.md](TEAMMATES.md#copy-and-paste-from-a-mac-over-ssh).
