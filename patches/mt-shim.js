// MiniTube compatibility shim — loaded FIRST in the background page.
//
// 1) chrome.privacy does not exist under WKWebExtension, and webext.js:144
//    dereferences it unguarded — killing uBO's whole background init (so the
//    dashboard messaging channel never registers and every pane is inert).
//    Stub the three settings uBO touches as callback-style BrowserSettings
//    reporting not_controllable; uBO disables those toggles gracefully.
// 2) Persist any remaining background exception into extension storage so the
//    app's settings webview can read what failed (background console is
//    unreachable here).
(function() {
    'use strict';

    const mkSetting = (defaultValue) => ({
        get: function(details, cb) {
            const r = { value: defaultValue, levelOfControl: 'not_controllable' };
            if (cb) cb(r);
            return Promise.resolve(r);
        },
        set: function(details, cb) { if (cb) cb(); return Promise.resolve(); },
        clear: function(details, cb) { if (cb) cb(); return Promise.resolve(); },
        onChange: { addListener: function() {}, removeListener: function() {}, hasListener: function() { return false; } },
    });
    const privacyStub = {
        network: {
            networkPredictionEnabled: mkSetting(false),
            webRTCIPHandlingPolicy: mkSetting('default'),
        },
        websites: {
            hyperlinkAuditingEnabled: mkSetting(false),
        },
    };
    try { if (typeof chrome !== 'undefined' && !chrome.privacy) chrome.privacy = privacyStub; } catch (_) {}
    try { if (typeof browser !== 'undefined' && !browser.privacy) browser.privacy = privacyStub; } catch (_) {}

    // 1b) uBO copies runtime methods UNBOUND (`vAPI.getURL = browser.runtime.getURL`);
    //     WebKit's bridged functions silently return undefined without their receiver.
    //     Pre-bind the ones uBO detaches so the copies keep working.
    for (const g of [typeof chrome !== 'undefined' ? chrome : null,
                     typeof browser !== 'undefined' ? browser : null]) {
        if (!g || !g.runtime) continue;
        for (const m of ['getURL', 'getManifest']) {
            try {
                if (typeof g.runtime[m] === 'function') g.runtime[m] = g.runtime[m].bind(g.runtime);
            } catch (_) {}
        }
    }

    // 1c) WebKit implements these namespaces only partially — any event object
    //     uBO's init dereferences that is missing kills the whole background.
    //     Stub every missing event with a no-op listener interface (uBO simply
    //     never receives those events; the features degrade, init survives).
    const noopEvent = () => ({
        addListener: function() {}, removeListener: function() {},
        hasListener: function() { return false; },
    });
    const wanted = {
        browserAction: ['onClicked'],
        runtime: ['onConnect', 'onUpdateAvailable', 'onMessage', 'onInstalled', 'onStartup'],
        tabs: ['onActivated', 'onRemoved', 'onUpdated', 'onCreated', 'onReplaced'],
        webNavigation: ['onCommitted', 'onCreatedNavigationTarget', 'onDOMContentLoaded'],
        webRequest: ['onBeforeRedirect', 'onBeforeRequest', 'onCompleted', 'onErrorOccurred',
                     'onResponseStarted', 'onSendHeaders', 'onBeforeSendHeaders', 'onHeadersReceived'],
        windows: ['onFocusChanged', 'onCreated', 'onRemoved'],
        alarms: ['onAlarm'],
        contextMenus: ['onClicked'],
    };
    for (const g of [typeof chrome !== 'undefined' ? chrome : null,
                     typeof browser !== 'undefined' ? browser : null]) {
        if (!g) continue;
        for (const [ns, events] of Object.entries(wanted)) {
            try {
                if (!g[ns]) g[ns] = {};
                for (const ev of events) {
                    if (!g[ns][ev]) g[ns][ev] = noopEvent();
                }
            } catch (_) {}
        }
    }

    // 1d) Missing methods uBO calls unconditionally during init. WebKit's native
    //     api objects are non-extensible, so a plain assignment silently fails —
    //     replace the whole object with one that inherits the native surface (via
    //     Object.create) plus the missing method.
    for (const g of [typeof chrome !== 'undefined' ? chrome : null,
                     typeof browser !== 'undefined' ? browser : null]) {
        if (!g) continue;
        try {
            if (g.webRequest && typeof g.webRequest.handlerBehaviorChanged !== 'function') {
                var wr = g.webRequest;
                try { wr.handlerBehaviorChanged = function(){}; } catch (_) {}
                if (typeof wr.handlerBehaviorChanged !== 'function') {
                    var wrap = Object.create(wr);           // inherits native members
                    wrap.handlerBehaviorChanged = function(){};
                    Object.defineProperty(g, 'webRequest', { value: wrap, configurable: true, writable: true });
                }
            }
        } catch (_) {}
        try { if (g.contextMenus) {
            if (typeof g.contextMenus.removeAll !== 'function') g.contextMenus.removeAll = function(cb){ if(cb) cb(); return Promise.resolve(); };
            if (typeof g.contextMenus.create !== 'function') g.contextMenus.create = function(){ return 0; };
            if (typeof g.contextMenus.remove !== 'function') g.contextMenus.remove = function(cb){ if(cb) cb(); return Promise.resolve(); };
        } } catch (_) {}
    }

    const errs = [];
    const flush = () => {
        try {
            const api = (typeof browser !== 'undefined' ? browser : chrome);
            api.storage.local.set({ mtBgErrs: errs.slice(0, 20) });
        } catch (_) {}
    };
    self.addEventListener('error', e => {
        errs.push(String(e.message || e) + ' @' + String(e.filename || '').split('/').pop() + ':' + (e.lineno || 0));
        flush();
    });
    self.addEventListener('unhandledrejection', e => {
        errs.push('rej: ' + String(e.reason && e.reason.stack ? e.reason.stack : e.reason).slice(0, 300));
        flush();
    });
})();
