/*
 * Assert that the hardcoded Windows terminfo substitute can resolve every
 * capability that an entire feature is gated on.
 *
 * See regress/win32-terminfo-caps.sh for why this exists.
 */

#include <stdio.h>
#include <stdlib.h>

#include "win32-platform.h"

static int failures;

static void
require(const char *name, const char *why)
{
	if (win32_terminfo_find(name) == NULL) {
		printf("FAIL: capability '%s' missing (%s)\n", name, why);
		failures++;
	} else
		printf("ok: %s\n", name);
}

int
main(void)
{
	/* Mouse mode emission is gated on this (tty.c:941). */
	require("kmous", "mouse mode is never emitted without it");

	/* Hard requirements - tty_term_create refuses the terminal without these. */
	require("clear", "terminal is rejected");
	require("cup", "terminal is rejected");

	/* Erase strategies used when repainting a band. */
	require("el", "cannot erase to end of line");
	require("ech", "cannot erase characters in place");

	/* Alternate screen, used by every full-screen TUI. */
	require("smcup", "cannot enter the alternate screen");
	require("rmcup", "cannot leave the alternate screen");

	if (failures != 0) {
		printf("\n%d capability assertion(s) failed\n", failures);
		return (1);
	}
	printf("\nall capabilities resolved\n");
	return (0);
}
