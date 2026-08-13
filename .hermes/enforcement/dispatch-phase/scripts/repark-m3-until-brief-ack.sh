#!/usr/bin/env bash
# B6 / park-at-birth nurse: after parent Planning reaches done, Hermes may
# auto-promote M3 children to ready. Re-park any child that still lacks a
# signed brief-identity ack so the daemon cannot fan-out in parallel.
#
# Usage:
#   bash .hermes/enforcement/dispatch-phase/scripts/repark-m3-until-brief-ack.sh \
#     [--parent t_xxx] [--dry-run]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
export HERMES_HOME="${HERMES_HOME:-${ROOT}/.hermes/home}"
PARENT=""
DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --parent) PARENT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "usage: $0 [--parent t_xxx] [--dry-run]" >&2; exit 2 ;;
  esac
done

python3 - "$ROOT" "$PARENT" "$DRY" <<'PY'
import json, os, subprocess, sys
from pathlib import Path

root = Path(sys.argv[1])
parent = (sys.argv[2] or "").strip()
dry = sys.argv[3] == "1"
acks = root / "evidence" / "acks"
derived = root / "evidence" / "derived"

def signed_brief(story: str) -> bool:
    candidates = [
        acks / f"brief-identity-{story}.ack.yaml",
        acks / f"{story}.brief-identity.ack.yaml",
        acks / f"ack-{story}.yaml",
    ]
    for p in candidates:
        if not p.is_file():
            continue
        text = p.read_text(encoding="utf-8")
        if "status: unsigned" in text:
            continue
        if "ack_type: brief-identity" in text or "brief-identity" in p.name:
            if "status: signed" in text or "signed_at:" in text:
                return True
    return False

def story_for_task(task_id: str, title: str, map_cards: list) -> str:
    for c in map_cards:
        if isinstance(c, dict) and c.get("task_id") == task_id:
            return str(c.get("story_id") or "")
    if title.startswith("S-") and (":" in title or " " in title):
        return title.split(":", 1)[0].split(" ", 1)[0]
    return ""

map_cards = []
p = derived / "created-story-cards.json"
if p.is_file():
    try:
        map_cards = list(json.loads(p.read_text()).get("cards") or [])
    except Exception:
        pass

task_ids = []
if parent:
    claim = derived / f"created-cards-{parent}.json"
    if claim.is_file():
        try:
            data = json.loads(claim.read_text())
            task_ids = [c.get("id") for c in (data.get("cards") or []) if isinstance(c, dict) and c.get("id")]
        except Exception:
            task_ids = []
if not task_ids:
    task_ids = [c.get("task_id") for c in map_cards if isinstance(c, dict) and c.get("task_id")]

if not task_ids:
    print("repark-m3-until-brief-ack: no M3 task ids found", file=sys.stderr)
    sys.exit(1)

reparked, skipped_signed, already = [], [], []
for tid in task_ids:
    show = subprocess.run(["hermes", "kanban", "show", tid, "--json"], capture_output=True, text=True)
    title, status = "", ""
    if show.returncode == 0 and show.stdout.strip():
        try:
            d = json.loads(show.stdout)
            t = d.get("task") if isinstance(d.get("task"), dict) else d
            title = t.get("title") or ""
            status = (t.get("status") or "").lower()
        except Exception:
            pass
    story = story_for_task(tid, title, map_cards)
    if story and signed_brief(story):
        skipped_signed.append(tid)
        continue
    if status in ("blocked", "triage"):
        already.append(tid)
        continue
    reason = (
        "park-at-birth nurse: unsigned brief-identity ack"
        + (f" for {story}" if story else "")
        + "; serial HOLD until Operator signs (B6 / park-at-birth.md)"
    )
    print(f"REPARK {tid} story={story or '?'} was={status or '?'}")
    if dry:
        reparked.append(tid)
        continue
    subprocess.run(["hermes", "kanban", "block", "--kind", "needs_input", tid, reason], check=False)
    show2 = subprocess.run(["hermes", "kanban", "show", tid, "--json"], capture_output=True, text=True)
    st2 = ""
    if show2.returncode == 0 and show2.stdout.strip():
        try:
            d = json.loads(show2.stdout)
            t = d.get("task") if isinstance(d.get("task"), dict) else d
            st2 = (t.get("status") or "").lower()
        except Exception:
            pass
    if st2 not in ("blocked", "triage"):
        import sqlite3
        db = Path(os.environ.get("HERMES_HOME", str(root / ".hermes/home"))) / "kanban.db"
        conn = sqlite3.connect(db)
        conn.execute("UPDATE tasks SET status=? WHERE id=?", ("blocked", tid))
        conn.commit()
        conn.close()
        print("  sqlite fallback -> blocked")
    reparked.append(tid)

print(f"OK: reparked={len(reparked)} already_parked_unsigned={len(already)} signed_skip={len(skipped_signed)}")
print("reparked_ids=" + ",".join(reparked))
PY
