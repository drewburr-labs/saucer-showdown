# CLAUDE.md

## Always commit and push

Claude runs on a remote development machine. The user can only test, review or try work once it is on GitHub, so:

- **Commit and push every finished piece of work without asking.** Don't stop at "want me to commit?" — just do it.
- Push the current branch to `origin` (`git push -u origin HEAD`). If you're on `main`, make a branch first.
- Commit in sensible steps as you go rather than one giant commit at the end, and push after each.
- Never force-push or rewrite history that's already pushed unless the user asks.
- Pushing is the finish line. Don't open pull requests, or offer to, unless the user asks for one.

## Project

Godot 4.7 (standard build, GL Compatibility) team arcade brawler. See README.md for gameplay, layout and release process.

- `scripts/sim/` is the whole game as a deterministic simulation with no nodes or rendering. Keep it that way: rendering must never feed back into the sim.
- `scripts/view/` draws the sim's state each frame. `art.gd` loads the SVG sprites in `assets/sprites/` and recolours magenta placeholders (`#ff00ff`, `#800080`, `#ff80ff`) per team.
- SVG sprites are imported as "keep" (each has a `.svg.import` with `importer="keep"`); new sprites need that file too. The SVG renderer ignores `<pattern>` fills.

## Commands

```bash
godot --headless --path . --import
godot --headless --path . --script tests/test_sim.gd
godot --headless --path . --script tests/test_updater.gd
```

Visual checks (this machine has no display, so wrap screenshots in `xvfb-run`):

```bash
xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --script tools/screenshot.gd -- /path/to/out 3 12 30
godot --headless --path . --script tools/sprite_sheet.gd -- /path/to/sprites.png
```

Run the tests before every commit, and look at screenshots after any change to `scripts/view/` or `assets/`.
