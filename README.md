# Guardian for Planet Zoo 2 (version 1.2.3)

Stops escapes, brings escaped animals home, unboxes animals stuck in
transport boxes.

## Install (about 30 seconds)

1. In Steam: right-click Planet Zoo 2 > Manage > Browse local files.
   This opens your game folder (the one with PlanetZoo2.exe).
2. Copy the "Win64" folder from the zip into that game folder.
   Windows will say the folder already exists: choose "Replace" / merge.
   Nothing of the game is overwritten; only a new PZ2Guardian folder is
   added.
3. Check it worked: this file should now exist:
   `Planet Zoo 2\Win64\ovldata\PZ2Guardian\Main.ovl`
4. Start the game. It shows its normal one-time "modifications detected"
   notice; that is expected.

## Uninstall

Delete the folder `Planet Zoo 2\Win64\ovldata\PZ2Guardian`

## Updating

Copy the new "Win64" folder over the old one and choose "Replace".

## Where to find it in game

In a park: press Esc. Next to the game's menu (Save, Load, Settings...)
is a "Mods" box with a "Guardian" button that opens the panel.

There is also a "Guardian" button on the left of the screen. Drag it to
move it; right-click puts it back. It reads "Guardian (3)" when 3
animals are escaped or stuck in a box. Don't want it on screen? Switch
"Screen button" off at the top of the panel; Guardian then lives in the
Esc menu only.

Too big or too small? "Size" at the top of the panel (50-200 %).

## What it does

Each one can be switched on or off in the panel.

| Setting | Default | What it does |
|---|---|---|
| Block escapes | on | Switches animal escapes off. This is the same switch as the Sandbox option "Animal Escapes", applied in any park. |
| Send escapees home | on | An escaped animal, or one left boxed outside its habitat, is brought back by a keeper. |
| Unbox stuck animals | on | An animal left in a transport box inside its own habitat, with no move under way, is let out (the same as the game's Unbox button). |
| Paid emergency capture | off | An animal that stays loose too long is caught with the game's Emergency Capture. This costs money, so it is off by default. |

## Wait times

The -/+ buttons in the panel, in real seconds.

| Wait | Default |
|---|---|
| Escaped, before a keeper is sent | 15 s |
| Boxed outside its habitat, before sent home | 30 s |
| Boxed in its own habitat, before unboxed | 10 s |
| Between two tries for the same animal | 45 s |
| Escaped, before the paid emergency capture | 120 s |

Game speed does not change them. The wait gives the game's own staff
the first chance, and a box you made on purpose stays shut for a while.

## Results

The panel counts, for this session and all time: animals unboxed, sent
home, back in their habitat, and emergency captured (when switched on).

## What it leaves alone

- Animals already being moved (by a keeper, the vet, you or another mod).
- Animals being carried, in the Trade Centre, quarantine or vet surgery.
- Animals a vet has tranquillised.
- Everything while the game is paused.
- An animal the game keeps putting back in its box, in Franchise zoos:
  after 3 tries it is transported to its habitat once; boxed again
  after that, it is left alone for 2 minutes (the panel says why).
  In Career and Sandbox Guardian keeps unboxing it; unboxed 3 times
  within 30 s, it is transported to its habitat instead.
- A box in a broken habitat (open gate or broken barrier) stays shut, so
  the animal doesn't walk straight out again. Repair the habitat first.

## Why animals escape in the first place

Climbing animals get over walls that are not climb-proof, any animal
crosses a null barrier with nothing natural on top, and worn-out
barriers break (Fence Dilapidation). An escaped animal is tranquillised
by a vet and put in a transport box for the trip home, which is where
most "random" boxes come from.

## Compatibility

- Works alongside Mike's QoL Toolbox (formerly Genes & Gold, PZ2QoL):
  both share the in-park screen.
- Works alongside AutoHub: both share the in-park screen and the "Mods"
  box in the Esc menu.
- Settings and totals are kept in your player profile, for all parks,
  and survive a game restart.

## Changes

### 1.2.3
- Fixed: with PZ2 Essentials or More Path Stamp Sizes installed, Guardian's screen button and the "Mods" box in the Esc menu were missing and Guardian did nothing. Guardian now shares the in-park screen with them, so both work, in any install order.

### 1.2.2
- Fixed: in Career and Sandbox, animals the game kept boxing again
  (seen with aquatic animals) stayed boxed for minutes, long enough
  for guest protests. Guardian worked for a few minutes after
  loading and then seemed to stop. The 2-minute pause after 3 tries
  is now for Franchise zoos only (where the server can refuse), and
  even there the animal is first transported to its habitat once.
- Career and Sandbox: an animal boxed again within a minute of being
  unboxed is unboxed at once (no 10 s wait; that box isn't yours).
- Career and Sandbox: an animal unboxed 3 times within 30 s probably
  sits on a spot it can't use (a box opens where it stands). Guardian
  then has it transported to its habitat instead, and the count starts
  over. If no transport starts within a few seconds, it is unboxed in
  place.
- Franchise: the whole zoo sends at most 1 server request every 2 s
  (unbox, transport, send home). When many animals need help at once
  they queue, longest wait first, and the panel shows "queued".
  Career and Sandbox have no server and no limit.
- The panel row and Diagnose show what the game said at each rebox
  (habitat valid, location, whether the game asked for the box).
- Counts start over once an animal has stayed out of its box for a
  minute.
- Diagnose now also answers when Guardian has paused itself (it
  pauses while a park closes) and shows the zoo mode.

### 1.2.0
- Settings, wait times and the all-time totals are now saved for
  good: they were lost every time the game closed (the game's UI
  forgets them). They are now kept in your player profile. Set
  them once more after updating.
- With Mike's QoL Toolbox installed, its park launcher (Species
  board, Autosave) now also shows when Guardian's screen is used.
- Diagnose also shows whether the settings were saved.

### 1.1.0
- Guardian is now also in the game's Esc menu ("Mods" box next to
  Save / Load / Settings), and the screen button can be hidden
  ("Screen button" in the panel).
- Smaller default size: the new 100 % is the old 70 % (range
  50-200 %). A size you set before is kept as it looked.
- The button and panel now use the game's green UI colours.

### 1.0.3
- Fixed: when the game put an animal straight back in its box (seen
  in Franchise zoos, where the server can refuse the unbox), Guardian
  kept retrying forever. It now stops after 3 tries and leaves that
  animal alone for 2 minutes; the panel says why.
- Fixed: "Unboxed" in the Results also counted animals that went
  straight back into their box. It now only counts animals that
  stayed out for a minute.
- Diagnose now also shows what Guardian is tracking.

### 1.0.2
- New Size setting in the panel (50-150 %): makes the panel and
  button smaller or bigger, on top of the automatic scaling. Saved
  for all parks.

### 1.0.1
- The button and panel now scale with your screen resolution and the
  game's UI scale option, like the game's own panels (same size as
  before at 1920x1080). Diagnose shows the UI scale numbers.

### 1.0.0
- First release.

## Problems?

Open the panel and click "Diagnose". It lists what the mod found in the
game and the details of every escaped or boxed animal. Post a screenshot
of it with your report.

## Notes

- No game files are changed. The only thing written is the mod's own
  small entry in your player profile (its settings); nothing goes
  into park saves or online saves.
- Unofficial fan mod, not affiliated with Frontier Developments.

Building from source and the release workflow: see [CONTRIBUTING.md](CONTRIBUTING.md).
