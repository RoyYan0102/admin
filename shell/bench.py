"""A small, repeatable performance sample of one machine. One line per test, the best
of three runs, so machines line up side by side:

    python3 bench.py                 # the disk test under /tmp
    python3 bench.py /data/people/me # under that directory
    scp bench.py oimspot:/tmp/ && ssh oimspot 'cd repo/quant && .venv/bin/python /tmp/bench.py /data/people/me'

Run it with a python that has numpy and pandas (a quant venv's); without them those
lines say so. The single-thread matmul comes from a child python with the BLAS thread
variables set to 1 (they are read when numpy loads).

- loop: a pure-Python loop, 10 million additions (the interpreter, one core)
- matmul: a 3000x3000 float64 matmul, one BLAS thread, then every core
- memory: a 2 GB array copy (bandwidth)
- pandas: a 5-million-row groupby-mean on 1000 groups (memory and one core)
- disk: 1 GB written with an fsync, then read back (the read may be the page cache)

Measured 2026-10-01 — laptop (Core Ultra 5 135U, WSL) / payg VM (D32as_v7) / spot VM (F32as_v7):
loop 0.225 / 0.170 / 0.179 s; matmul 1 thread 1.0–2.3 (varies) / 0.49 / 0.51 s, every core 0.44 /
0.045 / 0.025 s; memory 0.62 / 0.16 / 0.16 s; pandas 0.113 / 0.034 / 0.034 s; disk
write 1 GB 1.5 (repo disk) / 10.8 (/data) / 10.9 (/data) s, the VMs' OS disks 21 / 42 s.
"""

from __future__ import annotations

import os
import platform
import subprocess
import sys
import tempfile
import time


ONE_THREAD = """
import time
import numpy as np
a = np.random.default_rng(0).standard_normal((3000, 3000))
best = None
for _ in range(3):
    t = time.perf_counter()
    a @ a
    took = time.perf_counter() - t
    best = took if best is None else min(best, took)
print(best)
"""


def best(fn, runs: int = 3) -> float:
    times = []
    for _ in range(runs):
        t = time.perf_counter()
        fn()
        times.append(time.perf_counter() - t)
    return min(times)


def loop() -> None:
    s = 0
    for i in range(10_000_000):
        s += i


def main() -> None:
    where = sys.argv[1] if len(sys.argv) > 1 else tempfile.gettempdir()
    print(f"host {platform.node()}  python {platform.python_version()}  cpus {os.cpu_count()}")
    print(f"loop 10M        {best(loop):7.3f} s")
    try:
        import numpy as np
    except ImportError:
        print("numpy          (not installed)")
        np = None
    if np is not None:
        a = np.random.default_rng(0).standard_normal((3000, 3000))
        one = subprocess.run(
            [sys.executable, "-c", ONE_THREAD],
            env={**os.environ, "OPENBLAS_NUM_THREADS": "1", "OMP_NUM_THREADS": "1", "MKL_NUM_THREADS": "1"},
            capture_output=True,
            text=True,
            check=False,
        )
        print(f"numpy matmul 1t {float(one.stdout):7.3f} s   (one BLAS thread)" if one.returncode == 0 else f"numpy matmul 1t (failed: {one.stderr.strip()[-80:]})")
        print(f"numpy matmul    {best(lambda: a @ a):7.3f} s   (every core)")
        big = np.ones(250_000_000)  # 2 GB
        print(f"memory copy 2GB {best(lambda: big.copy()):7.3f} s")
        del big
        try:
            import pandas as pd
        except ImportError:
            print("pandas         (not installed)")
        else:
            n = 5_000_000
            df = pd.DataFrame({"g": np.random.default_rng(1).integers(0, 1000, n), "v": np.random.default_rng(2).standard_normal(n)})
            print(f"pandas groupby  {best(lambda: df.groupby('g')['v'].mean()):7.3f} s   (5M rows, 1000 groups)")
    path = os.path.join(where, f"bench-{os.getpid()}.bin")
    data = os.urandom(1 << 20) * 64  # 64 MB
    t = time.perf_counter()
    with open(path, "wb") as f:
        for _ in range(16):  # 1 GB
            f.write(data)
        f.flush()
        os.fsync(f.fileno())
    write = time.perf_counter() - t
    subprocess.run(["sync"], check=False)
    t = time.perf_counter()
    with open(path, "rb") as f:
        while f.read(1 << 24):
            pass
    read = time.perf_counter() - t
    os.remove(path)
    print(f"disk write 1GB  {write:7.3f} s   read {read:7.3f} s   ({where}; the read may be the page cache)")


if __name__ == "__main__":
    main()
