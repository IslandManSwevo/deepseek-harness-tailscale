'use strict';

// Unit tests for web-files.js: path containment, browser-trust fence, and
// text read/write semantics. No dsh or Tailscale needed.
//
// Run: node --test test/files.test.js

const { test, before, after } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const files = require('../web-files.js');

let tmpRoot;
let outside;

before(() => {
  tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-files-test-'));
  outside = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-files-outside-'));
});

after(() => {
  fs.rmSync(tmpRoot, { recursive: true, force: true });
  fs.rmSync(outside, { recursive: true, force: true });
  delete process.env.DSH_TS_HOST;
  delete process.env.DSH_TS_IP;
  delete process.env.DSH_TS_IPV6;
  delete process.env.DSH_PROXY_PORT;
});

// --- safeResolve: path containment --------------------------------------

test('safeResolve: allows paths inside the root', () => {
  const target = path.join(tmpRoot, 'sub', 'file.txt');
  assert.strictEqual(files.safeResolve(target, [tmpRoot]), target);
});

test('safeResolve: allows not-yet-existing files inside the root', () => {
  const target = path.join(tmpRoot, 'brand', 'new', 'file.txt');
  assert.strictEqual(files.safeResolve(target, [tmpRoot]), target);
});

test('safeResolve: rejects traversal outside the root', () => {
  const target = path.join(tmpRoot, '..', 'escape.txt');
  assert.strictEqual(files.safeResolve(target, [tmpRoot]), null);
});

test('safeResolve: rejects absolute paths outside the root', () => {
  const target = path.join(outside, 'secret.txt');
  assert.strictEqual(files.safeResolve(target, [tmpRoot]), null);
});

test('safeResolve: rejects null bytes', () => {
  assert.strictEqual(files.safeResolve('a\0b', [tmpRoot]), null);
});

test('safeResolve: rejects symlink/junction escapes', (t) => {
  const link = path.join(tmpRoot, 'link');
  try {
    fs.symlinkSync(outside, link, 'junction');
  } catch (e) {
    t.skip('cannot create junctions in this environment: ' + e.message);
    return;
  }
  const target = path.join(link, 'file.txt');
  assert.strictEqual(files.safeResolve(target, [tmpRoot]), null);
});

// --- isTrustedRequest: browser-trust fence -------------------------------

test('isTrustedRequest: accepts loopback hosts', () => {
  const req = { headers: { host: '127.0.0.1:3080' } };
  assert.strictEqual(files.isTrustedRequest(req, []), true);
});

test('isTrustedRequest: accepts trusted authorities', () => {
  process.env.DSH_TS_HOST = 'myhost.tail1234.ts.net';
  process.env.DSH_TS_IP = '100.101.102.103';
  process.env.DSH_PROXY_PORT = '3080';
  const trusted = files.buildTrustedAuthorities();
  const req = { headers: { host: 'myhost.tail1234.ts.net:3080' } };
  assert.strictEqual(files.isTrustedRequest(req, trusted), true);
});

test('isTrustedRequest: rejects untrusted hosts', () => {
  const req = { headers: { host: 'evil.example.com' } };
  assert.strictEqual(files.isTrustedRequest(req, []), false);
});

test('isTrustedRequest: rejects cross-site requests', () => {
  const req = { headers: { host: '127.0.0.1:3080', 'sec-fetch-site': 'cross-site' } };
  assert.strictEqual(files.isTrustedRequest(req, []), false);
});

test('isTrustedRequest: rejects Origin/Host mismatch', () => {
  const req = { headers: { host: '127.0.0.1:3080', origin: 'http://evil.example.com' } };
  assert.strictEqual(files.isTrustedRequest(req, []), false);
});

// --- writeText / readText ------------------------------------------------

test('writeText: preserves CRLF on save', () => {
  const target = path.join(tmpRoot, 'crlf.txt');
  fs.writeFileSync(target, 'line1\r\nline2\r\n');
  files.writeText(target, 'line1\nline2\n');
  assert.strictEqual(fs.readFileSync(target, 'utf8'), 'line1\r\nline2\r\n');
});

test('writeText: leaves LF files alone', () => {
  const target = path.join(tmpRoot, 'lf.txt');
  fs.writeFileSync(target, 'a\nb\n');
  files.writeText(target, 'a\nb\n');
  assert.strictEqual(fs.readFileSync(target, 'utf8'), 'a\nb\n');
});

test('readText: flags binary files', () => {
  const target = path.join(tmpRoot, 'bin.dat');
  fs.writeFileSync(target, Buffer.from([0x00, 0x01, 0x02]));
  const r = files.readText(target);
  assert.strictEqual(r.binary, true);
});
