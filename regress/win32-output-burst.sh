#!/bin/sh

# Windows: a large, hyperlink-dense output burst must not wedge the server.
#
# Regression guard for the observed failure mode: after a burst of pane output
# (e.g. several concurrent web-content fetches rendered by a TUI) the tmux
# server sat at ~100% of one core in user mode and every later client hung
# forever waiting for an imsg reply.
#
# The real signature was NOT a crash and NOT memory growth (18.5 MB working
# set during the live hang). It was:
#   - server still ALIVE
#   - server burning ~100% of one core in user mode
#   - `tmux ls` never returning (client blocked on an imsg reply)
#
# Design note: the pane runs its normal default shell, which stays alive on
# its own, and the burst is injected with send-keys. This deliberately avoids
# -f/remain-on-exit, because a native tmux.exe cannot open an MSYS config path
# and a bare start-server exits immediately when no sessions exist.
#
# Must be run on Windows (Git Bash or similar).

PATH=/bin:/usr/bin
TERM=screen

RESPONSE_LIMIT=10
BURST_LINES=600

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Lburst"
$TMUX kill-server 2>/dev/null
sleep 1

OUT=$(mktemp)
PAYLOAD=$(mktemp)
trap "rm -f $OUT $PAYLOAD; $TMUX kill-server 2>/dev/null" 0 1 15

# On Windows, -f/dev/null doesn't work (native exe can't open a Unix path).
FNULL="-fNUL"

# ---------------------------------------------------------------------------
# 1. Build a burst payload that mimics rendered web content:
#    OSC-8 hyperlinks, tab stops, SGR colour changes and long lines.
# ---------------------------------------------------------------------------
i=0
: > "$PAYLOAD"
while [ $i -lt $BURST_LINES ]; do
	printf '\033]8;;https://example.invalid/%d\033\\link-%d\033]8;;\033\\\tA\tB\tC \033[1;31mred\033[0m %s\r\n' \
	    "$i" "$i" "0123456789012345678901234567890123456789012345678901234567890123456789" \
	    >> "$PAYLOAD"
	i=$((i + 1))
done

if [ ! -s "$PAYLOAD" ]; then
	echo "FAIL(setup): could not build burst payload"
	exit 1
fi

# ---------------------------------------------------------------------------
# 2. Start a session whose pane runs the default shell and stays alive.
# ---------------------------------------------------------------------------
$TMUX $FNULL new-session -d -sburst -x 120 -y 40 < /dev/null || {
	echo "FAIL(setup): could not create burst session"
	exit 1
}
sleep 3

COUNT=$($TMUX list-panes -tburst 2>/dev/null | wc -l)
[ "$COUNT" -eq 1 ] || {
	echo "FAIL(setup): pane did not start (got $COUNT)"
	exit 1
}

# ---------------------------------------------------------------------------
# 3. Inject the burst into the live pane. The pane survives the command
#    because the shell keeps running, so later unresponsiveness is the server.
# ---------------------------------------------------------------------------
WINPAYLOAD=$(cygpath -w "$PAYLOAD" 2>/dev/null)
[ -z "$WINPAYLOAD" ] && WINPAYLOAD="$PAYLOAD"

$TMUX send-keys -tburst "type $WINPAYLOAD" Enter || {
	echo "FAIL(setup): could not send burst command"
	exit 1
}
sleep 2

# ---------------------------------------------------------------------------
# 4. Measure responsiveness. A wedged main event loop never services the
#    client, so this blocks until the timeout fires.
# ---------------------------------------------------------------------------
START=$(date +%s)
if ! timeout $RESPONSE_LIMIT $TMUX ls >"$OUT" 2>&1; then
	ELAPSED=$(( $(date +%s) - START ))
	tr -d '\r' < "$OUT" > "$OUT.clean"
	if grep -qi 'no server running' "$OUT.clean"; then
		echo "FAIL(setup): server exited during burst"
	else
		echo "FAIL(wedge): server ALIVE but unresponsive after ${ELAPSED}s"
		echo "---- tmux ls output ----"
		cat "$OUT.clean"
		echo "------------------------"
	fi
	rm -f "$OUT.clean"
	exit 1
fi
rm -f "$OUT.clean"

# ---------------------------------------------------------------------------
# 5. The session must still be listed.
# ---------------------------------------------------------------------------
tr -d '\r' < "$OUT" | grep -q 'burst' || {
	echo "FAIL(wedge): burst session missing from tmux ls"
	exit 1
}

# ---------------------------------------------------------------------------
# 6. A second command must also still work (proves the loop kept servicing).
# ---------------------------------------------------------------------------
if ! timeout $RESPONSE_LIMIT $TMUX list-windows -tburst >"$OUT" 2>&1; then
	echo "FAIL(wedge): server stopped servicing commands after burst"
	exit 1
fi

# ---------------------------------------------------------------------------
# 7. The pane must still be alive and able to accept input.
# ---------------------------------------------------------------------------
COUNT=$($TMUX list-panes -tburst 2>/dev/null | wc -l)
[ "$COUNT" -eq 1 ] || {
	echo "FAIL(wedge): expected 1 pane after burst, got $COUNT"
	exit 1
}

$TMUX kill-server 2>/dev/null
sleep 1

exit 0
