import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

// A normal editable surface and its paste event: no browser/network or user data.
const messages = [];
const pasted = [];
let sessionId = 'session-a';
let acceptPaste = true;
const editor = {
  textContent: '',
  getClientRects: () => [{}],
  closest() { return null; },
  focus() {},
  dispatchEvent(event) {
    if (!acceptPaste) return false;
    const text = event.clipboardData.getData('text/plain');
    this.textContent += text;
    pasted.push(text);
    return true;
  },
};
class DataTransfer {
  values = new Map();
  items = {add() { throw new Error('this fixture has no files'); }};
  setData(k, v) { this.values.set(k, v); }
  getData(k) { return this.values.get(k) ?? ''; }
}
class ClipboardEvent {
  constructor(type, fields) { this.type = type; Object.assign(this, fields); }
}
const document = {
  addEventListener() {},
  querySelectorAll(selector) {
    return selector === '[data-lexical-editor="true"][contenteditable="true"]' ? [editor] : [];
  },
};
const window = {DshAppCompose: {postMessage(value) { messages.push(JSON.parse(value)); }}};
const context = vm.createContext({
  window, document, location: {href: 'https://fixture.invalid/'},
  localStorage: {getItem: () => JSON.stringify({sessionId})},
  sessionStorage: {getItem: () => null, removeItem() {}},
  history: {replaceState() {}}, URL, Date, setTimeout, clearTimeout,
  DataTransfer, ClipboardEvent,
});
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), context, {filename: process.argv[2]});
if (process.argv[3] === '--upload') {
  sessionId = null;
  assert.equal(window.__dshAppUploadTarget(), null);
  sessionId = 'session-a';
  const uploadTarget = window.__dshAppUploadTarget();
  let finishOpening;
  window.__dshAppOpening = new Promise(resolve => { finishOpening = resolve; });
  const stale = window.__dshAppCompose({text: 'old host path', uploadTarget, requestId: '1'});
  sessionId = 'session-b';
  finishOpening();
  await stale;
  assert.deepEqual(pasted, []);
  assert.equal(messages[0].text, false);
  const current = {
    text: 'Uploaded to the workspace.\n- "/one"', uploadTarget: window.__dshAppUploadTarget(), requestId: '2',
  };
  await window.__dshAppCompose(current);
  assert.deepEqual(pasted, [current.text]);
  assert.equal(messages[1].text, true);
  acceptPaste = false;
  await window.__dshAppCompose({...current, text: 'Uploaded to the workspace.\n- "/two"', requestId: '3'});
  assert.equal(messages[2].text, false);
  process.exit(0);
}
const drafts = process.argv[3] ? JSON.parse(process.argv[3]) : [{text: 'first ordinary draft', files: []}, {text: 'second ordinary draft', files: []}];
await Promise.all(drafts.map(draft => window.__dshAppCompose(draft)));
assert.deepEqual(pasted, drafts.map(x => x.text));
assert.equal(messages.length, drafts.length);
assert.ok(messages.every(x => x.text === true && x.files === 0));
process.stdout.write(JSON.stringify({drafts, messages, pasted, scope: 'Exact full JS; synthetic ordinary DOM/paste; actual 400ms timers; no WebKit.'}) + '\n');
