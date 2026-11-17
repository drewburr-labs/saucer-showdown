# Saucer Showdown relay

A relay for online games, so players behind home routers can play together without port forwarding. A host opens a room and gets a five-letter code; friends join with the code; the relay passes each room's packets between its host and clients without reading them.

Saucer Showdown uses it, but **any game can**: rooms belong to a game id, the host picks the room size, and packets keep their channel and reliability. There's a public one at `saucer.drewburr.com:24680`, or you can run your own from the image.

It's plain GDScript running on a headless Godot, packaged as a container. Everything the image needs is in this folder.

| File | What it is |
| --- | --- |
| `relay_server.gd` | rooms, codes, forwarding, limits |
| `relay_metrics.gd` | what the relay counts, written out for Prometheus |
| `relay_metrics_http.gd` | serves that over HTTP, on a port of its own |
| `run_relay.gd` | entry point: listens and polls forever |
| `relay_protocol.gd` | the wire format, the public relay's address, room codes. Games load it too, so it must not depend on anything else |
| `relay_client.gd` | a Godot game's side of the relay: host, join, send, receive. Depends only on `relay_protocol.gd` |
| `example/chat.gd` | the smallest game that uses the relay, to copy from |
| `relay_probe.gd` | checks a running relay end to end |
| `Dockerfile` | the image: pinned Godot and tini, linux/amd64 and linux/arm64 |

The scripts load each other by relative path, so they work both from the game's project (`res://relay/...`) and on their own in the image. Don't give this folder its own `project.godot`: Godot would then skip it in the game's project, and the game's exports would lose `relay_protocol.gd` and `relay_client.gd`. The image writes a one-line project file instead.

## Use it in your game

### Godot

1. Copy `relay_protocol.gd` and `relay_client.gd` into your project, side by side. They need nothing else.
2. Pick a **game id**: up to 32 printable ASCII characters with no spaces, such as `my-studio-tank-game`. Room codes only work within one game id, so another game on the same relay can't wander into your rooms.
3. Host or join, then call `poll()` every frame and handle its events:

```gdscript
const P = preload("res://net/relay_protocol.gd")
const RelayClient = preload("res://net/relay_client.gd")

var relay := RelayClient.new()

func host_game() -> void:
	relay.host(P.HOST_NAME, P.PORT, "my-tank-game", 3)   # room for 3 besides you

func join_game(code: String) -> void:
	relay.join(P.HOST_NAME, P.PORT, "my-tank-game", code)

func _process(_delta: float) -> void:
	for ev in relay.poll():
		match ev[0]:
			"room": show_code(ev[1])                 # host: tell your friends this
			"joined": my_id = ev[1]                  # you're in; the host is always 1
			"peer_in": add_player(ev[1])             # host: a client joined, by id
			"peer_out": remove_player(ev[1])         # host: and left
			"data": on_packet(ev[1], ev[2], ev[3])   # from id, bytes, channel
			"refused": show_error(ev[2])             # ev[1] says why: P.Refusal
			"failed": show_error("Can't reach the relay.")
			"closed": show_error("Connection lost.")
```

Send with `relay.send(to, bytes, channel, flags)`. A client's packets always go to the host (pass `P.HOST_ID`). The host passes a client's id, or 0 for every client. Clients never talk to each other directly; if they need to, the host passes packets on, as [`example/chat.gd`](example/chat.gd) does.

`relay_client.gd` sends bytes. It doesn't drive Godot's high-level multiplayer API (RPCs, `MultiplayerSynchronizer`). Encode your messages yourself, for example with `var_to_bytes` and `bytes_to_var` (never `allow_objects`), and check what arrives before trusting it.

Try the example against the public relay, in two terminals:

```bash
godot --headless --path . --script res://relay/example/chat.gd -- host
```

```bash
godot --headless --path . --script res://relay/example/chat.gd -- join KX4PZ
```

### Channels and reliability

Open up to 8 channels with the last argument to `host()` or `join()`. Each packet arrives on the channel it was sent on, with the same delivery:

- `ENetPacketPeer.FLAG_RELIABLE` (the default): always arrives, in order on its channel. Use it for events and chat.
- `0`: unreliable but in order; late packets are dropped. Use it for state that's replaced every frame, such as positions.
- `ENetPacketPeer.FLAG_UNSEQUENCED`: unreliable, any order.

Give every machine in a game the same number of channels. A packet sent on a channel the receiver doesn't have arrives on its last one.

### Other engines

The relay speaks [ENet](http://enet.bespin.org/) over UDP, so a client needs an ENet 1.3 library, no compression and up to 8 channels. Godot uses stock ENet, so a standard ENet library should be compatible, but only Godot clients are tested. Browsers can't send raw UDP, so web builds can't use it.

Every packet starts with a type byte. Numbers are little-endian. Send HOST and JOIN reliably on channel 0; the relay sends its own messages reliably on channel 0.

| Direction | Packet | Bytes |
| --- | --- | --- |
| game → relay | HOST | `1`, version u16 (= 2), clients u8 (1–31), game id |
| | JOIN | `2`, version u16, code (5 ASCII), game id |
| | DATA | `3`, to u32, payload. Host: a client id, or 0 for every client. Client: ignored, it goes to the host |
| relay → game | ROOM | `10`, clients u8 (what you got), code (5 ASCII) |
| | JOINED | `11`, your id u32 |
| | ERROR | `12`, refusal u8, UTF-8 reason. The relay hangs up afterwards |
| | PEER_IN | `13`, client id u32 (to the host) |
| | PEER_OUT | `14`, client id u32 (to the host) |
| | DATA | `3`, from u32 (1 is the host), payload |

Refusals: 1 bad request, 2 outdated (a different protocol version), 3 relay full, 4 no such room, 5 room full, 6 too many wrong codes. The reason text is plain English you can show players, or use the number to show your own. `relay_protocol.gd` is the authority if this table and it ever disagree.

### Good to know

- **The host is the game.** When the host leaves, its room closes and everyone in it is disconnected. There's no host migration.
- **Ids:** the host is 1; clients get ids from 2 up, never reused while the relay runs.
- **Your versions are up to you.** The relay doesn't check whether two builds of your game can play together. Check that yourself when a client joins (Saucer Showdown sends a HELLO with its protocol number, and the host turns away mismatches with a reason). Or put the version in your game id (`my-tank-game/4`) so mismatched builds can't find each other's rooms.
- **Ping:** `relay_ping()` is only the round trip to the relay. Measure the trip to the host yourself.
- **The public relay** is a hobby server with no uptime promise, and the limits below are shared by every game on it. For anything serious, run your own: it's one `docker run`.

## Run it

```bash
docker run -p 24680:24680/udp ghcr.io/drewburr-labs/saucer-showdown-relay
```

- It needs **UDP** port 24680 reachable from the internet. An HTTP proxy or tunnel won't carry it.
- It keeps no state and logs to stdout, one line per room opened and closed, with its game id. Idle, it uses well under 1% of a core and about 35 MB.
- It serves [metrics](#metrics) on **TCP** port 24681. That port is for you, not the internet: the command above doesn't publish it.
- Options go after the image name: `--port=N`, `--bind=ADDRESS`, `--metrics-port=N` and `--metrics-bind=ADDRESS`. Options replace the image's defaults, so repeat `--metrics-port=24681` to keep metrics on (leave it out and they're off).
- Saucer Showdown connects to `saucer.drewburr.com:24680` (`HOST_NAME` and `PORT` in `relay_protocol.gd`). Players can point a build elsewhere with `-- --relay=HOST[:PORT]`.

## Build it

```bash
docker build -t saucer-showdown-relay relay
```

```bash
docker run --rm -p 24680:24680/udp saucer-showdown-relay
```

Without Docker, from the game's folder (metrics are off unless you give them a port):

```bash
godot --headless --path . --script res://relay/run_relay.gd -- --port=24680 --metrics-port=24681
```

CI (`.github/workflows/relay-image.yml`) builds the image whenever something in this folder (or the workflow) changes, except `example/`, which isn't in the image. It smoke-tests the image with the probe, reads its metrics, and on `main` pushes it to `ghcr.io/drewburr-labs/saucer-showdown-relay` as `latest` and `sha-<commit>`. Changes elsewhere in the repo leave the image alone; "Run workflow" rebuilds it by hand.

## Check a relay

```bash
godot --headless --path . --script res://relay/relay_probe.gd -- saucer.drewburr.com
```

It opens a room, checks that a different game id can't join it, joins as a friend and passes a packet each way on channel 1. Then it exits 0, or 1 with the step that failed.

## Metrics

The relay counts what it's doing and serves the numbers in [Prometheus](https://prometheus.io/)'s text format:

```bash
curl http://localhost:24681/metrics
```

`/healthz` on the same port answers `ok`, for a liveness check (UDP alone gives an orchestrator nothing to poke).

**Keep the port private.** Metrics are on their own TCP port, apart from the game's UDP port, so that one can face the internet and the other not. Forward or publish only UDP 24680. Scrape 24681 from inside your network: another container, the cluster, or the same machine (`-p 127.0.0.1:24681:24681`). There's no login on it. It never gives out room codes or players' addresses, only the totals below, but they're still yours rather than the world's.

```yaml
scrape_configs:
  - job_name: saucer-relay
    static_configs:
      - targets: ["relay:24681"]
```

The relay sees machines, not players: two friends on one couch are one peer. And it can't see inside a game, so there's nothing here about matches or scores.

| Metric | Type | What it is |
| --- | --- | --- |
| `relay_rooms{game}` | gauge | rooms open now |
| `relay_room_seats{game}` | gauge | machines the open rooms have room for, hosts included |
| `relay_room_peers{game}` | gauge | machines in them now, hosts included |
| `relay_rooms_opened_total{game}`, `relay_rooms_closed_total{game}` | counter | rooms opened and closed |
| `relay_room_joins_total{game}` | counter | times a client got into a room |
| `relay_room_duration_seconds{game}` | histogram | how long each closed room was open |
| `relay_room_peak_peers{game}` | histogram | the most machines each closed room had at once |
| `relay_game_packets_total{game}`, `relay_game_bytes_total{game}` | counter | game packets taken in to pass on, and their payload |
| `relay_peer_round_trip_seconds{game}` | histogram | round trip from the relay to each machine in a room, sampled every 10 s |
| `relay_peer_packet_loss_ratio{game}` | histogram | packet loss to each of them (0 to 1), sampled with it |
| `relay_connections` | gauge | connections open now, in a room or not |
| `relay_connections_opened_total`, `relay_connections_closed_total` | counter | connections made and ended |
| `relay_refusals_total{reason}` | counter | hosts and joins turned away: `bad_request`, `outdated`, `relay_full`, `no_such_room`, `room_full`, `too_many_tries` |
| `relay_ignored_packets_total` | counter | packets dropped: empty, too big, an unknown type, or data from outside a room |
| `relay_network_sent_bytes_total`, `relay_network_received_bytes_total` | counter | traffic on the wire, ENet's overhead included (`..._packets_total` counts the UDP packets) |
| `relay_poll_duration_seconds` | histogram | how long each pass over waiting packets took. Packets wait while one runs, so this is the delay the relay adds; its `_sum` is the time spent working |
| `relay_rooms_limit`, `relay_connections_limit` | gauge | the [limits](#limits), to graph how full it is |
| `relay_info{protocol}` | gauge | always 1; the protocol version it speaks |
| `process_cpu_seconds_total`, `process_resident_memory_bytes`, `process_start_time_seconds` | | the relay process: CPU used, memory held, when it started (the first two on Linux only) |

Some things to ask of them:

```promql
sum by (game) (relay_room_peers)                               # who's playing what, right now
sum(relay_room_peers) / sum(relay_room_seats)                   # how full the rooms are
sum by (game) (increase(relay_rooms_opened_total[1d]))          # games hosted today
histogram_quantile(0.5, sum by (le) (rate(relay_room_duration_seconds_bucket[1d])))      # a typical session
histogram_quantile(0.95, sum by (le) (rate(relay_peer_round_trip_seconds_bucket[5m])))   # ping to the relay, the worst 5%
sum by (reason) (rate(relay_refusals_total[5m]))                # wrong codes, full rooms, old builds
histogram_quantile(0.99, rate(relay_poll_duration_seconds_bucket[5m]))                   # delay the relay adds
rate(process_cpu_seconds_total[5m])                             # cores in use
```

Game ids come from whoever connects, so only the first 32 the relay sees get a `game` label of their own; any more are counted together as `other`. Everything resets when the relay restarts, as counters do. Answering a scrape takes about half a millisecond with a game or two on the relay.

## Limits

- Up to 32 machines per room: the host plus 31. The host asks for how many it wants; Saucer Showdown asks for 7, which fills a 4v4 with couch players on some machines.
- 400 rooms and 1024 connections in all, shared by every game.
- 8 channels per connection, and 256 KB per packet.
- 20 wrong room codes per address per minute, against guessing.
- A host leaving closes its room and sends everyone in it home.

## Compatibility

The relay never reads game messages, so game updates don't need a new relay. Bump `VERSION` in `relay_protocol.gd` only when the relay's own wire format changes. A client with a different `VERSION` is refused as outdated, so release updated games alongside the new relay. Version 2 added game ids, room sizes and channels; version 1 clients (Saucer Showdown before this change) are told to update.
