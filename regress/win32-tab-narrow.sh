#!/bin/sh

# Windows: tabs in a very narrow pane must not wedge the server.
#
# Guards the tab-stop loop in input.c (case '\011'). Both the early-exit guard
# and the do/while bound are written as `screen_size_x(s) - 1`, where
# screen_size_x(s) is an unsigned u_int. If the width is 0 that subtraction
# underflows to UINT_MAX, the guard fails to trigger, and the loop can run
# billions of iterations in pure user mode with no allocation growth - i.e. a
# silent 100% CPU spin that never returns to the event loop.
#
# The fix adds `if (screen_size_x(s) < 2) break;`. This script asserts the
# observable consequence: the server keeps answering after tabs are emitted.
#
# Must be run on Windows (Git Bash or similar).

PATH=/bin:/usr/bin
TERM=screen

RESPONSE_LIMIT=10

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltab"
$TMUX kill-server 2>/dev/null
sleep 1

OUT=$(mktemp)
trap "rm -f $OUT; $TMUX kill-server 2>/dev/null" 0 1 15

FNULL="-fNUL"

# Very narrow panes maximise the chance of hitting the degenerate width.
for W in 1 2 3; do
	$TMUX $FNULL new-session -d -s"n$W" -x $W -y 5 < /dev/null || {
		echo "FAIL(setup): could not create session at width $W"
		exit 1
	}
done
sleep 2

# Emit real tab characters plus text so the tab-stop loop actually runs.
TAB=$(printf '\t')
for W in 1 2 3; do
	$TMUX send-keys -t"n$W" "a${TAB}b${TAB}c" Enter || {
		echo "FAIL(setup): could not send tabs to width $W"
		exit 1
	}
done
sleep 2

# The server must still service commands. A spin never returns to the loop.
if ! timeout $RESPONSE_LIMIT $TMUX ls >"$OUT" 2>&1; then
	echo "FAIL(wedge): server unresponsive after tabs in narrow panes"
	tr -d '\r' < "$OUT"
	exit 1
fi

tr -d '\r' < "$OUT" > "$OUT.clean"
if grep -qi 'no server running' "$OUT.clean"; then
	echo "FAIL(setup): server exited during tab test"
	rm -f "$OUT.clean"
	exit 1
fi

for W in 1 2 3; do
	grep -q "n$W" "$OUT.clean" || {
		echo "FAIL(wedge): session n$W missing after tab test"
		rm -f "$OUT.clean"
		exit 1
	}
done
rm -f "$OUT.clean"

# A second command proves the loop kept servicing requests.
if ! timeout $RESPONSE_LIMIT $TMUX list-windows -tn1 >"$OUT" 2>&1; then
	echo "FAIL(wedge): server stopped servicing commands after tab test"
	exit 1
fi

$TMUX kill-server 2>/dev/null
sleep 1

exit 0
