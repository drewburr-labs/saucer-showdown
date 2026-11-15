extends RefCounted
## The night-farm greybox map: one mirrored screen, plus the platform graph bots
## use to get around. Every platform except the ground is one-way (jump up
## through it, down + jump to drop through it).

const Cfg = preload("res://scripts/sim/config.gd")

enum { UP, DOWN, GAP }

# Platform tiers, 95 px apart so one jump reaches the next tier.
const T1 := 565.0
const T2 := 470.0
const T3 := 375.0
const T4 := 280.0


class Plat extends RefCounted:
	var x0: float
	var x1: float
	var y: float

	func _init(a: float, b: float, c: float) -> void:
		x0 = a
		x1 = b
		y = c


class Edge extends RefCounted:
	var kind := 0
	var xs := PackedFloat32Array() # where to stand to take this hop
	var dir := 0.0 # GAP only
	var land_x := 0.0 # GAP only

	func nearest(x: float) -> float:
		var best := xs[0]
		for v in xs:
			if absf(v - x) < absf(best - x):
				best = v
		return best


var platforms: Array[Plat] = [] # index 0 is the ground
var stations: Array[Vector2] = []
var wormholes: Array[Vector2] = []
var silo_zone: Array[Rect2] = []
var silo_point: Array[Vector2] = []
var crop_x: Array[float] = []
var overlord_spawn: Array[Vector2] = []
var pasture := Vector2(500, 780) # x range, on the ground
var tractor_start := Vector2.ZERO
var barn := Rect2()

var _next: Array = [] # [from][to] -> next platform index, or -1
var _edges: Dictionary = {} # from * 64 + to -> Edge


func _init() -> void:
	_build_farm()
	_build_nav()


func _build_farm() -> void:
	platforms.append(Plat.new(0.0, Cfg.W, Cfg.GROUND_Y))
	_mirrored(90, 250, T1) # step up to the silo
	_mirrored(340, 540, T1) # wormhole deck
	_mirrored(0, 150, T2) # silo ledge
	_mirrored(200, 390, T2)
	_single(500, 780, T2) # barn roof
	_mirrored(80, 240, T3)
	_mirrored(380, 540, T3)
	_single(580, 700, T3)
	_mirrored(210, 440, T4) # probe decks
	_single(560, 720, T4)

	stations = [Vector2(325, T4 - 24), Vector2(640, T4 - 24), Vector2(Cfg.W - 325, T4 - 24)]
	wormholes = [Vector2(440, T1 - 24), Vector2(Cfg.W - 440, T1 - 24)]
	silo_zone = [Rect2(0, T2 - 100, 70, 100), Rect2(Cfg.W - 70, T2 - 100, 70, 100)]
	silo_point = [Vector2(40, T2 - Cfg.GREY_HALF.y), Vector2(Cfg.W - 40, T2 - Cfg.GREY_HALF.y)]
	crop_x = [150.0, Cfg.W - 150.0]
	overlord_spawn = [Vector2(150, 190), Vector2(Cfg.W - 150, 190)]
	tractor_start = Vector2(Cfg.W / 2.0, Cfg.GROUND_Y - Cfg.TRACTOR_HALF.y)
	barn = Rect2(520, T2, 240, Cfg.GROUND_Y - T2)


func _single(x0: float, x1: float, y: float) -> void:
	platforms.append(Plat.new(x0, x1, y))


func _mirrored(x0: float, x1: float, y: float) -> void:
	platforms.append(Plat.new(x0, x1, y))
	platforms.append(Plat.new(Cfg.W - x1, Cfg.W - x0, y))


func grey_spawn(team: int, slot: int) -> Vector2:
	var x := 40.0 + 34.0 * slot
	return Vector2(x if team == 0 else Cfg.W - x, Cfg.GROUND_Y - Cfg.GREY_HALF.y)


## The platform a thing at `p` is standing on or would fall onto.
func plat_under(p: Vector2) -> int:
	var best := 0
	var best_y := INF
	for i in platforms.size():
		var pl := platforms[i]
		if p.x >= pl.x0 and p.x <= pl.x1 and pl.y >= p.y - 2.0 and pl.y < best_y:
			best_y = pl.y
			best = i
	return best


## First hop from platform `from` towards platform `to`, or null if there is none.
func edge(from: int, to: int) -> Edge:
	var hop: int = _next[from][to]
	if hop < 0:
		return null
	return _edges[from * 64 + hop]


func _first_below(a: int, x: float) -> int:
	var best := -1
	var best_y := INF
	for i in platforms.size():
		var pl := platforms[i]
		if i != a and pl.y > platforms[a].y + 1.0 and x >= pl.x0 and x <= pl.x1 and pl.y < best_y:
			best_y = pl.y
			best = i
	return best


func _build_nav() -> void:
	var n := platforms.size()
	for a in n:
		for b in n:
			if a == b:
				continue
			var pa := platforms[a]
			var pb := platforms[b]
			var rise := pa.y - pb.y # > 0 when b is above a
			var lo := maxf(pa.x0, pb.x0) + 14.0
			var hi := minf(pa.x1, pb.x1) - 14.0
			var e := Edge.new()
			if rise > 1.0 and rise <= 100.0 and hi >= lo:
				e.kind = UP
				var x := lo
				while x <= hi:
					e.xs.append(x)
					x += 8.0
			elif rise < -1.0 and a != 0 and hi >= lo:
				e.kind = DOWN
				var x := lo
				while x <= hi:
					if _first_below(a, x) == b:
						e.xs.append(x)
					x += 8.0
			elif absf(rise) <= 1.0:
				var gap_r := pb.x0 - pa.x1
				var gap_l := pa.x0 - pb.x1
				if gap_r > 0.0 and gap_r <= 110.0:
					e.kind = GAP
					e.dir = 1.0
					e.xs.append(pa.x1 - 6.0)
					e.land_x = pb.x0 + 20.0
				elif gap_l > 0.0 and gap_l <= 110.0:
					e.kind = GAP
					e.dir = -1.0
					e.xs.append(pa.x0 + 6.0)
					e.land_x = pb.x1 - 20.0
			if e.xs.size() > 0:
				_edges[a * 64 + b] = e

	# Breadth-first from every platform, remembering the first hop.
	_next.clear()
	for s in n:
		var first: Array[int] = []
		first.resize(n)
		first.fill(-1)
		var queue: Array[int] = [s]
		var seen := {s: true}
		while not queue.is_empty():
			var cur: int = queue.pop_front()
			for t in n:
				if seen.has(t) or not _edges.has(cur * 64 + t):
					continue
				seen[t] = true
				first[t] = t if cur == s else first[cur]
				queue.append(t)
		_next.append(first)
