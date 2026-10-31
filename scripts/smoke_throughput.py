"""GB10 quickstart smoke test: MACE NVE throughput on the GPU, with physics checks.

Adapted from the Cool Orbit team's smoke test (https://github.com/MadhanJ05/cool-orbit).

Runs NVE molecular dynamics of a periodic FCC copper crystal (well inside MACE-MP's training
domain) with a MACE-MP foundation model in float32, then checks that the run is physically right,
not just fast:

  * the GPU is used;
  * total energy is conserved: drift < 1e-6 eV/atom/step;
  * equipartition: a crystal started on perfect lattice sites with 300 K velocities shares that
    energy with the potential and settles near 150 K. The mean temperature over the last 50 steps
    must be 0.4-0.6 x the start temperature.

Quick mode (default): cuEquivariance kernels, 864 atoms, 50 warm-up + 300 timed steps.
--full: adds plain e3nn kernels, 2,048 atoms and 8 x 864 atoms batched (~11 min on a GB10).

Usage:
    .venv/bin/python scripts/smoke_throughput.py [--full]
Exit code 0 = every check passed, 1 = something failed.
"""

from __future__ import annotations

import argparse
import json
import platform
import sys
import time
import traceback
from datetime import datetime, timezone
from importlib.metadata import version
from pathlib import Path

import torch
from ase.build import bulk

import nvalchemi
from nvalchemi.data import AtomicData, Batch
from nvalchemi.dynamics import NVE
from nvalchemi.dynamics.base import DynamicsStage
from nvalchemi.dynamics.hooks import EnergyDriftMonitorHook, NaNDetectorHook
from nvalchemi.dynamics.hooks._utils import kinetic_energy_per_graph
from nvalchemi.hooks import NeighborListHook, WrapPeriodicHook
from nvalchemi.models.mace import MACEWrapper

KB_EV = 8.617333262e-5  # eV/K
CU_LATTICE_A = 3.61  # Angstrom, room-temperature FCC Cu (approximate starting value)
DRIFT_LIMIT = 1e-6  # eV/atom/step
T_RATIO_RANGE = (0.4, 0.6)  # tail temperature / start temperature (equipartition gives ~0.5)
SLOW_WARN_FRACTION = 0.5  # warn if throughput is below half of our reference

# Our measurements on a Dell Pro Max GB10 (driver 580.178.04, CUDA 13.0, torch 2.14.1+cu130,
# nvalchemi-toolkit 0.2.0; MACE-MPA-0, float32, dt = 1 fs, 50 warm-up + 299 timed steps).
REFERENCE_ATOM_STEPS_PER_S = {
    "e3nn 1x864 atoms": 2257,
    "e3nn 1x2048 atoms": 2231,
    "cueq 1x864 atoms": 18874,
    "cueq 1x2048 atoms": 20059,
    "cueq 8x864 atoms": 21233,
}


def make_cu_crystal(reps: int, temperature: float, seed: int) -> AtomicData:
    """Perfect FCC Cu supercell with Maxwell-Boltzmann velocities, zero net momentum."""
    atoms = bulk("Cu", "fcc", a=CU_LATTICE_A, cubic=True).repeat((reps, reps, reps))
    n = len(atoms)
    masses = torch.tensor(atoms.get_masses(), dtype=torch.float32)
    gen = torch.Generator().manual_seed(seed)
    # Velocities in sqrt(eV/amu), so KE = 0.5 m v^2 is in eV (toolkit convention).
    v = torch.randn(n, 3, generator=gen) * torch.sqrt(KB_EV * temperature / masses).unsqueeze(-1)
    v -= (masses.unsqueeze(-1) * v).sum(0) / masses.sum()  # remove centre-of-mass drift
    data = AtomicData(
        positions=torch.tensor(atoms.positions, dtype=torch.float32),
        atomic_numbers=torch.tensor(atoms.numbers, dtype=torch.long),
        forces=torch.zeros(n, 3),
        energy=torch.zeros(1, 1),
        cell=torch.tensor(atoms.cell.array, dtype=torch.float32).unsqueeze(0),
        pbc=torch.tensor([[True, True, True]]),
    )
    data.add_node_property("velocities", v)
    return data


def kinetic_and_temperature(batch: Batch) -> tuple[torch.Tensor, torch.Tensor]:
    """Per-system kinetic energy (eV) and temperature (K), left on the GPU."""
    ke = kinetic_energy_per_graph(
        velocities=batch.velocities,
        masses=batch.atomic_masses,
        batch_idx=batch.batch_idx,
        num_graphs=batch.num_graphs,
    ).squeeze(-1)
    n_atoms = batch.num_nodes_per_graph.to(ke.dtype)
    return ke, 2.0 * ke / (3.0 * n_atoms * KB_EV)


def energies(batch: Batch) -> tuple[torch.Tensor, torch.Tensor]:
    """Per-system (total energy, temperature) as CPU float64 tensors."""
    ke, temp = kinetic_and_temperature(batch)
    pe = batch.energy.squeeze(-1)
    return (ke + pe).double().cpu(), temp.double().cpu()


class TimingProbe:
    """After the warm-up steps, snapshot total energy and start the clock.

    Only synchronizes the GPU once (when the clock starts), so it does not slow down the timed steps.
    """

    stage = DynamicsStage.AFTER_STEP
    frequency = 1

    def __init__(self, warmup: int) -> None:
        self.warmup = warmup
        self.t0: float | None = None
        self.e0: torch.Tensor | None = None
        self.n_timed = 0

    def __call__(self, ctx, stage) -> None:
        if self.t0 is not None:
            self.n_timed += 1
        elif ctx.step_count >= self.warmup:
            torch.cuda.synchronize()
            self.e0, _ = energies(ctx.batch)
            self.t0 = time.perf_counter()


class TemperatureTail:
    """Record per-system temperature over the last steps of the run (stays on the GPU, no sync).

    One instantaneous temperature can be caught mid-oscillation; the mean over the tail can't.
    """

    stage = DynamicsStage.AFTER_STEP
    frequency = 1

    def __init__(self, first_step: int) -> None:
        self.first_step = first_step
        self.samples: list[torch.Tensor] = []

    def __call__(self, ctx, stage) -> None:
        if ctx.step_count >= self.first_step:
            self.samples.append(kinetic_and_temperature(ctx.batch)[1].detach())

    def mean_per_system(self) -> torch.Tensor | None:
        if not self.samples:
            return None
        return torch.stack(self.samples).mean(0).double().cpu()


def run_one(label: str, model, reps: int, n_copies: int, args) -> dict:
    device = torch.device("cuda")
    data_list = [make_cu_crystal(reps, args.temperature, seed=i) for i in range(n_copies)]
    batch = Batch.from_data_list(data_list, device=device)
    atoms_per_system = data_list[0].num_nodes
    n_total = args.warmup + args.steps

    nve = NVE(model=model, dt=args.dt, n_steps=n_total)
    # MACE needs a neighbor list rebuilt before every force call.
    nve.register_hook(
        NeighborListHook(model.model_config.neighbor_config, stage=DynamicsStage.BEFORE_COMPUTE)
    )
    nve.register_hook(WrapPeriodicHook(stage=DynamicsStage.AFTER_POST_UPDATE))
    nve.register_hook(NaNDetectorHook(frequency=50))
    nve.register_hook(
        EnergyDriftMonitorHook(threshold=1e-4, metric="per_atom_per_step", action="warn", frequency=50)
    )
    probe = TimingProbe(args.warmup)
    nve.register_hook(probe)
    tail = TemperatureTail(first_step=n_total - args.tail)
    nve.register_hook(tail)

    torch.cuda.reset_peak_memory_stats()
    batch = nve.run(batch)
    torch.cuda.synchronize()
    wall = time.perf_counter() - probe.t0

    e1, t_final = energies(batch)
    drift = ((e1 - probe.e0).abs() / (atoms_per_system * probe.n_timed)).max().item()
    steps_per_s = probe.n_timed / wall
    t_tail = tail.mean_per_system()
    return {
        "label": label,
        "status": "ok",
        "n_systems": n_copies,
        "atoms_per_system": atoms_per_system,
        "total_atoms": atoms_per_system * n_copies,
        "steps_timed": probe.n_timed,
        "wall_s": round(wall, 3),
        "steps_per_s": round(steps_per_s, 2),
        "atom_steps_per_s": round(steps_per_s * atoms_per_system * n_copies),
        "ns_per_day_per_system": round(steps_per_s * args.dt * 86400 / 1e6, 3),
        "max_drift_eV_per_atom_per_step": drift,
        "T_final_K_mean": round(t_final.mean().item(), 1),
        "T_tail_K_min": None if t_tail is None else round(t_tail.min().item(), 1),
        "T_tail_K_max": None if t_tail is None else round(t_tail.max().item(), 1),
        "T_tail_steps": len(tail.samples),
        "peak_gpu_mem_GB": round(torch.cuda.max_memory_allocated() / 1e9, 2),
    }


def evaluate(results: list[dict], args) -> list[tuple[str, str]]:
    """Turn results into (PASS/FAIL/WARN/INFO, message) lines."""
    checks: list[tuple[str, str]] = []
    lo, hi = (r * args.temperature for r in T_RATIO_RANGE)
    for r in results:
        if r["status"] != "ok":
            checks.append(("FAIL", f"{r['label']}: {r['error'][:300]}"))
            continue
        d = r["max_drift_eV_per_atom_per_step"]
        checks.append((
            "PASS" if d < DRIFT_LIMIT else "FAIL",
            f"{r['label']}: energy drift {d:.1e} eV/atom/step (limit {DRIFT_LIMIT:.0e})",
        ))
        tmin, tmax = r["T_tail_K_min"], r["T_tail_K_max"]
        if tmin is None:
            checks.append(("FAIL", f"{r['label']}: no temperature samples recorded"))
        else:
            span = f"{tmin:.0f} K" if tmin == tmax else f"{tmin:.0f}-{tmax:.0f} K"
            checks.append((
                "PASS" if lo <= tmin and tmax <= hi else "FAIL",
                f"{r['label']}: mean T over the last {r['T_tail_steps']} steps {span} "
                f"(expected {lo:.0f}-{hi:.0f} K: equipartition from a {args.temperature:.0f} K start)",
            ))
        ref = REFERENCE_ATOM_STEPS_PER_S.get(r["label"])
        if ref and args.model == "medium-mpa-0":
            frac = r["atom_steps_per_s"] / ref
            note = "" if frac >= SLOW_WARN_FRACTION else " (another job on the GPU?)"
            checks.append((
                "INFO" if frac >= SLOW_WARN_FRACTION else "WARN",
                f"{r['label']}: {r['atom_steps_per_s']:,} atom-steps/s = {100 * frac:.0f}% of our GB10 "
                f"reference ({ref:,}){note}",
            ))
    if not any(r["status"] == "ok" for r in results):
        checks.append(("FAIL", "no MD run completed"))
    return checks


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--full", action="store_true", help="also plain e3nn, 2,048 atoms and the batched run (~11 min)")
    p.add_argument("--model", default="medium-mpa-0", help="MACE-MP named checkpoint or path")
    p.add_argument("--reps", type=int, nargs="+", default=None,
                   help="cubic supercell reps, 4*r^3 atoms (default: 6 quick; 6 8 full)")
    p.add_argument("--batch-copies", type=int, default=8, help="copies in the batched run (--full only)")
    p.add_argument("--warmup", type=int, default=50)
    p.add_argument("--steps", type=int, default=300)
    p.add_argument("--tail", type=int, default=50, help="average the temperature over this many final steps")
    p.add_argument("--dt", type=float, default=1.0, help="timestep, fs")
    p.add_argument("--temperature", type=float, default=300.0, help="initial velocity temperature, K")
    p.add_argument("--out", default="logs", help="folder for the JSON results")
    args = p.parse_args()
    reps = args.reps or ([6, 8] if args.full else [6])
    kernel_modes = [("e3nn", False), ("cueq", True)] if args.full else [("cueq", True)]

    if not torch.cuda.is_available():
        print("FAIL  CUDA not available: torch can't see the GPU (see docs/TROUBLESHOOTING.md)")
        return 1

    env = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "arch": platform.machine(),
        "gpu": torch.cuda.get_device_name(0),
        "capability": list(torch.cuda.get_device_capability(0)),
        "torch": torch.__version__,
        "nvalchemi": nvalchemi.__version__,
        "mace_torch": version("mace-torch"),
        "cuequivariance": version("cuequivariance"),
        "model": args.model,
        "dtype": "float32",
        "args": vars(args),
    }
    print(json.dumps(env, indent=2))

    results = []
    for kernels, cueq in kernel_modes:
        try:
            model = MACEWrapper.from_checkpoint(
                args.model, device=torch.device("cuda"), dtype=torch.float32, enable_cueq=cueq
            )
        except Exception as exc:  # report the failure, keep going
            results.append({"label": f"{kernels} model load", "status": "failed", "error": repr(exc)})
            traceback.print_exc()
            continue
        jobs = [(r, 1) for r in reps]
        if args.full and cueq:
            jobs.append((min(reps), args.batch_copies))
        for r, copies in jobs:
            label = f"{kernels} {copies}x{4 * r**3} atoms"
            print(f"\n--- {label} ---", flush=True)
            try:
                res = run_one(label, model, r, copies, args)
            except Exception as exc:  # report the failure, keep going
                res = {"label": label, "status": "failed", "error": repr(exc)}
                traceback.print_exc()
            res["kernels"] = kernels
            results.append(res)
            print(json.dumps(res), flush=True)
            torch.cuda.empty_cache()
        del model
        torch.cuda.empty_cache()

    print("\n=== Results ===")
    print(f"{'run':<22}{'steps/s':>9}{'atom-steps/s':>14}{'ns/day':>9}{'drift eV/at/step':>18}"
          f"{'T_tail K':>10}{'T_end K':>9}{'mem GB':>8}")
    for r in results:
        if r["status"] != "ok":
            print(f"{r['label']:<22}  FAILED: {r['error'][:80]}")
            continue
        t_tail = "n/a" if r["T_tail_K_min"] is None else f"{(r['T_tail_K_min'] + r['T_tail_K_max']) / 2:.1f}"
        print(f"{r['label']:<22}{r['steps_per_s']:>9.1f}{r['atom_steps_per_s']:>14,}"
              f"{r['ns_per_day_per_system']:>9.2f}{r['max_drift_eV_per_atom_per_step']:>18.2e}"
              f"{t_tail:>10}{r['T_final_K_mean']:>9.1f}{r['peak_gpu_mem_GB']:>8.2f}")
    print(f"ns/day assumes dt = {args.dt} fs (fine for Cu; H-rich organics need ~0.5 fs).")

    checks = [("PASS", f"GPU in use: {env['gpu']} (compute capability {env['capability'][0]}.{env['capability'][1]})")]
    checks += evaluate(results, args)
    print("\n=== Checks ===")
    for status, msg in checks:
        print(f"{status:<5} {msg}")
    ok = not any(s == "FAIL" for s, _ in checks)
    print(f"\nRESULT: {'PASS' if ok else 'FAIL'}")

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"smoke_throughput-{env['timestamp_utc'].replace(':', '')}.json"
    out_file.write_text(json.dumps({"env": env, "results": results, "checks": checks, "pass": ok}, indent=2))
    print(f"Saved {out_file}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
