-- Duchess the Cat: procedural animation (hand-written). Include cat_rig.lua BEFORE this file. No #version line
-- (included). Pure: plain math + the Vec / Quat / Transform constructors only, no engine state - the server runs it too
-- and the offline test runs it without the game. Adapted from Mochi the Corgi's dog_anim.lua (same conventions).
--
-- Defines only globals:
--   CatPose(a, out)  fills out[partName] = Transform(centre, rot): each part's .vox CENTRE and rotation in the cat's
--                    ROOT frame (origin = ground point under the cat, +y up, +z forward = the nose, +x = the cat's left).
--                    Existing out[] transforms are updated in place. Also out.__mouth = Vec (between the jaws).
--   a = {st, t, base, phase, speed, tail, puff, flick, talk, purr, crouch, scared, time, lookYaw, lookPitch}:
--     st     a state of CAT_STATES (unknown -> "stand"); t = seconds in it
--     base   the posture under a one-shot act ("stand" / "sit" / "loaf" / "curl")
--     phase  gait phase (radians), advanced by distance: phase = phase + dist / CatStride(speed) * 2 * pi
--     speed  m/s on the ground (walk / trot / the zoomies' gallop)
--     tail   0..1: the tail up (content, greeting: a question mark), 0 = carried low behind
--     puff   0..1: angry / spooked - tail up and stiff, back up, head low
--     flick  0..1: annoyed - the tail tip lashes
--     talk   0..1: the jaw moves (a reply being said)
--     purr   0..1: being petted - eyes-half-closed look (head tilted up, a slow lean into the hand)
--     crouch 0..1: stalking - belly low, head low and forward, slow
--     scared 0..1: running away - tail tucked low, crouched
--     time   GetTime() (breathing, tail sway)
--     lookYaw, lookPitch  degrees the head turns toward something (+yaw = to the cat's left, +pitch = up); clamped
--   CAT_STATES     every state CatPose knows
--   CAT_ACTS       one-shot acts: {dur = s, after = the posture left at the end (nil: back to the base)}
--   CatStride(speed)  metres per gait cycle
--
-- Conventions (as Mochi): a part's local rotation is in its PARENT's frame about its own pivot. pitch about +x:
-- positive tips the nose DOWN, swings a hanging leg BACK and RAISES a part that points backward (the tail: its angle
-- above the backward horizontal grows by the pitch); yaw about +y: positive turns toward +x (the cat's left); roll about
-- +z: positive moves a hanging leg toward +x. The whole-cat motion ("root") is a rotation about a point plus a lift.
-- The tail is two parts: tail1 (rest: back and 30 deg down) and tail2 (its tip half, rest 10 deg down).

CAT_STATES = {"stand", "walk", "sit", "loaf", "curl", "dead", "sit_down", "loaf_down", "curl_up", "stand_up", "stretch",
	"groom", "meow", "hiss", "swat", "pounce", "leap", "land", "startle", "flinch", "eat", "rub", "knead", "yawn",
	"chatter", "roll", "shake", "die", "sniff", "blink", "swim"}
CAT_ACTS = {
	sit_down = {dur = 0.4, after = "sit"}, loaf_down = {dur = 0.6, after = "loaf"}, curl_up = {dur = 0.9, after = "curl"},
	stand_up = {dur = 0.4, after = "stand"},
	stretch = {dur = 2.4, after = "stand"}, groom = {dur = 3.2, after = nil}, meow = {dur = 0.8, after = nil},
	hiss = {dur = 1.4, after = nil}, swat = {dur = 0.55, after = nil}, pounce = {dur = 1.3, after = "stand"},
	leap = {dur = 0.8, after = "stand"}, land = {dur = 0.25, after = "stand"}, startle = {dur = 0.9, after = "stand"},
	flinch = {dur = 0.35, after = nil}, eat = {dur = 1.8, after = nil}, rub = {dur = 2.0, after = "stand"},
	knead = {dur = 3.0, after = nil}, yawn = {dur = 2.0, after = nil}, chatter = {dur = 1.5, after = nil},
	roll = {dur = 2.6, after = "stand"}, shake = {dur = 0.6, after = nil}, die = {dur = 1.0, after = "dead"},
	sniff = {dur = 2.0, after = nil}, blink = {dur = 1.2, after = nil},
}

local rad, sin, cos, abs, floor = math.rad, math.sin, math.cos, math.abs, math.floor
local pi = math.pi

local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local function smooth(x) x = clamp(x, 0, 1) return x * x * (3 - 2 * x) end
local function lerp(a, b, s) return a + (b - a) * s end
local function bump(t, a, b, fade) return smooth((t - a) / fade) * (1 - smooth((t - b) / fade)) end   -- (up from a, down by b)

function CatStride(speed)
	if not speed or speed < 0.1 then return 0.4 end
	if speed < 2.0 then return 0.36 + speed * 0.06 end            -- (walk: neat little steps)
	return clamp(0.5 + (speed - 2.0) * 0.12, 0.5, 1.3)              -- (trot -> the zoomies' gallop)
end

-- ---- quaternions as plain numbers {x, y, z, w}
local function qmul(a, b)
	return a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2], a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
		a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4], a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3]
end
local function qrot(q, x, y, z)
	local qx, qy, qz, qw = q[1], q[2], q[3], q[4]
	local tx = 2 * (qy * z - qz * y); local ty = 2 * (qz * x - qx * z); local tz = 2 * (qx * y - qy * x)
	return x + qw * tx + (qy * tz - qz * ty), y + qw * ty + (qz * tx - qx * tz), z + qw * tz + (qx * ty - qy * tx)
end
-- Ry(yaw) * Rx(pitch) * Rz(roll), degrees
local function euler(pitch, yaw, roll)
	local hp, hy, hr = rad(pitch or 0) / 2, rad(yaw or 0) / 2, rad(roll or 0) / 2
	local Y = {0, sin(hy), 0, cos(hy)}
	local X = {sin(hp), 0, 0, cos(hp)}
	local Z = {0, 0, sin(hr), cos(hr)}
	local a, b, c, d = qmul(Y, X)
	return {qmul({a, b, c, d}, Z)}
end

-- a frame = {q = quat, p = {x, y, z}}: a point x goes to q * x + p
local function compose(F, G)                                     -- F * G
	local x, y, z = qrot(F.q, G.p[1], G.p[2], G.p[3])
	return {q = {qmul(F.q, G.q)}, p = {F.p[1] + x, F.p[2] + y, F.p[3] + z}}
end
local function apply(F, v)
	local x, y, z = qrot(F.q, v[1], v[2], v[3])
	return F.p[1] + x, F.p[2] + y, F.p[3] + z
end
-- rotation q about point c, then a lift (dx, dy, dz)
local function about(q, c, dx, dy, dz)
	local x, y, z = qrot(q, -c[1], -c[2], -c[3])
	return {q = q, p = {c[1] + x + (dx or 0), c[2] + y + (dy or 0), c[3] + z + (dz or 0)}}
end

local PARTS = nil
local function rig()
	if PARTS then return end
	PARTS = {}
	for _, p in ipairs(CAT_RIG.parts) do
		PARTS[#PARTS + 1] = {name = p.name, parent = p.parent, pivot = p.pivot, center = p.center}
	end
end

-- ---- the pose description: P[part] = {pitch, yaw, roll}; root = {pitch, yaw, roll, about = {x,y,z}, lift = {x,y,z}}
local NAMES = {"body", "head", "jaw", "tail1", "tail2", "leg_fl", "leg_fr", "leg_bl", "leg_br"}
local LEGS = {"leg_fl", "leg_fr", "leg_bl", "leg_br"}
local function blank(P)
	for _, n in ipairs(NAMES) do
		local r = P[n]
		if not r then r = {0, 0, 0}; P[n] = r end
		r[1], r[2], r[3] = 0, 0, 0
	end
	P.root = P.root or {0, 0, 0, about = {0, 0, 0}, lift = {0, 0, 0}}
	local R = P.root
	R[1], R[2], R[3] = 0, 0, 0
	R.about[1], R.about[2], R.about[3] = 0, 0.24, 0
	R.lift[1], R.lift[2], R.lift[3] = 0, 0, 0
	return P
end

local function copyPose(src, dst)
	for k, r in pairs(src) do
		if k == "root" then
			dst.root = dst.root or {0, 0, 0, about = {0, 0, 0}, lift = {0, 0, 0}}
			for i = 1, 3 do dst.root[i] = r[i]; dst.root.about[i] = r.about[i]; dst.root.lift[i] = r.lift[i] end
		else
			dst[k] = dst[k] or {0, 0, 0}
			for i = 1, 3 do dst[k][i] = r[i] end
		end
	end
	return dst
end

-- an angle s of the way from a to b, the short way round (a roll ends near 360: blending that back the long way would
-- turn her round backwards - Mochi's lesson)
local function alerp(a, b, s)
	local d = (b - a) % 360
	if d > 180 then d = d - 360 end
	return a + d * s
end

local function mix(A, B, s)
	for k, r in pairs(B) do
		local q = A[k]
		if k == "root" then
			for i = 1, 3 do q[i] = alerp(q[i], r[i], s); q.about[i] = lerp(q.about[i], r.about[i], s); q.lift[i] = lerp(q.lift[i], r.lift[i], s) end
		else
			for i = 1, 3 do q[i] = alerp(q[i], r[i], s) end
		end
	end
	return A
end

-- ---- postures (the still poses; the acts move between them)
local SHOULDER = {0, 0.20, 0.13}           -- (the sit rotates about the front shoulders: the rump goes down to the ground)
local SIT_PITCH = -34

local function posStand(P)
	P.tail1[1] = 10                          -- (carried a little below level, the tip rising)
	P.tail2[1] = 15
	return P
end

local function posSit(P)                   -- (upright on her haunches, front legs straight, the tail round the paws)
	local R = P.root
	R[1] = SIT_PITCH; R.about[1], R.about[2], R.about[3] = SHOULDER[1], SHOULDER[2], SHOULDER[3]
	P.leg_fl[1], P.leg_fr[1] = -SIT_PITCH, -SIT_PITCH   -- (front legs upright again)
	P.leg_bl[1], P.leg_br[1] = -46, -46      -- (hind legs folded forward under the belly, paws down)
	P.leg_bl[3], P.leg_br[3] = 10, -10
	P.head[1] = -SIT_PITCH - 6               -- (undoes the body's tilt: the face level, looking a little up)
	P.tail1[1] = 62; P.tail1[2] = 55         -- (the tail along the ground, curled round to her right side: the
	P.tail2[1] = -8; P.tail2[2] = 45         --  root's -34 tips it down, +62 lays it flat)
	return P
end

local function posLoaf(P)                  -- (the bread loaf: all four paws tucked under, a round lump)
	local R = P.root
	R.lift[2] = -0.135
	P.leg_fl[1], P.leg_fr[1] = 92, 92        -- (front paws folded back under the chest)
	P.leg_bl[1], P.leg_br[1] = -95, -95      -- (hind legs forward under the belly)
	P.head[1] = -6
	P.tail1[1] = 20; P.tail1[2] = -50        -- (the tail along her side, tucked in)
	P.tail2[2] = -40
	return P
end

local function posCurl(P)                  -- (asleep: a donut - lying low with all paws tucked, the head turned back
	posLoaf(P)                               --  along her side, the tail wrapped round to the front)
	local R = P.root
	R.lift[2] = -0.145
	P.body[2] = 8
	P.head[1] = 30; P.head[2] = 55; P.head[3] = 20
	P.tail1[1] = 15; P.tail1[2] = 80
	P.tail2[1] = 5; P.tail2[2] = 75
	return P
end

local function posDead(P)                  -- (on her side, stiff legs out)
	local R = P.root
	R[3] = 85; R.about[1], R.about[2], R.about[3] = 0, 0.2, 0; R.lift[2] = -0.1
	for _, n in ipairs(LEGS) do P[n][3] = -14 end
	P.leg_fl[1], P.leg_fr[1], P.leg_bl[1], P.leg_br[1] = -20, -25, 20, 25
	P.head[1] = 12; P.head[3] = -8
	P.jaw[1] = 16
	P.tail1[1] = 25
	return P
end

local POSTURES = {stand = posStand, sit = posSit, loaf = posLoaf, curl = posCurl, dead = posDead}
CAT_POSTURES = {"stand", "sit", "loaf", "curl", "dead"}

local function posture(P, name)
	blank(P)
	local f = POSTURES[name] or posStand
	return f(P)
end

-- ---- moving
local function gait(P, a)
	posture(P, "stand")
	local sp = clamp(a.speed or 1.0, 0, 9)
	local ph = a.phase or 0
	local gal = smooth((sp - 3.2) / 1.4)       -- (trot -> gallop between 3.2 and 4.6 m/s: the zoomies)
	local amp = lerp(20, 42, smooth((sp - 0.4) / 3.5)) * smooth(sp / 0.2)
	-- walk / trot: diagonal pairs (fl + br, fr + bl); gallop: front pair together, hind pair a while later (a bound)
	local s1, s2 = sin(ph), sin(ph + pi)
	P.leg_fl[1] = lerp(amp * s1, amp * 1.2 * sin(ph), gal)
	P.leg_br[1] = lerp(amp * s1, amp * 1.25 * sin(ph + 2.4), gal)
	P.leg_fr[1] = lerp(amp * s2, amp * 1.2 * sin(ph + 0.3), gal)
	P.leg_bl[1] = lerp(amp * s2, amp * 1.25 * sin(ph + 2.7), gal)
	P.root.lift[2] = abs(cos(ph)) * lerp(0.008, 0.035, gal) - 0.004
	P.body[1] = lerp(0, 9 * sin(ph + 1.2), gal)                -- (the bound flexes the back)
	P.body[3] = lerp(2 * sin(ph), 0, gal)
	P.head[1] = -2 + 2 * sin(ph * 2) - P.body[1]
	P.tail1[1] = lerp(P.tail1[1], 30, gal); P.tail2[1] = lerp(P.tail2[1], 0, gal)   -- (streams out behind)
	return P
end

-- ---- swimming: a paddle (front paws reach and pull, hind legs kick), nose up out of the water, the tail floating
-- straight out behind; the paddle never stops, even treading water (a.time drives it)
local function paddle(P, a)
	posture(P, "stand")
	local sp = clamp((a.speed or 0) / 0.8, 0, 1)
	local ph = (a.time or 0) * lerp(6.5, 9, sp)
	local amp = lerp(26, 38, sp)
	local R = P.root
	R[1] = -12; R.about[1], R.about[2], R.about[3] = 0, 0.25, 0   -- (nose up, rump down)
	R.lift[2] = 0.008 * sin(ph * 2)
	P.leg_fl[1] = -30 + amp * sin(ph)
	P.leg_fr[1] = -30 + amp * sin(ph + pi)
	P.leg_bl[1] = 25 + amp * 0.8 * sin(ph + pi * 0.5)
	P.leg_br[1] = 25 + amp * 0.8 * sin(ph + pi * 1.5)
	P.body[3] = 3 * sin(ph)
	P.head[1] = 4 - 2 * sin(ph * 2)
	P.tail1[1], P.tail2[1] = 14, -4
	P.tail1[2] = 8 * sin(ph * 0.5)
	return P
end

-- ---- acts (one-shots); t = seconds since the act started; base = the posture it starts from
local S1 = {}

-- P = the posture "from" moved s of the way to the posture "to"
local function between(P, from, to, s)
	posture(S1, from)
	posture(P, to)
	if s < 1 then mix(S1, P, s); copyPose(S1, P) end
	return P
end

local function act(P, a, st, t)
	local base = a.base or "stand"
	if st == "sit_down" then
		return between(P, base == "sit" and "stand" or base, "sit", smooth(t / 0.4))
	elseif st == "loaf_down" then
		return between(P, base == "loaf" and "stand" or base, "loaf", smooth(t / 0.6))
	elseif st == "curl_up" then                                -- (turns round once, then flops down curled)
		local turn = smooth(clamp(t / 0.5, 0, 1))
		if t < 0.5 then
			posture(P, base == "curl" and "stand" or base)
			P.root[2] = 300 * turn; P.root.about[1], P.root.about[2], P.root.about[3] = 0, 0, 0
			return P
		end
		between(P, "stand", "curl", smooth((t - 0.5) / 0.4))
		return P
	elseif st == "stand_up" then
		return between(P, base, "stand", smooth(t / 0.4))
	elseif st == "stretch" then                                -- (the downward stretch: front paws far out, chest
		posture(P, "stand")                                      --  down, butt up, tail high; then a back-leg stretch)
		local d = bump(t, 0.0, 1.3, 0.4)
		local R = P.root
		R[1] = 22 * d; R.about[1], R.about[2], R.about[3] = 0, 0.20, -0.14
		R.lift[2] = -0.02 * d
		P.leg_fl[1], P.leg_fr[1] = lerp(0, -62, d), lerp(0, -62, d)
		P.leg_bl[1], P.leg_br[1] = lerp(0, -20, d), lerp(0, -20, d)
		P.head[1] = -18 * d
		P.tail1[1] = lerp(P.tail1[1], 95, d)
		local h = bump(t, 1.4, 2.2, 0.25)                        -- (then one hind leg stretched out behind)
		P.leg_bl[1] = P.leg_bl[1] + 55 * h
		P.root[1] = P.root[1] - 6 * h
		P.jaw[1] = 25 * bump(t, 0.4, 1.0, 0.25)                 -- (a little yawn in it)
		return P
	elseif st == "groom" then                                  -- (licks a front paw, then washes over an ear with it)
		posture(P, base)
		local up = bump(t, 0.0, 2.9, 0.3)
		local lick = bump(t, 0.3, 1.6, 0.2)
		local wash = bump(t, 1.6, 2.8, 0.2)
		local paw = base == "loaf" and -60 or -95
		P.leg_fr[1] = lerp(P.leg_fr[1], paw + 10 * sin(t * 6) * wash, up)
		P.leg_fr[3] = -18 * up
		P.head[1] = P.head[1] + 22 * lick - 20 * wash
		P.head[2] = P.head[2] - 10 * up
		P.head[3] = P.head[3] - 25 * wash * (0.6 + 0.4 * sin(t * 6))
		P.jaw[1] = lick * (3 + 5 * abs(sin(t * 12)))
		return P
	elseif st == "meow" then                                   -- (head up, the mouth opens wide, closes)
		posture(P, base)
		local d = bump(t, 0.05, 0.6, 0.15)
		P.head[1] = P.head[1] - 14 * d
		P.jaw[1] = 30 * d
		return P
	elseif st == "hiss" then                                   -- (side-on, back up, head low, mouth wide, tail puffed)
		posture(P, (base == "loaf" or base == "curl") and "stand" or base)
		local d = bump(t, 0.0, 1.2, 0.15)
		local R = P.root
		R[2] = 25 * d; R.about[1], R.about[2], R.about[3] = 0, 0, 0
		R.lift[2] = R.lift[2] + 0.03 * d
		P.body[1] = -6 * d
		P.head[1] = P.head[1] + 18 * d; P.head[2] = -25 * d
		P.jaw[1] = 34 * d + 3 * d * sin(t * 40)
		P.tail1[1] = lerp(P.tail1[1], 70, d); P.tail2[1] = lerp(P.tail2[1], -10, d)
		return P
	elseif st == "swat" then                                   -- (a quick right paw strike out ahead and down)
		posture(P, base == "loaf" and "loaf" or (base == "curl" and "stand" or base))
		local k = clamp(t / 0.55, 0, 1)
		local strike = t < 0.18 and smooth(t / 0.18) or (1 - smooth((t - 0.18) / 0.3))
		P.leg_fr[1] = lerp(P.leg_fr[1], -115, strike)
		P.leg_fr[3] = -8 * strike
		P.head[1] = P.head[1] - 8 * strike
		P.root.lift[3] = 0.03 * strike
		P.jaw[1] = 10 * strike * (1 - k)
		return P
	elseif st == "pounce" then                                 -- (crouch, the butt wiggle, the leap, paws out, land)
		posture(P, "stand")
		local R = P.root
		if t < 0.7 then
			local c = smooth(t / 0.2)
			R.lift[2] = -0.06 * c
			P.leg_fl[1], P.leg_fr[1] = -35 * c, -35 * c
			P.leg_bl[1], P.leg_br[1] = 35 * c, 35 * c
			P.head[1] = 10 * c
			P.body[2] = 10 * sin(t * 30) * smooth((t - 0.2) / 0.1)   -- (the wiggle)
			P.tail1[1] = -15 * c; P.tail2[2] = 30 * sin(t * 12) * c
		elseif t < 1.05 then
			local k = (t - 0.7) / 0.35
			R.lift[2] = 0.28 * sin(k * pi)
			R[1] = lerp(-18, 15, k)
			P.leg_fl[1], P.leg_fr[1] = -80 * sin(k * pi), -80 * sin(k * pi)
			P.leg_bl[1], P.leg_br[1] = 60 * sin(k * pi), 60 * sin(k * pi)
			P.head[1] = -R[1] * 0.5
			P.tail1[1] = 25
		else
			R.lift[2] = -0.04 * (1 - smooth((t - 1.05) / 0.25))
			P.leg_fl[1], P.leg_fr[1] = -20, -20
		end
		return P
	elseif st == "leap" then                                   -- (in the air: stretched out, front paws reaching)
		posture(P, "stand")
		local k = clamp(t / 0.6, 0, 1)
		P.root[1] = lerp(-12, 10, k)
		P.leg_fl[1], P.leg_fr[1] = lerp(-30, -70, k), lerp(-30, -70, k)
		P.leg_bl[1], P.leg_br[1] = lerp(50, 30, k), lerp(50, 30, k)
		P.tail1[1] = 25; P.tail2[1] = 0
		P.head[1] = -P.root[1] * 0.6
		return P
	elseif st == "land" then                                   -- (absorbs the landing)
		posture(P, "stand")
		local d = 1 - smooth(t / 0.25)
		P.root.lift[2] = -0.04 * d
		P.leg_fl[1], P.leg_fr[1] = -15 * d, -15 * d
		P.leg_bl[1], P.leg_br[1] = 15 * d, 15 * d
		return P
	elseif st == "startle" then                                -- (the cucumber jump: straight up, arched, tail a brush)
		posture(P, "stand")
		local k = clamp(t / 0.55, 0, 1)
		local up = t < 0.55 and sin(k * pi) or 0
		local arch = bump(t, 0, 0.8, 0.1)
		P.root.lift[2] = 0.38 * up
		P.root.lift[3] = -0.15 * smooth(k)
		P.root[2] = 40 * smooth(k); P.root.about[1], P.root.about[2], P.root.about[3] = 0, 0, 0
		P.body[1] = -8 * arch
		for _, n in ipairs(LEGS) do P[n][3] = (n == "leg_fl" or n == "leg_bl") and 12 * arch or -12 * arch end
		P.head[1] = 15 * arch
		P.jaw[1] = 22 * arch
		P.tail1[1] = 90 * arch; P.tail2[1] = -20 * arch
		return P
	elseif st == "flinch" then                                 -- (hurt: a jolt away, head down, tail low)
		posture(P, base)
		local d = sin(clamp(t / 0.35, 0, 1) * pi)
		P.root.lift[3] = P.root.lift[3] - 0.05 * d
		P.root[3] = P.root[3] + 5 * d * sin(t * 40)
		P.head[1] = P.head[1] + 20 * d
		P.tail1[1] = P.tail1[1] - 30 * d
		P.jaw[1] = 16 * d
		return P
	elseif st == "eat" then                                    -- (head down to it, little chews)
		posture(P, base == "curl" and "stand" or base)
		local d = bump(t, 0.0, 1.5, 0.25)
		P.head[1] = lerp(P.head[1], 50, d)
		P.jaw[1] = d * (3 + 10 * abs(sin(t * 10)))
		return P
	elseif st == "rub" then                                    -- (rubs her cheek and side along someone's legs)
		posture(P, "stand")
		local d = bump(t, 0.0, 1.8, 0.25)
		local sway = sin(t * 3.2)
		P.root[3] = -10 * d * (0.5 + 0.5 * sway)
		P.root[2] = 18 * d * sway; P.root.about[1], P.root.about[2], P.root.about[3] = 0, 0, 0
		P.head[3] = -20 * d; P.head[2] = 20 * d * sway; P.head[1] = -8 * d
		P.tail1[1] = lerp(P.tail1[1], 100, d); P.tail2[1] = lerp(P.tail2[1], 35, d)
		return P
	elseif st == "knead" then                                  -- (making biscuits: the front paws press in turn)
		posture(P, base == "loaf" and "sit" or base)
		local d = bump(t, 0.0, 2.7, 0.3)
		local k = sin(t * 7)
		P.leg_fl[1] = P.leg_fl[1] - (k > 0 and 35 * k or 0) * d
		P.leg_fr[1] = P.leg_fr[1] - (k < 0 and -35 * k or 0) * d
		P.head[1] = P.head[1] - 10 * d
		return P
	elseif st == "yawn" then                                   -- (head up, a huge slow yawn)
		posture(P, base)
		local d = bump(t, 0.0, 1.5, 0.4)
		P.head[1] = P.head[1] - 20 * d
		P.jaw[1] = 40 * bump(t, 0.25, 1.3, 0.35)
		return P
	elseif st == "chatter" then                                -- (staring up at something, the jaw chattering)
		posture(P, base == "curl" and "sit" or base)
		local d = bump(t, 0.0, 1.3, 0.15)
		P.head[1] = P.head[1] - 22 * d
		P.jaw[1] = d * (6 + 6 * sin(t * 45))
		P.tail2[2] = 25 * d * sin(t * 15)
		return P
	elseif st == "roll" then                                   -- (flops over onto her back, paws up: "pet my belly")
		local k = smooth(clamp(t / 0.6, 0, 1)) * (1 - smooth((t - 2.1) / 0.45))
		between(P, base == "curl" and "loaf" or base, "loaf", smooth(t / 0.3))
		local R = P.root
		R[3] = 150 * k; R.about[1], R.about[2], R.about[3] = 0, 0.15, 0
		R.lift[2] = lerp(R.lift[2], 0.11, k)
		for _, n in ipairs(LEGS) do P[n][1] = lerp(P[n][1], (n == "leg_fl" or n == "leg_fr") and -60 or -30, k) end
		P.leg_fl[1] = P.leg_fl[1] + 15 * k * sin(t * 4)
		P.head[1] = P.head[1] + 15 * k; P.head[3] = -45 * k             -- (her cheek on the ground)
		return P
	elseif st == "shake" then                                  -- (a quick head shake)
		posture(P, base)
		local d = bump(t, 0.0, 0.5, 0.08)
		P.head[3] = P.head[3] + 22 * d * sin(t * 45)
		return P
	elseif st == "die" then                                    -- (a slow collapse onto her side)
		local f = smooth(clamp(t / 0.8, 0, 1))
		between(P, base, "dead", f)
		P.root.lift[2] = P.root.lift[2] + 0.05 * sin(f * pi)
		return P
	elseif st == "sniff" then                                  -- (nose down, a careful sniff)
		posture(P, base)
		local d = bump(t, 0.0, 1.7, 0.3)
		P.head[1] = lerp(P.head[1], 35, d) + 3 * sin(t * 16) * d
		P.head[2] = P.head[2] + 14 * sin(t * 1.8) * d
		return P
	elseif st == "blink" then                                  -- (the slow blink: head tips up and down, "I love you")
		posture(P, base)
		local d = bump(t, 0.1, 1.0, 0.3)
		P.head[1] = P.head[1] - 10 * d
		return P
	end
	return posture(P, base)
end

-- ---- the overlays every state gets: tail mood, puff, flick, talking jaw, purr, crouch, scared, breathing, looking
local STILL = {dead = true, die = true, roll = true, curl = true, curl_up = true}
local function overlays(P, a, st)
	local tm = a.time or 0
	local still = STILL[st] or st == "swim"                           -- (in the water: no moods on the tail)
	-- the tail: up in a question mark when content (on her feet), low otherwise; never quite still
	local up = clamp(a.tail or 0, 0, 1)
	if up > 0 and (st == "stand" or st == "walk" or st == "rub" or st == "meow") then
		P.tail1[1] = lerp(P.tail1[1], 100, up)
		P.tail2[1] = lerp(P.tail2[1], 32, up)
	end
	if not still then
		P.tail2[2] = P.tail2[2] + 10 * sin(tm * 1.1) + 5 * sin(tm * 2.7)
		P.tail1[2] = P.tail1[2] + 4 * sin(tm * 0.8)
	end
	local flick = clamp(a.flick or 0, 0, 1)
	if flick > 0 and not still then                               -- (annoyed: the tip lashes side to side)
		P.tail2[2] = P.tail2[2] + 45 * flick * sin(tm * 9)
		P.tail1[2] = P.tail1[2] + 15 * flick * sin(tm * 9 - 0.6)
	end
	local puff = clamp(a.puff or 0, 0, 1)
	if puff > 0 and not still then                                -- (angry / spooked: tail straight up and stiff)
		P.tail1[1] = lerp(P.tail1[1], 85, puff); P.tail2[1] = lerp(P.tail2[1], -5, puff)
		P.head[1] = P.head[1] + 10 * puff
		P.root.lift[2] = P.root.lift[2] + 0.02 * puff
	end
	local scared = clamp(a.scared or 0, 0, 1)
	if scared > 0 and not still then
		P.tail1[1] = lerp(P.tail1[1], -55, scared); P.tail2[1] = lerp(P.tail2[1], 10, scared)
		P.head[1] = P.head[1] + 12 * scared
		P.root.lift[2] = P.root.lift[2] - 0.03 * scared
	end
	local crouch = clamp(a.crouch or 0, 0, 1)
	if crouch > 0 and (st == "stand" or st == "walk") then       -- (stalking: belly low, legs angled, head low ahead)
		P.root.lift[2] = P.root.lift[2] - 0.05 * crouch
		P.leg_fl[1], P.leg_fr[1] = P.leg_fl[1] - 38 * crouch, P.leg_fr[1] - 38 * crouch
		P.leg_bl[1], P.leg_br[1] = P.leg_bl[1] + 38 * crouch, P.leg_br[1] + 38 * crouch
		P.head[1] = P.head[1] + 6 * crouch
		P.tail1[1] = lerp(P.tail1[1], -5, crouch)
	end
	local talk = clamp(a.talk or 0, 0, 1)
	if talk > 0 and st ~= "meow" and st ~= "hiss" and st ~= "yawn" then
		P.jaw[1] = math.max(P.jaw[1], talk * (4 + 12 * abs(sin(tm * 12 + sin(tm * 4)))))
	end
	local purr = clamp(a.purr or 0, 0, 1)
	if purr > 0 and not STILL[st] then                            -- (leaning into the hand, chin up)
		P.head[1] = P.head[1] - 12 * purr
		P.head[3] = P.head[3] + 8 * purr * sin(tm * 0.9)
	end
	if st ~= "dead" and st ~= "die" and st ~= "roll" then
		P.body[1] = P.body[1] + 0.7 * sin(tm * (st == "curl" and 1.4 or 2.4))   -- (breathing; slower asleep)
		if st ~= "curl" then
			local ly = clamp(a.lookYaw or 0, -60, 60)
			local lp = clamp(a.lookPitch or 0, -25, 45)
			local free = (st == "groom" or st == "eat" or st == "pounce" or st == "leap" or st == "sniff" or st == "stretch") and 0 or 1
			P.head[2] = P.head[2] + ly * free
			P.head[1] = P.head[1] - lp * free
		end
	end
end

-- ---- forward kinematics into out
local frames = {}
local function solve(P, out)
	rig()
	local R = P.root
	local rootF = about(euler(R[1], R[2], R[3]), R.about, R.lift[1], R.lift[2], R.lift[3])
	for _, q in ipairs(PARTS) do
		local r = P[q.name] or {0, 0, 0}
		local local_ = about(euler(r[1], r[2], r[3]), q.pivot)
		local F = q.parent and frames[q.parent] or rootF
		F = compose(F, local_)
		frames[q.name] = F
		local x, y, z = apply(F, q.center)
		local t = out[q.name]
		if t then
			t.pos[1], t.pos[2], t.pos[3] = x, y, z
			t.rot[1], t.rot[2], t.rot[3], t.rot[4] = F.q[1], F.q[2], F.q[3], F.q[4]
		else
			out[q.name] = Transform(Vec(x, y, z), Quat(F.q[1], F.q[2], F.q[3], F.q[4]))
		end
	end
	local m = CAT_RIG.mouth
	local hf = frames.head
	if m and hf then
		local x, y, z = apply(hf, m)
		local v = out.__mouth
		if v then v[1], v[2], v[3] = x, y, z else out.__mouth = Vec(x, y, z) end
	end
end

local KNOWN = {}
for _, s in ipairs(CAT_STATES) do KNOWN[s] = true end

local work = {}
-- the pose DESCRIPTION for a (angles per part + the root motion; reused table: copy it to keep it)
function CatDescribe(a)
	local st = KNOWN[a.st] and a.st or "stand"
	local P
	if st == "walk" then P = gait(work, a)
	elseif st == "swim" then P = paddle(work, a)
	elseif POSTURES[st] then P = posture(work, st)
	else P = act(work, a, st, a.t or 0) end
	overlays(P, a, st)
	return P
end

-- a description -> out (each part's centre + rotation in the root frame, out.__mouth)
function CatSolve(P, out)
	solve(P, out)
	return out
end

function CatPose(a, out)
	return CatSolve(CatDescribe(a), out)
end

-- blending a state change: CatPoseCopy(P, keep) keeps a description; CatPoseMix(A, B, s) moves A s of the way to B
CatPoseCopy = copyPose
CatPoseMix = mix
