# relay/

The game's side of [game-relay](https://github.com/drewburr-labs/game-relay), the relay server online games go through: a copy of its two client scripts. The tag they were copied at is in `VERSION`. The server itself isn't in this repo.

| File | Why the game has it |
| --- | --- |
| `relay_protocol.gd` | the wire format and the public relay's address |
| `relay_client.gd` | hosts, joins and sends; `scripts/net/relay_link.gd` drives it |

**Don't edit them here.** Change them in game-relay, tag a release there, then:

```bash
tools/update_relay.sh v1.2.0
```

Run the tests and commit. `tools/update_relay.sh --check` says whether this folder still matches its tag.

`tests/test_net.gd` plays through a real relay over loopback. `tools/update_relay.sh --server` fetches the server's scripts at the same tag into `tests/relay_server/`, which git ignores, and the test runs that itself when the folder is missing or from another tag.

Don't give this folder a `project.godot`: Godot would skip it, and exports would lose the two scripts the game loads. Everything about running, building and watching a relay is in game-relay's README.
