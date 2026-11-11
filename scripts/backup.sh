#!/bin/bash
# Mac Backup engine: restic -> OneDrive via rclone
set -uo pipefail

BASE="$HOME/Library/Application Support/macbackup"
CFG="$BASE/config.json"
STATE="$BASE/state.json"
USAGE="$BASE/usage.json"
LOG="$HOME/Library/Logs/macbackup.log"

export RESTIC_PASSWORD_FILE="$BASE/restic.pass"
# repository is resolved from config below (remote / repoPath)
export PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ "${1:-}" = "--estimate" ]; then
  shift
  python3 "$BASE/estimate.py" "$@"
  exit 0
fi

mkdir -p "$(dirname "$LOG")"
echo "===== $(date '+%F %T') start (force=$FORCE) =====" >>"$LOG"

# read config
read -r CAP_GB BW USE_PROXY REMOTE SUBDIR < <(python3 - "$CFG" <<'PY'
import json,sys
try: c=json.load(open(sys.argv[1]))
except Exception: c={}
print(c.get("monthlyCapGB",5), c.get("bwlimitMB",2),
      1 if c.get("useProxy") else 0,
      c.get("remote","onedrive"), c.get("repoPath","MacBackup/restic"))
PY
)
export RESTIC_REPOSITORY="rclone:${REMOTE}:${SUBDIR}"
if [ "$USE_PROXY" = "1" ]; then
  export HTTPS_PROXY="http://127.0.0.1:7897"
  export HTTP_PROXY="http://127.0.0.1:7897"
  export ALL_PROXY="http://127.0.0.1:7897"
  echo "upload route: proxy (foreign IP)" >>"$LOG"
else
  echo "upload route: direct" >>"$LOG"
fi

export RCLONE_BWLIMIT="${BW}M"
export RCLONE_TRANSFERS=2
export RCLONE_CHECKERS=2
export GOMAXPROCS=2

write_state() {
  python3 - "$STATE" "$1" "$2" "$3" <<'PY'
import json,sys,datetime
p,status,msg,bytes_=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
st={"lastRun":datetime.datetime.now().isoformat(timespec="seconds"),
    "status":status,"message":msg,"lastBytes":int(bytes_ or 0)}
json.dump(st,open(p,"w"),indent=1)
PY
}

if ! pmset -g batt 2>/dev/null | grep -q "AC Power"; then
  echo "on battery, skipping" >>"$LOG"
  write_state "skipped" "On battery power" 0
  exit 0
fi

LOCK="${TMPDIR:-/tmp}/macbackup.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "another job running, skipping" >>"$LOG"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# monthly data cap
MONTH=$(date +%Y-%m)
USED=$(python3 - "$USAGE" "$MONTH" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
print(d.get(sys.argv[2],0))
PY
)
CAP_B=$(( ${CAP_GB%.*} * 1024 * 1024 * 1024 ))
if [ "$FORCE" = "0" ] && [ "$USED" -ge "$CAP_B" ] && [ "$CAP_B" -gt 0 ]; then
  echo "monthly cap reached ($USED/$CAP_B), skipping" >>"$LOG"
  write_state "capped" "Monthly data cap reached" 0
  exit 0
fi

EST_JSON=$(python3 "$BASE/estimate.py" 2>/dev/null)
EST_TXT=$(python3 - "$EST_JSON" <<'PY2'
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    print("unknown"); raise SystemExit
b=d.get("bytes",0); f=d.get("files",0)
g=b/1024**3
print(f"{g:.1f} GB · {f:,} files")
PY2
)
echo "estimated upload: $EST_TXT" >>"$LOG"
osascript -e "display notification \"About $EST_TXT\" with title \"Backup starting\" subtitle \"Encrypted upload to OneDrive\"" >/dev/null 2>&1

OUT=$(mktemp)
# resolve selected scope
SCOPE=$(python3 - "$CFG" <<'PY'
import json,sys
try: c=json.load(open(sys.argv[1]))
except Exception: c={}
print(" ".join(c.get("scope") or ["documents","desktop","pictures","dotfiles"]))
PY
)
PATHS=()
for cid in $SCOPE; do
  case "$cid" in
    documents) PATHS+=("$HOME/Documents") ;;
    desktop)   PATHS+=("$HOME/Desktop") ;;
    pictures)  PATHS+=("$HOME/Pictures") ;;
    movies)    PATHS+=("$HOME/Movies") ;;
    music)     PATHS+=("$HOME/Music") ;;
    downloads) PATHS+=("$HOME/Downloads") ;;
    dotfiles)  for d in .zshrc .zprofile .bash_profile .bashrc .gitconfig .gitignore_global .ssh .config .gnupg .npmrc; do [ -e "$HOME/$d" ] && PATHS+=("$HOME/$d"); done ;;
    full)      PATHS=("$HOME"); break ;;
  esac
done
[ ${#PATHS[@]} -eq 0 ] && PATHS=("$HOME")
echo "scope: ${PATHS[*]}" >>"$LOG"

run_backup_once() {
  nice -n 19 taskpolicy -c background restic backup "${PATHS[@]}" --json \
    --exclude-caches \
    --exclude "$HOME/Library/Caches" \
    --exclude "$HOME/Library/CloudStorage" \
    --exclude "$HOME/Library/Containers" \
    --exclude "$HOME/Library/Group Containers" \
    --exclude "$HOME/Library/Android" \
    --exclude "$HOME/Library/Daemon Containers" \
    --exclude "$HOME/Library/Application Support/Code/Cache" \
    --exclude "$HOME/Library/Application Support/Code/CachedData" \
    --exclude "$HOME/Library/Application Support/Code/User/workspaceStorage" \
    --exclude "$HOME/Library/Application Support/OrbStack" \
    --exclude "$HOME/.orbstack" \
    --exclude "$HOME/Documents/virtual" \
    --exclude "$HOME/.Trash" \
    --exclude "node_modules" --exclude "*/node_modules" \
    --exclude "__pycache__" --exclude "*/.venv" --exclude "*/venv" \
    --exclude "*.pyc" --exclude "*/DerivedData" \
    --tag auto >>"$LOG" 2>&1 | tee "$OUT" >/dev/null
}

wait_for_remote() {
  local i
  for i in $(seq 1 20); do
    rclone lsd "${REMOTE}:" >/dev/null 2>&1 && return 0
    echo "remote unreachable (check $i), waiting 30s" >>"$LOG"
    write_state "offline" "Waiting for network" 0
    sleep 30
  done
  return 1
}

MAX_ATTEMPTS=5
RC=1
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  if ! wait_for_remote; then
    echo "remote still unreachable, giving up" >>"$LOG"
    write_state "offline" "Remote unreachable" 0
    exit 0
  fi
  run_backup_once
  RC=$?
  [ "$RC" -eq 0 ] && break
  echo "attempt $attempt failed (rc=$RC)" >>"$LOG"
  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    write_state "retrying" "Connection lost · retry $attempt/$MAX_ATTEMPTS" 0
    sleep $((attempt * 20))
  fi
done

ADDED=$(python3 - "$OUT" <<'PY'
import json,sys
added=0
for line in open(sys.argv[1]):
    line=line.strip()
    if not line.startswith("{"): continue
    try: d=json.loads(line)
    except Exception: continue
    if d.get("message_type")=="summary":
        added=d.get("data_added",0)
print(added)
PY
)
rm -f "$OUT"

python3 - "$USAGE" "$MONTH" "$ADDED" <<'PY'
import json,sys
p,m,a=sys.argv[1],sys.argv[2],int(sys.argv[3] or 0)
try: d=json.load(open(p))
except Exception: d={}
d[m]=d.get(m,0)+a
json.dump(d,open(p,"w"),indent=1)
PY

if [ "$RC" -eq 0 ]; then
  write_state "ok" "Backup completed" "$ADDED"
else
  write_state "error" "Backup failed (exit $RC)" "$ADDED"
fi

# weekly prune on Sundays
if [ "$(date +%u)" = "7" ]; then
  echo "--- prune ---" >>"$LOG"
  nice -n 19 taskpolicy -c background restic forget \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune >>"$LOG" 2>&1
fi

echo "===== $(date '+%F %T') done rc=$RC added=$ADDED =====" >>"$LOG"
exit 0
