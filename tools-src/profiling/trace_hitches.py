"""Finds stretches where a thread was stuck in one unusual function, in a sample trace.

A hitch (one frame taking 60-500 ms) shows up in a sampling trace as a run of samples
in which some thread sits in a single function it rarely visits otherwise: a shader
compile, a file read, a lock wait. This script reads the CSV written by
`sample_profiler.py --trace` and reports those runs, together with what every other
traced thread did at the same time.

Usage:
    python -I trace_hitches.py trace.csv
    python -I trace_hitches.py trace.csv --window 0.05 --min-duration 0.06
"""

from __future__ import annotations

import argparse
import collections
import csv
import sys

Sample = tuple[float, str]  # seconds, function


def load(path: str) -> dict[int, list[Sample]]:
    threads: dict[int, list[Sample]] = collections.defaultdict(list)
    with open(path, encoding="utf-8", newline="") as source:
        for row in csv.DictReader(source):
            threads[int(row["thread"])].append((float(row["seconds"]), row["function"]))
    return threads


def windows(samples: list[Sample], size: float) -> dict[int, collections.Counter]:
    """Function histogram per window index."""
    result: dict[int, collections.Counter] = collections.defaultdict(collections.Counter)
    for at, function in samples:
        result[int(at / size)][function] += 1
    return result


def dominant(counter: collections.Counter, share: float) -> str | None:
    total = sum(counter.values())
    if total == 0:
        return None
    function, n = counter.most_common(1)[0]
    return function if n / total >= share else None


def summary(counter: collections.Counter, limit: int = 3) -> str:
    total = sum(counter.values()) or 1
    return ", ".join(f"{function} {100 * n / total:.0f}%" for function, n in counter.most_common(limit))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("trace", help="CSV written by sample_profiler.py --trace")
    parser.add_argument("--window", type=float, default=0.05, help="window size in seconds")
    parser.add_argument("--share", type=float, default=0.6,
                        help="fraction of a window one function must hold to count as stuck")
    parser.add_argument("--rare", type=float, default=0.02,
                        help="a function is unusual below this share of the thread's samples")
    parser.add_argument("--min-duration", type=float, default=0.06,
                        help="report runs at least this long, in seconds")
    args = parser.parse_args()

    threads = load(args.trace)
    per_window = {tid: windows(samples, args.window) for tid, samples in threads.items()}
    overall = {tid: collections.Counter(function for _, function in samples)
               for tid, samples in threads.items()}

    found = 0
    for tid, histograms in per_window.items():
        total = sum(overall[tid].values())
        run_function, run_start, run_end = None, 0, 0
        for index in sorted(histograms) + [None]:
            function = None
            if index is not None:
                candidate = dominant(histograms[index], args.share)
                if candidate and overall[tid][candidate] / total < args.rare:
                    function = candidate
            continues = function is not None and function == run_function and index == run_end + 1
            if continues:
                run_end = index
                continue
            if run_function is not None and (run_end - run_start + 1) * args.window >= args.min_duration:
                found += 1
                start, end = run_start * args.window, (run_end + 1) * args.window
                print(f"{start:8.2f}s  {1000 * (end - start):5.0f} ms  thread {tid} stuck in {run_function}")
                for other, other_windows in per_window.items():
                    if other == tid:
                        continue
                    merged: collections.Counter = collections.Counter()
                    for w in range(run_start, run_end + 1):
                        merged.update(other_windows.get(w, {}))
                    print(f"{'':25}thread {other}: {summary(merged)}")
            run_function, run_start, run_end = function, index or 0, index or 0
    if not found:
        print("no stuck runs found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
