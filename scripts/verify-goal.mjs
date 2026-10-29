// Verification gate for goal_complete (tmux-windows).
//
// Mirrors the pi monorepo's scripts/verify-goal.mjs + test.sh split. Two things
// are deliberate:
//
//   TWO formatting entry points, because the policies differ:
//     .husky/pre-commit        formats STAGED files for a human committing.
//     scripts/verify-goal.mjs  formats CHANGED files and FAILS if the formatter
//                              rewrote any of them - accountability.
//
//   TWO tripwires, both from pi:
//     1. post-format - the formatter is a mutator, so success must not hide it.
//     2. post-gate   - a file already changed must not change again while the
//                      gate runs (concurrent worktree, stray formatter, a test
//                      that rewrites tracked content).
//
// Like pi's test.sh, this script SELF-HEALS a fresh checkout: it hydrates
// dependencies and builds the binary before testing, so a new clone or a new
// worktree does not fail just because nobody ran install/build yet.
//
// Target set comes from git diff, never a glob, so unrelated and upstream files
// are never touched and untracked files are excluded by construction.
//
// Usage (works from PowerShell, cmd, and Git Bash):
//   node scripts/verify-goal.mjs
//
// Overrides:
//   PI_VERIFY_BINARY=<path>    use a specific tmux.exe
//   PI_VERIFY_BASH=<path>      use a specific bash.exe
//   PI_VERIFY_GATE_CMD=<cmd>   replace the regression suite (used by tests)
//   PI_VERIFY_SKIP_SETUP=1     skip dependency hydration and the build

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
	existsSync,
	lstatSync,
	readFileSync,
	readdirSync,
	realpathSync,
	mkdtempSync,
	rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname, delimiter, basename } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
process.chdir(ROOT_DIR);

const MARKDOWN_RE = /\.mdx?$/i;

// Tests and installs legitimately rewrite lockfiles; they are not tripwire targets.
const LOCKFILE_NAMES = new Set(["package-lock.json", "bun.lock", "pnpm-lock.yaml", "yarn.lock"]);

// Prefer the symbol-bearing build so a failure can be debugged with cdb.
const CANDIDATE_BINARIES = [
	"build/RelWithDebInfo/tmux.exe",
	"build/Release/tmux.exe",
	"build/Debug/tmux.exe",
];

const BUILD_CONFIG = "RelWithDebInfo";
const CMAKE_GENERATOR = "Visual Studio 17 2022";
const SCRIPT_TIMEOUT_MS = 300_000;

const isWindows = process.platform === "win32";

/**
 * Changed tracked files: union of unstaged (git diff --name-only -z) and staged
 * (git diff --cached --name-only --diff-filter=ACMR -z). Untracked files are
 * excluded by construction. Deleted paths are dropped. Dedupe is by realpath.
 */
export function getChangedFiles(cwd = ROOT_DIR) {
	const raw = [];
	for (const args of [
		["diff", "--name-only", "-z"],
		["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"],
	]) {
		const r = spawnSync("git", args, { cwd, encoding: "utf8" });
		if (r.status !== 0) {
			const stderr = (r.stderr ?? "").trim();
			if (stderr) console.error(stderr);
			continue;
		}
		raw.push(...(r.stdout ?? "").split("\0").filter((p) => p.length > 0));
	}

	const seen = new Set();
	const files = [];
	for (const p of raw) {
		try {
			lstatSync(p);
		} catch {
			continue; // Deleted: nothing to format or watch.
		}
		let key = p;
		try {
			key = realpathSync(p);
		} catch {
			// Raw path fallback keeps dedupe best-effort.
		}
		if (seen.has(key)) continue;
		seen.add(key);
		files.push(p);
	}
	return files;
}

/** Map of path -> sha256 of its bytes. Unreadable files hash to null. */
export function snapshotFiles(paths) {
	const m = new Map();
	for (const p of paths) {
		try {
			m.set(p, createHash("sha256").update(readFileSync(p)).digest("hex"));
		} catch {
			m.set(p, null);
		}
	}
	return m;
}

/**
 * `node_modules/.bin/<name>`, preferring the `.cmd` shim on Windows: npm writes
 * the extensionless entry as a POSIX shell script there, which spawnSync cannot
 * execute directly.
 */
export function resolveToolCommand(name) {
	const bin = join("node_modules", ".bin", name);
	return isWindows && existsSync(`${bin}.cmd`) ? `${bin}.cmd` : bin;
}

function printDiff(files) {
	const r = spawnSync("git", ["diff", "--", ...files], { encoding: "utf8" });
	if (r.status === 0 && r.stdout) process.stdout.write(r.stdout);
}

function printReviewBanner(title, lines, files) {
	console.log("");
	console.log("=".repeat(72));
	console.log(title);
	console.log("=".repeat(72));
	for (const line of lines) console.log(line);
	for (const f of files) console.log(`  - ${f}`);
	console.log("=".repeat(72));
}

export function findBinary() {
	if (process.env.PI_VERIFY_BINARY) {
		const forced = process.env.PI_VERIFY_BINARY;
		return existsSync(forced) ? forced : null;
	}
	for (const rel of CANDIDATE_BINARIES) {
		if (existsSync(rel)) return rel;
	}
	return null;
}

/**
 * Locate bash. The regression scripts are POSIX shell, and Git for Windows does
 * not necessarily put bash on PATH, so spawning plain "bash" fails with ENOENT
 * from PowerShell/cmd. Resolve it explicitly instead.
 */
export function findBash() {
	if (process.env.PI_VERIFY_BASH) {
		const forced = process.env.PI_VERIFY_BASH;
		return existsSync(forced) ? forced : null;
	}

	const exeNames = isWindows ? ["bash.exe", "bash"] : ["bash"];
	const pathDirs = (process.env.PATH ?? "").split(delimiter).filter(Boolean);
	for (const dir of pathDirs) {
		for (const name of exeNames) {
			const candidate = join(dir, name);
			if (existsSync(candidate)) return candidate;
		}
	}

	if (isWindows) {
		const known = [
			"C:\\Program Files\\Git\\bin\\bash.exe",
			"C:\\Program Files\\Git\\usr\\bin\\bash.exe",
			"C:\\Program Files (x86)\\Git\\bin\\bash.exe",
			"C:\\Program Files (x86)\\Git\\usr\\bin\\bash.exe",
			join(process.env.LOCALAPPDATA ?? "", "Programs\\Git\\bin\\bash.exe"),
			join(process.env.USERPROFILE ?? "", "scoop\\apps\\git\\current\\bin\\bash.exe"),
		];
		for (const candidate of known) {
			if (candidate && existsSync(candidate)) return candidate;
		}
	}

	return null;
}

/**
 * Locate CMake. The VS-bundled copy is not on PATH in a plain SSH shell, which
 * is why an unqualified `cmake` invocation fails there.
 */
export function findCmake() {
	if (process.env.PI_VERIFY_CMAKE) {
		const forced = process.env.PI_VERIFY_CMAKE;
		return existsSync(forced) ? forced : null;
	}

	const pathDirs = (process.env.PATH ?? "").split(delimiter).filter(Boolean);
	for (const dir of pathDirs) {
		for (const name of isWindows ? ["cmake.exe", "cmake"] : ["cmake"]) {
			const candidate = join(dir, name);
			if (existsSync(candidate)) return candidate;
		}
	}

	if (isWindows) {
		const known = [
			"C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\Common7\\IDE\\CommonExtensions\\Microsoft\\CMake\\CMake\\bin\\cmake.exe",
			"C:\\Program Files\\Microsoft Visual Studio\\2022\\BuildTools\\Common7\\IDE\\CommonExtensions\\Microsoft\\CMake\\CMake\\bin\\cmake.exe",
			"C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\Community\\Common7\\IDE\\CommonExtensions\\Microsoft\\CMake\\CMake\\bin\\cmake.exe",
			join(process.env.USERPROFILE ?? "", "scoop\\apps\\cmake\\current\\bin\\cmake.exe"),
		];
		for (const candidate of known) {
			if (candidate && existsSync(candidate)) return candidate;
		}
	}

	return null;
}

/** vcpkg toolchain file, if one can be found. Needed for libevent on a fresh clone. */
function findVcpkgToolchain() {
	const candidates = [
		process.env.VCPKG_ROOT ? join(process.env.VCPKG_ROOT, "scripts", "buildsystems", "vcpkg.cmake") : null,
		join(process.env.USERPROFILE ?? "", "scoop", "apps", "vcpkg", "current", "scripts", "buildsystems", "vcpkg.cmake"),
		join(process.env.USERPROFILE ?? "", "vcpkg", "scripts", "buildsystems", "vcpkg.cmake"),
	];
	for (const candidate of candidates) {
		if (candidate && existsSync(candidate)) return candidate;
	}
	return null;
}

function npmCommand() {
	return isWindows ? "npm.cmd" : "npm";
}

function setupSkipped() {
	return process.env.PI_VERIFY_SKIP_SETUP === "1";
}

/**
 * Hydrate dependencies when prettier is missing. Like pi's `npm install
 * --ignore-scripts`, this makes a fresh checkout usable without a manual step;
 * --ignore-scripts avoids husky's `git config` during install.
 */
export function ensureDependencies() {
	if (setupSkipped()) return;
	if (existsSync(join("node_modules", ".bin", "prettier"))) return;

	console.log("setup  : node_modules missing -> npm install --ignore-scripts");
	const r = spawnSync(npmCommand(), ["install", "--ignore-scripts"], {
		cwd: ROOT_DIR,
		stdio: "inherit",
		shell: isWindows,
	});
	if (r.status !== 0) {
		console.error(`FAIL: npm install failed (exit ${r.status ?? 1}).`);
		process.exit(1);
	}
}

/**
 * Build the binary when it is missing. Configures the tree first when there is no
 * CMakeCache, so a fresh worktree (which has no build/ at all) works.
 */
export function ensureBuild() {
	if (setupSkipped()) return;

	const cmake = findCmake();
	if (cmake === null) {
		console.error("FAIL: cmake was not found.");
		console.error("Install CMake (or the VS C++ build tools), or set PI_VERIFY_CMAKE.");
		process.exit(1);
	}

	if (!existsSync(join("build", "CMakeCache.txt"))) {
		const args = ["-S", ".", "-B", "build", "-G", CMAKE_GENERATOR];
		const toolchain = findVcpkgToolchain();
		if (toolchain !== null) {
			args.push(`-DCMAKE_TOOLCHAIN_FILE=${toolchain}`);
			args.push("-DVCPKG_TARGET_TRIPLET=x64-windows-static");
			args.push("-DVCPKG_MANIFEST_MODE=OFF");
		} else {
			console.log("setup  : no vcpkg toolchain found; configuring without one");
		}
		console.log(`setup  : configuring -> ${cmake} ${args.join(" ")}`);
		const c = spawnSync(cmake, args, { cwd: ROOT_DIR, stdio: "inherit" });
		if (c.status !== 0) {
			console.error(`FAIL: cmake configure failed (exit ${c.status ?? 1}).`);
			process.exit(1);
		}
	}

	/*
	 * Build unconditionally, mirroring pi's test.sh which runs `npm run build` on
	 * every full run. Building only when no binary exists would happily test a
	 * stale artifact left over from an earlier configuration - a false green that
	 * validates code which does not match the sources.
	 */
	console.log(`setup  : building -> cmake --build build --config ${BUILD_CONFIG}`);
	const b = spawnSync(cmake, ["--build", "build", "--config", BUILD_CONFIG], {
		cwd: ROOT_DIR,
		stdio: "inherit",
	});
	if (b.status !== 0) {
		console.error(`FAIL: build failed (exit ${b.status ?? 1}).`);
		process.exit(1);
	}

	// Require the configuration we just built. Never fall back to another
	// config's binary, which would silently test code that does not match HEAD.
	const expected = join("build", BUILD_CONFIG, "tmux.exe");
	if (!existsSync(expected)) {
		console.error(`FAIL: build succeeded but ${expected} is missing.`);
		process.exit(1);
	}
}

/** POSIX-style relative paths: bash treats backslashes as escapes. */
function regressionScripts() {
	const dir = join(ROOT_DIR, "regress");
	if (!existsSync(dir)) return [];
	return readdirSync(dir)
		.filter((name) => name.startsWith("win32-") && name.endsWith(".sh"))
		.sort()
		.map((name) => `regress/${name}`);
}

/**
 * Format the changed Markdown files and fail if formatting mutated any of them.
 * Tripwire 1: a formatter is a mutator, so success must not hide its edits.
 */
export function formatChangedMarkdown() {
	const md = getChangedFiles().filter((f) => MARKDOWN_RE.test(f));
	if (md.length === 0) {
		console.log("format : no changed Markdown");
		return;
	}

	if (!existsSync(join("node_modules", ".bin", "prettier"))) {
		console.error("prettier is not installed. Run: npm install --ignore-scripts");
		process.exit(1);
	}

	console.log(`format : ${md.length} changed Markdown file(s)`);
	const before = snapshotFiles(md);
	const r = spawnSync(resolveToolCommand("prettier"), ["--write", ...md], {
		stdio: "inherit",
		shell: isWindows,
	});
	if (r.status !== 0) {
		console.error(`prettier --write failed (exit ${r.status ?? 1}).`);
		process.exit(r.status ?? 1);
	}

	const after = snapshotFiles(md);
	const mutated = md.filter((f) => before.get(f) !== after.get(f));
	if (mutated.length > 0) {
		printDiff(mutated);
		printReviewBanner(
			"MANDATORY REVIEW REQUIRED",
			[
				"The formatter rewrote files that were already changed. Read each diff",
				"above, confirm the change is intended, then re-run goal_complete.",
			],
			mutated,
		);
		process.exit(1);
	}
}

/** Run the authoritative gate. PI_VERIFY_GATE_CMD lets tests inject a command. */
function runGate(bash, env, scripts) {
	const override = process.env.PI_VERIFY_GATE_CMD;
	if (override !== undefined) {
		console.log(`gate   : override -> ${override}`);
		const r = spawnSync(bash, ["-c", override], { cwd: ROOT_DIR, env, stdio: "inherit" });
		return r.status ?? 1;
	}

	const failures = [];
	for (const script of scripts) {
		const started = Date.now();
		const result = spawnSync(bash, [script], {
			cwd: ROOT_DIR,
			env,
			encoding: "utf8",
			timeout: SCRIPT_TIMEOUT_MS,
		});
		const elapsed = ((Date.now() - started) / 1000).toFixed(1);

		if (result.error) {
			// Spawn-level failure (ENOENT, EACCES, timeout). Never report this as a
			// test failure without saying why.
			console.log(`ERROR ${script}  (${elapsed}s)`);
			console.log(`      spawn: ${result.error.code ?? result.error.message}`);
			failures.push(script);
			continue;
		}

		if (result.status === 0) {
			console.log(`PASS  ${script}  (${elapsed}s)`);
		} else {
			const why = result.signal ? `signal ${result.signal}` : `exit ${result.status}`;
			console.log(`FAIL  ${script}  (${elapsed}s, ${why})`);
			const out = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
			if (out) {
				for (const line of out.split(/\r?\n/).slice(-10)) {
					console.log(`      ${line}`);
				}
			}
			failures.push(script);
		}
	}

	if (failures.length > 0) {
		console.error(`FAILED: ${failures.join(", ")}`);
		return 1;
	}
	return 0;
}

export function main() {
	// Stage 0: self-heal a fresh checkout, like pi's test.sh hydrate+build steps.
	ensureDependencies();
	ensureBuild();

	const binary = findBinary();
	if (binary === null) {
		console.error("FAIL: no tmux binary found. Build one of:");
		for (const rel of CANDIDATE_BINARIES) console.error(`  - ${rel}`);
		process.exit(1);
	}

	const bash = findBash();
	if (bash === null) {
		console.error("FAIL: could not find bash.");
		console.error("Install Git for Windows, or set PI_VERIFY_BASH to bash.exe.");
		process.exit(1);
	}

	const scripts = regressionScripts();
	if (scripts.length === 0 && process.env.PI_VERIFY_GATE_CMD === undefined) {
		console.error("FAIL: no regress/win32-*.sh scripts found");
		process.exit(1);
	}

	// Stage 1: format changed Markdown; fail if the formatter mutated anything.
	formatChangedMarkdown();

	// Snapshot AFTER formatting and AFTER setup, so the gate tripwire only sees
	// gate-time changes (npm install/build output is gitignored or a lockfile).
	const tripwireTargets = getChangedFiles().filter((f) => !LOCKFILE_NAMES.has(basename(f)));
	const postFormat = snapshotFiles(tripwireTargets);

	const home = mkdtempSync(join(tmpdir(), "tmux-verify-"));
	const env = {
		...process.env,
		HOME: home,
		USERPROFILE: home,
		TEST_TMUX: resolve(ROOT_DIR, binary),
	};

	console.log("");
	console.log(`binary : ${binary}`);
	console.log(`bash   : ${bash}`);
	console.log(`scripts: ${scripts.length}`);
	console.log(`watch  : ${tripwireTargets.length} changed file(s)`);
	console.log("");

	const gateStatus = runGate(bash, env, scripts);

	try {
		rmSync(home, { recursive: true, force: true });
	} catch {
		/* best effort */
	}

	// Tripwire 2: nothing already changed may change again while the gate ran.
	const postGate = snapshotFiles(tripwireTargets);
	const changedDuringGate = tripwireTargets.filter((f) => postFormat.get(f) !== postGate.get(f));
	if (changedDuringGate.length > 0) {
		printDiff(changedDuringGate);
		printReviewBanner(
			"MANDATORY REVIEW REQUIRED",
			[
				"A file that was already changed was modified WHILE the test gate ran.",
				"The usual cause is another process formatting or rewriting the tree",
				"concurrently. Read each diff above, confirm the change is intended,",
				"then re-run goal_complete.",
			],
			changedDuringGate,
		);
		process.exit(1);
	}

	console.log("");
	console.log(`RESULT: ${gateStatus === 0 ? "gate passed" : "gate FAILED"}`);
	process.exit(gateStatus);
}

function isMainModule() {
	const entry = process.argv[1];
	if (!entry) return false;
	try {
		return realpathSync(entry) === realpathSync(fileURLToPath(import.meta.url));
	} catch {
		return false;
	}
}

if (isMainModule()) main();
