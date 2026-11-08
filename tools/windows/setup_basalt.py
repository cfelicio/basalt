#!/usr/bin/env python3
"""The Windows first run: check the machine, set up Python, choose a model, write the config, serve.

    python tools/windows/setup_basalt.py [--plan] [--yes] [--model NAME|FILE|skip] [--gpu A,B]
                                         [--port N] [--engine-bin FILE] [--build] [--no-download] [--no-serve]

Asking is the default.  ``--plan`` prints every decision and changes nothing, which is what an agent and a person
who wants to read first should run.  ``--yes`` takes the shown default for every question.

Layout it works in: the folder holding ``serve/`` and ``data/``, with the engine in ``bin/basalt.exe`` (a
release zip) or ``build/bin/basalt.exe`` (a source tree you built).  Nothing is installed system-wide: Python
packages go in ``.venv`` here, models in ``models/``, settings in ``basalt_config.json``.  Standard library
only, because it runs before the server's dependencies are installed.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IS_WINDOWS = os.name == "nt"
ENGINE_EXE = "basalt.exe" if IS_WINDOWS else "basalt"
HF_REPOS = ([os.environ["BASALT_HF_REPO"]] if os.environ.get("BASALT_HF_REPO")
            else ["jesdga/Qwen3.8-Flash-Next-Basalt", "jesdga/DeepSeek-V4.1-Flash-1017-Basalt"])
FEED = os.environ.get("BASALT_FEED", "https://github.com/cfelicio/basalt/releases/latest/download")
SERVER_MODULES = ["numpy", "regex", "jinja2", "yaml", "tqdm", "PIL", "psutil", "markupsafe"]
NEED_COMPUTE = (12, 0)          # the architecture the engine is compiled for: Blackwell, sm_120
DEFAULT_PACK = "Qwen3.8-FN-UD-IQ1_M.basalt"        # the pick when it is in a listing; else the listing's smallest
ZIP_RE = re.compile(r"basalt-[0-9][^/\"']*windows-x64-cuda13\.zip")
GIB = 1024 ** 3


def gib(n: float) -> str:
    return f"{n / GIB:.1f} GiB"


def say(step: str, text: str) -> None:
    print(f"  {step:<12} {text}", flush=True)


def fix(message: str) -> None:
    print(f"  {'fix':<12} {message}", flush=True)


# --------------------------------------------------------------------------------------- reading the machine

def run(argv: list[str], timeout: int = 60) -> tuple[int, str]:
    """(exit code, stdout+stderr). A program that cannot start gives (-1, its name)."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, encoding="utf-8", errors="replace")
    except (OSError, subprocess.SubprocessError):
        return -1, argv[0]
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def parse_nvidia_smi(text: str) -> list[dict]:
    """Rows of ``nvidia-smi --query-gpu=name,compute_cap,memory.total,driver_version --format=csv,noheader,nounits``.

    A row with no whole-MiB third field is not a card row and is skipped, so the header of a non-``noheader``
    listing and any driver banner cannot be read as a card.
    """
    cards = []
    for line in text.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 4 or not parts[2].split(".")[0].isdigit():
            continue
        cap = [int(x) for x in re.split(r"[^0-9]+", parts[1]) if x]
        if len(cap) < 2:
            continue
        cards.append({"name": parts[0], "compute": (cap[0], cap[1]), "memory_mib": int(float(parts[2])),
                      "driver": parts[3]})
    return cards


def read_nvidia_smi() -> list[dict]:
    code, out = run(["nvidia-smi", "--query-gpu=name,compute_cap,memory.total,driver_version",
                     "--format=csv,noheader,nounits"])
    return parse_nvidia_smi(out) if code == 0 else []


def parse_hf_tree(entries: list[dict]) -> list[tuple[str, int]]:
    """The ``.basalt`` packs of a Hugging Face tree listing, smallest first, as (path, bytes)."""
    packs = []
    for e in entries:
        path = str(e.get("path", ""))
        if e.get("type") != "file" or not path.endswith(".basalt"):
            continue
        size = int((e.get("lfs") or {}).get("size") or e.get("size") or 0)
        packs.append((path, size))
    return sorted(packs, key=lambda p: p[1])


def fetch(url: str, timeout: int = 30) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "basalt-setup/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def hf_packs() -> tuple[list[tuple[str, str, int]], list[str]]:
    """The packs of every listing repo, smallest first, as (repo, path, bytes), and the repos not reachable."""
    packs: list[tuple[str, str, int]] = []
    dead: list[str] = []
    for repo in HF_REPOS:
        try:
            entries = json.loads(fetch(f"https://huggingface.co/api/models/{repo}/tree/main?recursive=true")
                                 .decode("utf-8", "replace"))
        except Exception as e:
            dead.append(f"{repo} ({type(e).__name__})")
            continue
        packs.extend((repo, path, size) for path, size in parse_hf_tree(entries))
    return sorted(packs, key=lambda p: p[2]), dead


def hf_links() -> str:
    return " and ".join(f"https://huggingface.co/{r}" for r in HF_REPOS)


def disk_free(path: Path) -> int:
    return shutil.disk_usage(str(path)).free


def total_ram() -> int:
    """System memory in bytes: psutil when it is installed (the server's requirements), then the OS's own
    reading (Windows: kernel32, Linux: /proc/meminfo), then wmic, which recent Windows 11 builds dropped."""
    try:
        import psutil
        return int(psutil.virtual_memory().total)
    except Exception:
        pass
    if IS_WINDOWS:
        try:
            import ctypes
            kilobytes = ctypes.c_ulonglong(0)
            if ctypes.windll.kernel32.GetPhysicallyInstalledSystemMemory(ctypes.byref(kilobytes)) != 0:
                return int(kilobytes.value) * 1024
        except Exception:
            pass
    else:
        try:
            for line in Path("/proc/meminfo").read_text(encoding="ascii").splitlines():
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) * 1024
        except OSError:
            pass
    code, out = run(["wmic", "ComputerSystem", "get", "TotalPhysicalMemory", "/value"])
    tail = out.strip().split("=")[-1].strip()
    return int(tail) if tail.isdigit() else 0


# ---------------------------------------------------------------------------------------------- the engine

def engine_candidates(root: Path, extra: str = "") -> list[Path]:
    """Where the engine binary may be, in the order the starter tries them."""
    out = [Path(extra)] if extra else []
    out += [root / "bin" / ENGINE_EXE, root / "build" / "bin" / ENGINE_EXE,
            root / "bin" / "basalt", root / "build" / "bin" / "basalt"]
    return out


def find_engine(root: Path, extra: str = "") -> Path | None:
    for c in engine_candidates(root, extra):
        if c.is_file():
            return c.resolve()
    return None


def build_commands(root: Path) -> list[list[str]]:
    return [["cmake", "-S", str(root), "-B", str(root / "build"), "-G", "Ninja",
             "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_CUDA_ARCHITECTURES=120"],
            ["cmake", "--build", str(root / "build"), "-j"]]


def build_from_source(root: Path, plan_only: bool) -> bool:
    """Configure and build in ``build/``, when the compiler, CMake, Ninja and nvcc are on PATH."""
    missing = [t for t in ("cmake", "ninja", "nvcc", "cl") if not shutil.which(t)]
    if missing:
        say("build", "cannot build here: no " + ", ".join(missing) + " on PATH")
        fix("open a Developer command prompt (or call vcvarsall.bat x64) and run again, or download the engine: "
            + f"{FEED}/basalt-<version>-windows-x64-cuda13.zip")
        return False
    cfg, build = build_commands(root)
    if plan_only:
        say("build", "would run: " + " ; ".join(" ".join(c) for c in (cfg, build)))
        return False
    say("build", " ".join(cfg))
    if run(cfg, timeout=900)[0] != 0:
        fix("see the messages above; docs/platforms.md has the Windows build steps")
        return False
    say("build", " ".join(build))
    return run(build, timeout=7200)[0] == 0


def release_zip_name(text: str) -> str:
    m = ZIP_RE.search(text)
    return m.group(0) if m else ""


def sha_from_sums(text: str, name: str) -> str:
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].endswith(name):
            return parts[0].lower()
    return ""


def name_of(url: str) -> str:
    return url.rsplit("/", 1)[-1].split(os.sep)[-1]


def download(url: str, dst: Path, expect_sha: str = "") -> bool:
    """Stream `url` into `dst`, printing every 256 MiB; checks the SHA-256 when `expect_sha` is given."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    part = dst.with_name(dst.name + ".part")
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "basalt-setup/1.0"}),
                                    timeout=120) as r, open(part, "wb") as f:
            total = int(r.headers.get("Content-Length") or 0)
            done, h = 0, hashlib.sha256()
            while True:
                block = r.read(1 << 20)
                if not block:
                    break
                f.write(block)
                h.update(block)
                done += len(block)
                if done % (256 << 20) < (1 << 20):
                    say("download", f"{name_of(url)}: {gib(done)}" + (f" of {gib(total)}" if total else ""))
    except (OSError, urllib.error.URLError, ValueError) as e:
        say("download", f"{name_of(url)} failed: {type(e).__name__} {e}")
        part.unlink(missing_ok=True)
        return False
    if expect_sha and h.hexdigest().lower() != expect_sha:
        say("download", f"{name_of(url)}: SHA-256 does not match; the file is left as {part.name}")
        return False
    part.replace(dst)
    say("download", f"{name_of(url)}: {gib(dst.stat().st_size)}")
    return True


def zip_root(entries: list[str]) -> str:
    """The single top-level folder of a zip listing, or "" when its files sit at the root."""
    tops = {n.split("/")[0] for n in entries if n and not n.endswith("/")}
    return tops.pop() + "/" if len(tops) == 1 else ""


def unpack_zip(zip_path: Path, root: Path) -> bool:
    """Unpack the release zip into `root`, so bin/ ends up beside serve/ and data/ (what the engine looks for)."""
    import zipfile
    with zipfile.ZipFile(zip_path) as z:
        names = [n for n in z.namelist() if not n.endswith("/") and not n.startswith("__MACOSX")]
        strip = zip_root(names)
        moved = 0
        for n in names:
            rel = n[len(strip):] if strip and n.startswith(strip) else n
            if not rel or Path(rel).name in ("README-WINDOWS.md", "VERSION"):
                continue
            target = root / rel.replace("/", os.sep)
            target.parent.mkdir(parents=True, exist_ok=True)
            with z.open(n) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)
            moved += 1
    say("engine", f"unpacked {moved} files from {name_of(str(zip_path))} into {root}")
    return (root / "bin" / ENGINE_EXE).is_file()


def sha_ok(path: Path, want: str) -> bool:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest().lower() == want


def fetch_release(root: Path) -> Path | None:
    """The newest release's Windows zip, checked against the release's SHA-256, unpacked into `root`."""
    if (root / ".git").exists():
        # unpacking replaces serve/, tools/, data/ and the docs: in a checkout that dirties the working tree
        say("engine", "this is a source checkout, so the prebuilt engine is not unpacked over it")
        fix("build it (START-HERE.bat --build), or unpack the zip from " + FEED.rsplit("/download", 1)[0] +
            " into an empty folder and run START-HERE.bat there")
        return None
    try:
        sums = fetch(f"{FEED}/SHA256SUMS.txt").decode("utf-8", "replace")
    except (OSError, urllib.error.URLError) as e:
        say("engine", f"no SHA256SUMS.txt at {FEED} ({type(e).__name__})")
        return None
    name = release_zip_name(sums)
    if not name:
        say("engine", "this release carries no windows-x64-cuda13 zip")
        return None
    sha = sha_from_sums(sums, name)
    if not sha:
        say("engine", f"{name} is not listed in SHA256SUMS.txt; not downloading it")
        return None
    cache = Path(os.environ.get("LOCALAPPDATA") or str(Path.home())) / "Basalt" / "downloads"
    dst = cache / name
    if dst.is_file() and not sha_ok(dst, sha):
        say("engine", f"the cached {name} does not match this release; fetching it again")
        dst.unlink(missing_ok=True)
    if not dst.is_file() and not download(f"{FEED}/{name}", dst, sha):
        return None
    return dst if unpack_zip(dst, root) else None


# --------------------------------------------------------------------------------------------- the server

def server_ready() -> bool:
    return all(importlib.util.find_spec(m) for m in SERVER_MODULES)


def requirements(root: Path) -> Path:
    return root / "requirements.txt"


def install_requirements(plan_only: bool) -> bool:
    req = requirements(ROOT)
    if not req.is_file():
        say("python", f"{req} is missing")
        fix("the release folder should carry requirements.txt; a source tree has it")
        return False
    cmd = [sys.executable, "-m", "pip", "install", "-r", str(req)]
    if plan_only:
        say("python", "would run: " + " ".join(cmd))
        return False
    say("python", "installing the server's packages into " + sys.prefix)
    code, out = run(cmd, timeout=1800)
    if code != 0:
        print(out[-1500:])
        fix("the package install failed: no network, a Python from the Microsoft Store, or a blocked proxy")
        return False
    return server_ready()


# ------------------------------------------------------------------------------------------ model + config

def model_choices(root: Path) -> tuple[list[Path], list[tuple[str, str, int]]]:
    models_dir = root / "models"
    local = sorted(models_dir.glob("*.basalt")) if models_dir.is_dir() else []
    remote: list[tuple[str, str, int]] = []
    try:
        remote, dead = hf_packs()
    except Exception as e:
        dead = [f"the listings ({type(e).__name__})"]
    for d in dead:
        say("models", f"the listing for {d} is not reachable: the other listings and this machine's files are still offered")
    return local, remote


def download_pack(root: Path, repo: str, path: str, size: int, args, plan: bool, ask) -> Path | None:
    dst = root / "models" / Path(path).name
    free = disk_free(root)
    say("model", f"{path}: {gib(size)}")
    say("disk", f"{gib(free)} free on {root.drive or '/'}; the file is {gib(size)}, and the experts that "
                f"do not fit in VRAM are read from RAM")
    if size and free < size + GIB:
        say("disk", "that is not enough: the pack plus room for the download")
        fix("choose a smaller pack, or free disk; the list is ordered smallest first")
        return None
    if plan:
        say("model", f"would download https://huggingface.co/{repo}/resolve/main/{path} into {dst}")
        return None
    if not args.yes and ask(f"download {gib(size)}? [y/N]: ", "n").lower() not in ("y", "yes"):
        say("model", "not downloaded; choose later")
        return None
    if not download(f"https://huggingface.co/{repo}/resolve/main/{path}", dst):
        fix(f"the download failed; the pack is on https://huggingface.co/{repo}")
        return None
    say("model", f"saved {dst}")
    return dst


def choose_model(root: Path, args, plan: bool, ask) -> Path | None:
    """The model to serve, or None when the choice is left for later."""
    if args.model == "skip":
        say("model", 'left for later: add the file to "models" in basalt_config.json, then run START-HERE.bat again')
        return None
    if args.model in ("local", "default") and not args.model.endswith(".basalt"):
        local, remote = model_choices(root)
        if args.model == "local" and local:
            return local[0]
        if args.model == "default" and remote:
            pick = next((p for p in remote if p[1] == DEFAULT_PACK), remote[0])
            return download_pack(root, pick[0], pick[1], pick[2], args, plan, ask)
    if args.model and args.model not in ("local", "default"):
        p = Path(args.model)
        found = p if p.is_file() else root / "models" / Path(args.model).name
        if found.is_file():
            return found
        say("model", f"{args.model}: no such file")
        fix(f"put it in {root / 'models'} or give a full path; the packs are at {hf_links()}")
        return None

    local, remote = model_choices(root)
    if not (local or remote):
        say("model", "no pack on this machine and the listings are unreachable")
        fix(f"put a .basalt file in {root / 'models'} and run START-HERE.bat again; packs are at {hf_links()}")
        return None

    print()
    print("  Model. One file holds the weights, the tokenizer, the drafter and the vision projector.")
    print("  It needs that much free disk, and the experts that do not fit in VRAM are read from system RAM.")
    for i, p in enumerate(local, 1):
        shown = p.relative_to(root) if p.is_relative_to(root) else p
        say(f"[{i}]", f"on this machine: {shown}  {gib(p.stat().st_size)}")
    off = len(local)
    for i, (repo, path, size) in enumerate(remote, off + 1):
        say(f"[{i}]", f"download: {path}  {gib(size)}  ({repo.split('/', 1)[1]})")
    say("[0]", 'choose later (add the file to "models" in basalt_config.json, then run START-HERE.bat again)')
    default = next((i for i, (_, path, _) in enumerate(remote, off + 1) if path == DEFAULT_PACK), off + 1)
    answer = ask(f"model [{default}]: ", str(default))
    try:
        pick = int(answer)
    except ValueError:
        pick = 0
    if pick == 0:
        say("model", 'left for later: add the file to "models" in basalt_config.json, then run START-HERE.bat again')
        return None
    if 1 <= pick <= len(local):
        return local[pick - 1]
    if len(local) < pick <= len(local) + len(remote):
        repo, path, size = remote[pick - len(local) - 1]
        return download_pack(root, repo, path, size, args, plan, ask)
    say("model", f"{answer} is not a choice")
    return None


def is_deepseek(model: Path | None) -> bool:
    return model is not None and "deepseek" in model.name.lower()


def engine_defaults(model: Path | None) -> dict:
    """Suggested values for the config's engine block, per model family (docs/models/index.md): Flash-Next
    tunes the KV cache and expert residency; DeepSeek-V4.1-Flash is fp16-KV-only and has no residency or
    relaxed-drafting flags, so it gets the expert-slot cap and the engine's own defaults."""
    if is_deepseek(model):
        return {"expert-cache": "auto"}
    return {"expert-cache": "auto", "prefill": "auto", "kv": "int8", "resident-experts": True}


def read_config(root: Path) -> dict:
    """The settings file, empty when it is missing or is not JSON (then the writer says it replaces it)."""
    f = root / "basalt_config.json"
    if not f.is_file():
        return {}
    try:
        data = json.loads(f.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        say("config", f"{f} is not readable as JSON; it is kept as {f.name}.bak and a new one is written")
        try:
            f.replace(f.with_name(f.name + ".bak"))
        except OSError:
            pass
        return {}
    return data if isinstance(data, dict) else {}


def to_v2(existing: dict) -> tuple[dict, str, bool]:
    """The existing settings in the v2 shape the server reads: (cfg, note, keep_old_as_bak).

    A v2 file passes through; a v1 file goes through the migration tool beside this script
    (``tools/migrations/config_v1_to_v2.py``, the one the server's own refusal names), so both read it the same
    way. When that cannot run or refuses the file, the caller starts fresh and keeps the old one as ``.bak``.
    """
    if not existing:
        return {"version": 2, "models": []}, "", False
    if isinstance(existing.get("models"), list) and existing.get("version", 2) == 2:
        cfg = json.loads(json.dumps(existing))
        cfg["version"] = 2
        return cfg, "", False
    try:
        path = ROOT / "tools" / "migrations" / "config_v1_to_v2.py"
        spec = importlib.util.spec_from_file_location("config_v1_to_v2", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        cfg = mod.migrated(existing)
    except (OSError, ValueError, AttributeError, TypeError) as e:
        return {"version": 2, "models": []}, f"cannot migrate the v1 config: {e}", True
    return cfg, "the v1 config moved to the v2 shape: the model and its settings are now an entry of \"models\"", False


def merge_config(cfg: dict, root: Path, model: Path | None, gpu: str, port: int, engine_defaults: dict) -> dict:
    """What to write, `cfg` already in the v2 shape: the settings that are already there win, except the values
    this run was told. The chosen model leads ``models`` and carries the cards; models the file already named
    stay in the list."""
    cfg = json.loads(json.dumps(cfg)) if cfg else {"version": 2, "models": []}
    cfg["version"] = 2
    server, engine = dict(cfg.get("server") or {}), dict(cfg.get("engine") or {})
    entries = [e for e in cfg.get("models") or [] if isinstance(e, dict)]
    if model is not None:
        # a model inside the folder is written with forward slashes, the way the docs' examples write it
        rel = model.relative_to(root).as_posix() if model.is_relative_to(root) else str(model)
        lead = [e for e in entries if str(e.get("model", "")).replace("\\", "/") == rel]
        entries = lead + [e for e in entries if e not in lead]
        if not lead:
            entries.insert(0, {"model": rel})
    if gpu and entries:
        entries[0]["gpu"] = gpu
    if port:
        server["port"] = port
    for k, v in engine_defaults.items():
        engine.setdefault(k, v)
    cfg["models"] = entries
    cfg["server"], cfg["engine"] = server, engine
    return cfg


def write_config(root: Path, cfg: dict) -> Path:
    f = root / "basalt_config.json"
    # LF on every platform, so the file is byte-identical to the one a Linux setup writes
    f.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
    say("config", f"wrote {f}")
    for line in f.read_text(encoding="utf-8").splitlines():
        print(f"      {line}")
    return f


# ------------------------------------------------------------------------------------------------ main

def pick_cards(cards: list[dict], args, interactive: bool, ask) -> str:
    if args.gpu:
        return args.gpu
    if len(cards) >= 2 and interactive:
        return ask("cards: '0' for the first alone, '0,1' to use the second as an expert tier [0]: ", "0")
    return "0"


def main() -> int:
    ap = argparse.ArgumentParser(description="Set up and start Basalt on Windows (or on Linux, from a release).")
    ap.add_argument("--plan", action="store_true", help="print every decision, change nothing")
    ap.add_argument("--yes", action="store_true", help="take the shown default for every question")
    ap.add_argument("--model", default="", help="a pack name, a path to a .basalt file, 'local', 'default' or 'skip'")
    ap.add_argument("--gpu", default="", help="the cards, as '0' or '0,1' (the second is an expert tier)")
    ap.add_argument("--port", type=int, default=0, help="the port to serve on (default 8080)")
    ap.add_argument("--engine-bin", default="", help="the engine binary, if it is not bin/basalt.exe")
    ap.add_argument("--build", action="store_true", help="build from source when the engine is missing")
    ap.add_argument("--no-download", action="store_true", help="never download the engine zip")
    ap.add_argument("--no-serve", action="store_true", help="set everything up and stop before serving")
    args = ap.parse_args()

    plan = args.plan
    interactive = sys.stdin.isatty() and not (args.yes or plan)

    def ask(question: str, default: str) -> str:
        if not interactive:
            return default
        try:
            return (input(f"  {question}").strip() or default)
        except EOFError:
            return default

    print()
    print(f"Basalt setup  (folder: {ROOT})" + ("   --plan: nothing is changed" if plan else ""))

    # 1. the machine
    cards = read_nvidia_smi()
    if not cards:
        say("gpu", "nvidia-smi gave nothing: no NVIDIA driver, or no NVIDIA card")
        fix("install the current driver from nvidia.com; this engine runs on Blackwell (RTX 50 series, "
            "RTX PRO Blackwell, compute capability 12.0)")
        if not plan:
            return 2
    else:
        for c in cards:
            say("gpu", f"{c['name']}  compute {c['compute'][0]}.{c['compute'][1]}  "
                       f"{c['memory_mib'] // 1024} GiB  driver {c['driver']}")
        if not any(c["compute"] == NEED_COMPUTE for c in cards):
            say("gpu", "no card here is compute capability 12.0, which is what this build compiles for")
            fix("this engine is Blackwell only (docs/platforms.md); Strata supports older cards")
            if not plan:
                return 2
    ram = total_ram()
    say("ram", gib(ram) + " of system memory" if ram else "system memory: unknown")
    say("disk", f"{gib(disk_free(ROOT))} free where Basalt lives")

    # 2. the engine binary
    engine = find_engine(ROOT, args.engine_bin)
    if engine is None:
        say("engine", f"no {ENGINE_EXE} in bin{os.sep} or build{os.sep}bin{os.sep}")
        if args.no_download:
            say("engine", "not downloading the release (--no-download)")
        elif plan:
            if (ROOT / ".git").exists():
                say("engine", "this is a source checkout: the prebuilt engine is not unpacked over it; "
                              "--build builds it, or unpack the zip into an empty folder and run START-HERE.bat there")
            else:
                say("engine", f"would fetch {FEED}/basalt-<version>-windows-x64-cuda13.zip, check its SHA-256 "
                              f"and unpack it into {ROOT}")
        elif args.yes or (interactive and ask("download the prebuilt engine for this card? [Y/n]: ", "y")
                          .lower() in ("y", "yes")):
            if fetch_release(ROOT) or find_engine(ROOT, args.engine_bin):
                engine = find_engine(ROOT, args.engine_bin)
        if engine is None and (args.build or (interactive and ask("build from source? [Y/n]: ", "y")
                                              .lower() in ("y", "yes"))):
            if build_from_source(ROOT, plan):
                engine = find_engine(ROOT, args.engine_bin)
    if engine:
        say("engine", f"using {engine}")
    elif not plan:
        fix("run START-HERE.bat --plan to see every step, and see docs/platforms.md for the requirements")
        return 2

    # 3. Python and the server's packages
    venv = ROOT / ".venv" / ("Scripts/python.exe" if IS_WINDOWS else "bin/python")
    say("python", f"{sys.version.split()[0]} at {sys.executable}"
                  + ("" if venv.is_file() else "  (no .venv here: the engine will use the python on PATH)"))
    if server_ready():
        say("python", "the server's packages are installed")
    elif plan:
        install_requirements(True)
    elif args.yes or (interactive and ask("install the server's packages now? [Y/n]: ", "y").lower() in ("y", "yes")):
        if not install_requirements(False):
            return 2
    if not server_ready() and not plan:
        return 2

    # 4. the model
    model = choose_model(ROOT, args, plan, ask)

    # 5. the settings
    gpu = pick_cards(cards, args, interactive, ask)
    port = args.port or int((read_config(ROOT).get("server") or {}).get("port") or 8080)
    if is_deepseek(model):
        say("model", "DeepSeek-V4.1-Flash: fp16 KV only (no --kv), no residency flags; DSpark drafting is on by default")
    defaults = engine_defaults(model)
    existing, note, replaced = to_v2(read_config(ROOT))
    if note:
        say("config", note)
    cfg = merge_config(existing, ROOT, model, gpu, port, defaults)
    if plan:
        say("config", "would write basalt_config.json: " + json.dumps(cfg, ensure_ascii=False))
    else:
        f = ROOT / "basalt_config.json"
        if replaced and f.is_file():
            f.replace(f.with_name(f.name + ".bak"))
            say("config", f"the config that would not migrate is kept as {f.name}.bak")
        write_config(ROOT, cfg)

    # 6. serve
    engine_shown = engine or ROOT / "bin" / ENGINE_EXE
    cmd = [str(engine_shown), "serve", "--config", str(ROOT / "basalt_config.json")]
    print()
    if model:
        print("  The engine places the experts in VRAM, in the peer card and in RAM at start, and prints what it did.")
        print(f"  To measure this machine and get suggested values:  bin\\basalt-probe.exe --model {model.name}")
    else:
        print(f"  No model is set: put a .basalt file in {ROOT / 'models'} and run START-HERE.bat again.")
    if plan:
        say("serve", "would run: " + " ".join(cmd))
        return 0
    if args.no_serve:
        say("serve", "stopped before serving; run: " + " ".join(cmd))
        return 0
    if not args.yes and interactive and ask("start the server now? [Y/n]: ", "y").lower() not in ("y", "yes"):
        say("serve", "not started; run: " + " ".join(cmd))
        return 0
    print()
    print(f"  serving: http://127.0.0.1:{port}  (OpenAI- and Anthropic-compatible API, and a web page)")
    print("  Ctrl+C in this window stops the server. The first load reads the whole pack: minutes, not seconds.")
    return subprocess.call(cmd, cwd=str(ROOT))


if __name__ == "__main__":
    sys.exit(main())
