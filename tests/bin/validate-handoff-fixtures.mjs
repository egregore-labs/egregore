#!/usr/bin/env node
// validate-handoff-fixtures.mjs — JS half of the validator drift test.
//
// Reads a JSON array of { name, artifact } from stdin and prints
// { name: { subset: bool, zod: bool } } — the verdict of BOTH deployed
// JS validators:
//   subset — packages/egregore-emissary/lib/validate.js (the zero-dep
//            draft-07 subset validator the CLI runs before every POST)
//   zod    — packages/egregore-handoff/lib/format.js safeValidate (the
//            source schema the JSON Schema is generated from)
//
// tests/test_validator_drift.py runs the same artifacts through the
// Python jsonschema validator and asserts the three verdicts agree.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const repo = resolve(here, '..', '..')

const { validateArtifact } = await import(
  `${repo}/packages/egregore-emissary/lib/validate.js`
)
const { safeValidate } = await import(
  `${repo}/packages/egregore-handoff/lib/format.js`
)

const fixtures = JSON.parse(readFileSync(0, 'utf8'))
const out = {}
for (const { name, artifact } of fixtures) {
  const subset = validateArtifact(artifact)
  const zod = safeValidate(artifact)
  out[name] = { subset: subset.valid === true, zod: zod.success === true }
}
process.stdout.write(JSON.stringify(out))
