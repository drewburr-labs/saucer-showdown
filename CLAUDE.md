# CLAUDE.md

## Always commit and push

Claude runs on a remote development machine. The user can only test, review or try work once it is on GitHub, so:

- **Commit and push every finished piece of work without asking.** Don't stop at "want me to commit?" — just do it.
- Push straight to `main` on `origin`, not to a feature branch. From a worktree branch: `git fetch origin && git rebase origin/main && git push origin HEAD:main`.
- Commit in sensible steps as you go rather than one giant commit at the end, and push after each.
- Never force-push or rewrite history that's already pushed unless the user asks.
- Pushing is the finish line. Don't open pull requests, or offer to, unless the user asks for one.

## Project

Godot 4.7 (standard build, GL Compatibility) team arcade brawler. See README.md for gameplay, layout and release process.

- `scripts/sim/` is the whole game as a deterministic simulation with no nodes or rendering. Keep it that way: rendering must never feed back into the sim.
- `scripts/ui/` is the menus (home, settings, online lobby, in-game menu); they only call into `main.gd`. They must all work with a gamepad alone (`tests/test_menus.gd` checks every enabled control is reachable); `pad_keyboard.gd` is the on-screen keyboard for text fields. Player settings live in `scripts/settings.gd`.
- `scripts/audio/sound.gd` plays sound from the sim's events and state, like the view. Every sound in `assets/sounds/` is made by `tools/make_sounds.gd`; edit a recipe there and re-run it rather than editing audio files. Loops are set to loop in their `.import` files.
- `scripts/view/` draws the sim's state each frame. `art.gd` loads the SVG sprites in `assets/sprites/` and recolours magenta placeholders (`#ff00ff`, `#800080`, `#ff80ff`) per team.
- `relay/` is the relay server and everything its Docker image needs; CI rebuilds the image only when that folder changes. Its scripts load each other by relative path and depend on nothing outside it. The game loads `relay/relay_protocol.gd` and `relay/relay_client.gd`, and other games copy them, so they must depend on nothing but each other, and `relay/` must never get its own `project.godot` (Godot would skip the folder in exports). Bump `VERSION` in `relay_protocol.gd` when the relay's wire format changes. The relay's metrics (`relay_metrics.gd`, listed in `relay/README.md`) are served on a private TCP port, never the game's UDP port, and must never name a room code or a player's address; a new server script needs adding to the Dockerfile's `COPY`.
- SVG sprites are imported as "keep" (each has a `.svg.import` with `importer="keep"`); new sprites need that file too. The SVG renderer ignores `<pattern>` fills.

## Commands

```bash
godot --headless --path . --import
godot --headless --path . --script tests/test_sim.gd
godot --headless --path . --script tests/test_updater.gd
godot --headless --path . --script tests/test_net.gd
godot --headless --path . --script tests/test_relay_metrics.gd
godot --headless --path . --script tests/test_input.gd
godot --headless --path . --script tests/test_menus.gd
```

Visual checks (this machine has no display, so wrap screenshots in `xvfb-run`):

```bash
xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --script tools/screenshot.gd -- /path/to/out 3 12 30
xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --script tools/menu_shots.gd -- /path/to/out
godot --headless --path . --script tools/sprite_sheet.gd -- /path/to/sprites.png
```

Every test has a `TIME_LIMIT` (see `tests/watchdog.gd`): past it, the run fails and names the step it was stuck on instead of hanging. Keep a new test well inside its limit, and don't raise a limit to make a slow test pass. `test_net` takes free ports at random, so it can run alongside another copy.

Run the tests before every commit, and look at screenshots after any change to `scripts/view/`, `scripts/ui/` or `assets/`.
