#!/usr/bin/env node
/* Exercise the maintenance module with the same capability replies as the CGI. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname,
    '../src/www/httpd/htdocs/js/modules/maintenance.js'), 'utf8');

function page(info, offline) {
    const elements = {};
    const handlers = {};
    const requests = [];
    const uploads = [];
    const file = {name: 'y28ga_3.8.0.tgz', size: 4096};
    const document = {getElementById: () => ({files: [file]})};
    function $(selector) {
        if (selector === document) {
            return {on: (_event, id, handler) => { handlers[id] = handler; }};
        }
        if (!elements[selector]) {
            elements[selector] = {};
        }
        const element = elements[selector];
        return {
            attr: (key, value) => { element[key] = value; },
            prop: (key, value) => { element[key] = value; },
            text: value => { element.text = value; }
        };
    }
    $.ajax = request => {
        requests.push(request.url);
        assert.equal(request.url, 'cgi-bin/fw_upgrade.sh?get=info');
        if (offline) {
            request.error({});
        } else {
            request.success(info);
        }
    };
    function XMLHttpRequest() {
        this.upload = {};
        this.open = (method, url) => { this.method = method; this.url = url; };
        this.setRequestHeader = () => {};
        this.send = body => { uploads.push({method: this.method, url: this.url, body}); };
    }
    const context = {jQuery: $, document, XMLHttpRequest, confirm: () => true,
        console: {log: () => {}}};
    vm.runInNewContext(source, context);
    context.APP.maintenance.init();
    return {elements, handlers, requests, uploads, file};
}

for (const info of [
    {error: false, profile: 'flash-core', fw_version: '3.8.0-flash-core',
        upload_supported: false, description: 'Upload flashing is not supported on flash-core.'},
    {error: true, message: 'Old flash-core stub'},
    {error: false, fw_version: 'old backend without capabilities'}
]) {
    const state = page(info);
    assert.equal(state.elements['#button-fw-upload'].disabled, true);
    assert.equal(state.elements['#button-fw-file'].disabled, true);
    assert.ok(state.elements['#text-fw-upload'].text);
    state.handlers['#button-fw-upload']();
    assert.equal(state.uploads.length, 0);
    assert.equal(state.handlers['#button-fw-online'], undefined);
}
const offline = page(null, true);
assert.equal(offline.elements['#button-fw-upload'].disabled, true);
offline.handlers['#button-fw-upload']();
assert.equal(offline.uploads.length, 0);

const legacy = page({error: false, profile: 'sd-legacy', fw_version: '3.8.0', upload_supported: true});
assert.equal(legacy.elements['#button-fw-upload'].disabled, false);
assert.equal(legacy.elements['#button-fw-file'].disabled, false);
legacy.handlers['#button-fw-upload']();
assert.equal(legacy.uploads.length, 1);
assert.equal(legacy.uploads[0].url, 'cgi-bin/fw_upload.sh');
assert.equal(legacy.uploads[0].method, 'POST');
assert.equal(legacy.uploads[0].body, legacy.file);
assert.equal(legacy.elements['#button-fw-upload'].disabled, true);
console.log('PASS: local status, capability-gated uploads, offline rejection and legacy upload request');
