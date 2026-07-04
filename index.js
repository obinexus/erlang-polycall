'use strict';

const path = require('node:path');

const fromPackageRoot = (...segments) => path.join(__dirname, ...segments);

module.exports = Object.freeze({
  root: __dirname,
  erlangModule: fromPackageRoot('src', 'erlang_polycall.erl'),
  applicationSource: fromPackageRoot('src', 'erlang_polycall.app.src'),
  nativeAdapter: fromPackageRoot('c_src', 'erlang_polycall.c'),
  nifSource: fromPackageRoot('c_src', 'erlang_polycall_nif.c'),
  publicHeader: fromPackageRoot('include', 'erlang_polycall.h'),
  ffiHeader: fromPackageRoot('generated', 'polycall', 'polycall_ffi.h'),
  config: fromPackageRoot('erlang-polycallrc'),
  manifest: fromPackageRoot('polycall-binding.json')
});
