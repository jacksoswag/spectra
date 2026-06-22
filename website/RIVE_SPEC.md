# Fighters rig spec (Rive)

This is the contract between the website and the character animation. Build a Rive file
to this spec, export it to `website/assets/fighters.riv`, reload the page, and it auto-
upgrades from the placeholder canvas rig to your Rive rig (no code changes). Until the
file exists, the page falls back to the built-in stick rig, so nothing breaks.

The page owns the **shaded backgrounds, the prism orb, the props, the timing, the screen
position, and the facing** of each character. Your rig owns the **body animation** — the
run cycle, the punch, the recoil, the weight. That is where Becker-quality comes from:
anticipation, squash/stretch, overshoot, follow-through, settle. Spend it there.

## File

- Path: `website/assets/fighters.riv` (runtime export: File → Export → Runtime `.riv`).
- **Two artboards**, identical rig, different colour:
  - `Cyan` — cyan line `#2fd9ff`.
  - `Magenta` — magenta line `#ff3df0`.
  - Add a dark outline/contour under the line so the character stays readable over busy
    shaders (the placeholder rig does this).

## Artboard layout (load-bearing — the page positions against it)

- Artboard size **240 × 320**.
- A standing (idle) character is **~280 px tall**, **horizontally centred**, with **feet
  at the bottom edge** (the page anchors bottom-centre and scales from there).
- Author the character **facing right**. The page mirrors the whole artboard for left-
  facing, so do **not** mirror inside the rig.
- Keep every action within the artboard bounds (a jump rises but stays inside 320 px).

## State machine

- One state machine named **`Loco`** with two inputs:
  - **`action`** — Number. The page sets this to pick the current action; transition from
    Any State on `action == value`. Values:

    | value | state | kind | notes |
    |------:|-------|------|-------|
    | 0 | idle | loop | breathing idle |
    | 1 | walk | loop | |
    | 2 | run | loop | bigger stride, lean |
    | 3 | reach | hold | reach up/forward (toward the orb) |
    | 4 | grab | hold | both hands forward, gripping |
    | 5 | punch | one-shot → hold | a cross with anticipation + overshoot |
    | 6 | recoil | one-shot → hold | took a hit; head back, stagger |
    | 7 | jump | hold | airborne, legs tucked |
    | 8 | crouch | hold | low, ready/creeping |
    | 9 | paint | loop | sweeping arm (painting a wall) |
    | 10 | dodge | hold | hard lean to the side |
    | 11 | amazed | hold | gazing up, awe |
    | 12 | present | hold | holding the orb out, showing it off |
    | 13 | detective | hold | crouched peering (holds a magnifier — page draws it) |
    | 14 | frozen | hold | rigid, mid-action freeze (VHS pause) |
    | 15 | down | hold | knocked over on the ground |

  - **`flip`** — Boolean. Optional. The page already mirrors for facing; only wire this
    if you want to swap an asymmetric detail, and tell us so we disable the CSS mirror.

- Timing: the page holds each action for the length of its shot (1–4 s). Loops should
  read at 1×; one-shots land in ~0.3–0.6 s then settle into a hold.

## What each character does, by shot (priorities for the animator)

The 13-shot loop (see `js/story.js`). Cyan = hero, Magenta = greedy rival.

1. discover — Cyan: walk → reach. Magenta: crouch (lurking).
2–4. demo — Cyan: present / amazed. Magenta: crouch.
5. grab — Magenta: run → grab. Cyan: amazed → recoil.
6. crt — both: recoil/dodge/crouch (disoriented).
7. comic — Cyan: run → punch → recoil. Magenta: recoil → punch.
8. painting — Magenta: paint (builds a wall). Cyan: run → recoil (bonks it).
9. matrix — Magenta: present → recoil → crouch (hit). Cyan: dodge → grab.
10. golden — Cyan: amazed → recoil. Magenta: crouch → walk → grab.
11. vhs — Cyan: run → jump → frozen. Magenta: recoil → present → walk (off).
12. noir — Cyan: detective (pans the scene). Magenta: off-screen.
13. fade — Cyan: walk (off).

The highest-value actions to nail first: **run, punch, recoil, jump, present, detective.**

## The orb

The prism orb is drawn by the page, snapped to the holder's hand. So in `grab`,
`present`, and `reach`, place the active hand at a clear, consistent point (around the
upper-right of the artboard when facing right) so the page-drawn orb lands in the palm.

## Getting a rig without animating from scratch

- Rive Community (`rive.app/community`) has free character/stick rigs — fork one, rename
  its state machine to `Loco`, and wire the `action` values above.
- Or commission it: this document is the brief. A Rive animator needs only the artboard
  layout + the `Loco`/`action` table.

## Testing

Drop `fighters.riv` into `website/assets/`, reload. The page logs nothing on success and
silently uses your rig; if the file is missing or fails to load it falls back to the
canvas rig within ~4 s. Tune the standing height constant (`CHAR_H`) in
`js/character.js` if your character sits higher or lower in the artboard.
