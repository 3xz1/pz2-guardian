// A shared "Mods" box next to the game's pause menu (Esc: Save, Load,
// Settings, ...). The same file ships with PZ2AutoHub and PZ2Guardian.
// Every copy adds its mod's entry to one registry on window, so there is
// one box whatever the load order; the copy that loaded first draws it.
//
// The box is our own element on document.body, never inside the game's
// Preact-managed DOM: each frame it is shown it is placed beside
// .PauseMenu_root. It hides while another menu layer (Settings, Save,
// a dialog) sits on top of the pause menu, and then calls onMenuClosed.
// Green box, white buttons: the same colours as the mods' own panels.
//
//   addPauseMenuEntry({ id, order, label: () => text,
//                       onSelect: ({ menu, box }) => ..., onMenuClosed: () => ... })
//   pauseMenuSeen()  true once the box has been on screen (ever, any mod)
//   refreshPauseMenu()  redraw the labels
const SEEN_KEY = 'PZ2PauseMenu.seen';

function registry() {
    if (!window.__PZ2PauseMenu) {
        window.__PZ2PauseMenu = { version: 1, entries: [], started: false, refresh: null };
    }
    return window.__PZ2PauseMenu;
}

export function addPauseMenuEntry(entry) {
    const reg = registry();
    reg.entries = reg.entries.filter(e => e.id != entry.id);
    reg.entries.push(entry);
    reg.entries.sort((a, b) => (a.order || 0) - (b.order || 0));
    if (!reg.started) {
        reg.started = true;
        start(reg);
    }
    else if (reg.refresh) {
        reg.refresh();
    }
}

export function refreshPauseMenu() {
    const reg = registry();
    if (reg.refresh) reg.refresh();
}

export function pauseMenuSeen() {
    try {
        return window.localStorage.getItem(SEEN_KEY) === 'true';
    }
    catch (e) {
        return false;
    }
}

function markSeen() {
    try {
        window.localStorage.setItem(SEEN_KEY, 'true');
    }
    catch (e) {
        // this session only
    }
}

// The pause menu's own card, if it is on screen and nothing covers it.
function visibleMenu() {
    const menu = document.querySelector('.PauseMenu_root');
    if (!menu) return null;
    const r = menu.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return null;
    // a later layer that blocks the mouse (Settings, Save/Load, a dialog) is on top
    let layer = menu.parentNode;
    while (layer && !(layer.classList && layer.classList.contains('Layer_root'))) layer = layer.parentNode;
    for (let n = layer ? layer.nextElementSibling : null; n; n = n.nextElementSibling) {
        if (n.querySelector && n.querySelector('.Layer_background.blockPointerEvents, .Layer_background.darken')) return null;
    }
    return menu;
}

function remPx() {
    try {
        return parseFloat(document.documentElement.style.fontSize)
            || parseFloat(window.getComputedStyle(document.documentElement).fontSize) || 18;
    }
    catch (e) {
        return 18;
    }
}

function start(reg) {
    let box = null;
    let list = null;
    let shown = false;
    // Colours as the mods' panels: the game's bar green with white text,
    // white buttons with dark green text (the game's own button component
    // is green too, so it would not stand out on the box).
    const GREEN = '#596943';
    const CREAM = '#fff2dd';
    const DARK = '#3c472e';

    function build() {
        box = document.createElement('div');
        box.className = 'PZ2PauseMenu_box';
        // inline styles: the box must not depend on which mod's CSS is loaded
        Object.assign(box.style, {
            position: 'fixed', zIndex: '8990', display: 'none', flexDirection: 'column',
            backgroundColor: GREEN, borderRadius: '0.5556rem',
            padding: '1.1111rem', width: '15rem', pointerEvents: 'auto',
        });
        box.addEventListener('mousedown', e => e.stopPropagation());
        const head = document.createElement('div');
        head.textContent = 'Mods';
        Object.assign(head.style, {
            color: CREAM, fontWeight: 'bold', fontSize: '1.1rem',
            marginBottom: '0.5556rem', textAlign: 'center',
        });
        box.appendChild(head);
        list = document.createElement('div');
        Object.assign(list.style, { display: 'flex', flexDirection: 'column' });
        box.appendChild(list);
        document.body.appendChild(box);
    }

    function select(entry) {
        const menu = document.querySelector('.PauseMenu_root');
        try {
            entry.onSelect({
                menu: menu ? menu.getBoundingClientRect() : null,
                box: box ? box.getBoundingClientRect() : null,
            });
        }
        catch (e) {
            console.log(`[PZ2PauseMenu] ${entry.id}: ${e}`);
        }
    }

    function labelOf(entry) {
        try {
            return String(entry.label());
        }
        catch (e) {
            return entry.id;
        }
    }

    function entryButton(entry) {
        const b = document.createElement('div');
        b.textContent = labelOf(entry);
        Object.assign(b.style, {
            backgroundColor: CREAM, color: DARK,
            borderRadius: '0.3rem', padding: '0.6rem 1rem', marginTop: '0.2778rem',
            textAlign: 'center', cursor: 'pointer', fontWeight: 'bold', fontSize: '1rem',
        });
        b.addEventListener('mouseenter', () => { b.style.backgroundColor = '#ffffff'; });
        b.addEventListener('mouseleave', () => { b.style.backgroundColor = CREAM; });
        b.addEventListener('click', e => {
            e.stopPropagation();
            select(entry);
        });
        return b;
    }

    function draw() {
        if (!box) return;
        list.textContent = '';
        for (const entry of reg.entries) list.appendChild(entryButton(entry));
    }
    reg.refresh = () => {
        if (shown) draw();
    };

    function place(menu) {
        const r = menu.getBoundingClientRect();
        const gap = 0.8 * remPx();
        const w = box.offsetWidth || 15 * remPx();
        // right of the menu, or left of it when the screen ends first
        let x = r.right + gap;
        if (x + w > window.innerWidth - 4) x = Math.max(4, r.left - gap - w);
        box.style.left = `${x}px`;
        box.style.top = `${Math.max(4, r.top)}px`;
    }

    function frame() {
        const menu = visibleMenu();
        if (menu) {
            if (!box) build();
            if (!shown) {
                shown = true;
                box.style.display = 'flex';
                draw();
                markSeen();
            }
            place(menu);
        }
        else if (shown) {
            shown = false;
            if (box) box.style.display = 'none';
            // closed, or covered by Settings / Save / a dialog: panels opened
            // from the box close with it
            for (const entry of reg.entries) {
                try {
                    if (entry.onMenuClosed) entry.onMenuClosed();
                }
                catch (e) {
                    // one mod's error must not stop the others
                }
            }
        }
    }
    setInterval(frame, 150);
}
