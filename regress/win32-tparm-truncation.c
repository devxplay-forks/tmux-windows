/*
 * DEV-111 regression test: tparm() string parameter width.
 *
 * tparm() reads all nine varargs as intptr_t (64-bit on Win64).  A caller that
 * passes a const char * through a 32-bit long truncates the pointer, and the
 * %s branch then dereferences a zero-extended bogus address -> access
 * violation that kills the server on OSC-8 hyperlinks (TTYC_HLS).
 *
 * This test links the real win32/win32-compat.c and exercises the %s branch
 * with a correctly-widthed pointer, then verifies the source-level call sites
 * in tty-term.c agree with the callee.
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* Provided by win32/win32-compat.c */
extern char *tparm(const char *str, ...);

/*
 * Stub: win32-compat.c references this from win32_kill(), which this test
 * never exercises.  Keeps the test linkable without win32-signal.c.
 */
void
win32_signal_notify(int signo)
{
	(void)signo;
}

static int failures = 0;

static void
check(int cond, const char *what)
{
	if (cond)
		printf("PASS: %s\n", what);
	else {
		printf("FAIL: %s\n", what);
		failures++;
	}
}

int
main(void)
{
	const char	*id = "id1";
	const char	*uri = "https://example.com/a/b";
	char		*out;
	FILE		*fp;
	char		 line[512];
	int		 saw_s = 0, saw_ss = 0, bad_long = 0;

	/*
	 * 0. Document the ABI fact that causes DEV-111: on Win64 `long` is
	 *    32-bit while pointers are 64-bit, so any pointer routed through a
	 *    `long` loses its high half (MSVC C4311 at tty-term.c:908,928).
	 *    intptr_t exists precisely so caller and callee can agree.
	 */
	check(sizeof(long) == 4,
	    "Win64 `long` is 32-bit (pointer through it would truncate)");
	check(sizeof(intptr_t) == sizeof(void *),
	    "intptr_t is pointer-width, so it round-trips a pointer");

	/*
	 * 1. Callee contract: %s must round-trip a pointer passed as intptr_t.
	 *    Hls is the only capability using %s:
	 *        "\033]8;%p1%s;%p2%s\033\\"
	 */
	out = tparm("\033]8;%p1%s;%p2%s\033\\",
	    (intptr_t)id, (intptr_t)uri, 0, 0, 0, 0, 0, 0, 0);
	check(out != NULL, "tparm() returns a buffer for Hls");
	check(out != NULL && strstr(out, uri) != NULL,
	    "tparm() %s expands the uri without truncation");
	check(out != NULL && strstr(out, id) != NULL,
	    "tparm() %s expands the id without truncation");

	/* The reset path uses two empty strings. */
	out = tparm("\033]8;%p1%s;%p2%s\033\\",
	    (intptr_t)"", (intptr_t)"", 0, 0, 0, 0, 0, 0, 0);
	check(out != NULL && strcmp(out, "\033]8;;\033\\") == 0,
	    "tparm() %s handles the empty-string reset path");

	/*
	 * 2. Caller contract: tty-term.c must hand pointers over as intptr_t so
	 *    caller and callee agree on width.  A 32-bit long truncates on Win64
	 *    (MSVC C4311) and is exactly the DEV-111 defect.
	 */
	fp = fopen("tty-term.c", "r");
	if (fp == NULL) {
		printf("FAIL: cannot open tty-term.c (run from the repo root)\n");
		return (1);
	}
	while (fgets(line, sizeof line, fp) != NULL) {
		if (strstr(line, "tparm((char *)x") == NULL)
			continue;
		if (strstr(line, "(intptr_t)a") != NULL)
			saw_s = 1;
		if (strstr(line, "(intptr_t)b") != NULL)
			saw_ss = 1;
		if (strstr(line, "(long)") != NULL)
			bad_long = 1;
	}
	fclose(fp);

	check(saw_s, "tty-term.c: tty_term_string_s passes (intptr_t)a");
	check(saw_ss, "tty-term.c: tty_term_string_ss passes (intptr_t)b");
	check(!bad_long, "tty-term.c: no (long) pointer cast at tparm() call sites");

	/*
	 * 3. Hardening: a truncated pointer must not kill the process.
	 *    Simulate the exact DEV-111 defect by routing a real pointer
	 *    through a 32-bit long, then feeding it to tparm's %s branch.
	 *    Without the SEH guard in case 's' this dereferences a bogus
	 *    zero-extended address and terminates the process; with the
	 *    guard we simply get a truncated expansion.  Reaching the next
	 *    check at all is the proof that the server survived.
	 */
	out = tparm("\033]8;%p1%s;%p2%s\033\\",
	    (intptr_t)(long)uri, (intptr_t)(long)uri,
	    0, 0, 0, 0, 0, 0, 0);
	check(1, "tparm() survived a truncated (32-bit) pointer");
	check(out != NULL, "tparm() still returns a buffer after a bad pointer");

	if (failures != 0) {
		printf("\n%d check(s) failed\n", failures);
		return (1);
	}
	printf("\nALL TParm WIDTH TESTS PASSED\n");
	return (0);
}
