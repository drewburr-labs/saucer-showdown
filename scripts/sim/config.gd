extends RefCounted
## Tuning constants for the prototype. Units are pixels and seconds.

const TICK := 1.0 / 60.0
const W := 1280.0
const H := 720.0
const GROUND_Y := 660.0
const CEIL_Y := 70.0

const TEAM_NAMES := ["Zeta Fleet", "Kepler Collective"]
const TEAM_COLORS := [Color("a66bff"), Color("5fd35f")]

# Win conditions
const OVERLORD_LIVES := 3
const SILO_GOAL := 12
const MAPS_TO_WIN := 2 # best of 3

const GRAVITY := 1800.0
const MAX_FALL := 900.0

# Greys
const GREY_HALF := Vector2(11, 15)
const GREY_RUN := 190.0
const GREY_ACCEL := 2400.0
const GREY_JUMP := 640.0 # apex ~114 px; platform tiers are 95 px apart
const SPEED_BOOST := 1.35
const CARRY_SLOW := 0.85
const PROBED_SLOW := 0.65
const GREY_RESPAWN := 3.0
const HOVER_TIME := 0.7
const HOVER_RISE := 120.0
const GATE_DWELL := 0.5
const PICKUP_CD := 0.6

# Overlords
const OV_HALF := Vector2(24, 11)
const OV_SPEED := 300.0
const OV_ACCEL := 1500.0
const OV_RESPAWN := 5.0
const BEAM_SLOW := 0.45
const BEAM_HALF_W := 34.0
const BEAM_RANGE := 190.0
const BEAM_HANG := 44.0
const BEAM_LIFT := 420.0
const WRECK_HALF := Vector2(26, 8)

# Combat
const SHIELD_TIME := 1.5
const OV_SHIELD_TIME := 2.5
const BOLT_SPEED := 480.0
const BOLT_RANGE := 280.0
const FIRE_CD := 0.45 # warrior ray gun
const OV_FIRE_CD := 0.7 # the saucer's blaster is slower, so duels can be dodged

# Cows
const COW_HALF := Vector2(15, 10)
const COW_SPAWN_EVERY := 8.0
const COW_START := 3
const COW_MAX_PASTURE := 5
const COW_MAX_TOTAL := 12
const COW_WANDER := 22.0
const PROBED_VALUE := 2

# Tractor and gates
const TRACTOR_HALF := Vector2(32, 20)
const TRACTOR_SPEED := 13.0 # "3 mph"
const GATE_RADIUS := 22.0
