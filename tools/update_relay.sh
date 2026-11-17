#!/usr/bin/env bash
# The relay is https://github.com/drewburr-labs/game-relay. The game keeps only
# its client side: relay/ is a copy of game-relay's two client scripts, taken
# at the tag named in relay/VERSION. This refreshes it.
#
# tests/test_net.gd plays through a real relay, so this also fetches the
# server's scripts at the same tag into tests/relay_server/. Git ignores that
# folder: the server is never committed here, and exports leave tests/ out.
#
#   tools/update_relay.sh            fetch both again at the pinned tag
#   tools/update_relay.sh v1.2.0     move the pin to that tag and fetch both
#   tools/update_relay.sh --server   fetch only the server the tests run
#   tools/update_relay.sh --check    fail if relay/ differs from the pinned tag
#
# After moving the pin, run the tests and commit relay/. Change these scripts
# in game-relay, never here: the next update would overwrite it.
set -euo pipefail

REPO="drewburr-labs/game-relay"
CLIENT_FILES=(relay_protocol.gd relay_client.gd)
# The server loads relay_protocol.gd from beside itself, so it gets its own.
SERVER_FILES=(relay_server.gd relay_metrics.gd relay_protocol.gd)

cd "$(dirname "$0")/.."
mode=update
tag="$(cat relay/VERSION)"
case "${1:-}" in
	--check) mode=check ;;
	--server) mode=server ;;
	"") ;;
	-*) echo "unknown option $1" >&2; exit 2 ;;
	*) tag="$1" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fetch() {
	for f in "$@"; do
		[ -f "$tmp/$f" ] && continue
		curl -fsSL -o "$tmp/$f" "https://raw.githubusercontent.com/$REPO/$tag/$f" \
			|| { echo "can't fetch $f from $REPO at $tag" >&2; exit 1; }
	done
}

if [ "$mode" = check ]; then
	fetch "${CLIENT_FILES[@]}"
	bad=0
	for f in "${CLIENT_FILES[@]}"; do
		cmp -s "$tmp/$f" "relay/$f" || { echo "relay/$f differs from $REPO $tag" >&2; bad=1; }
	done
	[ "$bad" = 0 ] && echo "relay/ matches $REPO $tag"
	exit "$bad"
fi

# Fetch everything before changing anything, so a failure leaves both as they were.
[ "$mode" = update ] && fetch "${CLIENT_FILES[@]}"
fetch "${SERVER_FILES[@]}"

if [ "$mode" = update ]; then
	for f in "${CLIENT_FILES[@]}"; do
		cp "$tmp/$f" "relay/$f"
	done
	echo "$tag" > relay/VERSION
	echo "relay/ is now $REPO $tag"
fi

rm -rf tests/relay_server
mkdir -p tests/relay_server
for f in "${SERVER_FILES[@]}"; do
	cp "$tmp/$f" "tests/relay_server/$f"
done
echo "$tag" > tests/relay_server/VERSION
echo "tests/relay_server/ is now the $REPO $tag server"
