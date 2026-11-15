extends RefCounted
## Trig that gives bit-identical results on every machine. Godot's sin() and
## cos() call the platform's C library, and the Linux and Windows builds use
## different ones, so two peers could drift apart. These use only + - * / and
## floor(), which IEEE 754 rounds the same way everywhere.

const HALF_PI := PI / 2.0


## sin(x) to within about 1e-7.
static func sin_d(x: float) -> float:
	# Bring x into [-PI, PI), then fold into [-PI/2, PI/2] where the series is tight.
	x -= TAU * floor((x + PI) / TAU)
	if x > HALF_PI:
		x = PI - x
	elif x < -HALF_PI:
		x = -PI - x
	var x2 := x * x
	# Taylor series to x^13, evaluated Horner-style.
	return x * (1.0 + x2 * (-1.0 / 6.0 + x2 * (1.0 / 120.0 + x2 * (-1.0 / 5040.0
			+ x2 * (1.0 / 362880.0 + x2 * (-1.0 / 39916800.0 + x2 * (1.0 / 6227020800.0)))))))


static func cos_d(x: float) -> float:
	return sin_d(x + HALF_PI)


## v rotated by `angle` radians, like Vector2.rotated().
static func rotated(v: Vector2, angle: float) -> Vector2:
	var s := sin_d(angle)
	var c := cos_d(angle)
	return Vector2(v.x * c - v.y * s, v.x * s + v.y * c)
