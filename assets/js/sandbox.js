/*
 * ApiWorkbench script sandbox: Postman's `pm` API on QuickJS.
 *
 * The host (lib/services/scripting/js_session.dart) loads this file as a
 * CommonJS-style module once per run and drives it:
 *
 *   init(ctx)            request, response, variables and info as JSON
 *   begin(origin)        before each script
 *   track(promise)       the script itself, wrapped in an async function
 *   poll()               variable writes, queued pm.sendRequest calls and
 *                        the next timer, until nothing is pending
 *   resolve(id, result)  a pm.sendRequest response (or error)
 *   fireTimers()         setTimeout / setInterval callbacks that are due
 *   end()                after each script: legacy tests[], unfinished tests
 *   finish()             tests, logs, next request, visualizer, request edits
 *
 * Nothing here can reach files or the network. The host performs the
 * requests that poll() hands it, so pm.sendRequest is the only way out.
 */
'use strict';

const G = globalThis;
const loadNative = G.__awLoad;

// ---------------------------------------------------------------------------
// Run state

const S = {
  phase: 'prerequest',
  origin: '',
  current: null,
  ops: [],
  logs: [],
  droppedLogs: 0,
  tests: [],
  next: undefined,
  skip: false,
  visualizer: undefined,
  queue: [],
  pending: Object.create(null),
  requestSeq: 0,
  timers: [],
  timerSeq: 0,
  dynamic: {},
  initial: null,
};

const LOG_LIMIT = 1000;
const MESSAGE_LIMIT = 20000;

const hasOwn = (o, k) => o != null && Object.prototype.hasOwnProperty.call(o, k);
const isObject = (v) => v !== null && typeof v === 'object';

/** How a variable value is stored by the host: always a string. */
function persistString(v) {
  if (typeof v === 'string') return v;
  if (v === undefined || v === null) return '';
  if (typeof v === 'object') {
    try {
      return JSON.stringify(v);
    } catch (e) {
      return String(v);
    }
  }
  return String(v);
}

// ---------------------------------------------------------------------------
// Formatting (console.* and error messages)

function inspect(v) {
  switch (typeof v) {
    case 'string':
      return JSON.stringify(v);
    case 'undefined':
      return 'undefined';
    case 'function':
      return '[Function' + (v.name ? ': ' + v.name : ' (anonymous)') + ']';
    case 'symbol':
      return v.toString();
    case 'bigint':
      return v + 'n';
    case 'object':
      if (v === null) return 'null';
      break;
    default:
      return String(v);
  }
  if (v instanceof Error) {
    const head = (v.name || 'Error') + (v.message ? ': ' + v.message : '');
    return v.stack ? head + '\n' + String(v.stack).replace(/\s+$/, '') : head;
  }
  if (v instanceof Date) return isNaN(v) ? 'Invalid Date' : v.toISOString();
  if (v instanceof RegExp) return String(v);
  const path = [];
  let json;
  try {
    json = JSON.stringify(v, function (key, val) {
      // `this` is the holder: drop finished branches so only real cycles
      // print as [Circular].
      while (path.length && path[path.length - 1] !== this) path.pop();
      if (typeof val === 'bigint') return val + 'n';
      if (typeof val === 'function') return '[Function' + (val.name ? ': ' + val.name : '') + ']';
      if (typeof val === 'symbol') return val.toString();
      if (val instanceof Map) return { '[Map]': Array.from(val.entries()) };
      if (val instanceof Set) return { '[Set]': Array.from(val.values()) };
      if (isObject(val)) {
        if (path.indexOf(val) >= 0) return '[Circular]';
        path.push(val);
      }
      return val;
    });
  } catch (e) {
    return Object.prototype.toString.call(v);
  }
  if (json === undefined) return String(v);
  if (json.length <= 200) return json;
  try {
    return JSON.stringify(JSON.parse(json), null, 2);
  } catch (e) {
    return json;
  }
}

function formatArgs(args) {
  if (!args.length) return '';
  const out = [];
  let i = 0;
  if (typeof args[0] === 'string' && /%[sdifjoOc%]/.test(args[0])) {
    let next = 1;
    out.push(
      args[0].replace(/%([sdifjoOc%])/g, (m, c) => {
        if (c === '%') return '%';
        if (next >= args.length) return m;
        const a = args[next++];
        switch (c) {
          case 's':
            return typeof a === 'string' ? a : inspect(a);
          case 'd':
            return String(Number(a));
          case 'i':
            return String(parseInt(a, 10));
          case 'f':
            return String(parseFloat(a));
          case 'c':
            return '';
          default:
            return inspect(a);
        }
      }),
    );
    i = next;
  }
  for (; i < args.length; i++) {
    out.push(typeof args[i] === 'string' ? args[i] : inspect(args[i]));
  }
  return out.join(' ');
}

function addLog(level, args) {
  if (S.logs.length >= LOG_LIMIT) {
    S.droppedLogs++;
    return;
  }
  let m;
  try {
    m = formatArgs(args);
  } catch (e) {
    m = '[value could not be printed]';
  }
  if (m.length > MESSAGE_LIMIT) {
    m = m.slice(0, MESSAGE_LIMIT) + '… (' + (m.length - MESSAGE_LIMIT) + ' more characters)';
  }
  S.logs.push({ l: level, m: m, t: Date.now(), o: S.origin });
}

/** Line of the current script in [stack], or 0. */
function scriptLine(stack) {
  const s = String(stack || '');
  const file = S.origin + ':';
  let i = s.indexOf('(' + file);
  if (i >= 0) i += 1;
  else {
    i = s.indexOf('at ' + file);
    if (i >= 0) i += 3;
  }
  if (i < 0) return 0;
  const m = /^(\d+)/.exec(s.slice(i + file.length));
  return m ? Number(m[1]) : 0;
}

function describeError(e) {
  if (e instanceof Error || (isObject(e) && 'message' in e)) {
    const text = (e.name || 'Error') + (e.message ? ': ' + e.message : '');
    const line = scriptLine(e.stack);
    return line ? text + ' (line ' + line + ')' : text;
  }
  // QuickJS throws null when it can't allocate an error for running out of
  // memory.
  if (e === null) return 'Uncaught null: the script threw null or ran out of memory';
  return 'Uncaught ' + inspect(e);
}

/** An error thrown by the running script outside pm.test. */
function scriptError(e) {
  if (S.current && !S.current.error) S.current.error = describeError(e);
}

const console = {
  log: (...a) => addLog('log', a),
  info: (...a) => addLog('info', a),
  warn: (...a) => addLog('warn', a),
  error: (...a) => addLog('error', a),
  debug: (...a) => addLog('debug', a),
  trace: (...a) => addLog('debug', a),
  dir: (v) => addLog('log', [v]),
  table: (v) => addLog('log', [v]),
  assert: (cond, ...a) => {
    if (!cond) addLog('error', ['Assertion failed' + (a.length ? ':' : '')].concat(a));
  },
  group: (...a) => {
    if (a.length) addLog('log', a);
  },
  groupCollapsed: (...a) => {
    if (a.length) addLog('log', a);
  },
  groupEnd: () => {},
  clear: () => {},
  _times: Object.create(null),
  _counts: Object.create(null),
  time(label) {
    this._times[label === undefined ? 'default' : label] = Date.now();
  },
  timeLog(label, ...a) {
    const k = label === undefined ? 'default' : label;
    if (k in this._times) addLog('log', [k + ': ' + (Date.now() - this._times[k]) + 'ms'].concat(a));
  },
  timeEnd(label) {
    const k = label === undefined ? 'default' : label;
    if (k in this._times) {
      addLog('log', [k + ': ' + (Date.now() - this._times[k]) + 'ms']);
      delete this._times[k];
    }
  },
  count(label) {
    const k = label === undefined ? 'default' : label;
    this._counts[k] = (this._counts[k] || 0) + 1;
    addLog('log', [k + ': ' + this._counts[k]]);
  },
  countReset(label) {
    delete this._counts[label === undefined ? 'default' : label];
  },
};
for (const k of ['_times', '_counts']) Object.defineProperty(console, k, { enumerable: false });

// ---------------------------------------------------------------------------
// Secure random numbers: ChaCha20 keyed with bytes the host draws from the
// OS generator, so crypto.getRandomValues, uuid and CryptoJS work.

const rng = { state: new Uint32Array(16), out: new Uint8Array(64), pos: 64 };

function seedRandom(bytes) {
  const st = rng.state;
  st.set([0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]);
  const b = new Uint8Array(44);
  for (let i = 0; i < 44; i++) b[i] = (bytes && bytes[i]) | 0;
  if (!bytes || bytes.length < 44) {
    // No seed from the host (should not happen): fall back to Math.random.
    for (let i = 0; i < 44; i++) b[i] ^= (Math.random() * 256) | 0;
  }
  const dv = new DataView(b.buffer);
  for (let i = 0; i < 8; i++) st[4 + i] = dv.getUint32(i * 4, true);
  st[12] = 0;
  for (let i = 0; i < 3; i++) st[13 + i] = dv.getUint32(32 + i * 4, true);
  rng.pos = 64;
}

function chachaBlock() {
  const st = rng.state;
  const x = new Uint32Array(st);
  const r = (v, c) => (v << c) | (v >>> (32 - c));
  const q = (a, b, c, d) => {
    x[a] += x[b];
    x[d] = r(x[d] ^ x[a], 16);
    x[c] += x[d];
    x[b] = r(x[b] ^ x[c], 12);
    x[a] += x[b];
    x[d] = r(x[d] ^ x[a], 8);
    x[c] += x[d];
    x[b] = r(x[b] ^ x[c], 7);
  };
  for (let i = 0; i < 10; i++) {
    q(0, 4, 8, 12);
    q(1, 5, 9, 13);
    q(2, 6, 10, 14);
    q(3, 7, 11, 15);
    q(0, 5, 10, 15);
    q(1, 6, 11, 12);
    q(2, 7, 8, 13);
    q(3, 4, 9, 14);
  }
  const dv = new DataView(rng.out.buffer);
  for (let i = 0; i < 16; i++) dv.setUint32(i * 4, (x[i] + st[i]) >>> 0, true);
  st[12] = (st[12] + 1) >>> 0;
  if (st[12] === 0) st[13] = (st[13] + 1) >>> 0;
  rng.pos = 0;
}

function getRandomValues(arr) {
  if (!ArrayBuffer.isView(arr) || arr instanceof Float32Array || arr instanceof Float64Array || arr instanceof DataView) {
    throw new TypeError('getRandomValues expects an integer typed array');
  }
  if (arr.byteLength > 65536) {
    throw new RangeError('getRandomValues can fill at most 65536 bytes');
  }
  const bytes = new Uint8Array(arr.buffer, arr.byteOffset, arr.byteLength);
  for (let i = 0; i < bytes.length; i++) {
    if (rng.pos === 64) chachaBlock();
    bytes[i] = rng.out[rng.pos++];
  }
  return arr;
}

function uuidV4() {
  const b = getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = Array.from(b, (x) => (x + 0x100).toString(16).slice(1)).join('');
  return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
}

const crypto = { getRandomValues: getRandomValues, randomUUID: uuidV4 };

// ---------------------------------------------------------------------------
// Text, Buffer and URL helpers that browsers and Node have and QuickJS lacks

function utf8Encode(s) {
  s = String(s);
  const out = [];
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const d = s.charCodeAt(i + 1);
      if (d >= 0xdc00 && d <= 0xdfff) {
        c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
        i++;
      } else c = 0xfffd;
    } else if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd;
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  return new Uint8Array(out);
}

function utf8Decode(bytes) {
  let s = '';
  const n = bytes.length;
  for (let i = 0; i < n; ) {
    const b = bytes[i++];
    let c = 0xfffd;
    if (b < 0x80) c = b;
    else if (b >= 0xc2 && b < 0xe0 && i < n && (bytes[i] & 0xc0) === 0x80) {
      c = ((b & 31) << 6) | (bytes[i++] & 63);
    } else if (b >= 0xe0 && b < 0xf0 && i + 1 < n && (bytes[i] & 0xc0) === 0x80 && (bytes[i + 1] & 0xc0) === 0x80) {
      c = ((b & 15) << 12) | ((bytes[i] & 63) << 6) | (bytes[i + 1] & 63);
      i += 2;
      if (c < 0x800) c = 0xfffd;
    } else if (b >= 0xf0 && b < 0xf5 && i + 2 < n && (bytes[i] & 0xc0) === 0x80 && (bytes[i + 1] & 0xc0) === 0x80 && (bytes[i + 2] & 0xc0) === 0x80) {
      c = ((b & 7) << 18) | ((bytes[i] & 63) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63);
      i += 3;
      if (c < 0x10000 || c > 0x10ffff) c = 0xfffd;
    }
    s += String.fromCodePoint(c);
  }
  return s;
}

function bytesToBinary(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 8192) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
  }
  return s;
}

function base64ToBytes(s) {
  s = String(s).replace(/[\s=]+/g, '').replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  const bin = G.atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

class TextEncoder {
  get encoding() {
    return 'utf-8';
  }
  encode(s) {
    return utf8Encode(s === undefined ? '' : s);
  }
}

class TextDecoder {
  constructor(label) {
    const l = String(label === undefined ? 'utf-8' : label).toLowerCase();
    if (l !== 'utf-8' && l !== 'utf8') throw new RangeError('Only utf-8 is supported');
  }
  get encoding() {
    return 'utf-8';
  }
  decode(input) {
    if (input === undefined) return '';
    const bytes = input instanceof ArrayBuffer ? new Uint8Array(input) : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    let s = utf8Decode(bytes);
    if (s.charCodeAt(0) === 0xfeff) s = s.slice(1);
    return s;
  }
}

function encodeString(s, enc) {
  s = String(s);
  switch (String(enc || 'utf8').toLowerCase()) {
    case 'hex': {
      const n = s.length >> 1;
      const out = new Uint8Array(n);
      for (let i = 0; i < n; i++) {
        const v = parseInt(s.substr(i * 2, 2), 16);
        if (isNaN(v)) return out.subarray(0, i);
        out[i] = v;
      }
      return out;
    }
    case 'base64':
    case 'base64url':
      return base64ToBytes(s);
    case 'latin1':
    case 'binary':
    case 'ascii': {
      const out = new Uint8Array(s.length);
      for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i) & 0xff;
      return out;
    }
    default:
      return utf8Encode(s);
  }
}

class Buffer extends Uint8Array {
  static from(v, enc) {
    if (typeof v === 'string') {
      const b = encodeString(v, enc);
      return new Buffer(b.buffer, b.byteOffset, b.length);
    }
    if (v instanceof ArrayBuffer) return new Buffer(v);
    if (ArrayBuffer.isView(v) || Array.isArray(v)) {
      const b = new Buffer(v.length);
      b.set(v);
      return b;
    }
    if (isObject(v) && v.type === 'Buffer' && Array.isArray(v.data)) return Buffer.from(v.data);
    throw new TypeError('Buffer.from expects a string, array or buffer');
  }
  static alloc(n, fill) {
    const b = new Buffer(n);
    if (fill !== undefined) b.fill(typeof fill === 'string' ? fill.charCodeAt(0) : fill);
    return b;
  }
  static isBuffer(b) {
    return b instanceof Buffer;
  }
  static byteLength(s, enc) {
    return typeof s === 'string' ? encodeString(s, enc).length : s.byteLength;
  }
  static concat(list, total) {
    const n = total === undefined ? list.reduce((a, b) => a + b.length, 0) : total;
    const out = new Buffer(n);
    let o = 0;
    for (const b of list) {
      if (o >= n) break;
      out.set(b.subarray(0, n - o), o);
      o += b.length;
    }
    return out;
  }
  toString(enc, start, end) {
    const b = this.subarray(start || 0, end === undefined ? this.length : end);
    switch (String(enc || 'utf8').toLowerCase()) {
      case 'hex':
        return Array.from(b, (x) => (x + 0x100).toString(16).slice(1)).join('');
      case 'base64':
        return G.btoa(bytesToBinary(b));
      case 'base64url':
        return G.btoa(bytesToBinary(b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
      case 'latin1':
      case 'binary':
        return bytesToBinary(b);
      case 'ascii':
        return bytesToBinary(b.map((x) => x & 0x7f));
      default:
        return utf8Decode(b);
    }
  }
  equals(other) {
    if (!other || other.length !== this.length) return false;
    for (let i = 0; i < this.length; i++) if (this[i] !== other[i]) return false;
    return true;
  }
  toJSON() {
    return { type: 'Buffer', data: Array.from(this) };
  }
}

function formDecode(s) {
  const t = s.replace(/\+/g, ' ');
  try {
    return decodeURIComponent(t);
  } catch (e) {
    return t;
  }
}

function formEncode(s) {
  return encodeURIComponent(s).replace(/%20/g, '+').replace(/[!'()~]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase());
}

class URLSearchParams {
  constructor(init) {
    Object.defineProperty(this, '_list', { value: [], writable: true });
    Object.defineProperty(this, '_owner', { value: null, writable: true });
    if (init === undefined || init === null) return;
    if (init instanceof URLSearchParams) this._list = init._list.map((p) => p.slice());
    else if (typeof init === 'string') this._parse(init);
    else if (Array.isArray(init) || typeof init[Symbol.iterator] === 'function') {
      for (const p of init) this._list.push([String(p[0]), String(p[1])]);
    } else if (isObject(init)) {
      for (const k of Object.keys(init)) this._list.push([k, String(init[k])]);
    }
  }
  _parse(s) {
    this._list = [];
    s = String(s);
    if (s.charAt(0) === '?') s = s.slice(1);
    for (const part of s.split('&')) {
      if (!part) continue;
      const i = part.indexOf('=');
      this._list.push(i < 0 ? [formDecode(part), ''] : [formDecode(part.slice(0, i)), formDecode(part.slice(i + 1))]);
    }
  }
  _changed() {
    if (this._owner) this._owner._search = this._list.length ? '?' + this.toString() : '';
  }
  get size() {
    return this._list.length;
  }
  append(k, v) {
    this._list.push([String(k), String(v)]);
    this._changed();
  }
  delete(k) {
    this._list = this._list.filter((p) => p[0] !== String(k));
    this._changed();
  }
  get(k) {
    const p = this._list.find((x) => x[0] === String(k));
    return p ? p[1] : null;
  }
  getAll(k) {
    return this._list.filter((x) => x[0] === String(k)).map((x) => x[1]);
  }
  has(k) {
    return this._list.some((x) => x[0] === String(k));
  }
  set(k, v) {
    k = String(k);
    const i = this._list.findIndex((x) => x[0] === k);
    if (i < 0) this._list.push([k, String(v)]);
    else {
      this._list[i][1] = String(v);
      this._list = this._list.filter((x, j) => j <= i || x[0] !== k);
    }
    this._changed();
  }
  sort() {
    this._list.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
    this._changed();
  }
  forEach(fn, thisArg) {
    for (const [k, v] of this._list) fn.call(thisArg, v, k, this);
  }
  keys() {
    return this._list.map((p) => p[0])[Symbol.iterator]();
  }
  values() {
    return this._list.map((p) => p[1])[Symbol.iterator]();
  }
  entries() {
    return this._list.map((p) => p.slice())[Symbol.iterator]();
  }
  [Symbol.iterator]() {
    return this.entries();
  }
  toString() {
    return this._list.map((p) => formEncode(p[0]) + '=' + formEncode(p[1])).join('&');
  }
}

const URL_RE = /^([a-zA-Z][a-zA-Z0-9+.\-]*:)(?:\/\/(?:([^:@\/?#]*)(?::([^@\/?#]*))?@)?(\[[^\]]*\]|[^:\/?#]*)(?::(\d*))?)?([^?#]*)(\?[^#]*)?(#.*)?$/;
const DEFAULT_PORTS = { 'http:': '80', 'https:': '443', 'ws:': '80', 'wss:': '443', 'ftp:': '21' };

class URL {
  constructor(url, base) {
    url = String(url);
    let m = URL_RE.exec(url);
    if (!m && base !== undefined) m = URL_RE.exec(URL._resolve(url, new URL(base)));
    if (!m) throw new TypeError('Invalid URL: ' + url);
    Object.defineProperty(this, '_sp', { value: new URLSearchParams(), writable: true });
    this._sp._owner = this;
    this._protocol = m[1].toLowerCase();
    this._username = m[2] || '';
    this._password = m[3] || '';
    this._hostname = (m[4] || '').toLowerCase();
    this._port = m[5] && m[5] !== DEFAULT_PORTS[this._protocol] ? m[5] : '';
    this._pathname = m[6] || (this._hostname ? '/' : '');
    this._hash = m[8] && m[8] !== '#' ? m[8] : '';
    this.search = m[7] && m[7] !== '?' ? m[7] : '';
    for (const k of Object.keys(this)) Object.defineProperty(this, k, { enumerable: false });
  }
  static _resolve(rel, base) {
    if (rel.charAt(0) === '#') return base.href.replace(/#.*$/, '') + rel;
    if (rel.charAt(0) === '?') return base.origin + base.pathname + rel;
    if (rel.slice(0, 2) === '//') return base.protocol + rel;
    if (rel.charAt(0) === '/') return base.origin + rel;
    const dir = base.pathname.replace(/[^/]*$/, '');
    const parts = [];
    for (const seg of (dir + rel).split('/')) {
      if (seg === '..') parts.pop();
      else if (seg !== '.') parts.push(seg);
    }
    return base.origin + parts.join('/');
  }
  get protocol() {
    return this._protocol;
  }
  set protocol(v) {
    this._protocol = String(v).replace(/:?$/, ':').toLowerCase();
  }
  get username() {
    return this._username;
  }
  set username(v) {
    this._username = String(v);
  }
  get password() {
    return this._password;
  }
  set password(v) {
    this._password = String(v);
  }
  get hostname() {
    return this._hostname;
  }
  set hostname(v) {
    this._hostname = String(v).toLowerCase();
  }
  get port() {
    return this._port;
  }
  set port(v) {
    v = String(v);
    this._port = v === DEFAULT_PORTS[this._protocol] ? '' : v;
  }
  get host() {
    return this._hostname + (this._port ? ':' + this._port : '');
  }
  set host(v) {
    const m = /^(\[[^\]]*\]|[^:]*)(?::(\d*))?$/.exec(String(v));
    if (m) {
      this.hostname = m[1];
      this.port = m[2] || '';
    }
  }
  get origin() {
    return this._hostname ? this._protocol + '//' + this.host : 'null';
  }
  get pathname() {
    return this._pathname;
  }
  set pathname(v) {
    v = String(v);
    this._pathname = v.charAt(0) === '/' || !this._hostname ? v : '/' + v;
  }
  get search() {
    return this._search;
  }
  set search(v) {
    v = String(v);
    if (v && v.charAt(0) !== '?') v = '?' + v;
    this._search = v === '?' ? '' : v;
    this._sp._parse(this._search);
  }
  get searchParams() {
    return this._sp;
  }
  get hash() {
    return this._hash;
  }
  set hash(v) {
    v = String(v);
    if (v && v.charAt(0) !== '#') v = '#' + v;
    this._hash = v === '#' ? '' : v;
  }
  get href() {
    const auth = this._username || this._password ? this._username + (this._password ? ':' + this._password : '') + '@' : '';
    const slashes = this._hostname || this._protocol === 'file:' ? '//' : '';
    return this._protocol + slashes + auth + this.host + this._pathname + this._search + this._hash;
  }
  set href(v) {
    const u = new URL(v);
    for (const k of ['protocol', 'username', 'password', 'hostname', 'port', 'pathname', 'search', 'hash']) this[k] = u[k];
  }
  toString() {
    return this.href;
  }
  toJSON() {
    return this.href;
  }
}

// ---------------------------------------------------------------------------
// Timers

function addTimer(fn, ms, args, repeat) {
  if (typeof fn !== 'function') throw new TypeError('The callback must be a function');
  const delay = Math.max(repeat ? 1 : 0, Number(ms) || 0);
  const id = ++S.timerSeq;
  S.timers.push({ id: id, due: Date.now() + delay, ms: delay, fn: fn, args: args, repeat: repeat });
  return id;
}

function clearTimer(id) {
  const t = isObject(id) ? id.id : id;
  S.timers = S.timers.filter((x) => x.id !== t);
}

function nextTimerDelay() {
  if (!S.timers.length) return null;
  let due = Infinity;
  for (const t of S.timers) due = Math.min(due, t.due);
  return Math.max(0, due - Date.now());
}

const timers = {
  setTimeout: (fn, ms, ...args) => addTimer(fn, ms, args, false),
  setInterval: (fn, ms, ...args) => addTimer(fn, ms, args, true),
  setImmediate: (fn, ...args) => addTimer(fn, 0, args, false),
  clearTimeout: clearTimer,
  clearInterval: clearTimer,
  clearImmediate: clearTimer,
};

// ---------------------------------------------------------------------------
// Postman collection SDK subset: property lists, URL, body, auth, request,
// response, cookies

function defineHidden(obj, key, value) {
  Object.defineProperty(obj, key, { value: value, writable: true, configurable: true, enumerable: false });
}

class KeyValue {
  constructor(o, value) {
    if (typeof o === 'string') o = value === undefined ? this.constructor.parse(o) : { key: o, value: value };
    this.update(o || {});
  }
  static parse(s) {
    return { key: s, value: '' };
  }
  update(o) {
    if (o.key !== undefined) this.key = o.key === null ? null : String(o.key);
    if (o.value !== undefined) this.value = o.value;
    else if (!('value' in this)) this.value = '';
    if (o.disabled !== undefined) {
      if (o.disabled) this.disabled = true;
      else delete this.disabled;
    }
    if (o.description !== undefined) {
      this.description = isObject(o.description) ? o.description.content : o.description;
    }
  }
  valueOf() {
    return this.value;
  }
  toString() {
    return this.key + '=' + this.value;
  }
  toJSON() {
    const j = { key: this.key, value: this.value };
    if (this.disabled) j.disabled = true;
    if (this.description) j.description = this.description;
    return j;
  }
}

class Header extends KeyValue {
  static parse(s) {
    const i = s.indexOf(':');
    return i < 0 ? { key: s.trim(), value: '' } : { key: s.slice(0, i).trim(), value: s.slice(i + 1).trim() };
  }
  toString() {
    return this.key + ': ' + this.value;
  }
}

class QueryParam extends KeyValue {
  static parse(s) {
    const i = s.indexOf('=');
    return i < 0 ? { key: s, value: null } : { key: s.slice(0, i), value: s.slice(i + 1) };
  }
  toString() {
    return this.value === null || this.value === undefined ? String(this.key) : this.key + '=' + this.value;
  }
}

class Variable extends KeyValue {
  update(o) {
    super.update(o);
    if (o.type !== undefined) this.type = o.type;
  }
  toJSON() {
    const j = super.toJSON();
    if (this.type) j.type = this.type;
    return j;
  }
}

class FormParam extends KeyValue {
  update(o) {
    super.update(o);
    for (const k of ['type', 'src', 'contentType']) if (o[k] !== undefined) this[k] = o[k];
  }
  toJSON() {
    const j = super.toJSON();
    for (const k of ['type', 'src', 'contentType']) if (this[k] !== undefined) j[k] = this[k];
    return j;
  }
}

class Cookie {
  constructor(o) {
    if (typeof o === 'string') o = Cookie.parse(o);
    o = o || {};
    this.name = o.name !== undefined ? o.name : o.key;
    this.value = o.value === undefined ? '' : o.value;
    for (const k of ['domain', 'path', 'expires', 'maxAge', 'secure', 'httpOnly', 'hostOnly', 'session', 'sameSite']) {
      if (o[k] !== undefined) this[k] = o[k];
    }
  }
  static parse(s) {
    const parts = String(s).split(';');
    const first = parts.shift();
    const i = first.indexOf('=');
    const c = { name: (i < 0 ? first : first.slice(0, i)).trim(), value: i < 0 ? '' : first.slice(i + 1).trim() };
    for (const p of parts) {
      const j = p.indexOf('=');
      const k = (j < 0 ? p : p.slice(0, j)).trim().toLowerCase();
      const v = j < 0 ? true : p.slice(j + 1).trim();
      if (k === 'domain') c.domain = v;
      else if (k === 'path') c.path = v;
      else if (k === 'expires') c.expires = v;
      else if (k === 'max-age') c.maxAge = Number(v);
      else if (k === 'secure') c.secure = true;
      else if (k === 'httponly') c.httpOnly = true;
      else if (k === 'samesite') c.sameSite = v;
    }
    return c;
  }
  get key() {
    return this.name;
  }
  valueOf() {
    return this.value;
  }
  toString() {
    return this.name + '=' + this.value;
  }
  toJSON() {
    return Object.assign({}, this);
  }
}

class PropertyList {
  constructor(Type, items, caseInsensitive, separator) {
    defineHidden(this, '_Type', Type);
    defineHidden(this, '_ci', !!caseInsensitive);
    defineHidden(this, '_sep', separator === undefined ? '\n' : separator);
    this.members = [];
    if (items !== undefined && items !== null) this.populate(items);
  }
  static isPropertyList(o) {
    return o instanceof PropertyList;
  }
  _norm(k) {
    return this._ci && typeof k === 'string' ? k.toLowerCase() : k;
  }
  _make(item) {
    return item instanceof this._Type ? item : new this._Type(item);
  }
  _matches(m, key) {
    return this._norm(m.key) === this._norm(key);
  }
  _index(ref) {
    if (typeof ref === 'string') return this.members.findIndex((m) => this._matches(m, ref));
    return this.members.indexOf(ref);
  }
  add(item) {
    if (item === undefined || item === null) return;
    this.members.push(this._make(item));
  }
  append(item) {
    this.add(item);
  }
  prepend(item) {
    if (item === undefined || item === null) return;
    this.members.unshift(this._make(item));
  }
  insert(item, before) {
    const i = before === undefined ? -1 : this._index(before);
    if (i < 0) this.add(item);
    else this.members.splice(i, 0, this._make(item));
  }
  insertAfter(item, after) {
    const i = after === undefined ? -1 : this._index(after);
    if (i < 0) this.add(item);
    else this.members.splice(i + 1, 0, this._make(item));
  }
  upsert(item) {
    if (item === undefined || item === null) return;
    const made = this._make(item);
    const existing = this.one(made.key);
    if (existing) {
      if (typeof existing.update === 'function') existing.update(isObject(item) && !(item instanceof this._Type) ? item : made.toJSON());
      else Object.assign(existing, made);
      return false;
    }
    this.members.push(made);
    return true;
  }
  remove(predicate, context) {
    let keep;
    if (typeof predicate === 'function') keep = (m) => !predicate.call(context, m);
    else if (typeof predicate === 'string') keep = (m) => !this._matches(m, predicate);
    else if (isObject(predicate)) keep = (m) => m !== predicate && !(predicate.key !== undefined && this._matches(m, predicate.key));
    else return;
    this.members = this.members.filter(keep);
  }
  clear() {
    this.members = [];
  }
  populate(items) {
    if (items instanceof PropertyList) items = items.members;
    if (typeof items === 'string') {
      for (const line of items.split(this._sep === '&' ? '&' : /\r?\n/)) if (line.trim()) this.add(line);
    } else if (Array.isArray(items)) {
      for (const it of items) this.add(it);
    } else if (isObject(items)) {
      for (const k of Object.keys(items)) {
        const v = items[k];
        if (Array.isArray(v)) for (const x of v) this.add({ key: k, value: x });
        else this.add({ key: k, value: v });
      }
    }
  }
  repopulate(items) {
    this.clear();
    this.populate(items);
  }
  assimilate(source, prune) {
    const list = source instanceof PropertyList ? source.members : Array.isArray(source) ? source : [];
    for (const it of list) this.upsert(it);
    if (prune) {
      const keys = list.map((x) => this._norm(x.key));
      this.members = this.members.filter((m) => keys.indexOf(this._norm(m.key)) >= 0);
    }
  }
  all() {
    return this.members.slice();
  }
  one(key) {
    for (let i = this.members.length - 1; i >= 0; i--) if (this._matches(this.members[i], key)) return this.members[i];
    return undefined;
  }
  get(key) {
    const m = this.one(key);
    return m === undefined ? undefined : m.valueOf();
  }
  has(key, value) {
    const k = isObject(key) ? key.key : key;
    if (arguments.length < 2) return this.members.some((m) => this._matches(m, k));
    return this.members.some((m) => this._matches(m, k) && m.valueOf() === value);
  }
  idx(i) {
    return this.members[i];
  }
  indexOf(item) {
    return this._index(item);
  }
  count() {
    return this.members.length;
  }
  each(fn, context) {
    this.members.slice().forEach((m) => fn.call(context, m));
  }
  filter(fn, context) {
    return this.members.filter((m) => fn.call(context, m));
  }
  find(fn, context) {
    return this.members.find((m) => fn.call(context, m));
  }
  map(fn, context) {
    return this.members.map((m) => fn.call(context, m));
  }
  reduce(fn, acc, context) {
    return this.members.reduce((a, m) => fn.call(context, a, m), acc);
  }
  toObject(excludeDisabled, caseSensitive, multiValue) {
    const o = {};
    for (const m of this.members) {
      if (excludeDisabled && m.disabled) continue;
      if (m.key === undefined || m.key === null) continue;
      const k = this._ci && !caseSensitive ? String(m.key).toLowerCase() : m.key;
      const v = m.valueOf();
      if (multiValue && hasOwn(o, k)) o[k] = [].concat(o[k], v);
      else o[k] = v;
    }
    return o;
  }
  toString() {
    return this.members.filter((m) => !m.disabled).map((m) => m.toString()).join(this._sep);
  }
  toJSON() {
    return this.members.map((m) => (typeof m.toJSON === 'function' ? m.toJSON() : m));
  }
  [Symbol.iterator]() {
    return this.members[Symbol.iterator]();
  }
}

function listJSON(v) {
  if (v instanceof PropertyList) return v.toJSON();
  if (Array.isArray(v)) return v.map((x) => (x && typeof x.toJSON === 'function' ? x.toJSON() : x));
  return v;
}

class Url {
  constructor(o) {
    this.update(o === undefined ? '' : o);
  }
  static parse(raw) {
    raw = String(raw).trim();
    const o = { raw: raw };
    let rest = raw;
    let i = rest.indexOf('#');
    if (i >= 0) {
      o.hash = rest.slice(i + 1);
      rest = rest.slice(0, i);
    }
    i = rest.indexOf('?');
    if (i >= 0) {
      o.query = rest
        .slice(i + 1)
        .split('&')
        .filter((p) => p !== '')
        .map((p) => QueryParam.parse(p));
      rest = rest.slice(0, i);
    }
    const m = /^([A-Za-z][A-Za-z0-9+.\-]*):\/\//.exec(rest);
    if (m) {
      o.protocol = m[1];
      rest = rest.slice(m[0].length);
    }
    i = rest.indexOf('/');
    let host = i >= 0 ? rest.slice(0, i) : rest;
    o.path = i >= 0 ? rest.slice(i + 1).split('/') : [];
    const at = host.lastIndexOf('@');
    if (at >= 0) {
      const a = host.slice(0, at);
      const c = a.indexOf(':');
      o.auth = c >= 0 ? { user: a.slice(0, c), password: a.slice(c + 1) } : { user: a };
      host = host.slice(at + 1);
    }
    const close = host.lastIndexOf(']');
    const colon = host.lastIndexOf(':');
    if (colon > close) {
      const port = host.slice(colon + 1);
      if (/^(\d*|\{\{[^{}]+\}\})$/.test(port)) {
        o.port = port;
        host = host.slice(0, colon);
      }
    }
    o.host = host === '' ? [] : host.charAt(0) === '[' ? [host] : host.split('.');
    return o;
  }
  update(o) {
    if (o instanceof Url) o = o.toJSON();
    if (typeof o === 'string') o = Url.parse(o);
    else if (isObject(o) && typeof o.raw === 'string' && o.host === undefined) {
      const p = Url.parse(o.raw);
      if (o.query !== undefined) p.query = o.query;
      if (o.variable !== undefined) p.variable = o.variable;
      o = p;
    }
    o = o || {};
    const split = (v, sep) => (v === undefined || v === null ? [] : Array.isArray(v) ? v.map(String) : String(v) === '' ? [] : String(v).split(sep));
    this.protocol = o.protocol;
    this.auth = o.auth;
    this.host = split(o.host, '.');
    this.port = o.port;
    this.path = split(o.path, '/');
    this.hash = o.hash;
    this.query = new PropertyList(QueryParam, o.query || [], false, '&');
    this.variables = new PropertyList(Variable, o.variable || o.variables || [], false);
  }
  getHost() {
    return this.host.join('.');
  }
  getPath(unresolved) {
    if (!this.path.length) return '';
    const vars = this.variables;
    return (
      '/' +
      this.path
        .map((seg) => {
          if (unresolved || seg.length < 2 || seg.charAt(0) !== ':') return seg;
          const v = vars.get(seg.slice(1));
          return v === undefined || v === null || v === '' ? seg : String(v);
        })
        .join('/')
    );
  }
  getQueryString() {
    return this.query.toString();
  }
  getPathWithQuery(unresolved) {
    const q = this.getQueryString();
    return (this.getPath(unresolved) || '/') + (q ? '?' + q : '');
  }
  getRemote(forcePort) {
    const port = this.port || (forcePort ? (this.protocol === 'https' ? '443' : '80') : '');
    return this.getHost() + (port ? ':' + port : '');
  }
  getRaw() {
    return this.toString();
  }
  addQueryParams(params) {
    if (typeof params === 'string') params = params.split('&').filter(Boolean).map((p) => QueryParam.parse(p));
    this.query.populate(params);
  }
  removeQueryParams(params) {
    const keys = [].concat(params).map((p) => (isObject(p) ? p.key : p));
    this.query.remove((q) => keys.indexOf(q.key) >= 0);
  }
  /** Everything but the query: the ApiWorkbench URL field. */
  _base(unresolved) {
    let s = '';
    if (this.protocol) s += String(this.protocol).replace(/:?(\/\/)?$/, '') + '://';
    if (this.auth && (this.auth.user || this.auth.password)) {
      s += (this.auth.user || '') + (this.auth.password ? ':' + this.auth.password : '') + '@';
    }
    s += this.getHost();
    if (this.port !== undefined && this.port !== null && this.port !== '') s += ':' + this.port;
    s += this.getPath(unresolved === undefined ? true : unresolved);
    return s;
  }
  toString(forceProtocol) {
    let s = this._base(false);
    if (!this.protocol && forceProtocol) s = 'http://' + s;
    const q = this.getQueryString();
    if (q) s += '?' + q;
    if (this.hash) s += '#' + this.hash;
    return s;
  }
  toJSON() {
    const j = { raw: this.toString(), host: this.host.slice(), path: this.path.slice() };
    if (this.protocol) j.protocol = this.protocol;
    if (this.port) j.port = this.port;
    if (this.hash) j.hash = this.hash;
    if (this.auth) j.auth = this.auth;
    j.query = this.query.toJSON();
    j.variable = this.variables.toJSON();
    return j;
  }
}

class RequestBody {
  constructor(o) {
    this.update(o);
  }
  update(o) {
    for (const k of ['mode', 'raw', 'urlencoded', 'formdata', 'file', 'graphql', 'options', 'disabled']) delete this[k];
    if (o === undefined || o === null) return;
    if (typeof o === 'string') {
      this.mode = 'raw';
      this.raw = o;
      return;
    }
    if (o instanceof RequestBody) o = o.toJSON();
    if (o.mode !== undefined) this.mode = o.mode;
    if (o.raw !== undefined) this.raw = typeof o.raw === 'string' ? o.raw : JSON.stringify(o.raw);
    if (o.urlencoded !== undefined) this.urlencoded = new PropertyList(QueryParam, o.urlencoded, false, '&');
    if (o.formdata !== undefined) this.formdata = new PropertyList(FormParam, o.formdata, false);
    if (o.file !== undefined) this.file = typeof o.file === 'string' ? { src: o.file } : Object.assign({}, o.file);
    if (o.graphql !== undefined) this.graphql = Object.assign({}, o.graphql);
    if (o.options !== undefined) this.options = JSON.parse(JSON.stringify(o.options));
    if (o.disabled) this.disabled = true;
    if (this.mode === undefined) {
      for (const m of ['raw', 'urlencoded', 'formdata', 'file', 'graphql']) {
        if (this[m] !== undefined) {
          this.mode = m;
          break;
        }
      }
    }
  }
  isEmpty() {
    switch (this.mode) {
      case 'raw':
        return !this.raw;
      case 'urlencoded':
      case 'formdata': {
        const l = this[this.mode];
        return !l || (l instanceof PropertyList ? l.count() === 0 : !l.length);
      }
      case 'file':
        return !(this.file && this.file.src);
      case 'graphql':
        return !(this.graphql && this.graphql.query);
      default:
        return true;
    }
  }
  toString() {
    switch (this.mode) {
      case 'raw':
        return this.raw || '';
      case 'urlencoded':
        return this.urlencoded instanceof PropertyList ? this.urlencoded.toString() : '';
      case 'graphql':
        return JSON.stringify(this.graphql || {});
      default:
        return '';
    }
  }
  toJSON() {
    const j = {};
    if (this.mode !== undefined) j.mode = this.mode;
    if (this.raw !== undefined) j.raw = this.raw;
    if (this.urlencoded !== undefined) j.urlencoded = listJSON(this.urlencoded);
    if (this.formdata !== undefined) j.formdata = listJSON(this.formdata);
    if (this.file !== undefined) j.file = this.file;
    if (this.graphql !== undefined) j.graphql = this.graphql;
    if (this.options !== undefined) j.options = this.options;
    if (this.disabled) j.disabled = true;
    return j;
  }
}

class RequestAuth {
  constructor(o) {
    this.type = 'noauth';
    if (o) this.update(o);
  }
  _list(type) {
    if (!(this[type] instanceof PropertyList)) {
      this[type] = new PropertyList(Variable, Array.isArray(this[type]) ? this[type] : [], false);
    }
    return this[type];
  }
  update(options, type) {
    if (options instanceof RequestAuth) options = options.toJSON();
    if (isObject(options) && !Array.isArray(options) && options.type !== undefined && type === undefined) {
      this.type = String(options.type);
      for (const k of Object.keys(options)) {
        if (k !== 'type') this[k] = new PropertyList(Variable, listJSON(options[k]), false);
      }
      return;
    }
    const list = this._list(type === undefined ? this.type : type);
    if (Array.isArray(options) || options instanceof PropertyList) {
      for (const p of listJSON(options)) list.upsert({ key: p.key, value: p.value });
    } else if (isObject(options)) {
      for (const k of Object.keys(options)) list.upsert({ key: k, value: options[k] });
    }
  }
  use(type, options) {
    this.type = String(type);
    this._list(this.type);
    if (options !== undefined) this.update(options, this.type);
  }
  current() {
    return this.type;
  }
  parameters() {
    return this._list(this.type);
  }
  clear(type) {
    if (type !== undefined && type !== 'type') delete this[type];
  }
  toJSON() {
    const j = { type: this.type };
    for (const k of Object.keys(this)) if (k !== 'type' && this[k] !== undefined) j[k] = listJSON(this[k]);
    return j;
  }
}

function headerList(v) {
  return v instanceof PropertyList ? v : new PropertyList(Header, v === undefined ? [] : v, true);
}

class Request {
  constructor(o) {
    if (typeof o === 'string' || o instanceof Url) o = { url: o };
    if (o instanceof Request) o = o.toJSON();
    o = o || {};
    if (o.id !== undefined) this.id = o.id;
    if (o.name !== undefined) this.name = o.name;
    if (o.description !== undefined) this.description = o.description;
    this.method = o.method ? String(o.method).toUpperCase() : 'GET';
    this.url = o.url === undefined ? '' : o.url;
    this.headers = o.header !== undefined ? o.header : o.headers;
    this.body = o.body;
    this.auth = o.auth;
  }
  get url() {
    return this._url;
  }
  set url(v) {
    defineHidden(this, '_url', v instanceof Url ? v : new Url(v));
  }
  get headers() {
    return this._headers;
  }
  set headers(v) {
    defineHidden(this, '_headers', headerList(v));
  }
  get body() {
    return this._body;
  }
  set body(v) {
    defineHidden(this, '_body', v instanceof RequestBody ? v : new RequestBody(v));
  }
  get auth() {
    return this._auth;
  }
  set auth(v) {
    defineHidden(this, '_auth', v instanceof RequestAuth ? v : new RequestAuth(v));
  }
  getHeaders(options) {
    options = options || {};
    const o = {};
    for (const h of this.headers.members) {
      if (options.enabled && h.disabled) continue;
      const k = options.ignoreCase ? String(h.key).toLowerCase() : h.key;
      o[k] = hasOwn(o, k) ? [].concat(o[k], h.value) : h.value;
    }
    return o;
  }
  forEachHeader(fn, context) {
    this.headers.each(fn, context);
  }
  addHeader(h) {
    this.headers.add(h);
  }
  upsertHeader(h) {
    this.headers.upsert(h);
  }
  removeHeader(h, options) {
    const key = isObject(h) ? h.key : h;
    if (options && options.ignoreCase === false) this.headers.remove((x) => x.key === key);
    else this.headers.remove(key);
  }
  addQueryParams(p) {
    this.url.addQueryParams(p);
  }
  removeQueryParams(p) {
    this.url.removeQueryParams(p);
  }
  authorizeUsing(type, options) {
    if (isObject(type)) this.auth = type;
    else this.auth.use(type, options);
  }
  clone() {
    return new Request(this.toJSON());
  }
  get to() {
    return getChai().expect(this).to;
  }
  toJSON() {
    const j = { method: this.method, url: this.url.toJSON(), header: this.headers.toJSON() };
    if (this.id !== undefined) j.id = this.id;
    if (this.name !== undefined) j.name = this.name;
    if (this.description !== undefined) j.description = this.description;
    if (this.body && this.body.mode !== undefined) j.body = this.body.toJSON();
    j.auth = this.auth.toJSON();
    return j;
  }
}

const REASONS = {
  100: 'Continue', 101: 'Switching Protocols', 200: 'OK', 201: 'Created', 202: 'Accepted',
  203: 'Non-Authoritative Information', 204: 'No Content', 205: 'Reset Content', 206: 'Partial Content',
  300: 'Multiple Choices', 301: 'Moved Permanently', 302: 'Found', 303: 'See Other', 304: 'Not Modified',
  307: 'Temporary Redirect', 308: 'Permanent Redirect', 400: 'Bad Request', 401: 'Unauthorized',
  402: 'Payment Required', 403: 'Forbidden', 404: 'Not Found', 405: 'Method Not Allowed',
  406: 'Not Acceptable', 407: 'Proxy Authentication Required', 408: 'Request Timeout', 409: 'Conflict',
  410: 'Gone', 411: 'Length Required', 412: 'Precondition Failed', 413: 'Payload Too Large',
  414: 'URI Too Long', 415: 'Unsupported Media Type', 416: 'Range Not Satisfiable',
  417: 'Expectation Failed', 418: "I'm a teapot", 422: 'Unprocessable Entity', 423: 'Locked',
  425: 'Too Early', 426: 'Upgrade Required', 428: 'Precondition Required', 429: 'Too Many Requests',
  431: 'Request Header Fields Too Large', 451: 'Unavailable For Legal Reasons',
  500: 'Internal Server Error', 501: 'Not Implemented', 502: 'Bad Gateway', 503: 'Service Unavailable',
  504: 'Gateway Timeout', 505: 'HTTP Version Not Supported',
};

class Response {
  constructor(r) {
    r = r || {};
    if (r.id !== undefined) this.id = r.id;
    this.code = Number(r.code) || 0;
    this.status = r.status || REASONS[this.code] || '';
    this.headers = new PropertyList(Header, r.header || r.headers || [], true);
    this.responseTime = Number(r.responseTime) || 0;
    this.responseSize = r.responseSize === undefined ? utf8Encode(r.body || '').length : Number(r.responseSize);
    defineHidden(this, '_body', r.body === undefined || r.body === null ? '' : String(r.body));
    const setCookies = this.headers.members.filter((h) => String(h.key).toLowerCase() === 'set-cookie').map((h) => new Cookie(String(h.value)));
    this.cookies = new PropertyList(Cookie, setCookies, false);
  }
  text() {
    return this._body;
  }
  json(reviver) {
    let b = this._body;
    if (b.charCodeAt(0) === 0xfeff) b = b.slice(1);
    return JSON.parse(b, reviver);
  }
  jsonp(reviver) {
    const m = /^[^(]*\(([\s\S]*)\)\s*;?\s*$/.exec(this._body.trim());
    return JSON.parse(m ? m[1] : this._body, reviver);
  }
  reason() {
    return this.status;
  }
  details() {
    return { code: this.code, name: this.status, detail: '' };
  }
  contentInfo() {
    const ct = this.headers.get('content-type') || '';
    const mime = ct.split(';')[0].trim().toLowerCase();
    const cs = /charset=([^;]+)/i.exec(ct);
    return { contentType: ct, mimeType: mime.split('/')[0], mimeFormat: mime.split('/')[1] || '', charset: cs ? cs[1].trim() : 'utf8' };
  }
  size() {
    const body = this.responseSize;
    const header = this.headers.members.reduce((a, h) => a + String(h.key).length + String(h.value).length + 4, 0);
    return { body: body, header: header, total: body + header };
  }
  dataURI() {
    const ct = (this.headers.get('content-type') || 'text/plain').split(';')[0];
    return 'data:' + ct + ';base64,' + G.btoa(bytesToBinary(utf8Encode(this._body)));
  }
  get stream() {
    return Buffer.from(this._body, 'utf8');
  }
  get to() {
    return getChai().expect(this).to;
  }
  toJSON() {
    return { code: this.code, status: this.status, header: this.headers.toJSON(), body: this._body, responseTime: this.responseTime, responseSize: this.responseSize };
  }
}

// ---------------------------------------------------------------------------
// Modules: require() and the lazy globals Postman has always had

const MODULES = {
  lodash: 'lodash',
  'crypto-js': 'crypto-js',
  moment: 'moment',
  uuid: 'uuid',
  chai: 'chai',
  tv4: 'tv4',
  ajv: 'ajv',
  handlebars: 'handlebars',
};

const BUILTINS = {
  atob: () => G.atob,
  btoa: () => G.btoa,
  buffer: () => ({ Buffer: Buffer }),
  url: () => ({ URL: URL, URLSearchParams: URLSearchParams }),
};

const moduleCache = Object.create(null);

function requireModule(name) {
  if (typeof name !== 'string') throw new TypeError('The module name must be a string');
  if (hasOwn(moduleCache, name)) return moduleCache[name].exports;
  if (hasOwn(BUILTINS, name)) {
    moduleCache[name] = { exports: BUILTINS[name]() };
    return moduleCache[name].exports;
  }
  if (!hasOwn(MODULES, name)) {
    const e = new Error("Cannot find module '" + name + "'");
    e.code = 'MODULE_NOT_FOUND';
    throw e;
  }
  const factory = loadNative(MODULES[name]);
  const module = { exports: {} };
  moduleCache[name] = module;
  try {
    // (module, exports, require, define, window, self, global): plain
    // CommonJS, so UMD bundles export instead of touching globals.
    factory.call(G, module, module.exports, requireModule, undefined, undefined, undefined, G);
  } catch (e) {
    delete moduleCache[name];
    throw e;
  }
  if (name === 'chai') module.exports.use(postmanAssertions);
  return module.exports;
}

function getChai() {
  return requireModule('chai');
}

// ---------------------------------------------------------------------------
// chai-postman: pm.response.to.have.status(200) and friends

function bodyText(o) {
  if (o instanceof Response) return o.text();
  if (o instanceof Request) return o.body ? o.body.toString() : '';
  return typeof o === 'string' ? o : '';
}

function jsonPath(path) {
  const parts = [];
  String(path).replace(/\[(?:'([^']*)'|"([^"]*)"|(\d+))\]|([^.[\]]+)/g, (m, a, b, c, d) => {
    parts.push(a !== undefined ? a : b !== undefined ? b : c !== undefined ? Number(c) : d);
    return '';
  });
  return parts;
}

function pathLookup(obj, path) {
  let cur = obj;
  for (const p of jsonPath(path)) {
    if (cur === null || typeof cur !== 'object' || !(p in Object(cur))) return { found: false };
    cur = cur[p];
  }
  return { found: true, value: cur };
}

function postmanAssertions(chai, utils) {
  const A = chai.Assertion;
  const target = (a) => utils.flag(a, 'object');
  const kind = (o) => (o instanceof Request ? 'request' : 'response');
  function response(a) {
    const o = target(a);
    if (!(o instanceof Response)) throw new chai.AssertionError('expected a response, got ' + utils.objDisplay(o));
    return o;
  }

  const classes = { info: 1, success: 2, redirection: 3, clientError: 4, serverError: 5 };
  Object.keys(classes).forEach((name) => {
    const n = classes[name];
    A.addProperty(name, function () {
      const r = response(this);
      this.assert(Math.floor(r.code / 100) === n, 'expected response code to be ' + n + 'XX but found ' + r.code, 'expected response code to not be ' + n + 'XX', n + 'XX', r.code);
    });
  });
  A.addProperty('error', function () {
    const r = response(this);
    const c = Math.floor(r.code / 100);
    this.assert(c === 4 || c === 5, 'expected response code to be 4XX or 5XX but found ' + r.code, 'expected response code to not be 4XX or 5XX', '4XX or 5XX', r.code);
  });

  const codes = { accepted: 202, withoutContent: 204, badRequest: 400, unauthorized: 401, forbidden: 403, notFound: 404, notAcceptable: 406, rateLimited: 429 };
  Object.keys(codes).forEach((name) => {
    const code = codes[name];
    A.addProperty(name, function () {
      const r = response(this);
      this.assert(r.code === code, 'expected response code to be ' + code + ' but found ' + r.code, 'expected response code to not be ' + code, code, r.code);
    });
  });
  A.overwriteProperty('ok', (_super) =>
    function () {
      const o = target(this);
      if (o instanceof Response) {
        this.assert(o.code === 200, 'expected response code to be 200 but found ' + o.code, 'expected response code to not be 200', 200, o.code);
      } else _super.call(this);
    },
  );

  A.addMethod('statusCode', function (code) {
    const r = response(this);
    this.assert(r.code === Number(code), 'expected response to have status code #{exp} but got #{act}', 'expected response to not have status code #{act}', Number(code), r.code);
  });
  A.addMethod('statusCodeClass', function (cls) {
    const r = response(this);
    const c = Math.floor(r.code / 100);
    this.assert(c === Number(cls), 'expected response to have status code class #{exp} but got #{act}', 'expected response to not have status code class #{act}', Number(cls), c);
  });
  A.addMethod('statusReason', function (reason) {
    const r = response(this);
    this.assert(r.status === reason, 'expected response to have status reason #{exp} but got #{act}', 'expected response to not have status reason #{act}', reason, r.status);
  });
  A.addMethod('status', function (codeOrReason) {
    const r = response(this);
    if (typeof codeOrReason === 'number') {
      this.assert(r.code === codeOrReason, 'expected response to have status code #{exp} but got #{act}', 'expected response to not have status code #{act}', codeOrReason, r.code);
    } else {
      this.assert(r.status === codeOrReason, 'expected response to have status reason #{exp} but got #{act}', 'expected response to not have status reason #{act}', codeOrReason, r.status);
    }
  });

  A.addMethod('header', function (key, value) {
    const o = target(this);
    if (!(o instanceof Response) && !(o instanceof Request)) throw new chai.AssertionError('expected a request or response, got ' + utils.objDisplay(o));
    const k = kind(o);
    const has = o.headers.has(key);
    if (arguments.length < 2) {
      this.assert(has, "expected " + k + " to have header with key '" + key + "'", "expected " + k + " to not have header with key '" + key + "'", true, has);
      return;
    }
    const act = o.headers.get(key);
    const ok = has && (value instanceof RegExp ? value.test(String(act)) : act === value);
    this.assert(ok, "expected '" + key + "' " + k + " header to be '" + value + "' but got '" + act + "'", "expected '" + key + "' " + k + " header to not be '" + value + "'", value, act);
  });

  A.addProperty('withBody', function () {
    const o = target(this);
    const t = bodyText(o);
    this.assert(t.length > 0, 'expected ' + kind(o) + ' to have content in body', 'expected ' + kind(o) + ' to not have content in body');
  });
  A.addMethod('body', function (content) {
    const o = target(this);
    const k = kind(o);
    const t = bodyText(o);
    if (arguments.length === 0) {
      this.assert(t.length > 0, 'expected ' + k + ' to have content in body', 'expected ' + k + ' to not have content in body');
    } else if (content instanceof RegExp) {
      this.assert(content.test(t), 'expected ' + k + ' body text to match #{exp} but got #{act}', 'expected ' + k + ' body text #{act} to not match #{exp}', content, t);
    } else if (typeof content === 'string') {
      this.assert(t === content, 'expected ' + k + ' body to equal #{exp} but got #{act}', 'expected ' + k + ' body to not equal #{exp}', content, t, true);
    } else {
      let json;
      try {
        json = JSON.parse(t);
      } catch (e) {
        json = undefined;
      }
      this.assert(utils.eql(json, content), 'expected ' + k + ' body json to equal #{exp} but got #{act}', 'expected ' + k + ' body json to not equal #{exp}', content, json, true);
    }
  });
  A.addProperty('json', function () {
    const o = target(this);
    let err;
    try {
      JSON.parse(bodyText(o));
    } catch (e) {
      err = e;
    }
    this.assert(!err, 'expected ' + kind(o) + ' body to be a valid json but got error ' + (err && err.message), 'expected ' + kind(o) + ' body to not be a valid json');
  });
  for (const fmt of ['html', 'xml']) {
    A.addProperty(fmt, function () {
      const o = target(this);
      const ct = String(o && o.headers ? o.headers.get('content-type') || '' : '').toLowerCase();
      this.assert(ct.indexOf(fmt) >= 0, 'expected ' + kind(o) + ' to be ' + fmt + ' but its content type is ' + (ct || 'missing'), 'expected ' + kind(o) + ' to not be ' + fmt);
    });
  }
  A.addMethod('jsonBody', function (pathOrValue, value) {
    const o = target(this);
    const k = kind(o);
    let json;
    let err;
    try {
      json = JSON.parse(bodyText(o));
    } catch (e) {
      err = e;
    }
    if (arguments.length === 0) {
      this.assert(!err, 'expected ' + k + ' body to be a valid json but got error ' + (err && err.message), 'expected ' + k + ' body to not be a valid json');
      return;
    }
    if (err) {
      this.assert(false, 'expected ' + k + ' body to be a valid json but got error ' + err.message, 'expected ' + k + ' body to not be a valid json');
      return;
    }
    if (typeof pathOrValue === 'string') {
      const hit = pathLookup(json, pathOrValue);
      if (arguments.length === 1) {
        this.assert(hit.found, "expected #{act} to have property in json body at path '" + pathOrValue + "'", "expected #{act} to not have property in json body at path '" + pathOrValue + "'", pathOrValue, json);
      } else {
        this.assert(hit.found && utils.eql(hit.value, value), "expected json body to have '" + pathOrValue + "' set to #{exp} but got #{act}", "expected json body to not have '" + pathOrValue + "' set to #{exp}", value, hit.value, true);
      }
      return;
    }
    this.assert(utils.eql(json, pathOrValue), 'expected ' + k + ' body json to equal #{exp} but got #{act}', 'expected ' + k + ' body json to not equal #{exp}', pathOrValue, json, true);
  });
  A.addMethod('jsonSchema', function (schema, options) {
    const o = target(this);
    let data = o;
    if (o instanceof Response || o instanceof Request) {
      try {
        data = JSON.parse(bodyText(o));
      } catch (e) {
        this.assert(false, 'expected ' + kind(o) + ' body to be a valid json but got error ' + e.message, 'expected ' + kind(o) + ' body to not be a valid json');
        return;
      }
    }
    const Ajv = requireModule('ajv');
    const ajv = new Ajv(Object.assign({ allErrors: true, logger: false }, options));
    const valid = ajv.validate(schema, data);
    this.assert(valid, 'expected data to satisfy schema but found following errors: \n' + ajv.errorsText(), 'expected data to not satisfy schema', true, valid);
  });
  A.addMethod('cookie', function (name, value) {
    const o = target(this);
    const list = o instanceof Response ? o.cookies : cookieList;
    const has = list.has(name);
    if (arguments.length < 2) {
      this.assert(has, "expected response to have cookie '" + name + "'", "expected response to not have cookie '" + name + "'", name);
      return;
    }
    const act = list.get(name);
    this.assert(has && act === value, "expected cookie '" + name + "' to have value #{exp} but got #{act}", "expected cookie '" + name + "' to not have value #{exp}", value, act);
  });
  A.addChainableMethod(
    'responseTime',
    function (ms) {
      const t = target(this);
      this.assert(t === ms, 'expected response time to be #{exp} but got #{act}', 'expected response time to not be #{exp}', ms, t);
    },
    function () {
      const o = target(this);
      if (o instanceof Response) utils.flag(this, 'object', o.responseTime);
    },
  );
  A.addChainableMethod(
    'responseSize',
    function (n) {
      const t = target(this);
      this.assert(t === n, 'expected response size to be #{exp} but got #{act}', 'expected response size to not be #{exp}', n, t);
    },
    function () {
      const o = target(this);
      if (o instanceof Response) utils.flag(this, 'object', o.responseSize);
    },
  );
  A.addMethod('method', function (m) {
    const o = target(this);
    const act = o instanceof Request ? o.method : undefined;
    this.assert(act === String(m).toUpperCase(), 'expected request method to be #{exp} but got #{act}', 'expected request method to not be #{exp}', String(m).toUpperCase(), act);
  });
}

// ---------------------------------------------------------------------------
// Variables

let store = null;

const ORDER = ['local', 'data', 'environment', 'session', 'collection', 'globals'];

function resolveVar(name) {
  for (const s of ORDER) if (hasOwn(store[s], name)) return { found: true, value: store[s][name] };
  return { found: false };
}

const DYNAMIC = {
  $guid: uuidV4,
  $randomUUID: uuidV4,
  $timestamp: () => String(Math.floor(Date.now() / 1000)),
  $isoTimestamp: () => new Date().toISOString(),
  $randomInt: () => String(Math.floor(Math.random() * 1001)),
};

function replaceVars(template, lookup) {
  if (typeof template !== 'string') return template;
  return template.replace(/\{\{([^{}]+)\}\}/g, (m, raw) => {
    const name = raw.trim();
    const hit = lookup(name);
    if (hit.found) return persistString(hit.value);
    if (name.charAt(0) === '$') {
      if (hasOwn(DYNAMIC, name)) return DYNAMIC[name]();
      if (hasOwn(S.dynamic, name)) return S.dynamic[name];
    }
    return m;
  });
}

class VariableScope {
  constructor(scope, op) {
    defineHidden(this, '_scope', scope);
    defineHidden(this, '_op', op);
  }
  get _map() {
    return store[this._scope];
  }
  get(key) {
    return hasOwn(this._map, key) ? this._map[key] : undefined;
  }
  set(key, value) {
    if (key === undefined || key === null) return;
    key = String(key);
    this._map[key] = value;
    if (this._op) S.ops.push([this._op, 's', key, persistString(value)]);
  }
  unset(key) {
    key = String(key);
    delete this._map[key];
    if (this._op) S.ops.push([this._op, 'u', key]);
  }
  has(key) {
    return hasOwn(this._map, key);
  }
  clear() {
    for (const k of Object.keys(this._map)) delete this._map[k];
    if (this._op) S.ops.push([this._op, 'c']);
  }
  toObject() {
    return Object.assign({}, this._map);
  }
  replaceIn(template) {
    return replaceVars(template, (n) => (this.has(n) ? { found: true, value: this.get(n) } : { found: false }));
  }
  toJSON() {
    return { values: Object.keys(this._map).map((k) => ({ key: k, value: this._map[k] })) };
  }
}

const variables = {
  get: (key) => resolveVar(key).value,
  set: (key, value) => locals.set(key, value),
  unset: (key) => locals.unset(key),
  has: (key) => resolveVar(key).found,
  clear: () => locals.clear(),
  toObject() {
    const o = {};
    for (let i = ORDER.length - 1; i >= 0; i--) Object.assign(o, store[ORDER[i]]);
    return o;
  },
  replaceIn: (template) => replaceVars(template, resolveVar),
};

let locals = null;
let cookieList = new PropertyList(Cookie, [], false);

// ---------------------------------------------------------------------------
// pm.sendRequest

function requestSpec(req) {
  const r = req instanceof Request ? req : new Request(req);
  const spec = { method: r.method, url: r.url.toString(), headers: r.headers.toJSON().filter((h) => !h.disabled) };
  if (r.body && r.body.mode !== undefined && !r.body.disabled) spec.body = r.body.toJSON();
  const auth = r.auth.toJSON();
  if (auth.type !== 'noauth') spec.auth = auth;
  return spec;
}

function sendRequest(req, callback) {
  const spec = requestSpec(req);
  const id = ++S.requestSeq;
  S.queue.push({ id: id, request: spec });
  if (typeof callback === 'function') {
    S.pending[id] = { callback: callback };
    return undefined;
  }
  return new Promise((resolve, reject) => {
    S.pending[id] = { resolve: resolve, reject: reject };
  });
}

// ---------------------------------------------------------------------------
// The pm object and Postman's legacy globals

let pm = null;
let response;

function makeExecution(info) {
  const location = [info.collectionName || '', info.requestName || ''].filter(Boolean);
  location.current = S.origin;
  return {
    skipRequest() {
      if (S.phase !== 'prerequest') {
        addLog('warn', ['pm.execution.skipRequest() only works in pre-request scripts']);
        return;
      }
      S.skip = true;
    },
    setNextRequest(next) {
      if (next === null || next === undefined) S.next = { stop: true };
      else S.next = { name: String(isObject(next) ? next.name || next.id : next) };
    },
    get location() {
      location.current = S.origin;
      return location;
    },
  };
}

function test(name, fn) {
  const t = { name: String(name), pass: true, error: null, origin: S.origin, done: true };
  S.tests.push(t);
  if (typeof fn !== 'function') {
    t.skipped = true;
    return pm;
  }
  const fail = (e) => {
    t.pass = false;
    t.error = isObject(e) && 'message' in e ? (e.name || 'Error') + ': ' + e.message : String(e);
  };
  try {
    if (fn.length > 0) {
      t.done = false;
      let settled = false;
      const done = (err) => {
        if (settled) return;
        settled = true;
        t.done = true;
        if (err) fail(err);
      };
      const r = fn(done);
      if (r && typeof r.then === 'function') {
        r.then(null, (e) => {
          if (!settled) {
            settled = true;
            t.done = true;
            fail(e);
          }
        });
      }
    } else {
      const r = fn();
      if (r && typeof r.then === 'function') {
        t.done = false;
        r.then(
          () => {
            t.done = true;
          },
          (e) => {
            t.done = true;
            fail(e);
          },
        );
      }
    }
  } catch (e) {
    t.done = true;
    fail(e);
  }
  return pm;
}
test.skip = (name) => {
  S.tests.push({ name: String(name), pass: true, error: null, origin: S.origin, done: true, skipped: true });
  return pm;
};
test.index = () => S.tests.length;

function legacyRequest(req) {
  let data = '';
  if (req.body) {
    if (req.body.mode === 'urlencoded' || req.body.mode === 'formdata') {
      const l = req.body[req.body.mode];
      data = l instanceof PropertyList ? l.toObject(true) : {};
    } else data = req.body.toString();
  }
  return { id: req.id, name: req.name, description: req.description, method: req.method, url: req.url.toString(), headers: req.headers.toObject(true, true), data: data };
}

function installGlobals(info, req) {
  const environment = new VariableScope('environment', 'environment');
  const globals = new VariableScope('globals', 'globals');
  const collectionVariables = new VariableScope('collection', 'collection');
  const iterationData = new VariableScope('data', null);
  locals = new VariableScope('local', 'local');

  pm = {
    info: {
      eventName: S.phase,
      iteration: info.iteration || 0,
      iterationCount: info.iterationCount === undefined ? 1 : info.iterationCount,
      requestName: info.requestName || '',
      requestId: info.requestId || '',
    },
    environment: environment,
    globals: globals,
    collectionVariables: collectionVariables,
    variables: variables,
    iterationData: iterationData,
    request: req,
    response: response,
    cookies: cookieList,
    test: test,
    sendRequest: sendRequest,
    execution: makeExecution(info),
    visualizer: {
      set(template, data, options) {
        const hb = requireModule('handlebars');
        S.visualizer = { html: String(hb.compile(String(template), options)(data === undefined ? {} : data)) };
      },
      clear() {
        S.visualizer = null;
      },
    },
    require(name) {
      throw new Error("pm.require('" + name + "'): package libraries are not supported; use require() for the bundled modules");
    },
  };
  Object.defineProperty(pm, 'expect', { enumerable: true, get: () => getChai().expect });
  pm.cookies.jar = () => ({
    get(url, name, cb) {
      if (typeof cb === 'function') cb(null, cookieList.get(name));
    },
    getAll(url, cb) {
      if (typeof cb === 'function') cb(null, cookieList.all());
    },
    set(url, name, value, cb) {
      const done = [cb, value, name].find((f) => typeof f === 'function');
      if (done) done(new Error('Changing the cookie jar from scripts is not supported'));
    },
    unset(url, name, cb) {
      const done = [cb, name].find((f) => typeof f === 'function');
      if (done) done(new Error('Changing the cookie jar from scripts is not supported'));
    },
    clear(url, cb) {
      if (typeof cb === 'function') cb(new Error('Changing the cookie jar from scripts is not supported'));
    },
  });

  const postman = {
    setEnvironmentVariable: (k, v) => environment.set(k, v),
    getEnvironmentVariable: (k) => environment.get(k),
    clearEnvironmentVariable: (k) => environment.unset(k),
    clearEnvironmentVariables: () => environment.clear(),
    setGlobalVariable: (k, v) => globals.set(k, v),
    getGlobalVariable: (k) => globals.get(k),
    clearGlobalVariable: (k) => globals.unset(k),
    clearGlobalVariables: () => globals.clear(),
    getResponseHeader: (name) => (response ? response.headers.get(name) : undefined),
    getResponseCookie: (name) => {
      const c = (response && response.cookies.one(name)) || cookieList.one(name);
      return c ? c.toJSON() : undefined;
    },
    setNextRequest: (next) => pm.execution.setNextRequest(next),
  };

  const lazy = (name, module) =>
    Object.defineProperty(G, name, {
      configurable: true,
      enumerable: false,
      get: () => requireModule(module),
      set: (v) => Object.defineProperty(G, name, { value: v, writable: true, configurable: true }),
    });

  Object.assign(G, timers, {
    pm: pm,
    postman: postman,
    console: console,
    require: requireModule,
    crypto: crypto,
    Buffer: Buffer,
    URL: URL,
    URLSearchParams: URLSearchParams,
    TextEncoder: TextEncoder,
    TextDecoder: TextDecoder,
    request: legacyRequest(req),
    iteration: pm.info.iteration,
  });
  if (typeof G.queueMicrotask !== 'function') G.queueMicrotask = (fn) => Promise.resolve().then(fn);
  lazy('_', 'lodash');
  lazy('CryptoJS', 'crypto-js');
  lazy('tv4', 'tv4');
  if (response) {
    Object.assign(G, {
      responseBody: response.text(),
      responseCode: { code: response.code, name: response.status, detail: '' },
      responseTime: response.responseTime,
      responseHeaders: caseInsensitive(response.headers.toObject(false, true)),
      responseCookies: cookieList.map((c) => c.toJSON()),
    });
  }
}

/**
 * [obj] with case-insensitive reads: header names arrive lower-cased, and
 * legacy scripts read `responseHeaders['Content-Type']`.
 */
function caseInsensitive(obj) {
  const find = (k) => {
    if (typeof k !== 'string' || hasOwn(obj, k)) return k;
    const lower = k.toLowerCase();
    const hit = Object.keys(obj).find((x) => x.toLowerCase() === lower);
    return hit === undefined ? k : hit;
  };
  return new Proxy(obj, {
    get: (t, k) => t[find(k)],
    has: (t, k) => find(k) in t,
  });
}

/** What the host maps back onto the request: only the parts that changed. */
function snapshot(req) {
  return {
    method: String(req.method || 'GET').toUpperCase(),
    url: req.url._base(true) + (req.url.hash ? '#' + req.url.hash : ''),
    params: JSON.stringify(req.url.query.toJSON()),
    pathVariables: JSON.stringify(req.url.variables.toJSON()),
    headers: JSON.stringify(req.headers.toJSON()),
    body: JSON.stringify(req.body ? req.body.toJSON() : {}),
    auth: JSON.stringify(req.auth.toJSON()),
  };
}

function requestChanges() {
  const req = pm.request instanceof Request ? pm.request : new Request(pm.request);
  const now = snapshot(req);
  const was = S.initial;
  const out = {};
  if (now.method !== was.method) out.method = now.method;
  if (now.url !== was.url) out.url = now.url;
  for (const k of ['params', 'pathVariables', 'headers', 'body', 'auth']) {
    if (now[k] !== was[k]) out[k] = JSON.parse(now[k]);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Host interface

function init(ctx) {
  delete G.__awLoad;
  S.phase = ctx.phase === 'test' ? 'test' : 'prerequest';
  S.dynamic = ctx.dynamic || {};
  seedRandom(ctx.seed);
  const v = ctx.vars || {};
  const obj = (m) => Object.assign(Object.create(null), m || {});
  const session = obj(v.session);
  store = {
    globals: obj(v.globals),
    collection: obj(v.collection),
    session: session,
    environment: v.environment ? obj(v.environment) : session,
    data: obj(v.data),
    local: obj(v.local),
  };
  cookieList = new PropertyList(Cookie, ctx.cookies || [], false);
  response = ctx.response ? new Response(ctx.response) : undefined;
  const req = new Request(ctx.request || {});
  S.initial = snapshot(req);
  installGlobals(ctx.info || {}, req);
  return true;
}

function begin(origin) {
  S.origin = String(origin);
  S.current = { error: null, firstTest: S.tests.length };
  G.tests = {};
  G.environment = pm.environment.toObject();
  G.globals = pm.globals.toObject();
  G.data = pm.iterationData.toObject();
  return true;
}

function track(p) {
  Promise.resolve(p).then(null, scriptError);
  return true;
}

function poll() {
  const out = { ops: S.ops, requests: S.queue, timer: nextTimerDelay() };
  S.ops = [];
  S.queue = [];
  return out;
}

function resolve(id, result) {
  const p = S.pending[id];
  if (!p) return false;
  delete S.pending[id];
  const err = result && result.error !== undefined ? new Error(String(result.error)) : null;
  const res = err ? null : new Response(result.response);
  if (p.callback) {
    try {
      p.callback(err, res, { cookies: res ? res.cookies : undefined });
    } catch (e) {
      scriptError(e);
    }
  } else if (err) p.reject(err);
  else p.resolve(res);
  return true;
}

function fireTimers() {
  const now = Date.now();
  const due = S.timers.filter((t) => t.due <= now).sort((a, b) => a.due - b.due || a.id - b.id);
  for (const t of due) {
    if (S.timers.indexOf(t) < 0) continue; // cleared by an earlier callback
    if (t.repeat) t.due = Date.now() + t.ms;
    else S.timers.splice(S.timers.indexOf(t), 1);
    try {
      t.fn.apply(undefined, t.args);
    } catch (e) {
      scriptError(e);
    }
  }
  return true;
}

function end() {
  const cur = S.current || { error: null, firstTest: S.tests.length };
  for (let i = cur.firstTest; i < S.tests.length; i++) {
    const t = S.tests[i];
    if (t.done === false) {
      t.done = true;
      t.pass = false;
      t.error = 'The test did not finish: its promise never settled or done() was not called.';
    }
  }
  const legacy = G.tests;
  if (isObject(legacy)) {
    for (const k of Object.keys(legacy)) {
      S.tests.push({ name: k, pass: !!legacy[k], error: null, origin: S.origin, done: true });
    }
  }
  S.timers = [];
  return { error: cur.error, skip: S.skip };
}

function finish() {
  const out = {
    tests: S.tests.map((t) => ({ name: t.name, pass: t.pass, error: t.error, origin: t.origin, skipped: !!t.skipped })),
    logs: S.logs,
    dropped: S.droppedLogs,
    next: S.next === undefined ? null : S.next,
    visualizer: S.visualizer === undefined ? null : S.visualizer,
    skip: S.skip,
    ops: S.ops,
  };
  S.ops = [];
  if (S.phase === 'prerequest' && pm) out.request = requestChanges();
  return out;
}

module.exports = {
  init: init,
  begin: begin,
  track: track,
  poll: poll,
  resolve: resolve,
  fireTimers: fireTimers,
  end: end,
  finish: finish,
};
