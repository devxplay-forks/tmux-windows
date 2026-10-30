---
created: 2026-10-30
updated: 2026-10-30
---

# tmux-windows render fidelity (DEV-114 residual)

Scope: fidelity of the Windows renderer. The property under specification is that
what an application writes into a pane is what appears in that pane's grid and on
the attached client. This covers cell content, background extent, and redraw
freshness. It does not cover input handling, mouse capabilities, or sizing.

## Verified facts (executed against the current worktree)

| Fact | How verified |
| --- | --- |
| Mouse capability resolution is complete | `regress/win32-terminfo-caps.sh` prints `all capabilities resolved`, exit 0 |
| A styled line round-trips exactly at 182 columns | emitted `awk 'NR>=55 { has=($0 ~ /x/ ) ? "BG" : "'` on a 256-colour background; `capture-pane -p` returned the string byte-identical |
| Pane, window and client sizes agree | client `182x92`, window `182x91`, pane `182x91` |
| `tty_draw_line()` no longer reads `last` uninitialised | the leading-padding path initialises `last` from `grid_default_cell`, and from the neighbouring wide glyph when one exists, before `tty_attributes()` reads it; clean build |
| The render hardening was reverted | `avoid_el` and `TERM_CONPTY_NO_PENDING_WRAP` return zero grep hits across `*.c`/`*.h`; the `#ifndef _WIN32` wrap guards are restored |
| The cell-fidelity guard passes | `regress/win32-tui-render.sh` asserts styled rows round-trip verbatim and that no glyph survives an overwrite; exit 0 |

## Invariants

- **I1 Content fidelity.** Every cell an application writes appears verbatim in
the grid. No cell is substituted, shifted, or blanked.
- **I2 Background extent.** A run of cells sharing a non-default background
renders with that background across the whole run, including rows whose only
content is that background.
- **I3 Redraw freshness.** No cell retains a glyph from a previously rendered
frame after the owning line has been redrawn.
- **I4 Defined initialisation.** `tty_draw_line()` must not read any local
structure before a defined initialisation is reachable on that path.

## Status of each invariant

- **I4 is satisfied.** The leading-padding path initialises `last` before
`tty_attributes()` reads it, so the clear no longer applies undefined stack
contents as the cell attributes. Fixed and verified in the worktree.
- **I1 and I3 are now guarded, and pass.** `regress/win32-tui-render.sh` asserts
that a corpus of styled rows returns verbatim from `capture-pane -p`, and that
overwriting a row with shorter content leaves no glyph from the previous frame.
- **I2 is guarded for the reported symptom.** `regress/win32-tui-render.sh`
paints a five-row full-width band and asserts that row 1 establishes the
background, that no row resets it, and that every row spans the pane width. A
band that stops being green, or leaves a default-background tail, fails with the
offending row and measured width. A subtly wrong colour on a subset of rows is
not detected.

## Evidence boundary

Claims derived from screenshots are excluded from this specification. Image reads
in this environment return file metadata only, so no glyph-level statement about
any screenshot can be substantiated and none is made. Any future specification of
I1-I3 must rest on captured grid bytes (`capture-pane -p`) compared against a
known-expected string, which is reproducible and diffable.

The `inner == outer` comparison in `regress/win32-tui-render.sh` detects
divergence between the two layers, so it catches emitter-side damage. It cannot
catch a defect shared by both layers, because tmux parses on both sides, and it
compares text only since `capture-pane -p` strips SGR. It is therefore necessary
but not sufficient. Background *presence* on a rendered row is asserted in the
narrow-pane wide-character phase, and background *extent* across a band is
asserted in the five-row band phase; both read one layer's own capture.

## Consequences for the renderer

I4 is satisfied, so background extent (I2) is evaluated on its own terms rather
than through a path that painted from undefined attributes.

The two behavioural edits are removed, so any observation about I1-I3 from this
point is attributable to pre-existing renderer behaviour rather than to them.
`regress/win32-tui-render.sh` guards I1, I2 and I3 directly.
