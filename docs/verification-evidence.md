# Verification evidence

Captured output from a real run on the development host. This file exists so the
claims about tooling, hooks, and test results are checkable from the repository
itself rather than from a chat transcript.

Re-capture everything with:

```sh
node scripts/verify-goal.mjs && node_modules/.bin/prettier --check "**/*.md"
```

---

## 1. Verbose logging: does a symbol-enabled build flood the log?

**No. Log verbosity is independent of build configuration.**

- `log_debug()` is compiled in for every build type and gated at runtime by
  `log_get_level()`.
- The server only opens a log file when started with `-v`. Without `-v`,
  `tty_log_fd` stays `-1` and no file is written.
- Therefore `RelWithDebInfo` produces **no** extra logging, and a `Debug` build
  would not either.
- The real hazard is `-v` combined with a large output burst, which produces an
  enormous log **in any build type**. Keep `-v` off by default and enable it only
  for a targeted reproduction.

Practical rule: use `RelWithDebInfo` for symbols, and leave `-v` alone unless the
stack from `cdb` is ambiguous.

---

## 2. Hook activation

`.git/config` contains **no** `core.hooksPath` entry:

```
[core]
	repositoryformatversion = 0
	filemode = false
	bare = false
	logallrefupdates = true
	symlinks = false
	ignorecase = true
```

With `core.hooksPath` unset, git uses the default `.git/hooks` directory. The
wrappers there are therefore the active mechanism:

```
-rwxr-xr-x  204 B  .git/hooks/pre-commit
-rwxr-xr-x 1070 B  .husky/pre-commit
```

`.husky/pre-commit` is the versioned source; `.git/hooks/pre-commit` is a
two-line wrapper that `exec`s it. `.husky/_/` is **not** used: husky generates
that directory only when it also sets `core.hooksPath=.husky/_`, which requires
a git config change and is unnecessary here.

Like pi, there is no `pre-push` hook. There are deliberately two formatting
entry points with different policies: `.husky/pre-commit` formats **staged**
files when a human commits, while `scripts/verify-goal.mjs` formats **changed**
files and fails if the formatter mutated them, so goal completion cannot
silently accept a file the formatter rewrote. `verify-goal.mjs` also snapshots
those files after formatting and fails if any changes again while the gate runs.

The gate also self-heals: it hydrates `node_modules` and builds the binary before
testing, and it always builds rather than reusing an existing artifact, so the
binary under test always matches the sources.

Execution proof (no Markdown staged, so the hook's `git add` path cannot fire):

```
=== HOOK EXECUTION (real run) ===
staged_md=''
hook_exit=0
```

If you ever prefer husky's own layout, run `npm run prepare` and the wrappers
become redundant.

---

## 3. Markdown formatting

```
=== PRETTIER ===
3.9.10
Checking formatting...
All matched files use Prettier code style!
```

Config matches pi's behaviour (pi has no prettier config, i.e. defaults):
`printWidth 80`, `proseWrap preserve`, `tabWidth 2`. `.goals/` is excluded
because those are agent artifacts, not repository content.

---

## 4. Regression gate

```
=== VERIFY GATE ===
binary : build/RelWithDebInfo/tmux.exe
scripts: 10

PASS  regress\win32-basic.sh  (25.9s)
PASS  regress\win32-claude-swarm.sh  (50.6s)
PASS  regress\win32-conf-syntax.sh  (34.4s)
PASS  regress\win32-control-client.sh  (14.2s)
PASS  regress\win32-format-strings.sh  (37.5s)
PASS  regress\win32-has-session.sh  (5.9s)
PASS  regress\win32-keys.sh  (51.2s)
PASS  regress\win32-layout.sh  (16.7s)
PASS  regress\win32-output-burst.sh  (9.0s)
PASS  regress\win32-tab-narrow.sh  (7.9s)

RESULT: 10/10 passed
GATE_EXITCODE=0 elapsed=254s
```

The gate runs each script with an isolated `HOME`/`USERPROFILE`, so the
maintainer's `~/.tmux.conf` (`base-index 1`) cannot skew assertions that assume
index 0.

---

## 5. Deployed binary identity

```
=== BINARY IDENTITY ===
3cb60cd86137f07672e240d3c36de736 *build/RelWithDebInfo/tmux.exe
3cb60cd86137f07672e240d3c36de736 *D:/workspace/github/devxpain/dotfiles/bin/tmux.exe

=== RUNNING VERSION ===
tmux 3.6a-win32-patched
```

Identical hashes mean the deployed binary is exactly the symbol-bearing build.

---

## 6. Symbols match the deployed binary

```
=== ARCHIVED PDB ===
-rw-r--r-- 17674240  C:\Users\payne\tools\tmux-symbols\tmux.pdb

=== SYMCHK ===
SYMCHK: FAILED files = 0
SYMCHK: PASSED + IGNORED files = 1
[SYMCHK] PDB Matched:  TRUE
[SYMCHK] Line numbers: TRUE
[SYMCHK] Global syms:  TRUE
```

`MSYS_NO_PATHCONV=1` is required when invoking `symchk` from Git Bash, otherwise
MSYS rewrites `/v` and `/s` into Windows paths and `symchk` prints usage instead
of checking anything.

---

## 7. What this evidence does and does not prove

**Proven here:** toolchain present and runnable, PDB matches the deployed binary,
the 10-script regression suite passes, Markdown formatting is enforced, and the
pre-commit hook executes.

**Root cause identified (this hang):** `tty_draw_line()` in `tty-draw.c`
advances its cell index `i` by `empty` or by `gcp->data.width`, and leaves the
`for (;;)` loop only when `i == nx`. A zero-width cell makes that increment a
no-op, and an increment that overshoots `nx` makes the equality test permanently
false. Either way the loop never terminates. The captured stack proved it:

```
tmux!tty_draw_line+0x41f          [tty-draw.c @ 258]
tmux!screen_redraw_draw_pane+0x202 [screen-redraw.c @ 996]
tmux!screen_redraw_pane+0x79       [screen-redraw.c @ 703]
tmux!server_client_check_redraw+0x3ce [server-client.c @ 3337]
```

A double-width character's trailing half carries `GRID_FLAG_PADDING` and
`data.width == 0`, which is why wide characters trigger it. The redraw path only
runs with a client attached, which is why the output-burst harness never
reproduced it.

Upstream guards this by returning `empty = 1` for padding and zero-width cells.
This fork handles padding through its own `TTY_DRAW_LINE_PAD` state, which skips
the append but not the increment. The fix keeps that state and makes the
increment total: `i >= nx` ends the loop, `gcp = &grid_default_cell` avoids
appending stale data on the final iteration, and a zero width advances by one.
`regress/win32-wide-char-redraw.sh` covers it with a real attached client.

**Still not proven:** whether this is the only such loop. The earlier three fixes
remain hardening rather than this fix - the `input.c` tab guard needs a width of
exactly 0, which tmux rejects, and the `tty.c` guard needs `TERM_NOAM`, which the
builtin terminfo clears.

---

## 8. Platform capability audit (DEV-114)

The Windows port replaces ncurses with the hardcoded `win32_terminfo[]` table in
`win32/win32-terminfo.c`. Any capability missing from that table is missing
everywhere, and tmux reports nothing when a whole feature disappears as a
result.

`kmous` was missing. tmux gates the entire mouse-mode emission block on
`tty_term_has(TTYC_KMOUS)` (`tty.c:388`, `tty.c:510`, `tty.c:941`), so it never
emitted `?1000h/?1002h/?1003h/?1006h` on Windows and no application could
receive mouse events - with `mouse on`, without it, and regardless of config.

Why the gap existed: upstream reads `kmous` from the system terminfo entry.
Here it can only arrive through `tty_features`, and `tty_default_features()` is
reached only from a device-attributes reply that identifies a known terminal
(`tty-keys.c:1565-1642` - `mintty`, `tmux`, `rxvt-unicode`, `iTerm2`, `XTerm`,
`foot`). A plain ConPTY answers secondary DA with a numeric id that hits none of
the `'M'`/`'T'`/`'U'` cases, and extended DA with a product name matching none of
the prefixes, so no features are added.

Two traps worth recording:

1. **A nested-tmux rig cannot observe this.** Attaching a tmux client inside a
   tmux pane makes the outer tmux answer extended DA as `tmux `, which calls
   `tty_default_features("tmux")` and adds `mouse` - on an unfixed build. Any
   assertion made through such a rig is green by artifact.
2. **The capability value is irrelevant.** `tty-keys.c` parses both X10
   (`\033[M`) and SGR (`\033[<`) mouse input by hardcoding them, so `kmous` is
   only ever a presence check. That is why `\033[<` here and the feature
   table's `\E[M` are interchangeable.

`regress/win32-terminfo-caps.sh` now asserts that the table resolves every
capability an entire feature is gated on. It was red on `kmous` alone, and is
green after adding the row.

---

## 9. ConPTY render hardening (DEV-114) - reverted

An earlier iteration gated the erase strategy and the wrapped-line lookup on a
runtime flag, `TERM_CONPTY_NO_PENDING_WRAP`. That flag has been removed. It
conflated two unrelated decisions, and the wrapped-line lookup it disabled is the
context `tty_draw_line_clear()` needs when a band continues across a row
boundary.

What remains in place from this work:

- `win32_terminfo.c` still declares `bce`, and `tty_fake_bce()` still returns 0
  when it is set, so `tty_draw_line_clear()` uses `EL`/`EL1` for blank runs
  exactly as upstream does.
- `b1f7abaa`'s `#ifndef _WIN32` guard around the wrapped-line optimisation is
  restored, so Windows still forces explicit `CUP` positioning between lines.

A real defect found while reverting: `tty_draw_line()` read `last` before it was
initialised. The leading-padding clear called `tty_attributes(tty, &last, ...)`
34 lines before `memcpy(&last, &grid_default_cell, ...)`, so undefined stack
contents were applied as cell attributes, background included. The padding path
now initialises `last` first, and inherits the neighbouring wide glyph's
attributes when one exists.

`regress/win32-tui-render.sh` covers four properties: the band repaint (the
client's rendered band must match the inner server's grid, text only), cell
fidelity (a corpus of styled rows must return verbatim from `capture-pane -p`,
including wide characters, and overwriting a row must leave no glyph from the
previous frame), wide characters carrying a specific background, and background
extent across a five-row band where every row is asserted for full pane width
and for the background attribute.
