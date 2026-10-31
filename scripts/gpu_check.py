"""GPU check for a fresh ALCHEMI venv: CUDA is visible, torch is the CUDA 13 build, and Triton compiles.

The torch.compile step is the one that crashes with an InductorError when the Python headers
(python3.12-dev) are missing, so this catches that before your first real MACE run does.
Run it with the venv's Python:  .venv/bin/python scripts/gpu_check.py
"""

from __future__ import annotations

import sys
import time

import torch

import nvalchemi


def main() -> int:
    print(f"  nvalchemi {nvalchemi.__version__} | torch {torch.__version__} | torch built for CUDA {torch.version.cuda}")
    if not torch.cuda.is_available():
        print("  torch.cuda.is_available() is False: a CPU-only torch build or a driver problem (docs/TROUBLESHOOTING.md)")
        return 1
    if not str(torch.version.cuda).startswith("13."):
        print(f"  torch is built for CUDA {torch.version.cuda}, expected 13.x (install with --torch-backend cu130)")
        return 1
    print(f"  GPU: {torch.cuda.get_device_name(0)}, compute capability {torch.cuda.get_device_capability(0)}")

    x = torch.randn(1024, 1024, device="cuda")
    print(f"  matmul on the GPU: checksum {(x @ x).sum().item():.3f}")

    t0 = time.perf_counter()
    f = torch.compile(lambda a: torch.sin(a) * 2.0 + 1.0)
    f(torch.randn(4096, device="cuda"))
    torch.cuda.synchronize()
    print(f"  torch.compile built and ran a Triton kernel in {time.perf_counter() - t0:.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
