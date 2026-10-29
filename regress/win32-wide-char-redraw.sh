#!/bin/sh

# Windows: redrawing a pane full of double-width characters must not wedge the
# server.
#
# Guards the draw loop in tty-draw.c (tty_draw_line). That loop advances `i` by
# `empty` or by `gcp->data.width`, and terminates only when `i == nx`.
#
# Two defects let it run forever in pure user mode with no allocation growth,
# which is the silent 100% CPU spin this script watches for:
#
#  1. A zero-width cell. The trailing half of a double-width character carries
#     GRID_FLAG_PADDING and data.width == 0, so `i += gcp->data.width` is a
#     no-op and `i` never reaches nx.
#  2. An increment that overshoots nx. When the background differs from the
#     previous cell, empty is forced to 0 and the full width is added even if
#     only one column remains, so `i` jumps past nx and the equality test is
#     permanently false.
#
# Upstream tmux guards both by treating padding and zero-width cells as empty
# (empty = 1, so i always advances). This fork handles padding through its own
# TTY_DRAW_LINE_PAD state instead, which skipped the append but not the
# increment. The fix keeps that state and makes the increment total: `i >= nx`
# ends the loop, and a zero width advances by one.
#
# A real client must be attached - without one tmux never renders and
# tty_draw_line never runs. The nested `attach` below supplies that client.
#
# Must be run on Windows (Git Bash or similar).

PATH=/bin:/usr/bin
TERM=screen

RESPONSE_LIMIT=10

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Lwide"
TMUX2="$TEST_TMUX -Lwide2"
$TMUX kill-server 2>/dev/null
$TMUX2 kill-server 2>/dev/null
sleep 1

OUT=$(mktemp)
trap "rm -f $OUT; $TMUX kill-server 2>/dev/null; $TMUX2 kill-server 2>/dev/null" 0 1 15

FNULL="-fNUL"

# Odd width so a double-width character cannot align to the right edge and the
# last one must straddle the boundary.
$TMUX2 $FNULL new-session -d -smain -x 21 -y 5 < /dev/null || {
	echo "FAIL(setup): could not create session"
	exit 1
}
sleep 1

# Fill the line with double-width characters so one straddles the last column.
$TMUX2 send-keys -t main "漢字日本語漢字日本語漢字日本語" Enter || {
	echo "FAIL(setup): could not send wide characters"
	exit 1
}
sleep 1

# Attach a real client: tty_draw_line only runs when something is attached.
$TMUX $FNULL new-session -d -scli -x 21 -y 5 "$TMUX2 attach" || {
	echo "FAIL(setup): could not attach client"
	exit 1
}
sleep 2

# Walk through odd widths to move the straddling character across the edge and
# force repeated full redraws.
for W in 23 25 27 29 19 17 15 21; do
	$TMUX2 resize-window -t main -x $W -y 5 >/dev/null 2>&1
	sleep 1
done

# The server must still service commands. A spin never returns to the loop.
if ! timeout $RESPONSE_LIMIT $TMUX2 ls >"$OUT" 2>&1; then
	echo "FAIL(wedge): server unresponsive after wide-character redraw"
	tr -d '\r' < "$OUT"
	exit 1
fi

tr -d '\r' < "$OUT" > "$OUT.clean"
if grep -qi 'no server running' "$OUT.clean"; then
	echo "FAIL(setup): server exited during wide-character test"
	rm -f "$OUT.clean"
	exit 1
fi

grep -q 'main' "$OUT.clean" || {
	echo "FAIL(wedge): session main missing after wide-character test"
	rm -f "$OUT.clean"
	exit 1
}
rm -f "$OUT.clean"

$TMUX kill-server 2>/dev/null
$TMUX2 kill-server 2>/dev/null
sleep 1

exit 0
