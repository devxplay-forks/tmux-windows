#!/bin/sh

# Windows: render fidelity for boxed TUIs.
#
# DEV-114 reported render damage in boxed TUIs: ghost glyphs surviving beneath a
# repainted background, duplicated chrome rows, and damaged text cells. This test
# covers four properties.
#
# 1. Band repaint. A coloured band repainted with a different background by
#    erasing it must not leave traces of the previous frame. Only the band rows
#    are compared, because the outer pane also shows the inner tmux's status line
#    and the two screens need not be the same height.
#
# 2. Cell fidelity. Text an application writes must come back out of the grid
#    verbatim, and no cell may retain a glyph from a previous frame. This is
#    asserted against an independently written expected string rather than by
#    comparing two tmux layers: a comparison with tmux on both sides can only
#    detect a difference between the layers, not damage present in both.
#
# 3. Wide characters with a background. Wide characters in a narrow pane must
#    keep their glyphs and their background. This exercises wide-character
#    rendering and the attributes used when clearing cells. It does NOT force a
#    leading padding cell: `cx != 0` in tty_draw_line needs a wide character
#    clipped off-screen to the left (horizontal panning or an overlay), not a
#    wrap - tmux moves a wide character that does not fit entirely to the next
#    row, so wrapping cannot produce leading padding.
#
# 4. Background extent across a band. A coloured block that should be one
#    continuous region must not lose its background part-way through, and its
#    rows must span the full pane width. Every row of a five-row band is asserted
#    independently for width and background, so one good row cannot satisfy it.
#
# Known limit: a leading padding cell (`cx != 0` in tty_draw_line) is not
# reachable here. It needs a wide character clipped off-screen to the left -
# horizontal panning or an overlay - and `display-popup` blocks indefinitely with
# no client attached. Wrapping cannot produce it.
#
# Transport note: the pane console starts in the system code page, so `type`
# re-encodes UTF-8 and `send-keys` mangles it. Prefixing with
# `cmd /c chcp 65001 >nul &` switches that console to UTF-8 first, which is the
# only form that preserves non-ASCII here. Do not wrap the whole thing in an
# extra pair of quotes - that routes through a different code path and mangles.
#
# Must be run on Windows (Git Bash or similar).

PATH=/bin:/usr/bin
# The tmux regress convention resets PATH for determinism, but panes inherit the
# server's environment. Without System32 on PATH the pane shell cannot find
# cmd.exe at all, so the frame never gets emitted.
PATH="$PATH:$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32"

BAND_ROWS=3

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Lrender"
TMUX2="$TEST_TMUX -Lrender2"
$TMUX kill-server 2>/dev/null
$TMUX2 kill-server 2>/dev/null
sleep 1

OUT=$(mktemp -d)
trap "rm -rf $OUT; $TMUX kill-server 2>/dev/null; $TMUX2 kill-server 2>/dev/null" 0 1 15

BOX_U="$OUT/box.ans"
BOX_W=$(cygpath -w "$BOX_U")

# Frame 1 paints a blue background with a band on row 1. Frame 2 repaints only
# row 1 with a different background by erasing it - the case that leaves traces
# when the terminal's erase colour cannot be trusted. The marker sits on row 3,
# a row that is never erased, so it proves the frame really rendered and stops
# the comparison from passing on two blank screens.
{
	printf '\033[2J\033[H\033[44m'
	printf 'BANDROW-ONE-TO-BE-ERASED..................\r\n'
	printf '\r\n'
	printf 'BANDMARKER-KEEPS-ROW-THREE................\r\n'
	printf '\033[0m\033[1;1H\033[41m\033[0K'
	printf '\033[24;1H'
} > "$BOX_U"

$TMUX2 -fNUL new-session -d -smain -x 80 -y 24 < /dev/null || {
	echo "FAIL(setup): could not create the render session"
	exit 1
}
sleep 1

$TMUX2 send-keys -tmain "cmd /c type \"$BOX_W\"" Enter || {
	echo "FAIL(setup): could not send the frame"
	exit 1
}
sleep 2

# A real client is required: without one tmux never renders.
$TMUX -fNUL new-session -d -scli -x 80 -y 24 "$TMUX2 attach" < /dev/null || {
	echo "FAIL(setup): could not attach a client"
	exit 1
}
sleep 3

$TMUX2 capture-pane -p -tmain | head -$BAND_ROWS > "$OUT/inner.txt" 2>&1
$TMUX capture-pane -p -tcli | head -$BAND_ROWS > "$OUT/outer.txt" 2>&1

if ! grep -q 'BANDMARKER-KEEPS-ROW-THREE' "$OUT/inner.txt"; then
	echo "FAIL(setup): the synthetic frame did not render"
	cat -v "$OUT/inner.txt"
	exit 1
fi

# Note: `capture-pane -p` strips SGR, so this phase compares text only. It can
# detect emitter-side divergence between the two layers, but not a background
# defect shared by both. Background is not asserted in this phase; the header
# states what this test does and does not cover.
if ! cmp -s "$OUT/inner.txt" "$OUT/outer.txt"; then
	echo "FAIL(render): the client rendered the band differently than tmux drew it"
	echo '--- inner (tmux grid) ---'
	cat -v "$OUT/inner.txt"
	echo '--- outer (client) ---'
	cat -v "$OUT/outer.txt"
	exit 1
fi

# --- Phase 2: cell fidelity -------------------------------------------------
FIDELITY_U="$OUT/fidelity.ans"
FIDELITY_W=$(cygpath -w "$FIDELITY_U")
FULL_ROW=$(printf 'X%.0s' $(seq 1 80))
# The literal string observed damaged in the field.
DAMAGED_ROW="awk 'NR>=55 { has=(\$0 ~ /x/ ) ? \"BG\" : \"'"
WIDE_ROW='漢字 wide'

{
	printf '\033[2J\033[H'
	printf '\033[38;5;1malpha\033[39m\033[48;5;2mbravo\033[49m charlie\r\n'
	printf '%s\r\n' "$FULL_ROW"
	printf '%s\r\n' "$DAMAGED_ROW"
	printf '%s\r\n' "$WIDE_ROW"
} > "$FIDELITY_U"

$TMUX2 send-keys -tmain "cmd /c chcp 65001 >nul & type \"$FIDELITY_W\"" Enter || {
	echo "FAIL(setup): could not send the fidelity corpus"
	exit 1
}
sleep 3

$TMUX2 capture-pane -p -tmain | head -4 > "$OUT/fidelity.txt" 2>&1

fidelity_fail=0
expect_row() {
	row="$1"
	want="$2"
	got=$(sed -n "${row}p" "$OUT/fidelity.txt" | sed 's/[[:space:]]*$//')
	if [ "$got" != "$want" ]; then
		echo "FAIL(fidelity): row $row was not preserved verbatim"
		echo "  want: [$want]"
		echo "  got : [$got]"
		fidelity_fail=1
	fi
}

expect_row 1 'alphabravo charlie'
expect_row 2 "$FULL_ROW"
expect_row 3 "$DAMAGED_ROW"
expect_row 4 "$WIDE_ROW"

if [ "$fidelity_fail" -ne 0 ]; then
	echo "FAIL(fidelity): cell content was damaged in transit"
	exit 1
fi
# Stale-glyph check: overwrite row 1 with shorter content. No cell from the
# previous frame may survive past the new text.
STALE_U="$OUT/stale.ans"
STALE_W=$(cygpath -w "$STALE_U")
printf '\033[1;1H\033[0mZZ\033[K' > "$STALE_U"
$TMUX2 send-keys -tmain "cmd /c type \"$STALE_W\"" Enter || {
	echo "FAIL(setup): could not send the stale-cell probe"
	exit 1
}
sleep 2

stale_row=$($TMUX2 capture-pane -p -tmain | sed -n '1p' | sed 's/[[:space:]]*$//')
if [ "$stale_row" != "ZZ" ]; then
	echo "FAIL(stale): row 1 kept content from the previous frame: [$stale_row]"
	exit 1
fi

# --- Phase 3: wide characters with a background in a narrow pane -------------
# Exercises wide-character rendering plus the attributes applied when cells are
# cleared. Note the correction above: leading padding comes from clipping, not
# wrapping, so this phase does not claim to reach that path.
PAD_U="$OUT/pad.ans"
PAD_W=$(cygpath -w "$PAD_U")
printf '\033[2J\033[H\033[48;5;2m漢字漢字漢字漢字漢字漢字漢字漢字漢字漢字漢\033[0m\r\n' > "$PAD_U"

$TMUX2 -fNUL new-session -d -spad -x 21 -y 6 < /dev/null || {
	echo "FAIL(setup): could not create the narrow session"
	exit 1
}
sleep 1
$TMUX2 send-keys -tpad "cmd /c chcp 65001 >nul & type \"$PAD_W\"" Enter || {
	echo "FAIL(setup): could not send the padding probe"
	exit 1
}
sleep 3

$TMUX2 capture-pane -p -tpad | head -4 > "$OUT/pad-plain.txt" 2>&1
$TMUX2 capture-pane -p -e -tpad | head -4 > "$OUT/pad.txt" 2>&1
pad_hits=$(grep -o '漢' "$OUT/pad-plain.txt" | wc -l)
if [ "$pad_hits" -lt 1 ]; then
	echo "FAIL(fidelity): wide characters were lost in a narrow pane (got $pad_hits)"
	cat -v "$OUT/pad.txt"
	exit 1
fi
# Assert the wide-character row carries the band background. This guards that a
# wide-character run keeps its background. It does not reach the leading-padding
# clear path, so it does not exercise the `last` initialisation fix.
#
# Known limit: this transport runs `type` as a pwsh background job (the `&` in
# `chcp ... & type`), so its output interleaves non-deterministically with the
# prompt redraw. Combined with the clipping requirement above, a specific
# leading-padding cell is not reachable deterministically here. This therefore
# asserts glyph survival and the background attribute on the wide-character row.
row1e=$(sed -n '1p' "$OUT/pad.txt" | cat -v)
case "$row1e" in
*'^[[48;5;2m'*|*'^[[42m'*) ;;
*)
	echo "FAIL(fidelity): the wide-character row lost its 48;5;2 background"
	echo "  row 1: [$row1e]"
	exit 1
	;;
esac

# --- Phase 4: background extent across a band --------------------------------
# DEV-114's reported symptom is a coloured block that should be one continuous
# region but loses its background part-way through. Paint a five-row band with a
# single background and assert EVERY row carries it. Per-row presence cannot be
# satisfied by one good row, so a band that stops being green fails here.
BAND4_U="$OUT/band4.ans"
BAND4_W=$(cygpath -w "$BAND4_U")
{
	printf '\033[2J\033[H\033[48;5;2m'
	i=1
	while [ "$i" -le 5 ]; do
		printf '%s\r\n' "$FULL_ROW"
		i=$((i + 1))
	done
	printf '\033[0m'
} > "$BAND4_U"

$TMUX2 -fNUL new-session -d -sband4 -x 80 -y 12 < /dev/null || {
	echo "FAIL(setup): could not create the band-extent session"
	exit 1
}
sleep 1
$TMUX2 send-keys -tband4 "cmd /c chcp 65001 >nul & type \"$BAND4_W\"" Enter || {
	echo "FAIL(setup): could not send the band-extent probe"
	exit 1
}
sleep 3

$TMUX2 capture-pane -p -tband4 | head -5 > "$OUT/band4-plain.txt" 2>&1
$TMUX2 capture-pane -p -e -tband4 | head -5 > "$OUT/band4.txt" 2>&1
band_bad=""
# `capture-pane -e` emits attributes only when they change, so a correct band
# establishes the background once on row 1 and carries it across the following
# lines. Assert exactly that: row 1 establishes it, no row resets it, and every
# row spans the full pane width. A band that stops being green fails here, while
# a correct band is not penalised for not repeating the sequence.
case "$(sed -n '1p' "$OUT/band4.txt" | cat -v)" in
*'^[[48;5;2m'*|*'^[[42m'*) ;;
*) band_bad="row 1 does not establish the background" ;;
esac

r=1
while [ "$r" -le 5 ]; do
	plain=$(sed -n "${r}p" "$OUT/band4-plain.txt")
	len=${#plain}
	line=$(sed -n "${r}p" "$OUT/band4.txt" | cat -v)
	if [ "$len" -ne 80 ]; then
		band_bad="row $r spans $len of 80 columns"
	fi
	case "$line" in
	*'^[[49m'*|*'^[[0m'*|*'^[[m'*)
		band_bad="row $r resets to the default background"
		;;
	esac
	r=$((r + 1))
done
if [ -n "$band_bad" ]; then
	echo "FAIL(extent): $band_bad"
	cat -v "$OUT/band4.txt"
	exit 1
fi

$TMUX kill-server 2>/dev/null
$TMUX2 kill-server 2>/dev/null
sleep 1

exit 0
