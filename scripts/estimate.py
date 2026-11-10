#!/usr/bin/env python3
"""Scan metadata to estimate backup size. Fast: metadata only."""
import os, sys, json, datetime, stat, subprocess, tempfile

HOME = os.path.expanduser("~")
CFG = os.path.join(HOME, "Library/Application Support/macbackup/config.json")
STATE = os.path.join(HOME, "Library/Application Support/macbackup/state.json")

EXCLUDE_ABS = [os.path.join(HOME, p) for p in [
    "Library/Caches", "Library/CloudStorage", "Library/Containers",
    "Library/Group Containers", "Library/Android", "Library/Daemon Containers",
    "Library/Application Support/Code/Cache",
    "Library/Application Support/Code/CachedData",
    "Library/Application Support/Code/User/workspaceStorage",
    "Library/Application Support/OrbStack", ".orbstack",
    "Documents/virtual", ".Trash",
]]
EXCLUDE_NAMES = {"node_modules", "__pycache__", ".venv", "venv", "DerivedData"}

CATEGORIES = [
    ("documents", "Documents"),
    ("desktop",   "Desktop"),
    ("pictures",  "Pictures"),
    ("movies",    "Movies"),
    ("music",     "Music"),
    ("downloads", "Downloads"),
    ("dotfiles",  "@dotfiles"),
    ("full",      "@full"),
]

DOTFILES = [".zshrc", ".zprofile", ".bash_profile", ".bashrc", ".gitconfig",
            ".gitignore_global", ".ssh", ".config", ".gnupg", ".npmrc"]

def excluded(path):
    for e in EXCLUDE_ABS:
        if path == e or path.startswith(e + os.sep):
            return True
    return False

def scan(paths):
    total = files = 0
    for base in paths:
        if os.path.isfile(base):
            try:
                st = os.lstat(base)
                if stat.S_ISREG(st.st_mode):
                    total += st.st_size; files += 1
            except OSError: pass
            continue
        for root, dirs, fs in os.walk(base, topdown=True, followlinks=False):
            if excluded(root):
                dirs[:] = []; continue
            dirs[:] = [d for d in dirs if d not in EXCLUDE_NAMES and not excluded(os.path.join(root, d))]
            for name in fs:
                p = os.path.join(root, name)
                try: st = os.lstat(p)
                except OSError: continue
                if stat.S_ISREG(st.st_mode):
                    total += st.st_size; files += 1
    return total, files

def cat_paths(cid):
    if cid == "dotfiles":
        return [os.path.join(HOME, d) for d in DOTFILES if os.path.exists(os.path.join(HOME, d))]
    if cid == "full":
        return [HOME]
    for k, v in CATEGORIES:
        if k == cid:
            return [os.path.join(HOME, v)]
    return []

def load_config():
    try: return json.load(open(CFG))
    except Exception: return {}

def main():
    args = sys.argv[1:]
    cfg = load_config()
    proxy_args = ["-x", "http://127.0.0.1:7897"] if cfg.get("useProxy") else []
    out = {"useProxy": bool(cfg.get("useProxy"))}

    if "--categories" in args:
        cats = {}
        for cid, _ in CATEGORIES:
            b, f = scan(cat_paths(cid))
            cats[cid] = {"bytes": b, "files": f}
        out["categories"] = cats

    # selected scope total
    scope = cfg.get("scope") or ["documents", "desktop", "pictures", "dotfiles"]
    paths = []
    for cid in scope:
        paths += cat_paths(cid)
    b, f = scan(paths)
    out.update({"bytes": b, "files": f, "firstRun": True})

    if "--egress" in args:
        try:
            r = subprocess.run(["curl", "-s", "-m", "8"] + proxy_args + ["https://ifconfig.co/json"],
                               capture_output=True, text=True, timeout=12)
            j = json.loads(r.stdout)
            out.update({"egressIP": j.get("ip"), "egressCC": j.get("country_iso"), "egressCity": j.get("city")})
        except Exception:
            out.update({"egressIP": None, "egressCC": None})

    if "--speed" in args:
        bps = 0
        tmp = None
        try:
            with tempfile.NamedTemporaryFile(delete=False) as fh:
                fh.write(b"0" * (2 * 1024 * 1024)); tmp = fh.name
            r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-m", "15",
                                "-w", "%{speed_upload}", "--data-binary", "@" + tmp,
                                "https://speed.cloudflare.com/__up"] + proxy_args,
                               capture_output=True, text=True, timeout=20)
            bps = float(r.stdout.strip() or 0)
        except Exception:
            bps = 0
        finally:
            if tmp:
                try: os.unlink(tmp)
                except Exception: pass
        out["uploadBps"] = bps

    print(json.dumps(out))

if __name__ == "__main__":
    main()
