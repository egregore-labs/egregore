#!/usr/bin/env node

import fs from "node:fs";

const PRERELEASE_SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-((?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;

// The implemented dogfood scheme is X.Y.Z-runtime-mvp.N. Enforcing the
// identifier here keeps the protected workflow from minting stale-scheme
// versions (0.21.0-rc.N and similar) onto the runtime-mvp dist-tag.
const RUNTIME_MVP_SCHEME = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-runtime-mvp\.(0|[1-9]\d*)$/;

function fail(message) {
  process.stderr.write(`create-egregore prerelease: ${message}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument !== "--version" && argument !== "--manifest") {
      fail(`unknown argument: ${argument}`);
    }
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      fail(`missing value for ${argument}`);
    }
    values[argument.slice(2)] = value;
    index += 1;
  }
  return values;
}

const { version, manifest } = parseArgs(process.argv.slice(2));

if (!version) {
  fail("--version is required");
}
if (!PRERELEASE_SEMVER.test(version)) {
  fail(`${version} is not a valid SemVer prerelease`);
}
if (!RUNTIME_MVP_SCHEME.test(version)) {
  fail(
    `${version} is not on the runtime-mvp prerelease scheme (expected X.Y.Z-runtime-mvp.N)`,
  );
}

if (manifest) {
  let packageJson;
  try {
    packageJson = JSON.parse(fs.readFileSync(manifest, "utf8"));
  } catch (error) {
    fail(`cannot read ${manifest}: ${error.message}`);
  }
  if (packageJson.name !== "create-egregore") {
    fail(`expected create-egregore, got ${packageJson.name || "an unnamed package"}`);
  }
  if (packageJson.version !== version) {
    fail(`requested ${version}, but ${manifest} contains ${packageJson.version || "no version"}`);
  }
}

process.stdout.write(`${version}\n`);
