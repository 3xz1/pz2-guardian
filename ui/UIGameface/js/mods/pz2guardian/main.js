// PZ2Guardian (in-park HUD): a "Guardian" button with a small panel.
// Switches (kept in localStorage, handed to Lua on hello), the animals it
// is watching right now, a log, and Diagnose.
//
// Lua side: pz2guardian.guard.lua. Event argument counts here must match
// the counts registered in pz2guardian.core.lua, and no event name may be
// both sent and listened to here (engine.trigger also fires this page's
// own engine.on).
// Also in the game's pause menu (Esc → Mods, pausemenu.js); the screen
// button can be hidden.
import { loadCSS } from '/js/common/util/CSSUtil.js';
import { addPauseMenuEntry, refreshPauseMenu } from './pausemenu.js';

const VERSION = '1.2.0';
const SHOW_BTN_KEY = 'PZ2Guardian.screenButton';
const TICK_MS = 3000;
const POS_KEY = 'PZ2Guardian.buttonPos';
const SET_KEY = 'PZ2Guardian.settings';
const KEYS = ['block', 'ret', 'unbox', 'emergency'];
const DEFAULTS = { block: true, ret: true, unbox: true, emergency: false };
const LABELS = {
    block: ['Block escapes', 'Switches the game\'s animal escapes off (as the sandbox option "Animal Escapes").'],
    ret: ['Send escapees home', 'A keeper brings escaped animals, and animals left boxed outside their habitat, back.'],
    unbox: ['Unbox stuck animals', 'Lets out animals left in a transport box inside their own habitat, with no move under way.'],
    emergency: ['Paid emergency capture', 'If an animal stays loose too long, use the game\'s Emergency Capture (costs money).'],
};
// wait times in real seconds, in the order Lua's SetTimes reads them
const TIMES_KEY = 'PZ2Guardian.times';
const TOTALS_KEY = 'PZ2Guardian.totals';
const TIMES = [
    ['loose', 'Escaped, before a keeper is sent', 15, 0],
    ['away', 'Boxed outside its habitat, before it is sent home', 30, 0],
    ['unbox', 'Boxed in its own habitat, before it is unboxed', 10, 0],
    ['retry', 'Between two tries for the same animal', 45, 10],
    ['emergency', 'Escaped, before the paid emergency capture', 120, 10],
];
const COUNTS = ['unboxed', 'returned', 'home', 'captured'];
const STATES = {
    loose: 'escaped',
    boxedHome: 'boxed in its habitat',
    boxedAway: 'boxed outside',
    moving: 'being moved',
    vet: 'vet capturing',
};

let connected = false;
let open = false;
let st = null;
let diag = '';
// The game's UI keeps localStorage in memory only: it is empty after every
// game start. So every saved value is also kept in the game's player save
// (Lua: Core.StoreRead / StoreWrite). The saved set comes with the hello
// and is written back into localStorage; changes go to Lua 1.5 s after the
// last one. localStorage stays the copy the page reads.
const STORE_DELAY_MS = 1500;
const STORE_CAP = 60000;    // characters; Lua refuses more
let kept = {};              // key -> localStorage text, everything the player save holds
let storeState = 'waiting for the mod';
let storeReady = false;     // the saved set has arrived (or there is none)
let storeTimer = null;
let settings =Object.assign({}, DEFAULTS, load(SET_KEY, {}));
let times = Object.assign(Object.fromEntries(TIMES.map(t => [t[0], t[2]])), load(TIMES_KEY, {}));
// Pre-release test builds used 45 s as the unbox default. Changing any time saved
// all of them, so a saved 45 is the old default, not a choice.
if (times.unbox === 45 && !load('PZ2Guardian.unboxMigrated', false)) {
    times.unbox = 10;
    save(TIMES_KEY, times);
}
save('PZ2Guardian.unboxMigrated', true);
// all-time totals. Lua counts from 0 at every game start (its "boot" id
// changes); a park reload reloads this page but keeps Lua's counts, so the
// counts already added are stored with that id.
let totals = Object.assign({ unboxed: 0, returned: 0, home: 0, captured: 0, boot: '', seen: {} }, load(TOTALS_KEY, {}));
let resetArmed = 0;
let showButton = load(SHOW_BTN_KEY, true) !== false;
let menuAnchor = null;      // { menu, box } rects while the panel was opened from the pause menu

function load(key, fallback) {
    try {
        const v = window.localStorage.getItem(key);
        return v == null ? fallback : JSON.parse(v);
    }
    catch (e) {
        return fallback;
    }
}
function save(key, value) {
    try {
        if (value == null) window.localStorage.removeItem(key);
        else window.localStorage.setItem(key, JSON.stringify(value));
    }
    catch (e) {
        // not saved, still works this session
    }
    keep(key, value == null ? null : JSON.stringify(value));
}

// ------------------------------------------- settings that outlast the game
function storeKeys() {
    return [SHOW_BTN_KEY, POS_KEY, SET_KEY, TIMES_KEY, TOTALS_KEY, SIZE_KEY, 'PZ2Guardian.unboxMigrated'];
}

function keep(key, text) {
    if (text == null) delete kept[key];
    else kept[key] = String(text);
    if (!storeReady) return;
    clearTimeout(storeTimer);
    storeTimer = setTimeout(flushStore, STORE_DELAY_MS);
}

// JSON with every non-ASCII character as \uXXXX (Lua keeps printable ASCII only)
function asciiJson(value) {
    return JSON.stringify(value).replace(/[\u007f-￿]/g, c => '\\u' + ('0000' + c.charCodeAt(0).toString(16)).slice(-4));
}

function flushStore() {
    storeTimer = null;
    const text = asciiJson(kept);
    if (text.length > STORE_CAP) {
        storeState = `too big to keep (${text.length} characters)`;
        return;
    }
    engine.trigger('PZ2Guardian_StoreSave', text);
}

// The hello's saved set (text = JSON object, "" when nothing is kept yet).
function applyStore(text, status) {
    storeReady = true;
    let saved = null;
    if (status == 'ok' && text) {
        try {
            saved = JSON.parse(text);
        }
        catch (e) {
            saved = null;
        }
    }
    if (saved && typeof saved == 'object' && !Array.isArray(saved)) {
        kept = {};
        for (const [key, value] of Object.entries(saved)) {
            if (typeof key == 'string' && key.startsWith('PZ2Guardian.') && value != null) kept[key] = String(value);
        }
        try {
            for (const [key, value] of Object.entries(kept)) window.localStorage.setItem(key, value);
        }
        catch (e) {
            // this session keeps its own values
        }
        storeState = 'settings loaded from the player save';
        readSettings();
        return;
    }
    // nothing kept yet (first start with this version): keep what this
    // session has
    for (const key of storeKeys()) {
        try {
            const v = window.localStorage.getItem(key);
            if (v != null) kept[key] = v;
        }
        catch (e) {
            // nothing to keep
        }
    }
    if (status == 'ok' || status == 'unreadable') {
        storeState = status == 'ok' ? 'nothing saved yet' : 'saved settings unreadable, starting over';
        flushStore();
    }
    else {
        storeReady = false;
        storeState = `not available (${status || 'no answer'}): settings last until the game closes`;
    }
}

// (re)reads every saved value from localStorage, e.g. after applyStore
function readSettings() {
    settings = Object.assign({}, DEFAULTS, load(SET_KEY, {}));
    times = Object.assign(Object.fromEntries(TIMES.map(t => [t[0], t[2]])), load(TIMES_KEY, {}));
    totals = Object.assign({ unboxed: 0, returned: 0, home: 0, captured: 0, boot: '', seen: {} }, load(TOTALS_KEY, {}));
    showButton = load(SHOW_BTN_KEY, true) !== false;
    sizeSetting = readSize();
    place();
    label();
    render();
}
function el(tag, className, text) {
    const e = document.createElement(tag);
    if (className) e.className = className;
    if (text != undefined) e.textContent = text;
    return e;
}
function button(label, onClick, extra) {
    const b = el('div', 'PZ2GD_btn' + (extra ? ' ' + extra : ''), label);
    b.addEventListener('click', e => {
        e.stopPropagation();
        onClick();
    });
    return b;
}
function bits() {
    return KEYS.map(k => settings[k] ? '1' : '0').join(',');
}
function timesText() {
    return TIMES.map(t => String(times[t[0]])).join(',');
}
// 5 s steps up to a minute, 15 s up to 5 minutes, then whole minutes
function stepTime(v, dir) {
    const step = dir > 0 ? (v < 60 ? 5 : v < 300 ? 15 : 60) : (v <= 60 ? 5 : v <= 300 ? 15 : 60);
    return v + dir * step;
}
function secs(n) {
    return n >= 60 ? `${Math.floor(n / 60)}m ${n % 60}s` : `${n}s`;
}
function wheelScroll(box) {
    box.addEventListener('wheel', e => {
        box.scrollTop += e.deltaY > 0 ? 60 : -60;
        e.preventDefault();
        e.stopPropagation();
    });
}

// ------------------------------------------------------------------ UI
let btn = null;
let panel = null;

function problems() {
    return st && st.rows ? st.rows.filter(r => r.state == 'loose' || r.state == 'boxedHome' || r.state == 'boxedAway') : [];
}

function labelText() {
    const n = problems().length;
    return n ? `Guardian (${n})` : 'Guardian';
}

function label() {
    refreshPauseMenu();
    if (!btn) return;
    btn.textContent = labelText();
    btn.classList.toggle('attention', problems().length > 0);
}

function render() {
    if (!panel || !open) return;
    const nTop = panel.scrollTop;
    panel.textContent = '';
    const head = el('div', 'PZ2GD_row');
    head.appendChild(el('div', 'PZ2GD_name', `Guardian ${VERSION}`));
    head.appendChild(el('div', 'PZ2GD_dim grow', connected ? (st && st.paused ? 'paused: waiting' : 'watching') : 'not connected'));
    head.appendChild(button('Diagnose', () => {
        diag = 'asking…';
        if (connected) engine.trigger('PZ2Guardian_Diagnose', 1);
        render();
    }));
    head.appendChild(button('Close', () => toggle(false)));
    panel.appendChild(head);
    const sizeRow = el('div', 'PZ2GD_row');
    sizeRow.appendChild(el('div', 'PZ2GD_dim', 'Size'));
    sizeRow.appendChild(button('-', () => stepSize(-1), 'step'));
    sizeRow.appendChild(el('div', 'PZ2GD_value', `${Math.round(sizeSetting * 100)}%`));
    sizeRow.appendChild(button('+', () => stepSize(1), 'step'));
    sizeRow.appendChild(el('div', 'PZ2GD_dim grow', 'of the panel and button, on top of the game\'s UI scale (saved).'));
    panel.appendChild(sizeRow);
    const btnRow = el('div', 'PZ2GD_row');
    btnRow.appendChild(button(`Screen button: ${showButton ? 'on' : 'off'}`, () => {
        showButton = !showButton;
        save(SHOW_BTN_KEY, showButton);
        place();
        render();
    }, showButton ? 'on' : ''));
    btnRow.appendChild(el('div', 'PZ2GD_dim grow', showButton
        ? 'Guardian is also in the game menu (Esc → Mods).'
        : 'Open Guardian from the game menu: Esc → Mods → Guardian.'));
    panel.appendChild(btnRow);

    for (const k of KEYS) {
        const row = el('div', 'PZ2GD_row');
        row.appendChild(button(`${LABELS[k][0]}: ${settings[k] ? 'on' : 'off'}`, () => {
            settings[k] = !settings[k];
            save(SET_KEY, settings);
            if (connected) engine.trigger('PZ2Guardian_Settings', bits());
            render();
        }, settings[k] ? 'on' : ''));
        row.appendChild(el('div', 'PZ2GD_dim grow', LABELS[k][1]));
        panel.appendChild(row);
    }
    if (st) panel.appendChild(el('div', 'PZ2GD_dim', `Escape block: ${st.blockState}`));

    panel.appendChild(el('div', 'PZ2GD_title', 'Results'));
    const res = el('div', 'PZ2GD_results');
    const showCapture = settings.emergency || totals.captured > 0;
    const cols = ['', 'Unboxed', 'Sent home', 'Back in habitat'].concat(showCapture ? ['Emergency captured'] : []);
    const headRow = el('div', 'PZ2GD_tr head');
    for (const x of cols) headRow.appendChild(el('div', 'PZ2GD_td', x));
    res.appendChild(headRow);
    const sess = st || { unboxed: 0, returned: 0, home: 0, captured: 0 };
    for (const [name, c] of [['This session', sess], ['All time', totals]]) {
        const tr = el('div', 'PZ2GD_tr');
        const vals = [name, c.unboxed, c.returned, c.home].concat(showCapture ? [c.captured] : []);
        for (const x of vals) tr.appendChild(el('div', 'PZ2GD_td', String(x)));
        res.appendChild(tr);
    }
    panel.appendChild(res);
    const resRow = el('div', 'PZ2GD_row');
    resRow.appendChild(el('div', 'PZ2GD_dim grow', 'Counted per animal. "Back in habitat" = sent home and arrived.'));
    resRow.appendChild(button(Date.now() < resetArmed ? 'Click again to reset' : 'Reset all time', () => {
        if (Date.now() < resetArmed) {
            totals.unboxed = totals.returned = totals.home = totals.captured = 0;
            save(TOTALS_KEY, totals);
            resetArmed = 0;
        }
        else {
            resetArmed = Date.now() + 5000;
            setTimeout(render, 5100);
        }
        render();
    }));
    panel.appendChild(resRow);

    panel.appendChild(el('div', 'PZ2GD_title', 'Wait times (real seconds; game speed does not change them)'));
    for (const [key, text, def, min] of TIMES) {
        if (key == 'emergency' && !settings.emergency) continue;
        const row = el('div', 'PZ2GD_row');
        row.appendChild(button('-', () => setTime(key, Math.max(min, stepTime(times[key], -1))), 'step'));
        row.appendChild(el('div', 'PZ2GD_value', secs(times[key])));
        row.appendChild(button('+', () => setTime(key, Math.min(3600, stepTime(times[key], 1))), 'step'));
        row.appendChild(el('div', 'PZ2GD_dim grow', text + (times[key] == def ? '' : ` (default ${secs(def)})`)));
        panel.appendChild(row);
    }

    panel.appendChild(el('div', 'PZ2GD_title', 'Animals needing attention'));
    const list = el('div', 'PZ2GD_box');
    const rows = st && st.rows ? st.rows : [];
    if (!rows.length) list.appendChild(el('div', 'PZ2GD_dim', 'None. Every habitat animal is where it belongs.'));
    for (const r of rows) {
        const line = el('div', 'PZ2GD_line' + (r.state == 'moving' || r.state == 'vet' ? ' dim' : ''));
        line.textContent = `${r.name}: ${STATES[r.state] || r.state} for ${secs(r.secs)}` + (r.tries ? ` · tries ${r.tries}` : '') + (r.note ? ` · ${r.note}` : '');
        list.appendChild(line);
    }
    panel.appendChild(list);

    panel.appendChild(el('div', 'PZ2GD_title', 'Log'));
    const log = el('div', 'PZ2GD_box log');
    log.textContent = st && st.log && st.log.length ? st.log.join('\n') : '(nothing yet)';
    panel.appendChild(log);
    if (diag) {
        panel.appendChild(el('div', 'PZ2GD_title', 'Diagnose'));
        panel.appendChild(el('div', 'PZ2GD_box log', diag));
    }
    for (const b of panel.querySelectorAll('.PZ2GD_box')) wheelScroll(b);
    log.scrollTop = log.scrollHeight;
    panel.scrollTop = nTop;
    place();
}

function setTime(key, v) {
    times[key] = v;
    save(TIMES_KEY, times);
    if (connected) engine.trigger('PZ2Guardian_Times', timesText());
    render();
}

// adds what Lua counted since the last state to the all-time totals
function addTotals() {
    if (!st || !st.boot) return;
    if (totals.boot !== st.boot) {
        totals.boot = st.boot;
        totals.seen = {};
    }
    let changed = false;
    for (const k of COUNTS) {
        const now = Number(st[k]) || 0;
        const before = Number(totals.seen[k]) || 0;
        if (now > before) {
            totals[k] += now - before;
            totals.seen[k] = now;
            changed = true;
        }
    }
    if (changed) save(TOTALS_KEY, totals);
}

function toggle(v) {
    open = v;
    if (!open) menuAnchor = null;
    if (panel) panel.style.display = open ? 'block' : 'none';
    render();
}

// default spot: slot 1 of the mod button stack (Studbook, Guardian,
// Breeding, AutoHub, Speed) at the left screen edge, centred vertically
function defaultPos() {
    return { x: 0, y: Math.max(0, Math.round(window.innerHeight / 2 - 99 + 1 * 42)) };
}

// The game's UI scale (js/common/core/UIScale.js): html font-size grows with
// the screen and the UI scale option. The CSS uses 1rem = 14.4 design px
// (calibrated in-game at 1920x1080); the sizes worked out here use the same
// factor, so k = 1 gives the design size.
function uiScale() {
    let n = 18;
    try {
        // UIScale.updateScale writes it inline; computed style as a fallback
        n = parseFloat(document.documentElement.style.fontSize)
            || parseFloat(window.getComputedStyle(document.documentElement).fontSize) || 18;
    }
    catch (e) {
        // unscaled
    }
    return n / 14.4 * SIZE_BASE * sizeSetting;
}

// "Size" in the panel: 50-150 % on top of the game's scale, saved for all parks
// Size 100 % (the default) = 70 % of the 1.0.x design size. Sizes saved
// under the old key are converted once, so they look the same as before.
const SIZE_BASE = 0.7;
const SIZE_MIN = 0.5;
const SIZE_MAX = 2;
const SIZE_KEY = 'PZ2Guardian.uiSize';
const OLD_SIZE_KEY = 'PZ2Guardian.size';
let sizeSetting = readSize();
function readSize() {
    let v = NaN;
    try {
        v = parseFloat(window.localStorage.getItem(SIZE_KEY));
        if (isNaN(v)) {
            const old = parseFloat(window.localStorage.getItem(OLD_SIZE_KEY));
            if (!isNaN(old)) {
                v = Math.round(old / SIZE_BASE * 20) / 20;
                v = Math.min(SIZE_MAX, Math.max(SIZE_MIN, v));
                window.localStorage.setItem(SIZE_KEY, String(v));
            }
        }
    }
    catch (e) {
        // default
    }
    return v >= SIZE_MIN && v <= SIZE_MAX ? v : 1;
}
function stepSize(dir) {
    sizeSetting = Math.round(Math.min(SIZE_MAX, Math.max(SIZE_MIN, sizeSetting + dir * 0.05)) * 100) / 100;
    save(SIZE_KEY, sizeSetting);
    place();
    render();
}

// one line for Diagnose: the numbers the scaling works from
function scaleInfo() {
    let body = '?';
    try {
        body = document.body.style.fontSize || window.getComputedStyle(document.body).fontSize;
    }
    catch (e) {
        // unknown
    }
    const html = document.documentElement.style.fontSize || '?';
    return `UI scale: view ${window.innerWidth}x${window.innerHeight}, html ${html}, body ${body}, size ${Math.round(sizeSetting * 100)}%, k ${uiScale().toFixed(3)}`;
}

// draggable button; right-click puts it back. The button's spot is a screen
// position in px (where you dropped it), so it stays put when the scale changes.
let drag = null;
function place() {
    if (!btn) return;
    const k = uiScale();
    const pos = load(POS_KEY, null) || defaultPos();
    // off: Guardian is reached through the pause menu's Mods box only
    btn.style.display = showButton ? '' : 'none';
    btn.style.left = `${pos.x}px`;
    btn.style.top = `${pos.y}px`;
    // the CSS is in em of these: everything scales with k
    btn.style.fontSize = `${14 * k}px`;
    if (panel) {
        panel.style.fontSize = `${13 * k}px`;
        const w = panel.offsetWidth || 520 * k;
        if (menuAnchor && menuAnchor.menu) {
            placeByMenu(w, k);
            return;
        }
        const x = Math.min(Math.max(4, pos.x), window.innerWidth - w - 4);
        panel.style.left = `${x}px`;
        // below the button, or above it when there is more room there
        const nBtn = btn.offsetHeight || 30 * k;
        const nBelow = window.innerHeight - pos.y - nBtn - 26 * k;
        if (nBelow >= 420 * k || nBelow >= pos.y - 20 * k) {
            panel.style.bottom = '';
            panel.style.top = `${pos.y + nBtn + 4 * k}px`;
            panel.style.maxHeight = `${Math.max(200 * k, nBelow)}px`;
        }
        else {
            panel.style.top = '';
            panel.style.bottom = `${window.innerHeight - pos.y + 4 * k}px`;
            panel.style.maxHeight = `${Math.max(200 * k, pos.y - 20 * k)}px`;
        }
    }
}
// Opened from the pause menu: left of the menu, else right of the Mods box,
// level with the menu's top.
function placeByMenu(w, k) {
    const { menu, box } = menuAnchor;
    let x = menu.left - 8 * k - w;
    if (x < 4) x = (box ? box.right : menu.right) + 8 * k;
    x = Math.min(Math.max(4, x), window.innerWidth - w - 4);
    const y = Math.max(4, menu.top);
    panel.style.left = `${x}px`;
    panel.style.bottom = '';
    panel.style.top = `${y}px`;
    panel.style.maxHeight = `${Math.max(200 * k, window.innerHeight - y - 20 * k)}px`;
}

// re-place when the game rescales (window size, UI scale option)
window.addEventListener('resize', () => requestAnimationFrame(place));
import('/js/common/core/UIScale.js').then(m => {
    if (m && m.onScaleChange && m.onScaleChange.add) m.onScaleChange.add(() => requestAnimationFrame(place));
}).catch(() => { });

function build() {
    if (btn) return;
    btn = el('div', 'PZ2GD_toggle', 'Guardian');
    btn.title = `PZ2Guardian ${VERSION}: escapes and stuck transport boxes (drag to move, right-click to reset)`;
    btn.addEventListener('mousedown', e => {
        if (e.button != 0) return;
        const pos = load(POS_KEY, null) || defaultPos();
        drag = { sx: e.clientX, sy: e.clientY, x: pos.x, y: pos.y, moved: false };
        e.stopPropagation();
    });
    window.addEventListener('mousemove', e => {
        if (!drag) return;
        const dx = e.clientX - drag.sx;
        const dy = e.clientY - drag.sy;
        if (Math.abs(dx) + Math.abs(dy) > 4) drag.moved = true;
        if (drag.moved) {
            save(POS_KEY, { x: Math.max(0, drag.x + dx), y: Math.max(0, drag.y + dy) });
            place();
        }
    });
    window.addEventListener('mouseup', () => {
        if (drag && !drag.moved) toggle(!open);
        drag = null;
    });
    btn.addEventListener('contextmenu', e => {
        e.preventDefault();
        save(POS_KEY, null);
        place();
    });
    panel = el('div', 'PZ2GD_panel');
    panel.style.display = 'none';
    panel.addEventListener('mousedown', e => e.stopPropagation());
    wheelScroll(panel);
    document.body.appendChild(btn);
    document.body.appendChild(panel);
    place();
    label();
    addPauseMenuEntry({
        id: 'PZ2Guardian',
        order: 1,
        label: labelText,
        onSelect: anchor => {
            if (open && menuAnchor) {
                toggle(false);
                return;
            }
            menuAnchor = anchor;
            toggle(true);
        },
        // a panel opened from the menu closes with it
        onMenuClosed: () => {
            if (open && menuAnchor) toggle(false);
        },
    });
}

// ------------------------------------------------------------- Lua -> JS
engine.on('PZ2Guardian_Hello', (version, storeText, storeStatus) => {
    connected = true;
    // the saved settings first: the triggers below hand them to Lua
    applyStore(String(storeText || ''), String(storeStatus || ''));
    engine.trigger('PZ2Guardian_Times', timesText());
    engine.trigger('PZ2Guardian_Settings', bits());
});
// Lua's answer to PZ2Guardian_StoreSave
engine.on('PZ2Guardian_StoreSaved', result => {
    result = String(result || '');
    storeState = result == 'saved' || result == 'kept'
        ? `saved in the player save (${new Date().toLocaleTimeString()})`
        : `could not save (${result})`;
});
engine.on('PZ2Guardian_State', text => {
    try {
        st = JSON.parse(text);
    }
    catch (e) {
        // never silently keep showing old data
        diag = `Guardian state unreadable (${e}): ${String(text).slice(0, 300)}`;
        render();
        return;
    }
    addTotals();
    label();
    render();
});
engine.on('PZ2Guardian_DiagnoseResult', text => {
    diag = `${scaleInfo()}\nsettings: ${storeState}; page ${window.location && window.location.pathname}\n${String(text)}`;
    render();
});
engine.on('PZ2Guardian_Log', text => {
    diag = String(text);
    render();
});
setInterval(() => {
    if (connected) engine.trigger('PZ2Guardian_Tick', 1);
}, TICK_MS);

try {
    loadCSS('mods/pz2guardian');
}
catch (e) {
    // unstyled, still works
}
const boot = setInterval(() => {
    if (document.body) {
        clearInterval(boot);
        build();
    }
}, 250);
console.log(`[PZ2Guardian] v${VERSION} loaded`);
