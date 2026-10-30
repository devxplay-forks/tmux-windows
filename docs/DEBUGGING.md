# Debugging tmux-windows

How to capture a stack from a hung or spinning `tmux.exe` server.

This exists because a live hang was once diagnosed only as far as "one thread
burns ~100% of a core in user mode" — the exact function was never identified,
because no debugger was installed and the memory dump attempt timed out.
Everything below is the setup that prevents a repeat of that.

## Toolchain

| Tool                    | Path                                                    |
| ----------------------- | ------------------------------------------------------- |
| `cdb.exe`, `symchk.exe` | `C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\` |
| ProcDump v12.02         | `C:\Users\payne\tools\procdump\procdump64.exe`          |
| Archived symbols        | `C:\Users\payne\tools\tmux-symbols\tmux.pdb`            |

`cdb` comes from the Windows SDK Debugging Tools component. Installing the SDK
without selecting that component leaves `Windows Kits\10\Debuggers\` missing —
check for `cdb.exe` before assuming the SDK install was sufficient.

## Build with symbols

The build uses the Visual Studio 17 2022 generator, which is multi-config, so
`RelWithDebInfo` needs no `CMakeLists.txt` change. It compiles with the same
`/O2` optimisation as `Release`, plus `/Zi`, so behaviour is unchanged while a
matching `.pdb` is produced.

Use the VS-bundled CMake by absolute path — it is not on `PATH` in a plain SSH
shell:

```sh
CM="/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe"
"$CM" --build build --config RelWithDebInfo
```

Outputs:

- `build/RelWithDebInfo/tmux.exe`
- `build/RelWithDebInfo/tmux.pdb`

**Do not use a `Debug` build to investigate timing-sensitive hangs.** `/Od` plus
`_DEBUG` changes code layout and timing, and asserts can abort where release
code would spin, so the bug may stop reproducing. `RelWithDebInfo` is the
correct choice.

## Logging volume

A symbol-enabled build does **not** log more than a stock one. `log_debug()` is
compiled into every build and gated at runtime by `log_get_level()`; the server
opens a log file only when started with `-v`. Without `-v`, `tty_log_fd` stays
`-1` and nothing is written.

The real hazard is `-v` combined with a large output burst, which produces an
enormous log in **any** build type. Keep `-v` off by default and enable it only
for a targeted reproduction.

## Verify the PDB matches the binary

A mismatched PDB silently produces wrong frames. Confirm before trusting a stack.

```sh
MSYS_NO_PATHCONV=1 "/c/Program Files (x86)/Windows Kits/10/Debuggers/x64/symchk.exe" \
  /v "C:\path\to\build\RelWithDebInfo\tmux.exe" \
  /s "C:\path\to\build\RelWithDebInfo"
```

Expect `PDB Matched: TRUE`, `Line numbers: TRUE`, `Global syms: TRUE`, and
`FAILED files = 0`.

`MSYS_NO_PATHCONV=1` is required: without it MSYS rewrites `/v` and `/s` into
Windows paths before `symchk` sees them, and it prints usage instead of running.

## Capture the spinning thread

Run this **before** killing the hung server — the stack is the only evidence that
identifies the loop.

```powershell
pwsh -File scripts/cdb-attach.ps1
```

Or manually:

```powershell
cdb -y C:\Users\payne\tools\tmux-symbols -p <SERVER_PID> ^
    -c "~*k 200; .detach" -logo $env:TEMP\tmux_spin.log
```

Find the server PID first (the one with `-D -S`):

```powershell
Get-CimInstance Win32_Process -Filter "Name='tmux.exe'" |
    Select-Object ProcessId, CommandLine
```

`.detach` leaves the process running, so the hang can still be studied after the
stack is captured.

## Fallback: dump the process

If `cdb` cannot attach, capture a dump and analyse it later:

```powershell
C:\Users\payne\tools\procdump\procdump64.exe -accepteula -ma <SERVER_PID> $env:TEMP\tmux.dmp
```

`rundll32 comsvcs.dll, MiniDump` was tried against a spinning server and timed
out after 120 seconds, so prefer ProcDump.

## Reading the output

Useful commands once attached:

| Command              | Purpose                                 |
| -------------------- | --------------------------------------- |
| `~*k`                | stacks for every thread                 |
| `!analyze -hang`     | automatic hang triage                   |
| `lm m tmux`          | confirm symbols loaded (not `deferred`) |
| `x tmux!input_parse` | check a symbol resolves                 |

A spinning server shows one thread `Running` with high user-mode CPU and every
other thread in `Wait`. Compare user versus privileged time to distinguish an
application loop from a syscall loop: mostly user time means tmux's own code.

## Capability gaps

When one feature dies wholesale - mouse, clipboard, hyperlinks - suspect a
missing terminfo capability rather than the feature's own logic. tmux gates
entire emission blocks on `tty_term_has()`, so an absent capability fails
silently and no configuration option can compensate.

Enumerate what the Windows port actually resolved, without needing a display:

```sh
tmux -Lprobe -fNUL new -d -sx -x 80 -y 24 </dev/null
tmux -Lprobe list-clients -F '#{client_termname} => #{client_termfeatures}'
```

`#{client_termfeatures}` reports the resolved feature bitmask. For the raw
capability set, start the server with `-vvv` and read the `tmux-*.log` dump
written by `tty_term_create`; an absent capability appears as `[missing]`.

Do **not** validate these through a tmux-inside-tmux rig. The outer tmux answers
extended device attributes as `tmux `, which silently enables the `mouse`
feature set, so such a check passes even on a build with no `kmous`. See
`verification-evidence.md` section 8.

## Regression gate

```sh
node scripts/verify-goal.mjs
```

Runs every `regress/win32-*.sh` against the symbol-bearing build with an isolated
`HOME`, so the maintainer's `~/.tmux.conf` cannot skew assertions. This is also
wired into `.pi/settings.json` so `goal_complete` cannot pass on a broken suite.
Markdown formatting is handled by `verify-goal.mjs`, which formats the changed
files and then **fails** if the formatter rewrote any of them, printing the diff
so the change gets reviewed. It also snapshots those files before running the
suite, and fails if any changes again while the tests run - that catches a
concurrent formatter or a test that rewrites tracked content. The pre-commit
hook is the separate, staged-only path used when a human commits.

The gate self-heals a fresh checkout, like pi's `test.sh`. If `node_modules` is
missing it runs `npm install --ignore-scripts`; if `build/` is unconfigured it
configures and then builds. The build runs on **every** invocation rather than
only when the binary is absent, because a leftover binary from an earlier
configuration would otherwise be tested instead of the current sources. Set
`PI_VERIFY_SKIP_SETUP=1` to skip both steps when you know they are current.
