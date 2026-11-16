# Saucer Showdown relay

Online games go through this relay so players behind home routers can connect without port forwarding. A host opens a room and gets a five-letter code; friends join with the code; the relay passes each room's packets between its host and clients without reading them.

It's plain GDScript running on a headless Godot, packaged as a container. Everything the image needs is in this folder.

| File | What it is |
| --- | --- |
| `relay_server.gd` | rooms, codes, forwarding, limits |
| `run_relay.gd` | entry point: listens and polls forever |
| `relay_protocol.gd` | the wire format, the relay's address, room codes. The game loads this file too, so it must not depend on anything else |
| `relay_probe.gd` | checks a running relay end to end |
| `Dockerfile` | the image: pinned Godot and tini, linux/amd64 and linux/arm64 |

The scripts load each other by relative path, so they work both from the game's project (`res://relay/...`) and on their own in the image. Don't give this folder its own `project.godot`: Godot would then skip it in the game's project, and the game's exports would lose `relay_protocol.gd`. The image writes a one-line project file instead.

## Run it

```bash
docker run -p 24680:24680/udp ghcr.io/drewburr-labs/saucer-showdown-relay
```

- It needs **UDP** port 24680 reachable from the internet. An HTTP proxy or tunnel won't carry it.
- It keeps no state and logs to stdout. Idle, it uses well under 1% of a core and about 35 MB.
- Options go after the image name: `--port=N` and `--bind=ADDRESS`.
- The game connects to `saucer.drewburr.com:24680` (`HOST_NAME` and `PORT` in `relay_protocol.gd`). Players can point a build elsewhere with `-- --relay=HOST[:PORT]`.

## Build it

```bash
docker build -t saucer-showdown-relay relay
```

```bash
docker run --rm -p 24680:24680/udp saucer-showdown-relay
```

Without Docker, from the game's folder:

```bash
godot --headless --path . --script res://relay/run_relay.gd -- --port=24680
```

CI (`.github/workflows/relay-image.yml`) builds the image whenever something in this folder (or the workflow) changes, smoke-tests it with the probe, and on `main` pushes it to `ghcr.io/drewburr-labs/saucer-showdown-relay` as `latest` and `sha-<commit>`. Changes elsewhere in the repo leave the image alone; "Run workflow" rebuilds it by hand.

## Check a relay

```bash
godot --headless --path . --script res://relay/relay_probe.gd -- saucer.drewburr.com
```

It opens a room, joins it as a friend and passes a packet each way, then exits 0, or 1 with the step that failed.

## Limits

- 8 machines per room: the host plus 7 friends. With couch players on some of them, that fills a 4v4.
- 400 rooms and 1024 connections in all.
- 20 wrong room codes per address per minute, against guessing.
- A host leaving closes its room and sends everyone in it home.

## Compatibility

The relay never reads game messages, so game updates don't need a new relay. Bump `VERSION` in `relay_protocol.gd` only when the relay's own wire format changes; a game with a different `VERSION` is told to update, so deploy the new relay alongside the release.
