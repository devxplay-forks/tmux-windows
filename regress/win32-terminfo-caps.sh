#!/bin/sh

# Windows: the hardcoded terminfo substitute must resolve every capability that
# an entire feature is gated on.
#
# tmux gates the whole mouse-mode emission block on
# tty_term_has(TTYC_KMOUS) (tty.c:941). When "kmous" cannot be resolved, tmux
# never emits ?1000h/?1006h, so the wheel and drag die everywhere downstream -
# with no error, nothing in the log, and no way for `mouse on` to help. That is
# a silent total feature loss, so it needs a standing assertion.
#
# Why it can vanish here but not upstream: upstream reads "kmous" from the
# system terminfo entry for xterm-256color. The Windows port replaces ncurses
# with win32_terminfo[], so a capability missing from that table is missing
# everywhere - unless a client's device-attributes reply happens to identify a
# known terminal, in which case tty_default_features() adds it
# (tty-keys.c:1565-1642). Depending on that is the bug: a plain ConPTY answers
# secondary DA with a numeric id (hitting none of the 'M'/'T'/'U' cases) and
# extended DA with a product name matching neither tmux, XTerm, mintty, iTerm2
# nor foot, so no features are added.
#
# Note: "kmous" is only ever a presence check. tty-keys.c parses both X10
# (\033[M) and SGR (\033[<) mouse input by hardcoding them, so the capability's
# value is irrelevant - hence this test asserts presence, not content.
#
# Must be run on Windows (Git Bash or similar).

PATH=/bin:/usr/bin
# The tmux regress convention resets PATH for determinism, but this test needs
# the MSVC toolchain, so cmd.exe from System32 has to be reachable again.
PATH="$PATH:$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32"

OUT=$(mktemp -d)
trap "rm -rf $OUT" 0 1 15

VCVARS='C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat'

if [ ! -f "$VCVARS" ]; then
	echo "FAIL(setup): vcvarsall.bat not found at $VCVARS"
	exit 1
fi

# Resolve the repo root from this script's location, not the caller's cwd:
# the suite may be invoked from the repo root or from regress/ itself.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

REPO_W=$(cygpath -w "$ROOT")
SRC_W=$(cygpath -w "$ROOT/regress/win32-terminfo-caps.c")
TI_W=$(cygpath -w "$ROOT/win32/win32-terminfo.c")
OUT_W=$(cygpath -w "$OUT")

cat > "$OUT/build.bat" <<EOF
@echo off
call "$VCVARS" x64 >nul 2>&1 || exit /b 1
cd /d "$OUT_W" || exit /b 1
cl /nologo /W3 /I"$REPO_W" /I"$REPO_W\\win32" "$SRC_W" "$TI_W" || exit /b 1
EOF

if ! cmd.exe //c "$OUT_W\\build.bat" > "$OUT/build.log" 2>&1; then
	echo "FAIL(setup): could not compile the capability test"
	cat "$OUT/build.log"
	exit 1
fi

# cl names the output after the first source file.
"$OUT/win32-terminfo-caps.exe"
if [ $? -ne 0 ]; then
	echo "FAIL(capability): win32_terminfo[] is incomplete"
	exit 1
fi

exit 0
