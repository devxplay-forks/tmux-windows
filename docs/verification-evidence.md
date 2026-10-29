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

**Not proven:** the identity of the loop that caused the original 100% CPU spin.
Reproduction has not succeeded - a synthetic output burst alone does not trigger
it, most likely because no client is attached and therefore tmux never renders.

**The three source fixes are hardening, not a proven fix for that hang.** Two of
them guard states tmux cannot actually reach. The `input.c` tab guard needs a
screen width of exactly 0, which tmux rejects (`new -x 0` fails with "width too
small") and `resize-pane` clamps to 1; at width 1 the original `cx >= sx - 1`
check was already true, so the old code was safe. The `tty.c` guard needs
`TERM_NOAM`, which the builtin terminfo clears because it sets `am`. The
`win32-ipc.c` deadline is reachable in principle, but the discovery pipe is never
busy in practice (it connects in about 11 ms), so it is not this hang either.
See `DEBUGGING.md` for how to capture the stack when it recurs.
