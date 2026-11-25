const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../web/webos_bridge.js'), 'utf8');
function bridge({href = 'file:///app/org.zorofin.tv/index.html', tv = true, status = 0, missing = false} = {}) {
  const events = {}, requests = [], forwarded = [];
  class XHR {
    open(method, url) { requests.push({method, url}); }
    send() { this.status = status; this.response = missing ? null : new Uint8Array([1, 2]).buffer; this.onload(); }
    abort() { this.onabort(); }
  }
  const window = {location:{href}, PalmSystem:tv ? {} : undefined,
    fetch: async (...args) => {forwarded.push(args); return 'remote';},
    addEventListener: (name, callback) => events[name] = callback};
  const context = {window, URL, Response, DOMException, XMLHttpRequest:XHR,
    KeyboardEvent:class {constructor(type, args) {this.type=type; Object.assign(this,args);}}, document:{}};
  vm.runInNewContext(source, context);
  return {window, events, requests, forwarded};
}
test('local wasm is loaded from the package with its streaming MIME type', async () => {
  const b = bridge(); const r = await b.window.fetch('canvaskit/canvaskit.wasm');
  assert.equal(r.status, 200); assert.equal(r.headers.get('content-type'), 'application/wasm');
  assert.equal((await r.arrayBuffer()).byteLength, 2);
  assert.equal(b.requests[0].url, 'file:///app/org.zorofin.tv/canvaskit/canvaskit.wasm');
});
test('remote requests including headers retain the original fetch path', async () => {
  const b=bridge(); const init={headers:{Authorization:'test'}};
  assert.equal(await b.window.fetch('https://media.example/System/Info/Public', init), 'remote');
  assert.equal(b.forwarded[0][1], init); assert.equal(b.requests.length, 0);
});
test('rejects traversal, neighboring packages, encoded traversal and file writes', async () => {
  const b=bridge();
  for (const value of ['../secrets', 'file:///app/other/token', 'file:///app/org.zorofin.tv2/token', 'file://other-host/app/org.zorofin.tv/token', '%2e%2e%2fsecrets']) {
    await assert.rejects(b.window.fetch(value), /denied/);
  }
  await assert.rejects(b.window.fetch('assets/a', {method:'POST'}), /denied/);
  assert.equal(b.requests.length, 0);
});
test('missing package assets fail without exposing their paths', async () => {
  await assert.rejects(bridge({missing:true}).window.fetch('assets/missing'), /Package asset unavailable/);
});
test('an already cancelled request never sends', async () => {
  const controller = new AbortController(); controller.abort(); const b=bridge();
  await assert.rejects(b.window.fetch('assets/test', {signal:controller.signal}), {name:'AbortError'});
});
test('Back maps both edges, keeps repeat and cannot recursively remap itself', () => {
  const b=bridge(); const mapped=[]; let stopped=0;
  for (const type of ['keydown','keyup']) {
    b.events[type]({keyCode:461, repeat:true, preventDefault(){stopped++;}, stopImmediatePropagation(){}, target:{dispatchEvent(e){mapped.push(e); b.events[type](e);}}});
  }
  assert.deepEqual(mapped.map(e=>[e.type,e.key,e.code,e.repeat]), [['keydown','Escape','Escape',true],['keyup','Escape','Escape',true]]);
  assert.equal(stopped,2);
});
test('ordinary browser builds do not intercept keyboard events or fetch', async () => {
  const b=bridge({href:'http://localhost/index.html'});
  assert.equal(Object.keys(b.events).length,0);
  assert.equal(await b.window.fetch('assets/a'), 'remote');
});
