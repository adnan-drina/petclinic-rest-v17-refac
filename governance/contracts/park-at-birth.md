# Park-at-birth: M3 mint must stay blocked (Class A)

**Status:** binding (in-tree).

## Problem

`create-m3-implementer.sh` passes `--initial-status blocked`, but when `--parent`
points at an already-**done** M2b card, Hermes may auto-promote the new child to
`ready` (dependency completion). Remints then birth **dispatchable unsigned**
cards during serial HOLD.

## Rule

1. After `hermes kanban create`, mint path **must** verify status is `blocked`
 (or `needs_input`/`triage` park).
2. If not parked: immediately
 `hermes kanban block <id> --kind needs_input "park-at-birth …"` and re-verify.
3. If still dispatchable (`ready`/`todo`/`running`): **die** — do not emit
 ack-request / claim success.
4. Unpark only after brief-identity ack + identity §3a + serial GO.

## Related

- born-parked precedent
- `slim-packet.md` M3 born-parked note

## Parent-done auto-promote (B6)

Native Hermes may flip parked M3 children to `ready` when the Planning parent
reaches `done`. That undoes park-at-birth and lets `hermes kanban daemon`
fan-out all stories in parallel before brief-identity acks exist.

**Rule 5:** Immediately after M2b/`Planning` complete (and before any daemon
tick), run:

```bash
bash .hermes/enforcement/dispatch-phase/scripts/repark-m3-until-brief-ack.sh \
  --parent <m2b-task-id>
```

Unpark remains gate-driven: signed brief-identity ack + identity §3a + serial GO.
