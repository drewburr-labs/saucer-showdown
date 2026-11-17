# relay/

A copy of four scripts from [game-relay](https://github.com/drewburr-labs/game-relay), the relay server online games go through. The tag they were copied at is in `VERSION`.

| File | Why the game has it |
| --- | --- |
| `relay_protocol.gd` | the wire format and the public relay's address |
| `relay_client.gd` | hosts, joins and sends; `scripts/net/relay_link.gd` drives it |
| `relay_server.gd`, `relay_metrics.gd` | the server itself, so `tests/test_net.gd` can run a real relay over loopback |

**Don't edit them here.** Change them in game-relay, tag a release there, then:

```bash
tools/update_relay.sh v1.2.0
```

Run the tests and commit. `tools/update_relay.sh --check` says whether this folder still matches its tag.

Don't give this folder a `project.godot`: Godot would skip it, and exports would lose the two scripts the game loads. Everything about running, building and watching a relay is in game-relay's README.
