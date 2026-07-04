'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const binding = require('..');

for (const [name, file] of Object.entries(binding)) {
  assert.equal(path.isAbsolute(file), true, `${name} must be an absolute path`);
  assert.equal(fs.existsSync(file), true, `${name} does not exist: ${file}`);
}

assert.equal(
  require.resolve('@obinexusltd/erlang-polycall/src/erlang_polycall.erl'),
  binding.erlangModule
);
assert.equal(
  require.resolve('@obinexusltd/erlang-polycall/c_src/erlang_polycall_nif.c'),
  binding.nifSource
);

console.log('erlang-polycall npm package test: PASS');
