# Saucer Showdown

A team arcade brawler: two alien fleets fight over one farm, and there are three ways to win a map.

This is the **prototype** (step 1 of the concept doc): one map, bots in every seat a human doesn't take, and all three win conditions working. The art is a first pass of hand-written SVG sprites; there is no sound yet.

![Screenshot](docs/screenshot.png)

## Run it

Needs Godot 4.7 (standard build).

```bash
godot --path .
```

Or open the folder in the Godot editor and press F5.

## How to win a map

| Win | Goal |
| --- | --- |
| Military | Shoot down the rival Overlord 3 times (each saucer takes 3 hits) |
| Economic | Bank 12 cows in your silo |
| Tractor | Ride the farmer's tractor into your crop circle |

A match is best of 3 maps.

## Controls

| | Move | Jump | Fire / use | Tractor beam | Switch unit | Join |
| --- | --- | --- | --- | --- | --- | --- |
| Player 1 | WASD | Space | J | K | Q | always in |
| Player 2 | Arrows | Up | . | / | Enter | Enter |
| Gamepad | Stick / D-pad | A | X | B | Y | Start |

- **Overlord (saucer):** flies freely. Fire shoots where you're moving. Hold the beam over a cow or a teammate to lift it, and fly it wherever you like; you're slow while beaming. Touch a Probe Station to claim it.
- **Grey:** runs and jumps; down + jump drops through a platform. Touching a cow picks it up. Carry it to your silo ledge to bank it. Press use next to the tractor to ride it (use or jump to hop off).
- **Probe Station** (upper decks): stand in it with a cow to become a warrior with a ray gun and a short hover. Warriors can't carry cows or ride the tractor. Enemy-claimed stations are locked.
- **Wormhole** (lower decks): stand in it with a cow for a permanent speed boost.
- **Probed cows:** a cow the Overlord beams through a Probe Station glows, is slower to carry, and banks for 2.
- **Cow heists:** an enemy grey that touches a cow in your beam takes it.
- **Saucer damage:** a saucer takes 3 hits to bring down. It smokes after one and sparks after two; the bar beside its lives shows what's left. A fresh saucer is back to full.
- **Saucer wrecks:** a downed saucer stays where it falls as a platform until its Overlord respawns.

Other keys: F1 controls, F2 team size (2v2 or 4v4), F3 hand Player 1's seat to a bot and watch, F5 check for an update (and install it when one is offered), R restart, Esc pause.

## Layout

```
scripts/
  main.gd              game shell: seats, score, fixed-tick loop
  sim/                 the whole game, with no nodes or rendering
    config.gd          every tuning number
    map_data.gd        the night-farm map and the bots' platform graph
    entities.gd        unit, cow, bolt, wreck, tractor data
    sim.gd             rules and physics; step_frame() advances one tick; snapshots
    bot.gd             bot brains (write the same inputs a human does)
    input_frame.gd     one tick of every unit's input, packed into bytes
    fmath.gd           sin/cos that give the same bits on every platform
  input/local_input.gd keyboards and gamepads
  update/updater.gd    update check and self-install from GitHub Releases
  view/
    arena_view.gd      draws the arena from sim state: sprites, animation, particles, glow
    hud.gd             top bar, win banner, controls overlay
    art.gd             loads and team-colours the sprites, and the fonts
assets/
  sprites/             SVG art, one file per sprite
  fonts/               Lilita One and Fredoka (SIL Open Font License)
tools/
  screenshot.gd        runs the game and saves screenshots
  sprite_sheet.gd      saves every sprite, in both team colours, on one sheet
  sim_trace.gd         plays fixed matches and writes the sim's checksums
tests/
  test_sim.gd          headless tests for every rule and win condition
  test_updater.gd      headless tests for version ordering and asset choice
  bot_stats.gd         balance probe: how bot-only matches end
export_presets.cfg     Linux and Windows export settings
.github/workflows/
  release.yml          builds and attaches both platforms to a release
  determinism.yml      checks Linux and Windows simulate identically
```

The simulation is deterministic and separate from rendering: inputs in, one fixed tick out. That is what makes it testable headless, and it is the shape rollback netcode needs.

## Netcode groundwork

There is no online play yet, but the sim is ready for it:

- **A match is its seed plus its input frames.** `Sim.step_frame()` takes one `InputFrame` per tick: 5 bytes per unit (stick axes quantised to a signed byte, plus button bits). A unit flagged `BOT` is driven by the sim's own bot, whose seed comes from the match seed, so bots need no network traffic and switching a seat between human and bot is just a different frame.
- **Rewind:** `save_state()` and `load_state()` snapshot everything, bots included. Loading reuses objects with the same id, so the view's animations survive a rollback.
- **Desync check:** `checksum()` is a 32-bit hash of the state, for peers to compare.
- **Same bits everywhere:** the sim uses only `+ - * /`, `sqrt` and `floor`, which IEEE 754 defines exactly. Anything else (sin, cos, rotations) goes through `fmath.gd`. The Determinism workflow plays fixed matches on Linux and Windows and fails if their checksums ever differ. Keep new sim code to those operations too.

A 4v4 tick with bots costs about 0.2 ms, so rewinding and replaying 7 ticks every frame takes under 2 ms.

## Art

Every sprite is a plain SVG in `assets/sprites`, so it can be edited in Inkscape or any text editor. They are imported as "Keep File" and shipped as-is; `scripts/view/art.gd` rasterises them at 2× when the game starts.

- **Team colours:** parts drawn in magenta are recoloured per team: `#ff00ff` becomes the team colour, `#800080` its shade and `#ff80ff` its highlight.
- **Pivots:** each file's comment says which point sits on the sim's position (usually the hitbox centre) and which way it faces. Legs, arms, wheels, rings and lights are drawn in code so they can animate.
- **Not supported:** the SVG renderer ignores `<pattern>` fills, so repeat shapes by hand.

To check art changes without playing, render a sprite sheet or screenshots (screenshots need a display; use `xvfb-run -a` on a headless machine):

```bash
godot --headless --path . --script tools/sprite_sheet.gd -- sprites.png
```

```bash
godot --path . --script tools/screenshot.gd -- shots 3 12 30
```

## Tests

```bash
godot --headless --path . --script tests/test_sim.gd
```

```bash
godot --headless --path . --script tests/test_updater.gd
```

```bash
godot --headless --path . --script tests/bot_stats.gd -- 3
```

```bash
godot --headless --path . --script tools/sim_trace.gd -- trace.txt
```

## Releases and updates

Publishing a GitHub release runs `.github/workflows/release.yml`. It stamps the release's tag into the game as its version, runs the tests, exports Linux and Windows builds, and attaches them to the release as `saucer-showdown-<tag>-linux.zip` and `saucer-showdown-<tag>-windows.zip`. Each zip holds one self-contained executable.

Use tags like `v0.2.0`. Running the workflow by hand from the Actions tab builds the same zips as an artifact without touching a release.

A released build checks the repo's latest release when it starts, and again whenever you press F5 with nothing to install (the HUD says whether it is up to date). If that tag is newer than its own, the HUD offers the update; F5 then downloads the zip for the platform, checks it against the SHA-256 GitHub publishes for the asset, installs it over the running game and restarts. Pre-releases and drafts are never offered.

- The check is off in the editor, in `dev` builds (anything not built by the workflow) and in builds exported with a `steam` feature tag, since Steam updates its own installs.
- The releases must be publicly readable. While this repo is private the check gets a 404 and stays silent.
- On Windows the swap is done by a small script after the game exits, because a running `.exe` can't be replaced.

To rehearse an update against a local feed, debug exports accept `-- --update-feed=<url>` (a JSON file shaped like GitHub's "latest release" reply) and `-- --update-auto` (install without waiting for F5).

## Known rough edges

- Bot balance: since saucers take 3 hits, bot-only matches mostly end in Economic wins after roughly 2–3 minutes, still short of the 3–5 minute target.
- The Windows half of the updater has not been run on Windows yet.
- No audio, no menus, no online play yet (see Netcode groundwork). The art is a first pass, not final.
- The sim's events (bursts, "HEIST!" pop-ups) aren't rollback-aware yet: a replayed tick would show its effects again.
