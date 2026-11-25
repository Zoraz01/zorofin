/* Packaged webOS support; no server address, credentials or remote code. */
(function () {
  'use strict';
  const appBase = new URL('./', window.location.href);
  const packaged = appBase.protocol === 'file:';
  const tv = packaged && !!(window.PalmSystem || window.webOSSystem);

  // Chromium fetch does not support file: URLs. LG packaged applications can
  // read their own assets using XHR. Keep this adapter restricted to GET/HEAD
  // under this package; remote API requests retain normal browser protections.
  if (packaged) {
    const browserFetch = window.fetch.bind(window);
    window.fetch = function(input, init) {
      const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url, appBase);
      if (url.protocol !== 'file:') return browserFetch(input, init);
      const method = (init?.method || input.method || 'GET').toUpperCase();
      const decoded = decodeURIComponent(url.pathname);
      if (url.host !== appBase.host || !decoded.startsWith(decodeURIComponent(appBase.pathname)) ||
          decoded.split('/').includes('..') || !['GET', 'HEAD'].includes(method)) {
        return Promise.reject(new TypeError('Package asset access denied'));
      }
      return new Promise(function(resolve, reject) {
        const xhr = new XMLHttpRequest();
        xhr.open(method, url.href, true);
        xhr.responseType = 'arraybuffer';
        const signal = init?.signal || input.signal;
        const abort = () => xhr.abort();
        const clean = () => signal?.removeEventListener('abort', abort);
        if (signal?.aborted) { reject(new DOMException('Aborted', 'AbortError')); return; }
        signal?.addEventListener('abort', abort, {once: true});
        xhr.onload = function() {
          clean();
          if ((xhr.status !== 0 && xhr.status !== 200) || xhr.response === null) {
            reject(new TypeError('Package asset unavailable')); return;
          }
          const type = url.pathname.endsWith('.wasm') ? 'application/wasm'
            : url.pathname.endsWith('.json') ? 'application/json' : 'application/octet-stream';
          resolve(new Response(method === 'HEAD' ? null : xhr.response, {
            status: 200, headers: {'Content-Type': type}
          }));
        };
        xhr.onerror = function() { clean(); reject(new TypeError('Package asset unavailable')); };
        xhr.onabort = function() { clean(); reject(new DOMException('Aborted', 'AbortError')); };
        xhr.send();
      });
    };
  }

  if (!tv) return;
  // LG reports Back as 461 and some media keys without a standard key/code.
  // Normalize both edges for Flutter, preserving repeat and the focused target.
  const keys = {
    461: ['Escape', 'Escape', 27],
    415: ['MediaPlay', 'MediaPlay', 415],
    19: ['MediaPause', 'MediaPause', 19],
    412: ['MediaRewind', 'MediaRewind', 412],
    417: ['MediaFastForward', 'MediaFastForward', 417],
    413: ['MediaStop', 'MediaStop', 413]
  };
  for (const type of ['keydown', 'keyup']) {
    window.addEventListener(type, function(event) {
      const key = keys[event.keyCode];
      if (!key || event.zorofinNormalized) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      const mapped = new KeyboardEvent(type, {
        key: key[0], code: key[1], keyCode: key[2], which: key[2],
        bubbles: true, cancelable: true, repeat: event.repeat
      });
      Object.defineProperty(mapped, 'zorofinNormalized', {value: true});
      (event.target || document).dispatchEvent(mapped);
    }, true);
  }
}());
