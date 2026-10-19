"""Minimal sampling profiler for a running Windows process (no admin rights needed).

It periodically suspends each thread of the target process, reads its instruction
pointer, resumes it, and attributes the sample to the loaded module (EXE/DLL) that
contains that address. This uses the same documented debugging APIs a debugger uses
on a process owned by the current user; nothing is injected into the target.

Usage:
    python -I sample_profiler.py --process moderngekko-run.exe --seconds 30
    python -I sample_profiler.py --pid 1234 --seconds 30 --rate 1000 --top-offsets 20
    python -I sample_profiler.py --process moderngekko-run.exe --wait --functions 25
    python -I sample_profiler.py --pid 1234 --seconds 30 --trace trace.csv

--functions resolves samples to function names for every module that has a PDB next
to it, using dbghelp.dll from Windows (offline, after sampling).

--trace writes every sample of the busiest threads, in time order, to a CSV
(seconds, thread, function) for finding what each thread did during a hitch
(see trace_hitches.py).

--slow-sample-ms lists samples that took long to take: a thread cannot be suspended while it
is busy in the kernel, so these show threads blocked in a driver call or a disk read.
"""

from __future__ import annotations

import argparse
import collections
import ctypes
import ctypes.wintypes as wt
import os
import sys
import time

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
psapi = ctypes.WinDLL("psapi", use_last_error=True)

TH32CS_SNAPPROCESS = 0x2
TH32CS_SNAPTHREAD = 0x4
PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
THREAD_SUSPEND_RESUME = 0x0002
THREAD_GET_CONTEXT = 0x0008
THREAD_QUERY_INFORMATION = 0x0040
CONTEXT_AMD64 = 0x00100000
CONTEXT_CONTROL = CONTEXT_AMD64 | 0x1
LIST_MODULES_ALL = 0x3
RIP_OFFSET = 0xF8  # offset of Rip inside the x64 CONTEXT structure
CONTEXT_SIZE = 0x4D0
CONTEXT_FLAGS_OFFSET = 0x30


class THREADENTRY32(ctypes.Structure):
    _fields_ = [
        ("dwSize", wt.DWORD), ("cntUsage", wt.DWORD), ("th32ThreadID", wt.DWORD),
        ("th32OwnerProcessID", wt.DWORD), ("tpBasePri", wt.LONG), ("tpDeltaPri", wt.LONG),
        ("dwFlags", wt.DWORD),
    ]


class PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [
        ("dwSize", wt.DWORD), ("cntUsage", wt.DWORD), ("th32ProcessID", wt.DWORD),
        ("th32DefaultHeapID", ctypes.c_void_p), ("th32ModuleID", wt.DWORD),
        ("cntThreads", wt.DWORD), ("th32ParentProcessID", wt.DWORD),
        ("pcPriClassBase", wt.LONG), ("dwFlags", wt.DWORD), ("szExeFile", wt.WCHAR * 260),
    ]


class MODULEINFO(ctypes.Structure):
    _fields_ = [("lpBaseOfDll", ctypes.c_void_p), ("SizeOfImage", wt.DWORD),
                ("EntryPoint", ctypes.c_void_p)]


kernel32.CreateToolhelp32Snapshot.restype = wt.HANDLE
kernel32.OpenProcess.restype = wt.HANDLE
kernel32.OpenThread.restype = wt.HANDLE
kernel32.SuspendThread.argtypes = [wt.HANDLE]
kernel32.ResumeThread.argtypes = [wt.HANDLE]
kernel32.GetThreadContext.argtypes = [wt.HANDLE, ctypes.c_void_p]
kernel32.CloseHandle.argtypes = [wt.HANDLE]
kernel32.GetExitCodeProcess.argtypes = [wt.HANDLE, ctypes.POINTER(wt.DWORD)]
kernel32.GetThreadDescription.argtypes = [wt.HANDLE, ctypes.POINTER(wt.LPWSTR)]
kernel32.LocalFree.argtypes = [ctypes.c_void_p]


def find_pid(process_name: str, required: bool = True) -> int | None:
    snapshot = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    entry = PROCESSENTRY32W()
    entry.dwSize = ctypes.sizeof(entry)
    try:
        ok = kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        while ok:
            if entry.szExeFile.lower() == process_name.lower():
                return entry.th32ProcessID
            ok = kernel32.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snapshot)
    if required:
        raise SystemExit(f"process not found: {process_name}")
    return None


def list_thread_ids(pid: int) -> list[int]:
    snapshot = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0)
    entry = THREADENTRY32()
    entry.dwSize = ctypes.sizeof(entry)
    ids = []
    try:
        ok = kernel32.Thread32First(snapshot, ctypes.byref(entry))
        while ok:
            if entry.th32OwnerProcessID == pid:
                ids.append(entry.th32ThreadID)
            ok = kernel32.Thread32Next(snapshot, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snapshot)
    return ids


Module = tuple[int, int, str, str]  # base, size, file name, full path


def list_modules_safe(process: int, previous: list[Module]) -> list[Module]:
    """list_modules, keeping the previous list while the loader is still mapping DLLs."""
    try:
        return list_modules(process)
    except OSError:
        return previous


def list_modules(process: int) -> list[Module]:
    handles = (ctypes.c_void_p * 1024)()
    needed = wt.DWORD()
    if not psapi.EnumProcessModulesEx(process, handles, ctypes.sizeof(handles),
                                      ctypes.byref(needed), LIST_MODULES_ALL):
        raise ctypes.WinError(ctypes.get_last_error())
    modules = []
    for handle in handles[: needed.value // ctypes.sizeof(ctypes.c_void_p)]:
        info = MODULEINFO()
        psapi.GetModuleInformation(process, ctypes.c_void_p(handle), ctypes.byref(info),
                                   ctypes.sizeof(info))
        name = ctypes.create_unicode_buffer(260)
        psapi.GetModuleBaseNameW(process, ctypes.c_void_p(handle), name, 260)
        path = ctypes.create_unicode_buffer(1024)
        psapi.GetModuleFileNameExW(process, ctypes.c_void_p(handle), path, 1024)
        modules.append((info.lpBaseOfDll, info.SizeOfImage, name.value, path.value))
    return sorted(modules)


IDLE_MODULES = ("ntdll.dll", "win32u.dll")
user32 = ctypes.WinDLL("user32", use_last_error=True)
WNDENUMPROC = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)


def process_alive(process: int) -> bool:
    code = wt.DWORD()
    kernel32.GetExitCodeProcess(process, ctypes.byref(code))
    return code.value == 259  # STILL_ACTIVE


def window_title(pid: int) -> str:
    """Longest visible window title of the process (the game shows its FPS there)."""
    titles: list[str] = []

    def callback(hwnd, _):
        owner = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd):
            buffer = ctypes.create_unicode_buffer(256)
            user32.GetWindowTextW(hwnd, buffer, 256)
            titles.append(buffer.value)
        return True

    user32.EnumWindows(WNDENUMPROC(callback), 0)
    return max(titles, key=len, default="")


def busy_samples(counter: collections.Counter) -> int:
    return sum(n for name, n in counter.items() if name not in IDLE_MODULES)


def resolve(modules: list[Module], address: int) -> tuple[str, int]:
    for base, size, name, _ in modules:
        if base <= address < base + size:
            return name, address - base
    return "<jit/unknown>", address


class SYMBOL_INFOW(ctypes.Structure):
    _fields_ = [
        ("SizeOfStruct", wt.ULONG), ("TypeIndex", wt.ULONG), ("Reserved", ctypes.c_uint64 * 2),
        ("Index", wt.ULONG), ("Size", wt.ULONG), ("ModBase", ctypes.c_uint64),
        ("Flags", wt.ULONG), ("Value", ctypes.c_uint64), ("Address", ctypes.c_uint64),
        ("Register", wt.ULONG), ("Scope", wt.ULONG), ("Tag", wt.ULONG),
        ("NameLen", wt.ULONG), ("MaxNameLen", wt.ULONG), ("Name", wt.WCHAR * 512),
    ]


class SymbolResolver:
    """Maps module offsets to function names using a module's PDB (dbghelp, offline).

    Modules are loaded from disk at a synthetic base address, so this works after the
    target has exited and never touches the target process.
    """

    SYMOPT_UNDNAME = 0x2
    SYMOPT_DEFERRED_LOADS = 0x4
    SYMOPT_NO_PROMPTS = 0x80000

    def __init__(self) -> None:
        self._dbghelp = ctypes.WinDLL("dbghelp", use_last_error=True)
        self._dbghelp.SymLoadModuleExW.restype = ctypes.c_uint64
        self._dbghelp.SymLoadModuleExW.argtypes = [
            wt.HANDLE, wt.HANDLE, wt.LPCWSTR, wt.LPCWSTR, ctypes.c_uint64, wt.DWORD,
            ctypes.c_void_p, wt.DWORD]
        self._dbghelp.SymFromAddrW.argtypes = [
            wt.HANDLE, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(SYMBOL_INFOW)]
        self._dbghelp.SymInitializeW.argtypes = [wt.HANDLE, wt.LPCWSTR, wt.BOOL]
        self._dbghelp.SymCleanup.argtypes = [wt.HANDLE]
        self._session = wt.HANDLE(0x5EED)  # any unique value works for offline use
        self._dbghelp.SymSetOptions(self.SYMOPT_UNDNAME | self.SYMOPT_DEFERRED_LOADS | self.SYMOPT_NO_PROMPTS)
        if not self._dbghelp.SymInitializeW(self._session, None, False):
            raise ctypes.WinError(ctypes.get_last_error())
        self._bases: dict[str, int] = {}
        self._next_base = 0x10000000

    def load(self, path: str, size: int) -> bool:
        if not os.path.exists(os.path.splitext(path)[0] + ".pdb"):
            return False
        base = self._dbghelp.SymLoadModuleExW(self._session, None, path, None,
                                              self._next_base, size, None, 0)
        if not base:
            return False
        self._bases[path] = base
        self._next_base += (size + 0xFFFFFF) & ~0xFFFFFF
        return True

    def name(self, path: str, offset: int) -> str:
        info = SYMBOL_INFOW()
        info.SizeOfStruct = 88  # sizeof(SYMBOL_INFOW) as declared by dbghelp.h (Name[1], 8-byte aligned)
        info.MaxNameLen = 512
        displacement = ctypes.c_uint64()
        if self._dbghelp.SymFromAddrW(self._session, self._bases[path] + offset,
                                      ctypes.byref(displacement), ctypes.byref(info)):
            return info.Name
        return f"+0x{offset:08X}"

    def close(self) -> None:
        self._dbghelp.SymCleanup(self._session)


class ThreadSampler:
    """Reads the instruction pointer of one thread by briefly suspending it."""

    def __init__(self, thread_id: int):
        self.thread_id = thread_id
        self.handle = kernel32.OpenThread(
            THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, False, thread_id)
        # CONTEXT must be 16-byte aligned.
        self._raw = ctypes.create_string_buffer(CONTEXT_SIZE + 16)
        self._ctx = (ctypes.addressof(self._raw) + 15) & ~15

    def sample(self) -> int | None:
        if not self.handle or kernel32.SuspendThread(self.handle) == 0xFFFFFFFF:
            return None
        try:
            ctypes.c_uint32.from_address(self._ctx + CONTEXT_FLAGS_OFFSET).value = CONTEXT_CONTROL
            if not kernel32.GetThreadContext(self.handle, ctypes.c_void_p(self._ctx)):
                return None
            return ctypes.c_uint64.from_address(self._ctx + RIP_OFFSET).value
        finally:
            kernel32.ResumeThread(self.handle)

    def description(self) -> str:
        """The name the process gave this thread (SetThreadDescription), or ""."""
        text = wt.LPWSTR()
        if not self.handle or kernel32.GetThreadDescription(self.handle, ctypes.byref(text)) < 0:
            return ""
        try:
            return text.value or ""
        finally:
            kernel32.LocalFree(text)

    def close(self) -> None:
        if self.handle:
            kernel32.CloseHandle(self.handle)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--process", help="executable name, e.g. moderngekko-run.exe")
    target.add_argument("--pid", type=int)
    parser.add_argument("--seconds", type=float, default=20.0)
    parser.add_argument("--rate", type=int, default=1000, help="sampling rounds per second")
    parser.add_argument("--top-offsets", type=int, default=0,
                        help="also print the hottest offsets inside each busy module")
    parser.add_argument("--offset-bytes", type=int, default=256,
                        help="size of the address ranges --top-offsets counts (a power of two; "
                             "1 gives exact instruction addresses)")
    parser.add_argument("--wait", action="store_true",
                        help="wait for --process to start instead of failing")
    parser.add_argument("--stop-file",
                        help="stop early as soon as this file exists")
    parser.add_argument("--window", type=float, default=0.0,
                        help="also print a timeline of the busiest thread every N seconds")
    parser.add_argument("--functions", type=int, default=0,
                        help="also print the hottest N functions per busy thread (modules with a PDB)")
    parser.add_argument("--trace",
                        help="write every sample of the busiest threads, in time order, to this CSV")
    parser.add_argument("--trace-threads", type=int, default=4,
                        help="how many of the busiest threads --trace keeps (default 4)")
    parser.add_argument("--slow-sample-ms", type=float, default=0.0,
                        help="report samples that took longer than this: the thread could not be "
                             "suspended because it was busy in the kernel (a driver call, a page fault)")
    args = parser.parse_args()
    if args.offset_bytes < 1 or args.offset_bytes & (args.offset_bytes - 1):
        parser.error("--offset-bytes must be a power of two")
    offset_mask = ~(args.offset_bytes - 1)

    pid = args.pid
    if args.process:
        while (pid := find_pid(args.process, required=not args.wait)) is None:
            time.sleep(0.5)
    process = kernel32.OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid)
    if not process:
        raise ctypes.WinError(ctypes.get_last_error())
    modules = list_modules_safe(process, [])

    samplers = {tid: ThreadSampler(tid) for tid in list_thread_ids(pid)}
    per_thread: dict[int, collections.Counter] = collections.defaultdict(collections.Counter)
    offsets: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    # Exact (module, offset) per thread, for --functions.
    exact: dict[int, collections.Counter] = collections.defaultdict(collections.Counter)
    # Time-ordered (seconds, module, offset) per thread, for --trace.
    trace: dict[int, list[tuple[float, str, int]]] = collections.defaultdict(list)
    module_info: dict[str, tuple[str, int]] = {}  # name -> (path, size)
    interval = 1.0 / args.rate
    deadline = time.perf_counter() + args.seconds
    rounds = 0
    next_refresh = 0.0
    started = time.perf_counter()
    timeline: list[tuple[float, str, collections.Counter]] = []
    window: dict[int, collections.Counter] = collections.defaultdict(collections.Counter)
    next_window = started + args.window if args.window else float("inf")
    slow_samples: list[tuple[float, int, float, str, int]] = []  # seconds, thread, ms, module, offset
    while time.perf_counter() < deadline:
        if (args.stop_file and os.path.exists(args.stop_file)) or not process_alive(process):
            break
        if time.perf_counter() >= next_window:
            hottest = max(window.values(), key=busy_samples, default=collections.Counter())
            timeline.append((time.perf_counter() - started, window_title(pid), hottest))
            window = collections.defaultdict(collections.Counter)
            next_window += args.window
        if time.perf_counter() >= next_refresh:
            # Threads come and go (the emulation threads start after boot), so re-scan.
            modules = list_modules_safe(process, modules)  # DLLs (game module, GPU driver) load late too
            module_info.update({name: (path, size) for _, size, name, path in modules})
            for tid in list_thread_ids(pid):
                if tid not in samplers:
                    samplers[tid] = ThreadSampler(tid)
            next_refresh = time.perf_counter() + 1.0
        now = time.perf_counter() - started
        for tid, sampler in samplers.items():
            before = time.perf_counter()
            rip = sampler.sample()
            took_ms = (time.perf_counter() - before) * 1000
            if rip is None:
                continue
            name, offset = resolve(modules, rip)
            if args.slow_sample_ms and took_ms > args.slow_sample_ms:
                slow_samples.append((before - started, tid, took_ms, name, offset))
            if args.trace:
                trace[tid].append((now, name, offset))
            per_thread[tid][name] += 1
            window[tid][name] += 1
            offsets[name][offset & offset_mask] += 1
            if args.functions:
                exact[tid][(name, offset)] += 1
        rounds += 1
        time.sleep(interval)

    thread_names = {tid: sampler.description() for tid, sampler in samplers.items()}
    for sampler in samplers.values():
        sampler.close()
    kernel32.CloseHandle(process)

    elapsed = time.perf_counter() - started
    print(f"pid {pid}: {rounds} rounds over {elapsed:.0f}s, {len(samplers)} threads")
    if timeline:
        print("\ntimeline (busiest thread per window):")
        for at, title, counter in timeline:
            total = sum(counter.values()) or 1
            top = ", ".join(f"{name.split('.')[0]} {100 * n / total:.0f}%"
                            for name, n in counter.most_common(4) if name not in IDLE_MODULES)
            fps = title.rsplit("|", 1)[-1].strip() if "|" in title else "-"
            print(f"  {at:6.0f}s  {fps:>9}  busy {100 * busy_samples(counter) / total:3.0f}%  {top}")
    # Every thread gets one sample per round, so rank by time spent outside the kernel.
    busy = sorted(per_thread.items(), key=lambda item: -busy_samples(item[1]))
    for tid, counter in busy:
        total = sum(counter.values())
        idle = total - busy_samples(counter)
        if total == 0 or idle / total > 0.98:
            continue  # mostly waiting in the kernel
        label = f" ({thread_names[tid]})" if thread_names.get(tid) else ""
        print(f"\nthread {tid}{label}: {total} samples ({100 * (1 - idle / total):.0f}% not in ntdll/win32u)")
        for name, n in counter.most_common(8):
            print(f"  {100 * n / total:5.1f}%  {name}")

    if args.top_offsets:
        totals = collections.Counter({name: sum(c.values()) for name, c in offsets.items()})
        for name, _ in totals.most_common(4):
            print(f"\nhottest {args.offset_bytes}-byte ranges in {name}:")
            for offset, n in offsets[name].most_common(args.top_offsets):
                print(f"  +0x{offset:08X}  {n}")

    if args.functions:
        print_functions(exact, module_info, busy, args.functions)
    if args.trace:
        write_trace(args.trace, trace, module_info, busy[: args.trace_threads])
    if args.slow_sample_ms:
        print_slow_samples(slow_samples, module_info, thread_names, args.slow_sample_ms)
    return 0


def print_slow_samples(slow_samples: list[tuple[float, int, float, str, int]],
                       module_info: dict[str, tuple[str, int]], thread_names: dict[int, str],
                       threshold_ms: float) -> None:
    print(f"\nsamples slower than {threshold_ms:g} ms (thread busy in the kernel), "
          f"with where it was once it stopped:")
    resolver = SymbolResolver()
    try:
        loaded = {name for name, (module_path, size) in module_info.items()
                  if name not in IDLE_MODULES and resolver.load(module_path, size)}
        for at, tid, took_ms, name, offset in slow_samples:
            where = (f"{name.split('.')[0]}!{resolver.name(module_info[name][0], offset)}"
                     if name in loaded else f"{name}+0x{offset:X}")
            label = f" ({thread_names[tid]})" if thread_names.get(tid) else ""
            print(f"  {at:7.2f}s  thread {tid}{label}  {took_ms:6.1f} ms  {where}")
    finally:
        resolver.close()


def write_trace(path: str, trace: dict[int, list[tuple[float, str, int]]],
                module_info: dict[str, tuple[str, int]],
                threads: list[tuple[int, collections.Counter]]) -> None:
    resolver = SymbolResolver()
    try:
        loaded = {name for name, (module_path, size) in module_info.items()
                  if name not in IDLE_MODULES and resolver.load(module_path, size)}
        names: dict[tuple[str, int], str] = {}
        with open(path, "w", encoding="utf-8", newline="") as out:
            out.write("seconds,thread,function\n")
            for tid, _ in threads:
                for at, name, offset in trace[tid]:
                    key = (name, offset)
                    if key not in names:
                        names[key] = (f"{name.split('.')[0]}!{resolver.name(module_info[name][0], offset)}"
                                      if name in loaded else name)
                    out.write(f"{at:.4f},{tid},\"{names[key]}\"\n")
        print(f"\ntrace: {sum(len(trace[tid]) for tid, _ in threads)} samples of "
              f"{len(threads)} threads written to {path}")
    finally:
        resolver.close()


def print_functions(exact: dict[int, collections.Counter], module_info: dict[str, tuple[str, int]],
                    busy: list[tuple[int, collections.Counter]], limit: int) -> None:
    resolver = SymbolResolver()
    try:
        loaded = {name for name, (path, size) in module_info.items()
                  if name not in IDLE_MODULES and resolver.load(path, size)}
        print(f"\nsymbols loaded for: {', '.join(sorted(loaded)) or 'none (no PDB found)'}")
        for tid, counter in busy:
            total = sum(counter.values())
            if total == 0 or busy_samples(counter) / total < 0.02:
                continue
            functions: collections.Counter = collections.Counter()
            for (name, offset), n in exact[tid].items():
                if name in loaded:
                    functions[f"{name.split('.')[0]}!{resolver.name(module_info[name][0], offset)}"] += n
                else:
                    functions[name] += n
            print(f"\nthread {tid}: hottest functions")
            for function, n in functions.most_common(limit):
                print(f"  {100 * n / total:5.1f}%  {function}")
    finally:
        resolver.close()


if __name__ == "__main__":
    sys.exit(main())
