// Windows counterpart of the three spawn-dependent cases in
// open-computer-use-cli.test.mjs. Those cases build a package fixture whose
// native executable is an extension-less POSIX shebang script ("dist/fake-native"),
// which Windows CreateProcess cannot execute (spawn ENOENT). Here the same
// behaviours are exercised against the real Windows native binary, which is a
// genuine PE image and therefore spawnable.
//
// The real binary is only used for the MCP handshake (`initialize`) and lives in
// a throwaway package root; the JavaScript evaluation, the `--timeout` handling
// and the REPL commands are implemented by the adapter/kernel, exactly as in the
// POSIX fixture, so the expected values are identical.
//
// No OPEN_COMPUTER_USE_* input-authorization variable is set: the JavaScript
// cases never touch the desktop.
//
// dist/ is untracked, so the coverage needs a local build
// (bash scripts/build-open-computer-use-windows.sh --arch amd64): without the
// artifact the cases skip loudly, and OCU_REQUIRE_WINDOWS_NATIVE=1 turns that
// missing build into a failure for callers that want the coverage mandatory.

import assert from "node:assert/strict";
import { copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { main } from "./open-computer-use-cli.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const NATIVE = path.resolve(HERE, "..", "..", "dist", "windows", "amd64", "open-computer-use.exe");
const NATIVE_RELATIVE = ["dist", "windows", "amd64", "open-computer-use.exe"];

// Skip note for a missing build; the command below is the one the repository
// documents for producing this artifact.
const BUILD_COMMAND = "bash scripts/build-open-computer-use-windows.sh --arch amd64";

const nativeMissing = !existsSync(NATIVE);
// dist/ is not tracked, so a fresh clone has no native. Callers that want the
// coverage to be mandatory set this to fail instead of skipping.
const requireNative = process.env.OCU_REQUIRE_WINDOWS_NATIVE === "1";

const SKIP_REASON = process.platform !== "win32"
  ? `Windows-only fixture: the real native executable requires win32 CreateProcess (current platform: ${process.platform})`
  : nativeMissing
    ? `Windows native not built; run: ${BUILD_COMMAND} (missing ${NATIVE})`
    : false;

function captureStream() {
  const stream = new PassThrough();
  let value = "";
  stream.setEncoding("utf8");
  stream.on("data", chunk => { value += chunk; });
  return { stream, value: () => value };
}

// JsonLinePeer.close() signals the child without awaiting its exit, and Windows
// keeps the image section of a just-terminated process open for a moment, so the
// first rm can race the teardown with EPERM. Retry until the handle is released.
async function removeFixture(root) {
  for (let attempt = 0; ; attempt += 1) {
    try {
      rmSync(root, { recursive: true, force: true });
      return;
    } catch (error) {
      if (attempt >= 40 || !["EPERM", "EBUSY", "ENOTEMPTY"].includes(error?.code)) throw error;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
  }
}

function makeWindowsPackage() {
  const packageRoot = mkdtempSync(path.join(os.tmpdir(), "ocu-cli-windows-test-"));
  const scripts = path.join(packageRoot, "scripts", "node-repl");
  const nativePath = path.join(packageRoot, ...NATIVE_RELATIVE);
  mkdirSync(scripts, { recursive: true });
  mkdirSync(path.dirname(nativePath), { recursive: true });
  for (const name of ["open-computer-use-repl.mjs", "open-computer-use-kernel.mjs"]) {
    cpSync(path.join(HERE, name), path.join(scripts, name));
  }
  copyFileSync(NATIVE, nativePath);
  const platformPackages = {
    "win32-x64": { executablePath: NATIVE_RELATIVE },
  };
  return {
    packageRoot,
    platformPackages,
    nativePath,
    cleanup: () => removeFixture(packageRoot),
  };
}

// Gate for the real-native coverage below. Three states:
//   local build present            -> the cases really run (asserted here, so a
//                                     future always-truthy skip cannot hide them)
//   missing, nothing demanded      -> loud skip naming the build command (dist/ is
//                                     untracked, so a fresh clone must stay green)
//   missing and OCU_REQUIRE_WINDOWS_NATIVE=1 -> hard failure for callers that insist
test("windows native coverage is run, loudly skipped, or required", { skip: process.platform === "win32" ? false : "not win32" }, t => {
  if (!nativeMissing) {
    assert.equal(SKIP_REASON, false, `real-native coverage would be skipped: ${SKIP_REASON}`);
    return;
  }
  if (requireNative) {
    assert.fail(`OCU_REQUIRE_WINDOWS_NATIVE=1 demands the real windows native: missing ${NATIVE}; run: ${BUILD_COMMAND}`);
  }
  t.skip(SKIP_REASON);
});

test("ocu js executes positional, stdin, and file source through the real windows native", { skip: SKIP_REASON }, async t => {
  const fixture = makeWindowsPackage();
  t.after(fixture.cleanup);
  const cases = [
    { argv: ["js", "nodeRepl.write(6 * 7)"], input: "", expected: "42\n" },
    { argv: ["js", "-"], input: "nodeRepl.write(await Promise.resolve('stdin'))", expected: "stdin\n" },
  ];
  const sourcePath = path.join(fixture.packageRoot, "source.mjs");
  writeFileSync(sourcePath, "nodeRepl.write('file')", "utf8");
  cases.push({ argv: ["js", "--file", sourcePath], input: "", expected: "file\n" });

  for (const entry of cases) {
    const input = new PassThrough();
    input.end(entry.input);
    const output = captureStream();
    const errorOutput = captureStream();
    const code = await main({
      packageRoot: fixture.packageRoot,
      platformPackages: fixture.platformPackages,
      argv: entry.argv,
      input,
      output: output.stream,
      errorOutput: errorOutput.stream,
    });
    assert.equal(code, 0, errorOutput.value());
    assert.equal(output.value(), entry.expected);
  }
});

test("ocu js returns a non-zero exit when evaluation times out against the real windows native", { skip: SKIP_REASON }, async t => {
  const fixture = makeWindowsPackage();
  t.after(fixture.cleanup);
  const output = captureStream();
  const errorOutput = captureStream();
  const code = await main({
    packageRoot: fixture.packageRoot,
    platformPackages: fixture.platformPackages,
    argv: ["js", "--timeout", "100", "while (true) {}"],
    output: output.stream,
    errorOutput: errorOutput.stream,
  });
  assert.equal(code, 1);
  assert.match(output.value(), /timed out after 100 ms/);
});

test("ocu repl preserves bindings and reset discards them against the real windows native", { skip: SKIP_REASON }, async t => {
  const fixture = makeWindowsPackage();
  t.after(fixture.cleanup);
  const input = new PassThrough();
  input.end([
    "var answer = 40; nodeRepl.write(answer)",
    "answer += 2; nodeRepl.write(answer)",
    ".editor",
    "var object = {",
    "  value: answer,",
    "};",
    "nodeRepl.write(object.value)",
    ".end",
    ".reset",
    "nodeRepl.write(typeof answer)",
    ".exit",
  ].join("\n"));
  const output = captureStream();
  const errorOutput = captureStream();
  const code = await main({
    packageRoot: fixture.packageRoot,
    platformPackages: fixture.platformPackages,
    argv: ["repl"],
    input,
    output: output.stream,
    errorOutput: errorOutput.stream,
  });
  assert.equal(code, 0, errorOutput.value());
  assert.equal(output.value(), "40\n42\n42\nOpen Computer Use JavaScript session reset\nundefined\n");
});
