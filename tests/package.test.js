'use strict';

// npm source-package test: every exported path exists, subpath exports
// resolve, and the package no longer ships the stub polycall_ffi.h.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const binding = require('..');
const pkg = require('../package.json');

for (const [name, file] of Object.entries(binding)) {
  assert.equal(path.isAbsolute(file), true, `${name} must be an absolute path`);
  assert.equal(fs.existsSync(file), true, `${name} does not exist: ${file}`);
}

assert.equal(pkg.name, '@obinexusltd/erlang-polycall');
assert.equal(pkg.repository.url, 'git+https://github.com/obinexus/erlang-polycall.git');
assert.equal(
  require.resolve('@obinexusltd/erlang-polycall/src/erlang_polycall.erl'),
  binding.erlangModule
);
assert.equal(
  require.resolve('@obinexusltd/erlang-polycall/c_src/erlang_polycall_nif.c'),
  binding.nifSource
);
assert.equal(fs.existsSync(path.join(binding.root, 'generated')), false,
  'the stub generated/polycall/polycall_ffi.h must not come back');
const nif = fs.readFileSync(binding.nifSource, 'utf8');
assert.match(nif, /#include <polycall\.h>/);

const manifest = require('../polycall-binding.json');
assert.equal(manifest.core, 'polycall >= 1.1.0 (binding ABI 1)');
assert.equal(manifest.core_repository, 'https://github.com/obinexus/polycall');
assert.equal(manifest.version, pkg.version);

console.log('erlang-polycall npm package test: PASS');
