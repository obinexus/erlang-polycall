'use strict';

// Source-package index: absolute paths of the Erlang/C sources for build
// tooling. This package contains no JavaScript implementation of Polycall;
// the binding is the Erlang NIF built against libpolycall (polycall >= 1.1.0).
const path = require('node:path');

const fromPackageRoot = (...segments) => path.join(__dirname, ...segments);

module.exports = Object.freeze({
  root: __dirname,
  erlangModule: fromPackageRoot('src', 'erlang_polycall.erl'),
  peerModule: fromPackageRoot('src', 'polycall_peer.erl'),
  nifModule: fromPackageRoot('src', 'erlang_polycall_nif.erl'),
  applicationSource: fromPackageRoot('src', 'erlang_polycall.app.src'),
  nativeAdapter: fromPackageRoot('c_src', 'erlang_polycall.c'),
  nifSource: fromPackageRoot('c_src', 'erlang_polycall_nif.c'),
  publicHeader: fromPackageRoot('include', 'erlang_polycall.h'),
  erlangHeader: fromPackageRoot('include', 'erlang_polycall.hrl'),
  rebarConfig: fromPackageRoot('rebar.config'),
  makefile: fromPackageRoot('Makefile'),
  config: fromPackageRoot('erlang-polycallrc'),
  manifest: fromPackageRoot('polycall-binding.json')
});
