extends RefCounted
## Wire format between the game and the relay server. Every packet starts
## with a type byte; most then carry a little-endian u32 peer id.
##
##   game -> relay   HOST    [HOST, version u16]                  open a room
##                   JOIN    [JOIN, version u16, code (5 ASCII)]   join one
##                   DATA    [DATA, to u32, payload]              host: to a client id, 0 = all
##                                                                client: always to the host
##   relay -> game   ROOM    [ROOM, code]                         your room is open
##                   JOINED  [JOINED, your id u32]                you're in
##                   ERROR   [ERROR, UTF-8 reason]                then the relay hangs up
##                   PEER_IN / PEER_OUT [type, id u32]            host: a client came or went
##                   DATA    [DATA, from u32, payload]            from is 1 for the host
##
## The payloads are the game's own messages (see net_peer.gd); the relay
## never looks inside them.

const HOST_NAME := "saucer.drewburr.com"
const PORT := 24680
const VERSION := 1
const CODE_CHARS := "ABCDEFGHJKMNPQRSTUVWXYZ23456789" # no I, L, O, 0 or 1
const CODE_LEN := 5
const MAX_CLIENTS := 7 # per room, besides the host

enum { HOST = 1, JOIN = 2, DATA = 3, ROOM = 10, JOINED = 11, ERROR = 12, PEER_IN = 13, PEER_OUT = 14 }


static func with_id(type: int, id: int) -> PackedByteArray:
	var p := PackedByteArray()
	p.resize(5)
	p[0] = type
	p.encode_u32(1, id)
	return p


static func with_version(type: int) -> PackedByteArray:
	var p := PackedByteArray()
	p.resize(3)
	p[0] = type
	p.encode_u16(1, VERSION)
	return p


## "kx4pz " -> "KX4PZ", or "" if it can't be a room code.
static func normalize_code(text: String) -> String:
	var c := text.strip_edges().to_upper()
	if c.length() != CODE_LEN:
		return ""
	for ch in c:
		if not CODE_CHARS.contains(ch):
			return ""
	return c
