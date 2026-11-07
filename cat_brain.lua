-- Duchess the Cat: the cat's mind and body on the HOST (server). Include cat_rig.lua and cat_anim.lua before it.
-- No #version line (included). Globals: PUD (the state), PudServerInit(), PudServerTick(dt), PudServerUpdate(dt),
-- PudServerPostUpdate(), PudPet(p), PudCommand(name, args, speaker) (also the offline test's entry), ...
--
-- Built like Mochi the Corgi's dog_brain.lua (the user's AI dog, mochi/): the cat has no body of its own on the server -
-- it is a position, a heading and a state, published in shared.pudding for every machine's client to draw (cat_view.lua);
-- it walks by raycasts and the engine's path planner, and LEAPS up onto ledges and down from them (a cat). Her fish treats
-- are real physics bodies; the laser pointer is a tool whose red dot she can't help chasing.
--
-- Where Mochi is an eager dog who obeys, Duchess is a cat: she does what SHE wants. With nobody bossing her she follows her
-- whims (naps curled up, loafs, grooms, perches up high, gets the zoomies, knocks things over, stares, rubs against legs,
-- bats the dog's ball, ambushes the dog, demands food); her AI decides whether she does what she's asked. Petting: she
-- purrs - until she's had enough and scratches (the belly trap). Hurt or startled by a bang, she bolts on her own.
--
-- TALKING goes through Proximity Comms' agents (proxchat/tools/API_public.md "Agents"): agent "duchess". Since API 20 she
-- also hears the other agents (.hearagents) - Mochi above all, whom she talks to as a cat talks to a dog. Other agents
-- (any mod's) show up in what she knows, with where they are (from their .at), so she can follow, stalk or swat them.

PUDDING_ID = "duchess"   -- (was "pudding": renamed 2026-11-04, Koetama heard "putting")
PUDDING_NAME = "Duchess"
PUDDING_LAYER = 32                       -- (the client's cat parts, and Mochi's: never hit by our rays)
PUDDING_MASK = 255 - PUDDING_LAYER

local CFG = {
	walk = 1.1, trot = 2.6, run = 6.5,     -- m/s (run: the zoomies, bolting)
	stalk = 0.55,                          -- m/s crouched, stalking
	turn = 480,                            -- deg/s
	followNear = 1.6, followFar = 3.5,
	comeStop = 0.9,
	catchUp = 45, stuckFor = 4.0,
	publish = 0.05, agentEvery = 0.5, speakEvery = 40, noteFor = 90,
	stepUp = 0.38, gravity = 10,
	leapUp = 2.1,                          -- m: the highest ledge she jumps onto
	leapDown = 3.2,                        -- m: the deepest drop she hops down (deeper: she won't walk off it)
	leapOut = 2.4,                         -- m: the farthest a leap goes
	hp = 100, regen = 1.5, regenAfter = 8,
	treatHeal = 25,
	shotDmg = 20, shotCap = 40, shotRadius = 0.25,
	blastDmg = 80, fallSafe = 11, fallDmg = 12, carDmg = 5, carSpeed = 4,
	torchDmg = 25, fireDmg = 12, flyingSpeed = 6, flyingDmg = 1.2, blameFor = 4,
	respawn = 30, lives = 9,
	fleeFor = 8, fleeTo = 18, fleeLeg = 6, dangerMemory = 30,
	-- petting: she purrs, and after tolerance (3-7) pets within petWindow s she has had enough: a scratch
	petRange = 2.4, petWindow = 25, scratchDmg = 0.04, scratchEvery = 8,
	-- food
	hungerRate = 1 / 600,                  -- 0..1 per s (hungry after ~7 min)
	treatsStart = 8, treatRefill = 20, treatThrow = 7, treatCooldown = 1.0, treatsMax = 5,
	snatchHold = 0.8, treatFind = 7,
	-- the laser pointer
	laserRange = 40,                       -- m the beam reaches
	laserSee = 22,                         -- m from her: she notices the dot
	laserLost = 1.6,                       -- s without the dot: "where did it go?"
	pounceAt = 1.5,                        -- m from the target: she pounces
	-- whims (free time): what she does when nobody is bossing her about
	whimMin = 6, whimMax = 22,             -- s a short whim lasts
	napMin = 45, napMax = 110,             -- s a nap lasts
	nearby = 18,                           -- m: players this close are "her people right now"
	wanderLeash = 25,
	-- other agents (Mochi): too close for too long and she hisses or swats
	dogClose = 1.1, dogCloseFor = 1.5, dogEvery = 25,
	-- bangs
	shotHear = 35, blastHear = 40, blastHearPer = 40, noiseGather = 1.0, noiseEvery = 8,
	startleShot = 10, startleBlast = 25, boltShot = 6, boltBlast = 18,
	-- bored: nothing has happened for a while (her AI may tease the dog, demand attention, ...); the wait doubles
	boredAfter = 120, boredMax = 480, boredNear = 25,
	wetFor = 45,                           -- s in the water before she appears by her people (no way out found)
	swimDepth = 0.32,                      -- m her feet float below the surface (her head held out of it)
	swim = 0.8,                            -- m/s paddling
}
PUDDING_CFG = CFG
PUDDING_TREAT_TOOL, PUDDING_LASER_TOOL = "puddingtreats", "puddinglaser"

local reg = "proxchat.agent." .. PUDDING_ID
local function now() return GetTime() end

PUD = nil

local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local function hdist(a, b) local dx, dz = a[1] - b[1], a[3] - b[3] return math.sqrt(dx * dx + dz * dz) end
local function yawTo(from, to) return math.deg(math.atan2(to[1] - from[1], to[3] - from[3])) end   -- (0 = +z)
local function angDiff(a, b) local d = (b - a) % 360 if d > 180 then d = d - 360 end return d end
local function fwd(yaw) local r = math.rad(yaw) return Vec(math.sin(r), 0, math.cos(r)) end
local function rnd(a, b) return a + math.random() * (b - a) end

-- ---- players
local function players()
	local l = {}
	for _, p in ipairs(GetAllPlayers() or {}) do
		if IsPlayerValid(p) then l[#l + 1] = p end
	end
	return l
end

local function alive(p) return p and IsPlayerValid(p) and GetPlayerHealth(p) > 0 end
local function feet(p) return GetPlayerTransform(p).pos end
local function nameOf(p) local ok, n = pcall(GetPlayerName, p) return ok and n and n ~= "" and n or ("Player " .. tostring(p)) end

function PudPlayerByName(s, speaker)
	s = tostring(s or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if (s == "" or s == "me" or s == "you" or s == "him" or s == "her" or s == "them") and alive(speaker) then return speaker end
	local best = nil
	for _, p in ipairs(players()) do
		local n = nameOf(p):lower()
		if n == s then return p end
		if not best and s ~= "" and (n:sub(1, #s) == s or s:find(n, 1, true)) then best = p end
	end
	return best
end

local function nearestPlayer(pos, maxd)
	local best, bd = nil, maxd or 1e9
	for _, p in ipairs(players()) do
		if alive(p) then
			local d = hdist(feet(p), pos) + math.abs(feet(p)[2] - pos[2]) * 0.5
			if d < bd then best, bd = p, d end
		end
	end
	return best, bd
end

local function hostPlayer()
	for _, p in ipairs(players()) do
		local ok, h = pcall(IsPlayerHost, p)
		if ok and h then return p end
	end
	return players()[1]
end
PudHost = hostPlayer

-- ---- queries: our rays skip the client-drawn models (layer 32: hers, Mochi's) and her treats
local function filter()
	QueryCollisionMask(PUDDING_MASK)
	QueryRequire("physical")
	local M = PUD
	if M then for _, t in ipairs(M.treats) do if IsHandleValid(t) then QueryRejectBody(t) end end end
end

-- the ground under x,z near height y (a step up to stepUp, or down to 2 m), or nil
local function groundAt(x, y, z)
	filter()
	local top = y + CFG.stepUp + 0.05
	local hit, d = QueryRaycast(Vec(x, top, z), Vec(0, -1, 0), CFG.stepUp + 2.05, 0.06)
	if not hit then return nil end
	return top - d - 0.06
end

-- a surface under x,z between heights top and bottom with room for a cat on it, or nil
local function surfaceAt(x, z, top, bottom)
	filter()
	local hit, d = QueryRaycast(Vec(x, top, z), Vec(0, -1, 0), top - bottom, 0.06)
	if not hit then return nil end
	local y = top - d - 0.06
	filter()
	if QueryRaycast(Vec(x, y + 0.12, z), Vec(0, 1, 0), 0.35, 0.05) then return nil end   -- (no room to stand; starts
	                                                                                    --  clear of the surface itself)
	return y
end

PudSurfaceAt = surfaceAt

-- water: a cat stays out of it (seen in-game, 2026-11-04: put down in Villa Gordon's pool, she strolled about its floor)
local function wet(p)
	local ok, w = pcall(IsPointInWater, VecAdd(p, Vec(0, 0.2, 0)))
	return ok and w == true
end
PudWet = wet

-- the water's surface over p (p in the water), or nil
local function waterTop(p)
	local q = VecAdd(p, Vec(0, 0.2, 0))
	local ok, w, d = pcall(IsPointInWater, q)
	if ok and w == true and type(d) == "number" then return q[2] + d end
	return nil
end
PudWaterTop = waterTop

local function blocked(pos, dir, dist)
	filter()
	return QueryRaycast(VecAdd(pos, Vec(0, CFG.stepUp + 0.08, 0)), dir, dist, 0.06)
end

-- the arc of a leap from a to b clear? (up to its top and down again)
local function arcClear(a, b, h)
	local top = Vec((a[1] + b[1]) / 2, math.max(a[2], b[2]) + h, (a[3] + b[3]) / 2)
	local s, e = VecAdd(a, Vec(0, 0.3, 0)), VecAdd(b, Vec(0, 0.3, 0))
	for _, seg in ipairs({{s, top}, {top, e}}) do
		local v = VecSub(seg[2], seg[1])
		local l = VecLength(v)
		filter()
		if l > 0.05 and QueryRaycast(seg[1], VecScale(v, 1 / l), l, 0.08) then return false end
	end
	return true
end

local function spotNear(p, back)
	local t = GetPlayerTransform(p)
	local b = TransformToParentVec(t, Vec(0, 0, back or 1.5))
	for _, k in ipairs({1, -1, 0.5}) do
		local q = VecAdd(t.pos, VecScale(b, k))
		local g = groundAt(q[1], t.pos[2] + 0.5, q[3])
		if g and not wet(Vec(q[1], g, q[3])) then return Vec(q[1], g, q[3]) end
	end
	return VecCopy(t.pos)
end

-- ---- other agents (any mod's AI characters: Mochi above all), from Proximity Comms' registry: where each is (its .at),
-- its name and speaker number. Read every 0.5 s
local function parse3(s)
	local x, y, z = tostring(s):match("^%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)%s*$")
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	if x and y and z then return Vec(x, y, z) end
	return nil
end

function PudAgentPlace(at)
	at = tostring(at or "")
	local kind, rest = at:match("^(%a+):(.+)$")
	if not kind then return parse3(at) end
	local off
	local a, b = rest:match("^([^+]+)%+(.+)$")
	if a then rest, off = a, parse3(b) end
	if kind == "body" then
		local h = tonumber(rest)
		if not (h and IsHandleValid(h)) then return nil end
		local t = GetBodyTransform(h)
		return off and TransformToParentPoint(t, off) or t.pos
	elseif kind == "player" then
		local p = tonumber(rest)
		if not (p and IsPlayerValid(p)) then return nil end
		return VecAdd(feet(p), off or Vec(0, 1, 0))
	end
	return nil
end

local function agentsTick()
	local M = PUD
	if now() - M.othersT < 0.5 then return end
	M.othersT = now()
	local list = {}
	local ok, ids = pcall(ListKeys, "proxchat.agent")
	for _, id in ipairs(ok and type(ids) == "table" and ids or {}) do
		local b = "proxchat.agent." .. id
		if id ~= PUDDING_ID and GetString(b .. ".persona") ~= "" then
			local head = PudAgentPlace(GetString(b .. ".at"))
			if head then
				filter()
				local hit, d = QueryRaycast(head, Vec(0, -1, 0), 4, 0.05)
				local g = hit and Vec(head[1], head[2] - d - 0.05, head[3]) or Vec(head[1], head[2] - 0.7, head[3])
				local name = GetString(b .. ".name")
				list[#list + 1] = {id = id, name = name ~= "" and name or id, p = GetInt(b .. ".player"), pos = g,
					head = head, d = hdist(g, M.pos) + math.abs(g[2] - M.pos[2]) * 0.5}
			end
		end
	end
	table.sort(list, function(x, y) return x.d < y.d end)
	M.others = list
end

-- another agent by a name ("Mochi", "the dog", "puppy"); nil if none
local DOG_WORDS = {dog = true, ["the dog"] = true, puppy = true, corgi = true, ["the corgi"] = true, mutt = true,
	["the mutt"] = true, pup = true, doggo = true, ["the puppy"] = true}
function PudOtherByName(s)
	s = tostring(s or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then return nil end
	for _, o in ipairs(PUD.others) do
		local n = o.name:lower()
		if n == s or o.id:lower() == s or (#s >= 3 and n:sub(1, #s) == s) then return o end
	end
	if DOG_WORDS[s] then
		for _, o in ipairs(PUD.others) do if o.id:lower():find("mochi") or o.name:lower():find("mochi") then return o end end
		return PUD.others[1]
	end
	return nil
end

local function otherBySpeaker(n)
	for _, o in ipairs(PUD.others) do if o.p == n then return o end end
	return nil
end
PudOtherBySpeaker = otherBySpeaker

local function nearestOther() return PUD.others[1] end

-- ---- her treats (a tool: fish treats thrown or held out) and the dog's (Mochi's bone biscuits: she'll eat those too)
local function spawnBody(file, tag, pos, vel)
	local ok, ents = pcall(Spawn, string.format("<body dynamic='true' tags='%s'><vox file='%s' tags='invisible unbreakable %s'/></body>",
		tag, file, tag), Transform(pos))
	if not ok or type(ents) ~= "table" then return nil end
	for _, h in ipairs(ents) do
		if GetEntityType(h) == "body" then
			if vel then SetBodyVelocity(h, vel) end
			PUD.uncentred[h] = true
			return h
		end
	end
	return nil
end

-- a toy's shape centred on its body's origin (a fresh shape can read size 0 in its spawn frame: tried each step)
local function centreToys()
	local M = PUD
	for h in pairs(M.uncentred) do
		if not IsHandleValid(h) then M.uncentred[h] = nil
		else
			local shapes = GetBodyShapes(h) or {}
			local ok = #shapes > 0
			for _, sh in ipairs(shapes) do
				local x, y, z, vs = GetShapeSize(sh)
				if not x or x <= 0 or not vs or vs <= 0 then ok = false end
			end
			if ok then
				for _, sh in ipairs(shapes) do
					local t = GetShapeLocalTransform(sh)
					local x, y, z, vs = GetShapeSize(sh)
					local c = TransformToParentPoint(t, Vec(x * vs / 2, y * vs / 2, z * vs / 2))
					SetShapeLocalTransform(sh, Transform(VecSub(t.pos, c), t.rot))
				end
				M.uncentred[h] = nil
			end
		end
	end
end

local function cleanTreats()
	local M, l = PUD, {}
	for _, t in ipairs(M.treats) do if IsHandleValid(t) then l[#l + 1] = t end end
	M.treats = l
end

local function bodyPos(h) return GetBodyTransform(h).pos end
local function heldBy(h)
	for _, p in ipairs(players()) do
		local ok, g = pcall(GetPlayerGrabBody, p)
		if ok and g == h then return p end
	end
	return nil
end

-- every treat she could eat: hers and the dog's (by tag)
local function foods()
	local l = {}
	for _, t in ipairs(PUD.treats) do if IsHandleValid(t) then l[#l + 1] = {h = t, dog = false} end end
	local M = PUD
	if now() - (M.dogFoodT or -1e9) > 0.25 or now() < (M.dogFoodT or 0) then   -- (the dog's: looked up 4 times a second)
		local ok, dog = pcall(FindBodies, "mochitreat", true)
		M.dogFood, M.dogFoodT = ok and dog or {}, now()
	end
	for _, t in ipairs(M.dogFood) do if IsHandleValid(t) then l[#l + 1] = {h = t, dog = true} end end
	return l
end

-- the invisible body the chat hangs her speech bubble over and hears from (agent at = body:<handle>), moved to her head
-- every step. Unbreakable, and made again if it is ever gone or empty (Mochi's lesson: an empty body put him nowhere)
local function spawnAnchor()
	local M = PUD
	if M.anchor and IsHandleValid(M.anchor) then Delete(M.anchor) end
	local ok, ents = pcall(Spawn, "<body dynamic='true' tags='puddinganchor'><vox file='MOD/vox/anchor.vox' tags='invisible unbreakable puddinganchor'/></body>",
		Transform(VecAdd(M.pos, Vec(0, 0.5, 0))))
	M.anchor = nil
	if not ok or type(ents) ~= "table" then return end
	for _, h in ipairs(ents) do
		if GetEntityType(h) == "body" then
			M.anchor = h
			for _, s in ipairs(GetBodyShapes(h) or {}) do SetShapeCollisionFilter(s, PUDDING_LAYER, 0) end
		end
	end
end

local function anchorTick()
	local M = PUD
	local ok = M.anchor and IsHandleValid(M.anchor)
	if ok then
		local shapes = GetBodyShapes(M.anchor) or {}
		ok = #shapes > 0 and IsHandleValid(shapes[1]) and (GetShapeVoxelCount(shapes[1]) or 0) > 0
	end
	if not ok then spawnAnchor(); M.anchorN = M.anchorN + 1 end
end

-- ---- agent events: gathered (Mochi's rule, the user's: at most every 4 s, riding on the next line said near her when
-- someone speaks: .note); arriving, dying, coming back and a few others go at once
-- (the user, 2026-11-04: too many speech bubbles) only these get a reply of their own, and (but for MUST) at most one
-- every speakEvery s, never within RUBRIC.gap s of her last reply; the rest only ride on the next line (notes, gone
-- after noteFor s)
local URGENT = {arrive = true, die = true, back = true, noise = true, bored = true, scratched = true, water = true}
local MUST = {arrive = true, die = true, back = true}
local function api18() return GetInt("proxchat.version") >= 18 end
PudApi18 = api18

function PudHappened()
	local M = PUD
	if not M then return end
	M.happenT = now()
	M.boredWait = CFG.boredAfter
	if M.bored then M.bored = false; M.stateDirty = true end
end

local function event(kind, text)
	local M = PUD
	if kind ~= "bored" then PudHappened() end
	local P = M.pendingEv
	if next(P) == nil then M.evFirstT = now() end
	if P[kind] then P[kind].text, P[kind].n = text, P[kind].n + 1
	else
		M.evOrder = M.evOrder + 1
		P[kind] = {text = text, n = 1, order = M.evOrder}
	end
	M.lastEvent = text
	M.stateDirty = true
	if URGENT[kind] then M.evUrgent = true end
	if MUST[kind] then M.evMust = true end
end
PudEvent = event

local function idList(str)
	local l = {}
	for w in tostring(str or ""):gmatch("%S+") do
		local n = tonumber(w)
		if n then l[#l + 1] = n end
	end
	return l
end
PudIdList = idList

-- she says text without the model (API 18 .say): her noises when the AI can't answer
function PudSay(text)
	if not api18() or PUD.dead then return end
	SetString(reg .. ".say", text)
	PUD.sayN = PUD.sayN + 1
end

function PudPendingEvents()
	local list = {}
	for _, e in pairs(PUD.pendingEv) do list[#list + 1] = e end
	table.sort(list, function(a, b) return a.order < b.order end)
	local parts = {}
	for _, e in ipairs(list) do
		parts[#parts + 1] = e.text .. (e.n > 1 and string.format(" (%d times just now)", e.n) or "")
	end
	return table.concat(parts, " ")
end

-- (each tick) the waiting events stand in .note (the chat sends it with the next line she gets, then clears it);
-- nobody spoke in time (or one is urgent): one .event line of their own
local function flushEvents()
	local M = PUD
	local t = now()
	if not api18() then M.pendingEv = {}; return end                -- (an older chat: no events at all)
	local key = reg .. ".note"
	if M.noteText and GetString(key) == "" then                       -- (a line took them)
		M.pendingEv, M.noteText = {}, nil
		M.evRode = M.evRode + 1
	end
	if next(M.pendingEv) == nil then return end
	local text = PudPendingEvents()
	local quiet = t - M.evFlushT >= CFG.speakEvery and t - (M.lastReplyT or -1e9) >= PUDDING_RUBRIC.gap
	if M.evMust or (M.evUrgent and quiet) then
		ClearKey(key)
		local cur = GetString(reg .. ".event")
		SetString(reg .. ".event", cur ~= "" and (cur .. "\n" .. text) or text)
		M.pendingEv, M.noteText, M.evUrgent, M.evMust, M.evFlushT = {}, nil, false, false, t
		M.eventLines = M.eventLines + 1
	elseif t - M.evFirstT > CFG.noteFor and not M.evUrgent then      -- (old news: nobody spoke to her since)
		ClearKey(key)
		M.pendingEv, M.noteText = {}, nil
	elseif text ~= M.noteText then
		SetString(key, text)
		M.noteText = text
	end
end

function PudAgentOn()
	local s = GetString("proxchat.agents")
	return GetInt("proxchat.version") >= 17 and (s == "ready" or s == "busy")
end

-- ---- acts and postures
local function startAct(kind)
	local M = PUD
	local d = CAT_ACTS[kind]
	if not d then return false end
	M.act = {kind = kind, t0 = now(), dur = d.dur, base = M.posture}
	M.actN = M.actN + 1
	return true
end

local function queueAct(kind)
	local M = PUD
	if #M.queue >= 4 then table.remove(M.queue, 1) end
	M.queue[#M.queue + 1] = kind
end

-- the posture each act needs first ("stand" for the ones on her feet; nil: any)
local NEEDS_STAND = {stretch = true, pounce = true, rub = true, roll = false, startle = false}
local function actTick()
	local M = PUD
	local t = now()
	if M.act and t - M.act.t0 >= M.act.dur then
		local after = CAT_ACTS[M.act.kind].after
		if after then M.posture = after end
		M.act = nil
	end
	if not M.act and #M.queue > 0 then
		local k = M.queue[1]
		if NEEDS_STAND[k] and M.posture ~= "stand" then startAct("stand_up"); return end
		if (k == "sit_down" and M.posture == "sit") or (k == "loaf_down" and M.posture == "loaf")
			or (k == "curl_up" and M.posture == "curl") or (k == "stand_up" and M.posture == "stand") then
			table.remove(M.queue, 1); return
		end
		if (k == "sit_down" or k == "loaf_down") and M.posture == "curl" then startAct("stand_up"); return end
		table.remove(M.queue, 1)
		startAct(k)
	end
end

local function wake(grumpy)
	local M = PUD
	if not M.asleep then return end
	M.asleep = false
	M.stateDirty = true
	if M.activity and M.activity.kind == "nap" then M.activity = nil end
	if grumpy then M.flickUntil = now() + 6 end
	queueAct("stand_up")
	if not grumpy and math.random() < 0.6 then queueAct("stretch") end
end
PudWake = wake

local function setMode(mode, who)
	local M = PUD
	M.mode, M.target = mode, who
	M.hunt = nil
	M.path, M.pathPts = nil, nil
	M.stuckT = 0
	if mode ~= "free" then M.activity = nil end
end

-- ---- leaps: onto a ledge, down from one, a pounce. A ballistic hop from where she is to a point, over dur s
local function startLeap(to, kind)
	local M = PUD
	local from = VecCopy(M.pos)
	local dist = VecLength(VecSub(to, from))
	local up = to[2] - from[2]
	M.leap = {from = from, to = VecCopy(to), t0 = now(), dur = clamp(0.42 + dist * 0.12, 0.45, 0.85),
		h = up > 0 and (0.35 * up + 0.25) or 0.22, kind = kind or "leap"}
	M.yaw = yawTo(from, to)
	M.act = nil
	startAct("leap")
	M.speed, M.vy = 0, 0
	M.posture = "stand"
	M.leapN = M.leapN + 1
end

-- (each step) along the leap's arc; true while she is in the air
local function leapTick()
	local M = PUD
	local L = M.leap
	if not L then return false end
	local k = (now() - L.t0) / L.dur
	if k >= 1 then
		M.pos = VecCopy(L.to)
		M.leap = nil
		M.vy, M.grounded = 0, true
		startAct("land")
		return false
	end
	local p = VecLerp(L.from, L.to, k)
	p[2] = p[2] + 4 * L.h * k * (1 - k)
	M.pos = p
	return true
end

-- a leap up onto a ledge ahead of her (dir, unit): the ledge's top within leapUp, room on it, the arc clear
local function ledgeAhead(dir)
	local M = PUD
	for _, d in ipairs({0.45, 0.75, 1.1}) do
		local x, z = M.pos[1] + dir[1] * d, M.pos[3] + dir[3] * d
		local y = surfaceAt(x, z, M.pos[2] + CFG.leapUp + 0.2, M.pos[2] + CFG.stepUp)
		if y and y - M.pos[2] > CFG.stepUp and y - M.pos[2] <= CFG.leapUp then
			local to = Vec(x + dir[1] * 0.15, y, z + dir[3] * 0.15)
			if not wet(to) and arcClear(M.pos, to, 0.35 * (y - M.pos[2]) + 0.25) then return to end
		end
	end
	return nil
end

-- a hop down to the ground ahead (a drop deeper than a step, at most leapDown)
local function dropAhead(dir)
	local M = PUD
	for _, d in ipairs({0.6, 0.9, 1.3}) do
		local x, z = M.pos[1] + dir[1] * d, M.pos[3] + dir[3] * d
		local y = surfaceAt(x, z, M.pos[2] + 0.3, M.pos[2] - CFG.leapDown)
		if y and M.pos[2] - y > CFG.stepUp and not wet(Vec(x, y, z)) and arcClear(M.pos, Vec(x, y, z), 0.22) then return Vec(x, y, z) end
	end
	return nil
end

-- a perch near her (within r m): a flat top 0.5 - leapUp above where she stands, room on it, not on an edge (the
-- ground under four points round it at the same height); near her people if any (near: a player to be close to)
local function findPerch(r, near)
	local M = PUD
	local c = M.pos
	local best, bs = nil, -1e9
	local a0 = math.random() * 2 * math.pi
	local rings = math.ceil((r - 0.6) / 0.45)                         -- (rings 0.45 m apart: a 1 m crate has two inside it)
	for i = 0, rings * 16 - 1 do                                     -- (a polar grid: rings x 16 directions)
		local ring = math.floor(i / 16)
		local a = a0 + (i % 16) * math.pi / 8 + ring * 0.2
		local d = 0.6 + (r - 0.6) * (ring + 0.5) / rings
		local x, z = c[1] + math.sin(a) * d, c[3] + math.cos(a) * d
		local y = surfaceAt(x, z, c[2] + CFG.leapUp + 0.3, c[2] + 0.5)
		if y and y - c[2] <= CFG.leapUp and not wet(Vec(x, y, z)) then
			local flat = true
			for _, o in ipairs({{0.13, 0}, {-0.13, 0}, {0, 0.13}, {0, -0.13}}) do
				local yy = surfaceAt(x + o[1], z + o[2], y + 0.3, y - 0.3)
				if not yy or math.abs(yy - y) > 0.06 then flat = false; break end
			end
			if flat then
				local sc = (y - c[2]) - d * 0.15 + math.random() * 0.3
				if near then sc = sc - hdist(Vec(x, 0, z), near) * 0.2 end
				if sc > bs then best, bs = Vec(x, y, z), sc end
			end
		end
	end
	return best
end
PudFindPerch = findPerch

-- ---- health: harm, bolting, lives
local function bodyMid(b)
	local lo, hi = GetBodyBounds(b)
	return VecScale(VecAdd(lo, hi), 0.5), lo, hi
end

local function attackerName(a)
	if not a then return "something" end
	if a.p then return nameOf(a.p) end
	return a.what or "that thing"
end

local function dangerPos(D)
	if D.p then return alive(D.p) and feet(D.p) or D.pos end
	if D.body and IsHandleValid(D.body) then return GetBodyTransform(D.body).pos end
	if D.other then
		local o = PudOtherByName(D.other)
		return o and o.pos or D.pos
	end
	return D.pos
end

local function startFlee(D)
	local M = PUD
	if not D or not dangerPos(D) then return false end
	wake(false)
	M.flee = {D = D, untilT = now() + CFG.fleeFor, to = nil, legT = -1e9}
	M.activity, M.hunt = nil, nil
	M.queue = {}
	if M.posture ~= "stand" then queueAct("stand_up") end
	M.puffUntil = now() + 3
	return true
end

local function fleePoint(dpos)
	local M = PUD
	local away = Vec(M.pos[1] - dpos[1], 0, M.pos[3] - dpos[3])
	if VecLength(away) < 0.1 then away = fwd(M.yaw) end
	local base = yawTo(Vec(0, 0, 0), VecNormalize(away))
	for _, k in ipairs({0, 35, -35, 70, -70, 110, -110}) do
		local f = fwd(base + k)
		local x, z = M.pos[1] + f[1] * CFG.fleeLeg, M.pos[3] + f[3] * CFG.fleeLeg
		local g = groundAt(x, M.pos[2] + 0.5, z)
		if g and math.abs(g - M.pos[2]) < 2 and not blocked(M.pos, f, 1.0) and not wet(Vec(x, g, z)) then return Vec(x, g, z) end
	end
	return nil
end

local function die(by, cause)
	local M = PUD
	M.dead, M.diedT, M.hp = true, now(), 0
	M.lives = M.lives - 1
	M.flee, M.queue, M.act, M.leap, M.hunt, M.activity = nil, {}, nil, nil, nil, nil
	M.asleep = false
	setMode("free")
	M.speed = 0
	startAct("die")
	M.diedN = M.diedN + 1
	event("die", "You were hurt too badly (" .. (by and ("by " .. attackerName(by)) or cause or "hurt") ..
		string.format(") and you are dying - you lose one of your nine lives (%d left). Say a very short, dramatic last word.",
			math.max(0, M.lives)))
end

local function respawn()
	local M = PUD
	local host = hostPlayer()
	if not host then return end
	M.pos = spotNear(host, 1.4)
	M.yaw = yawTo(M.pos, feet(host))
	if M.lives <= 0 then M.lives = CFG.lives end                     -- (a fresh set: she's a cat)
	M.dead, M.hp, M.vy, M.speed = false, CFG.hp, 0, 0
	M.posture, M.act, M.queue, M.path, M.pathPts, M.stuckT = "stand", nil, {}, nil, nil, 0
	M.respawnN = M.respawnN + 1
	M.look, M.lookUntil = host, now() + 4
	queueAct("shake")
	queueAct("groom")
	event("back", string.format("You're back, as if nothing happened (%d of your nine lives left). Act like it was all " ..
		"perfectly dignified.", M.lives))
end

-- harm: amount, by {p = player} / {body = handle} / nil, cause, where it came from. She bolts from it on her own
function PudDamage(amount, by, cause, at)
	local M = PUD
	if not (M and M.started) or M.dead or not amount or amount <= 0 then return end
	M.hp = M.hp - amount
	M.hurtT = now()
	M.yowlN = M.yowlN + 1
	if M.leap then M.leap = nil end
	if M.hp <= 0 then die(by, cause); return end
	M.act = nil
	startAct("flinch")
	if by and by.p and not alive(by.p) then by = nil end
	if by or at then
		M.danger = {p = by and by.p, body = by and by.body, what = by and attackerName(by) or cause, pos = at and VecCopy(at), t = now()}
		if not M.flee then startFlee(M.danger) else M.flee.untilT = now() + CFG.fleeFor end
	end
	event("hurt", (by and (attackerName(by) .. " hurt you") or ("You got hurt (" .. tostring(cause or "ouch") .. ")")) ..
		string.format("! Your health: %d/%d. You bolt away.", math.floor(M.hp + 0.5), CFG.hp))
end

-- a bullet's line through her middle? (as Mochi's) and who fired it
local function shotThrough(c, pos, dir)
	local b = VecScale(VecNormalize(dir), -1)
	local v = VecSub(c, pos)
	local along = VecDot(v, b)
	if along < -0.2 or along > 150 then return false end
	if VecLength(VecSub(v, VecScale(b, along))) > CFG.shotRadius then return false end
	local best, bd = nil, 1.2
	for _, p in ipairs(players()) do
		local e = VecSub(GetPlayerEyeTransform(p).pos, pos)
		local ae = VecDot(e, b)
		if ae > along then
			local pe = VecLength(VecSub(e, VecScale(b, ae)))
			if pe < bd then best, bd = p, pe end
		end
	end
	if best then return true, {p = best} end
	return true, nil
end

local HIT_TOOLS = {sledge = {reach = 2.8, dmg = 30, every = 0.45}, gun = {reach = 100, dmg = 25},
	shotgun = {reach = 30, dmg = 35}, rifle = {reach = 200, dmg = 60}}
local HIT_BOX_LO, HIT_BOX_HI = Vec(-0.15, 0.0, -0.32), Vec(0.15, 0.5, 0.43)    -- (her root frame: legs, body, the big head)

function PudRayHit(o, d, maxd)
	local M = PUD
	local inv = QuatEuler(0, -M.yaw, 0)
	local lo = QuatRotateVec(inv, VecSub(o, M.pos))
	local ld = QuatRotateVec(inv, d)
	local tmin, tmax = 0, maxd
	for i = 1, 3 do
		if math.abs(ld[i]) < 1e-9 then
			if lo[i] < HIT_BOX_LO[i] or lo[i] > HIT_BOX_HI[i] then return nil end
		else
			local t1, t2 = (HIT_BOX_LO[i] - lo[i]) / ld[i], (HIT_BOX_HI[i] - lo[i]) / ld[i]
			if t1 > t2 then t1, t2 = t2, t1 end
			tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			if tmin > tmax then return nil end
		end
	end
	return tmin
end

local function aimedAt(p, reach)
	local eye = GetPlayerEyeTransform(p)
	local d = TransformToParentVec(eye, Vec(0, 0, -1))
	local t = PudRayHit(eye.pos, d, reach)
	if not t then return nil end
	filter()
	QueryRejectPlayer(p)
	local hit, wd = QueryRaycast(eye.pos, d, t)
	if hit and wd < t - 0.05 then return nil end
	return t
end

-- ---- bangs: explosions and gunshots. At once: a startle jump when close, bolting when very close; then gathered for
-- noiseGather s into one event for her AI (at most every noiseEvery s)
local function side(pos)
	local M = PUD
	local a = angDiff(M.yaw, yawTo(M.pos, pos))
	if math.abs(a) < 45 then return "in front of you" elseif math.abs(a) > 135 then return "behind you" end
	return a > 0 and "to your left" or "to your right"
end

function PudNoise(kind, p, pos, str)
	local M = PUD
	if not (M and M.started) or M.dead or not pos then return end
	local t, d = now(), VecLength(VecSub(pos, M.pos))
	local blast = kind == "explosion"
	M.sound = {pos = VecCopy(pos), t = t}
	if d < (blast and CFG.startleBlast or CFG.startleShot) and not M.leap then
		wake(true)
		M.act = nil
		startAct("startle")
		M.puffUntil = t + 4
	end
	if d < (blast and CFG.boltBlast or CFG.boltShot) and not M.flee then
		startFlee({p = alive(p) and p or nil, pos = VecCopy(pos), what = blast and "the explosion" or "the gunshots", t = t})
	end
	local A = M.noiseAcc
	if not A then A = {firstT = t, shots = {}, blasts = 0}; M.noiseAcc = A end
	if blast then
		A.blasts = A.blasts + 1
		if not A.blastD or d < A.blastD then A.blastD, A.blastSide = d, side(pos) end
	else
		local key = alive(p) and p or 0
		local S = A.shots[key] or {n = 0}
		A.shots[key] = S
		S.n = S.n + 1
		if not S.d or d < S.d then S.d, S.side = d, side(pos) end
	end
end

local function noiseTick()
	local M = PUD
	local A = M.noiseAcc
	if not A or M.dead then M.noiseAcc = nil; return end
	local t = now()
	if t - A.firstT < CFG.noiseGather then return end
	if t - M.noiseSentT < CFG.noiseEvery then return end
	M.noiseAcc = nil
	local parts = {}
	if A.blasts > 0 then
		parts[#parts + 1] = string.format("BOOM! %s went off %d m away, %s.", A.blasts > 1 and (A.blasts .. " explosions") or
			"An explosion", math.floor(A.blastD + 0.5), A.blastSide)
	end
	for key, S in pairs(A.shots) do
		parts[#parts + 1] = string.format("BANG! %s fired %s %d m from you, %s.", key ~= 0 and IsPlayerValid(key) and nameOf(key) or "Someone",
			S.n > 1 and (S.n .. " shots") or "a gun", math.floor(S.d + 0.5), S.side)
	end
	if #parts == 0 then return end
	M.noiseSentT = t
	M.noiseN = M.noiseN + 1
	if not PudAgentOn() then M.hissN = M.hissN + 1; return end
	event("noise", table.concat(parts, " ") .. (M.flee and " You bolted." or " You jumped out of your fur."))
end

local function hurtTick(dt)
	local M = PUD
	if M.dead then return end
	local c = VecAdd(M.pos, Vec(0, 0.24, 0))
	local shot, by, shotFrom = 0, nil, nil
	for i = 1, GetEventCount("projectilehit") do
		local _, pos, dir = GetEvent("projectilehit", i)
		if pos and dir then
			local through, who = shotThrough(c, pos, dir)
			if through and not (who and who.p and PudShotCounted(who.p)) then
				shot = shot + CFG.shotDmg; by = by or who
				shotFrom = shotFrom or VecAdd(c, VecScale(VecNormalize(dir), -10))
			end
		end
	end
	local blast, blastAt, worst = 0, nil, 0
	for i = 1, GetEventCount("explosion") do
		local pos, str = GetEvent("explosion", i)
		str = tonumber(str) or 1
		local r = 2 + 3 * str
		local d = pos and VecLength(VecSub(pos, c)) or 1e9
		if d < math.min(150, CFG.blastHear + CFG.blastHearPer * str) then PudNoise("explosion", nil, pos, str) end
		if d < r then
			local hurt = CFG.blastDmg * str * (1 - d / r)
			blast = blast + hurt
			if hurt > worst then worst, blastAt = hurt, pos end
		end
	end
	if shot > 0 then PudDamage(math.min(shot, CFG.shotCap), by, "shot", shotFrom) end
	if blast > 0 then PudDamage(blast, nil, "an explosion", blastAt) end
	if not M.dead and now() - M.hurtT > CFG.regenAfter then M.hp = math.min(CFG.hp, M.hp + CFG.regen * dt) end
end

function PudShotCounted(p)
	local st = PUD.toolState[p]
	return st and st.shotT and now() - st.shotT < 0.3
end

local function toolHits(dt)
	local M = PUD
	local t = now()
	for _, p in ipairs(players()) do
		local okT, tool = pcall(GetPlayerTool, p)
		local T = okT and HIT_TOOLS[tool]
		local st = M.toolState[p] or {}
		M.toolState[p] = st
		if T and alive(p) and GetPlayerVehicle(p) == 0 then
			local okA, ammo = pcall(GetToolAmmo, tool, p)
			ammo = okA and tonumber(ammo) or 0
			local fired
			if tool == "sledge" then
				fired = InputPressed("usetool", p) and t - (st.swingT or -1e9) >= T.every
				if fired then st.swingT = t end
			else
				fired = st.tool == tool and st.ammo and ammo < st.ammo
			end
			st.tool, st.ammo = tool, ammo
			if fired and tool ~= "sledge" and hdist(feet(p), M.pos) < CFG.shotHear then PudNoise("shot", p, feet(p)) end
			if fired and aimedAt(p, T.reach) then
				st.shotT = t
				PudDamage(T.dmg, {p = p}, tool == "sledge" and "hit with a sledgehammer" or "shot", feet(p))
			end
		else
			st.tool, st.ammo = nil, nil
		end
		if okT and tool == "blowtorch" and alive(p) and InputDown("usetool", p) and aimedAt(p, 1.6) then
			M.burn = (M.burn or 0) + CFG.torchDmg * dt
			M.burnBy = {p = p}
		end
	end
end

local TOY_TAGS = {"mochiball", "mochitreat", "mochianchor", "mochidog", "mochitoy", "puddingtreat", "puddinganchor",
	"puddingcat", "puddingtoy"}
local function isToy(b)
	for _, tg in ipairs(TOY_TAGS) do if HasTag(b, tg) then return true end end
	return false
end

local function flyingHits()
	local M = PUD
	local t = now()
	for _, p in ipairs(players()) do
		local okG, g = pcall(GetPlayerGrabBody, p)
		if okG and g and g ~= 0 then M.heldBy[g] = {p = p, t = t} end
	end
	local okQ, list = pcall(QueryAabbBodies, VecAdd(M.pos, Vec(-0.5, -0.1, -0.5)), VecAdd(M.pos, Vec(0.5, 0.6, 0.5)))
	for _, b in ipairs(okQ and list or {}) do
		if IsHandleValid(b) and IsBodyDynamic(b) and not isToy(b) and t - (M.hitT[b] or -1e9) > 0.6
			and b ~= M.swatBody then
			local v = GetBodyVelocity(b)
			local sp = VecLength(v)
			if sp > CFG.flyingSpeed then
				local mid = bodyMid(b)
				if PudRayHit(VecSub(mid, VecScale(VecNormalize(v), 0.6)), VecNormalize(v), 1.2) then
					M.hitT[b] = t
					local mass = math.max(0.5, GetBodyMass(b) or 1)
					local h = M.heldBy[b]
					local by = h and t - h.t < CFG.blameFor and alive(h.p) and {p = h.p} or nil
					PudDamage(math.min(80, sp * math.sqrt(mass) * CFG.flyingDmg), by, "something flying", mid)
				end
			end
		end
	end
end

local function carTick()
	local M = PUD
	if M.dead or now() - M.carT < 1 or M.leap then return end
	for _, p in ipairs(players()) do
		local okV, v = pcall(GetPlayerVehicle, p)
		if okV and v and v ~= 0 then
			local body = GetVehicleBody(v)
			local vel = GetBodyVelocity(body)
			local sp = VecLength(vel)
			if sp > CFG.carSpeed then
				local lo, hi = GetBodyBounds(body)
				local q = M.pos
				if q[1] > lo[1] - 0.3 and q[1] < hi[1] + 0.3 and q[3] > lo[3] - 0.3 and q[3] < hi[3] + 0.3
					and q[2] + 0.4 > lo[2] and q[2] < hi[2] then
					M.carT = now()
					M.pos = VecAdd(M.pos, VecScale(VecNormalize(Vec(vel[1], 0, vel[3])), 1.0))
					PudDamage(sp * CFG.carDmg, {p = p}, "a car", GetBodyTransform(body).pos)
					return
				end
			end
		end
	end
end

function PudHitsTick(dt)
	local M = PUD
	if M.dead then return end
	toolHits(dt)
	flyingHits()
	local okF, fire = pcall(QueryClosestFire, VecAdd(M.pos, Vec(0, 0.25, 0)), 0.5)
	if okF and fire then M.burn = (M.burn or 0) + CFG.fireDmg * dt; M.burnAt = VecCopy(M.pos) end
	if (M.burn or 0) >= 5 then
		PudDamage(M.burn, M.burnBy, "fire", M.burnBy and M.burnBy.p and feet(M.burnBy.p) or M.burnAt)
		M.burn, M.burnBy = 0, nil
	end
end

-- ---- swats and scratches
-- a swat at a point: the act, and a loose small body there gets knocked (a cat's favourite thing)
local function swatAt(pos, body)
	local M = PUD
	M.yaw = yawTo(M.pos, pos)
	M.act = nil
	startAct("swat")
	M.swatN = M.swatN + 1
	if body and IsHandleValid(body) and IsBodyDynamic(body) then
		local mass = math.min(GetBodyMass(body) or 1, 25)
		local dir = VecNormalize(VecAdd(fwd(M.yaw + rnd(-25, 25)), Vec(0, 0.35, 0)))
		M.swatBody = body
		ApplyBodyImpulse(body, bodyMid(body), VecScale(dir, mass * rnd(2.5, 4.0)))
	end
end

local function scratch(p)
	local M = PUD
	if now() - M.scratchT < CFG.scratchEvery then return false end
	M.scratchT = now()
	swatAt(feet(p))
	M.hissN = M.hissN + 1
	pcall(ApplyPlayerDamage, p, CFG.scratchDmg, PUDDING_NAME)
	M.flickUntil = now() + 6
	return true
end

-- ---- what she does in her free time (whims). Each: {kind, untilT, ...}; goal() asks the whim where to go
local function chooseWhim()
	local M = PUD
	local t = now()
	local p, pd = nearestPlayer(M.pos)
	local o = nearestOther()
	local W = {}
	local function add(kind, w) if w > 0 then W[#W + 1] = {kind, w} end end
	local tired = 1 - M.energy
	add("nap", 1 + 5 * tired * tired)
	add("loaf", 2.5)
	add("groom", 2)
	add("stroll", 2)
	add("perch", 1.5)
	add("zoomies", M.energy > 0.5 and 0.8 * M.energy or 0)
	add("knock", 1.2)
	if p and pd < 12 then add("stare", 1.0); add("rub", M.affection * 2) end
	if M.hunger > 0.7 and p and pd < 20 and t - M.demandT > 60 then add("demand", 4) end
	if o and o.d < 12 then add("ambush", 0.8 * M.energy); add("sniff_dog", 0.5) end
	local ok, balls = pcall(FindBodies, "mochiball", true)
	if ok and balls and balls[1] and hdist(bodyPos(balls[1]), M.pos) < 10 then add("bat_ball", 1.2 * M.energy) end
	local sum = 0
	for _, e in ipairs(W) do sum = sum + e[2] end
	local r = math.random() * sum
	for _, e in ipairs(W) do
		r = r - e[2]
		if r <= 0 then return e[1] end
	end
	return "loaf"
end

-- a small loose thing near her to knock over (not held, light, not a toy), or nil
local function knockable(r)
	local M = PUD
	local okQ, list = pcall(QueryAabbBodies, VecAdd(M.pos, Vec(-r, -1, -r)), VecAdd(M.pos, Vec(r, 2.2, r)))
	local best, bd = nil, 1e9
	for _, b in ipairs(okQ and list or {}) do
		if IsHandleValid(b) and IsBodyDynamic(b) and not isToy(b) and not heldBy(b) then
			local m = GetBodyMass(b) or 0
			if m > 0.05 and m < 20 then
				local mid = bodyMid(b)
				local d = hdist(mid, M.pos) + math.abs(mid[2] - M.pos[2]) + math.random()
				if d < bd and mid[2] - M.pos[2] < CFG.leapUp + 0.6 then best, bd = b, d end
			end
		end
	end
	return best
end
PudKnockable = knockable

local function startWhim(kind)
	local M = PUD
	local t = now()
	local A = {kind = kind, t0 = t, untilT = t + rnd(CFG.whimMin, CFG.whimMax)}
	M.activity = A
	M.whimN = M.whimN + 1
	M.stateDirty = true
	local p = nearestPlayer(M.pos)
	if kind == "nap" then
		A.untilT = t + rnd(CFG.napMin, CFG.napMax)
		A.spot = math.random() < 0.5 and findPerch(5, p and feet(p)) or nil
	elseif kind == "perch" then
		A.spot = findPerch(6, p and feet(p))
		if not A.spot then A.kind = "loaf" end
		A.untilT = t + rnd(25, 60)
	elseif kind == "loaf" then
		A.untilT = t + rnd(15, 45)
	elseif kind == "zoomies" then
		A.legs = math.random(3, 5)
		A.untilT = t + 15
		M.zoomN = M.zoomN + 1
	elseif kind == "knock" then
		A.body = knockable(7)
		if not A.body then A.kind = "groom" end
	elseif kind == "stare" or kind == "rub" or kind == "demand" then
		A.p = p
		if kind == "demand" then A.p = hostPlayer(); M.demandT = t end
	elseif kind == "ambush" or kind == "sniff_dog" then
		local o = nearestOther()
		A.other = o and o.id
		A.untilT = t + 20
	elseif kind == "bat_ball" then
		local ok, balls = pcall(FindBodies, "mochiball", true)
		A.body = ok and balls and balls[1] or nil
		A.untilT = t + 15
	end
	if A.kind == "groom" then queueAct("groom"); if math.random() < 0.5 then queueAct("groom") end; A.untilT = t + 7 end
	return A
end
PudStartWhim = startWhim

-- the current whim's goal: a point (or nil), stop distance, speed; and its doings on arrival
local function otherNow(id)
	for _, o in ipairs(PUD.others) do if o.id == id then return o end end
	return nil
end

local function whimGoal()
	local M = PUD
	local t = now()
	local A = M.activity
	if not A or t > A.untilT then
		if A and A.kind == "nap" and M.asleep then wake(false) end
		if A and A.kind == "zoomies" then M.energy = math.max(0, M.energy - 0.3) end
		A = startWhim(chooseWhim())
	end
	local k = A.kind
	if k == "nap" then
		if M.asleep then return nil end
		if A.spot and hdist(A.spot, M.pos) > 0.4 and not A.arrived then return A.spot, 0.3, CFG.walk end
		A.arrived = true
		if M.posture ~= "curl" and not M.act then queueAct("curl_up") end
		if M.posture == "curl" then M.asleep = true; M.stateDirty = true; M.sleepN = M.sleepN + 1 end
		return nil
	elseif k == "perch" then
		if A.spot and not A.arrived and hdist(A.spot, M.pos) > 0.35 then return A.spot, 0.3, CFG.trot end
		A.arrived = true
		if M.posture ~= "loaf" and M.posture ~= "sit" and not M.act and #M.queue == 0 then
			queueAct(math.random() < 0.6 and "loaf_down" or "sit_down")
		end
		return nil
	elseif k == "rest" then                                          -- (told to sit / loaf: she holds it a while)
		if M.posture ~= A.posture and not M.act and #M.queue == 0 then queueAct(A.posture == "sit" and "sit_down" or "loaf_down") end
		return nil
	elseif k == "loaf" then
		local p, d = nearestPlayer(M.pos)
		if p and d > 7 and d < CFG.nearby and not A.arrived then return feet(p), 3.5, CFG.walk end
		A.arrived = true
		if M.posture ~= "loaf" and not M.act and #M.queue == 0 then queueAct("loaf_down") end
		return nil
	elseif k == "stroll" then
		if not A.to or hdist(A.to, M.pos) < 0.5 or t - (A.legT or 0) > 12 then
			local p, d = nearestPlayer(M.pos)
			local a = math.random() * 2 * math.pi
			local r = rnd(3, 8)
			local x, z = M.pos[1] + math.sin(a) * r, M.pos[3] + math.cos(a) * r
			if p and hdist(Vec(x, 0, z), feet(p)) > CFG.wanderLeash then
				local back = VecNormalize(Vec(feet(p)[1] - M.pos[1], 0, feet(p)[3] - M.pos[3]))
				x, z = M.pos[1] + back[1] * r, M.pos[3] + back[3] * r
			end
			local g = groundAt(x, M.pos[2] + 0.5, z)
			A.to, A.legT = g and not wet(Vec(x, g, z)) and Vec(x, g, z) or nil, t
			if not A.to then return nil end
			if math.random() < 0.3 then queueAct("sniff") end
		end
		return A.to, 0.4, CFG.walk
	elseif k == "zoomies" then
		if not A.to or hdist(A.to, M.pos) < 0.8 or t - (A.legT or 0) > 3 then
			if (A.legs or 0) <= 0 then
				A.kind, A.untilT = "groom", t + 6                       -- ("I meant to do that")
				queueAct("sit_down"); queueAct("groom")
				return nil
			end
			A.legs = A.legs - 1
			local a = math.random() * 2 * math.pi
			local r = rnd(4, 9)
			local x, z = M.pos[1] + math.sin(a) * r, M.pos[3] + math.cos(a) * r
			local g = groundAt(x, M.pos[2] + 0.5, z)
			A.to, A.legT = g and not wet(Vec(x, g, z)) and Vec(x, g, z) or nil, t
			if not A.to then return nil end
		end
		return A.to, 0.6, CFG.run
	elseif k == "knock" then
		local b = A.body
		if not (b and IsHandleValid(b)) or heldBy(b) then A.untilT = 0; return nil end
		local mid = bodyMid(b)
		if hdist(mid, M.pos) > 0.65 or math.abs(mid[2] - (M.pos[2] + 0.2)) > 0.6 then
			return Vec(mid[1], mid[2] - 0.1, mid[3]), 0.55, CFG.walk
		end
		if not M.act then
			if not A.eyed then A.eyed = t; M.look, M.lookUntil = nil, 0; M.yaw = yawTo(M.pos, mid); return nil end
			if t - A.eyed < 1.2 then return nil end                     -- (a long, meaningful look at it first)
			swatAt(mid, b)
			M.knockN = M.knockN + 1
			local p = nearestPlayer(M.pos, 15)
			if p and math.random() < 0.5 then
				event("knocked", "You knocked something over on purpose" .. (p and (", right in front of " .. nameOf(p)) or "") .. ".")
			end
			A.untilT = t + 2
		end
		return nil
	elseif k == "stare" then
		if not alive(A.p) then A.untilT = 0; return nil end
		local d = hdist(feet(A.p), M.pos)
		if d > 5 and not A.arrived then return feet(A.p), 3.5, CFG.walk end
		A.arrived = true
		M.look, M.lookUntil = A.p, t + 1
		if M.posture ~= "sit" and not M.act and #M.queue == 0 then queueAct("sit_down") end
		if not A.blinked and t - A.t0 > 6 and math.random() < 0.3 then A.blinked = true; queueAct("blink") end
		return nil
	elseif k == "rub" then
		if not alive(A.p) then A.untilT = 0; return nil end
		if not A.done then
			if hdist(feet(A.p), M.pos) > 0.55 then return feet(A.p), 0.5, CFG.walk end
			A.done = true
			M.affectionN = M.affectionN + 1
			M.trillN = M.trillN + 1
			queueAct("rub"); queueAct("rub")
			M.tailUntil = t + 6
			A.untilT = t + 5
		end
		return nil
	elseif k == "demand" then
		if not alive(A.p) then A.untilT = 0; return nil end
		local d = hdist(feet(A.p), M.pos)
		if d > 1.3 and not A.arrived then return feet(A.p), 1.1, CFG.trot end
		if not A.arrived then
			A.arrived = true
			queueAct("sit_down"); queueAct("meow"); queueAct("meow")
			M.look, M.lookUntil = A.p, t + 6
			event("hungry", "You are hungry. You sit in front of " .. nameOf(A.p) .. " and demand food (fish treats are in " ..
				"their tools). Let them know, as only a cat can.")
		end
		return nil
	elseif k == "ambush" then
		local o = otherNow(A.other)
		if not o then A.untilT = 0; return nil end
		local d = hdist(o.pos, M.pos)
		if A.pounced then return nil end
		if d > 4 then return o.pos, CFG.pounceAt, CFG.walk end
		if d > CFG.pounceAt then M.crouch = true; return o.pos, CFG.pounceAt, CFG.stalk end
		if not M.act then
			A.pounced = true
			M.yaw = yawTo(M.pos, o.pos)
			startAct("pounce")
			M.pounce = {to = o.pos, t0 = t}
			M.pounceN = M.pounceN + 1
			event("pounced", "You stalked " .. o.name .. " and pounced on them from behind. Ha! Gloat about it, or pretend you didn't.")
			A.untilT = t + 3
		end
		return nil
	elseif k == "sniff_dog" then
		local o = otherNow(A.other)
		if not o then A.untilT = 0; return nil end
		if not A.done then
			if hdist(o.pos, M.pos) > 0.9 then return o.pos, 0.8, CFG.walk end
			A.done = true
			M.yaw = yawTo(M.pos, o.pos)
			queueAct("sniff")
			if math.random() < 0.4 then queueAct("hiss") else M.tailUntil = t + 4 end
			A.untilT = t + 4
		end
		return nil
	elseif k == "bat_ball" then
		local b = A.body
		if not (b and IsHandleValid(b)) or heldBy(b) then A.untilT = 0; return nil end
		local bp = bodyPos(b)
		if hdist(bp, M.pos) > 0.5 then return bp, 0.45, CFG.trot end
		if not M.act then swatAt(bp, b); A.bats = (A.bats or 0) + 1; if A.bats >= 3 then A.untilT = t + 1.5 end end
		return nil
	end
	return nil
end

-- ---- the laser pointer: players' red dots (server: from their eyes while they hold the button), and her chase
local function laserTick()
	local M = PUD
	local t = now()
	local dots = {}
	for _, p in ipairs(players()) do
		local okT, tool = pcall(GetPlayerTool, p)
		if okT and tool == PUDDING_LASER_TOOL and alive(p) and GetPlayerVehicle(p) == 0 and InputDown("usetool", p)
			and not GetBool("proxchat.typing." .. p) then
			local eye = GetPlayerEyeTransform(p)
			local dir = TransformToParentVec(eye, Vec(0, 0, -1))
			filter()
			QueryRejectPlayer(p)
			local hit, d, n = QueryRaycast(eye.pos, dir, CFG.laserRange)
			if hit then
				local pos = VecAdd(eye.pos, VecScale(dir, d))
				dots[#dots + 1] = {p = p, pos = pos, n = n or Vec(0, 1, 0)}
			end
		end
	end
	M.dots = dots
	-- the nearest dot she sees
	local best, bd = nil, CFG.laserSee
	for _, D in ipairs(dots) do
		local d = VecLength(VecSub(D.pos, M.pos))
		if d < bd then best, bd = D, d end
	end
	if M.dead or M.flee then M.laser = nil; return end
	local L = M.laser
	if best then
		if not L then
			if M.asleep and math.random() > 0.02 then return end            -- (asleep: she may not notice it - yet)
			wake(false)
			L = {p = best.p, t0 = t, seenT = t}
			M.laser = L
			M.laserN = M.laserN + 1
			M.activity = nil
			if t - (M.laserEvT[best.p] or -1e9) > 60 then
				M.laserEvT[best.p] = t
				event("laser", nameOf(best.p) .. " is shining the little red dot around. You MUST catch it. You can't help it.")
			end
		end
		L.dot, L.seenT, L.p = best, t, best.p
		M.energy = math.max(0, M.energy - 0.004 * (1 / 60))
	elseif L and t - L.seenT > CFG.laserLost then
		M.laser = nil
		M.lookAround = t + 2.5                                          -- ("where did it go?")
		queueAct("sit_down")
		if math.random() < 0.6 then queueAct("groom") end              -- (she meant to stop anyway)
	end
end
PudLaserTick = laserTick

-- the chase: run to the dot, stalk it close up, pounce. A dot on a wall: to the wall under it (a leap at it)
local function laserGoal()
	local M = PUD
	local L = M.laser
	if not (L and L.dot) or now() - L.seenT > 0.2 then
		return L and L.lastTo, 0.3, CFG.trot
	end
	local D = L.dot
	local to = VecCopy(D.pos)
	if math.abs(D.n[2]) < 0.6 then                                   -- (on a wall: the floor under it, just off the wall)
		to = VecAdd(to, VecScale(Vec(D.n[1], 0, D.n[3]), 0.3))
		local g = groundAt(to[1], math.min(to[2], M.pos[2] + 1), to[3])
		to[2] = g or M.pos[2]
	end
	L.lastTo = to
	local d = hdist(to, M.pos)
	if d < CFG.pounceAt and not M.act and math.abs(to[2] - M.pos[2]) < 0.6 and now() - M.pounceT > 1.4 then
		M.pounceT = now()
		M.yaw = yawTo(M.pos, to)
		startAct("pounce")
		M.pounce = {to = to, t0 = now()}
		M.pounceN = M.pounceN + 1
		return nil
	end
	if d < 3 and VecLength(VecSub(D.pos, L.prev or D.pos)) < 0.02 then M.crouch = true; L.prev = D.pos; return to, 0.4, CFG.stalk end
	L.prev = D.pos
	return to, 0.35, d > 4 and CFG.run or CFG.trot
end

-- ---- commands (her AI's function calls and the keyword parser): ok, result text
local ACTIONS = {sit = "sit_down", loaf = "loaf_down", lie_down = "loaf_down", stand_up = "stand_up", stand = "stand_up",
	stretch = "stretch", groom = "groom", meow = "meow", hiss = "hiss", swat = "swat", roll_over = "roll",
	knead = "knead", yawn = "yawn", chatter = "chatter", slow_blink = "blink", blink = "blink", shake = "shake",
	sniff = "sniff"}
PUDDING_ACTIONS = {"sit", "loaf", "stand_up", "stretch", "groom", "meow", "hiss", "swat", "roll_over", "knead", "yawn",
	"chatter", "slow_blink", "shake", "sniff"}

-- a target by name for follow / come / hunt / scratch: {p = player} or {other = agent} or {ball = body}; nil
local function targetOf(s, speaker)
	local q = tostring(s or ""):lower()
	if q == "ball" or q == "the ball" or q == "mochi's ball" or q == "his ball" then
		local ok, balls = pcall(FindBodies, "mochiball", true)
		if ok and balls and balls[1] then return {ball = balls[1], what = "the ball"} end
		return nil
	end
	local o = PudOtherByName(s)
	if o then return {other = o.id, what = o.name} end
	local p = PudPlayerByName(s, speaker)
	if p then return {p = p, what = nameOf(p)} end
	return nil
end

local function targetPos(T)
	if T.p then return alive(T.p) and feet(T.p) or nil end
	if T.other then local o = otherNow(T.other); return o and o.pos end
	if T.ball then return IsHandleValid(T.ball) and bodyPos(T.ball) or nil end
	return nil
end

function PudCommand(name, args, speaker)
	local M = PUD
	args = args or {}
	PudHappened()
	if M.dead then return false, "error: you are dead (you'll be back soon - you have lives to spare)" end
	if name ~= "ignore" and name ~= "purr" and name ~= "action" then M.activity = nil end
	if M.flee and (name == "come" or name == "follow" or name == "relax") then M.flee = nil end
	if name == "action" then
		local a = tostring(args.name or ""):lower():gsub("[%s%-]", "_")
		local kind = ACTIONS[a]
		if not kind then return false, "error: no action called " .. a .. " (actions: " .. table.concat(PUDDING_ACTIONS, ", ") .. ")" end
		if M.asleep and kind ~= "yawn" then wake(false) end
		if M.mode == "come" then setMode("free") end
		if kind == "swat" then
			local o = nearestOther()
			local p = alive(speaker) and speaker or nil
			local at = (o and o.d < 1.5 and o.pos) or (p and hdist(feet(p), M.pos) < 1.5 and feet(p)) or VecAdd(M.pos, fwd(M.yaw))
			swatAt(at)
			return true, "ok: swat!"
		end
		if kind == "hiss" then M.hissN = M.hissN + 1; M.puffUntil = now() + 2 end
		if kind == "meow" then M.meowN = M.meowN + 1 end
		if kind == "chatter" then M.chatterN = M.chatterN + 1 end
		if kind == "roll" then M.rollT = now() end
		queueAct(kind)
		if kind == "sit_down" or kind == "loaf_down" then                 -- (she keeps it a while)
			M.activity = {kind = "rest", posture = kind == "sit_down" and "sit" or "loaf", t0 = now(), untilT = now() + 30}
		end
		return true, "ok: " .. a
	elseif name == "follow" then
		local T = targetOf(args.who or args.player, speaker)
		if not T or T.ball then return false, "error: nobody here called " .. tostring(args.who or args.player) end
		wake(false)
		setMode("follow", T)
		return true, "ok: following " .. T.what .. " (until you get bored of it)"
	elseif name == "come" then
		local T = targetOf(args.who or args.player, speaker)
		if not T then return false, "error: nobody here called " .. tostring(args.who or args.player) end
		wake(false)
		setMode("come", T)
		return true, "ok: strolling over to " .. T.what .. " (in your own time)"
	elseif name == "stay" then
		setMode("stay", nil)
		return true, "ok: staying put (because you wanted to anyway)"
	elseif name == "relax" or name == "ignore" then
		if name == "relax" then setMode("free", nil) end
		return true, name == "ignore" and "ok: you carry on as if nobody spoke" or "ok: back to doing as you please"
	elseif name == "nap" then
		setMode("free", nil)
		local A = startWhim("nap")
		A.kind = "nap"
		A.spot = tostring(args.where or ""):lower() == "high" and findPerch(6) or nil
		A.untilT = now() + rnd(CFG.napMin, CFG.napMax)
		return true, "ok: settling down for a nap" .. (A.spot and " up high" or "")
	elseif name == "perch" then
		setMode("free", nil)
		local A = startWhim("perch")
		if A.kind ~= "perch" then return false, "error: there is nothing high to sit on near here" end
		return true, string.format("ok: jumping up somewhere high (%.1f m up)", A.spot[2] - M.pos[2])
	elseif name == "knock_off" then
		setMode("free", nil)
		local A = startWhim("knock")
		if A.kind ~= "knock" then return false, "error: nothing small to knock over near you" end
		return true, "ok: going to knock something over"
	elseif name == "zoomies" then
		setMode("free", nil)
		wake(false)
		startWhim("zoomies")
		return true, "ok: ZOOMIES"
	elseif name == "hunt" then
		local T = targetOf(args.target or args.who, speaker)
		if not T then return false, "error: nothing here called " .. tostring(args.target or args.who) end
		wake(false)
		setMode("hunt", T)
		M.hunt = T
		return true, "ok: stalking " .. T.what
	elseif name == "scratch" then
		local T = targetOf(args.who or args.target, speaker)
		if not T or T.ball then return false, "error: nobody here called " .. tostring(args.who or args.target) end
		local pos = targetPos(T)
		if not pos then return false, "error: " .. T.what .. " isn't here" end
		if hdist(pos, M.pos) > 1.6 then return false, "error: " .. T.what .. " is out of reach (" ..
			math.floor(hdist(pos, M.pos) + 0.5) .. " m away)" end
		if T.p then
			if not scratch(T.p) then return false, "error: you scratched someone only a moment ago" end
			return true, "ok: you scratched " .. T.what
		end
		swatAt(pos)
		return true, "ok: you swatted " .. T.what .. " on the nose"
	elseif name == "run_away" then
		local s = tostring(args.from or ""):lower()
		local D
		local T = s ~= "" and s ~= "danger" and targetOf(s, nil) or nil
		if T and T.p then D = {p = T.p, what = T.what, t = now()}
		elseif T and T.other then D = {other = T.what, pos = targetPos(T), what = T.what, t = now()}
		elseif M.danger and now() - M.danger.t < CFG.dangerMemory then D = M.danger end
		if not D or not startFlee(D) then return false, "error: nothing here to run from" end
		return true, "ok: bolting away from " .. (D.what or "danger")
	elseif name == "purr" then
		local s = clamp(tonumber(args.seconds) or 5, 1, 15)
		M.purrUntil = math.max(M.purrUntil, now() + s)
		M.tailUntil = math.max(M.tailUntil, now() + s)
		return true, "ok: purring"
	end
	return false, "error: unknown action " .. tostring(name)
end

-- ---- players' buttons
-- (server.pudding_pet) E on her. Asleep: she wakes (maybe grumpy). Awake: she purrs - until she has had enough
function PudPet(p)
	local M = PUD
	if not (M and M.started and alive(p)) or M.dead or M.leap then return end
	if hdist(feet(p), M.pos) > CFG.petRange + 0.4 then return end
	if GetBool("proxchat.typing." .. p) then return end
	local t = now()
	M.look, M.lookUntil = p, t + 3
	M.petN = M.petN + 1
	if M.asleep then
		local grumpy = math.random() < 0.5
		wake(grumpy)
		if grumpy then queueAct("hiss"); M.hissN = M.hissN + 1 end
		event("woken", nameOf(p) .. " woke you up by petting you" .. (grumpy and ". You are NOT amused." or ". Fine. You allow it."))
		return
	end
	-- the belly trap: petting her while she's rolled over
	if M.rollT and t - M.rollT < 3 then
		M.rollT = nil
		if scratch(p) then
			event("scratched", nameOf(p) .. " fell for the belly trap: they rubbed your belly and you grabbed and scratched them. Victory.")
			return
		end
	end
	if t - M.petFirstT > CFG.petWindow then M.petFirstT, M.petCount, M.petTol = t, 0, math.random(3, 7) end
	M.petCount = M.petCount + 1
	if M.petCount > M.petTol then
		M.petCount, M.petFirstT = 0, -1e9
		if scratch(p) then
			M.activity = startWhim("stroll")
			event("scratched", nameOf(p) .. " kept petting you after you'd had enough, so you scratched them and walked off.")
			return
		end
	end
	M.purrUntil = math.max(M.purrUntil, t + 4)
	M.tailUntil = math.max(M.tailUntil, t + 5)
	M.hp = math.min(CFG.hp, M.hp + 3)
	M.heartN = M.heartN + 1
	M.affection = math.min(1, M.affection + 0.05)
	if M.petCount == M.petTol then M.flickUntil = t + 4 end             -- (the warning: the tail starts lashing)
	if not M.act and M.speed < 0.3 and math.random() < 0.15 and M.posture ~= "curl" then queueAct("roll"); M.rollT = t
	elseif not M.act and M.speed < 0.3 and math.random() < 0.3 then queueAct("blink") end
	event("pet", nameOf(p) .. " pets you" .. (M.petCount == M.petTol and " (you're getting a bit sick of it)" or " and you purr") .. ".")
end

-- ---- her treats as a tool, the laser pointer as a tool
function PudTreatsLeft(p)
	local M = PUD
	local t = now()
	if M.treatsLeft[p] == nil then M.treatsLeft[p], M.treatsT[p] = CFG.treatsStart, t end
	while M.treatsLeft[p] < CFG.treatsStart and t - M.treatsT[p] >= CFG.treatRefill do
		M.treatsLeft[p] = M.treatsLeft[p] + 1
		M.treatsT[p] = M.treatsT[p] + CFG.treatRefill
	end
	if M.treatsLeft[p] >= CFG.treatsStart then M.treatsT[p] = t end
	return M.treatsLeft[p]
end

function PudThrowTreat(p, speed)
	local M = PUD
	if not (M and M.started and alive(p)) then return end
	local t = now()
	if M.treatT[p] and t - M.treatT[p] < CFG.treatCooldown then return end
	local left = PudTreatsLeft(p)
	if left < 1 then return end
	M.treatsLeft[p] = left - 1
	M.treatT[p] = t
	cleanTreats()
	while #M.treats >= CFG.treatsMax do
		local old = table.remove(M.treats, 1)
		if IsHandleValid(old) and not heldBy(old) then Delete(old) end
	end
	local eye = GetPlayerEyeTransform(p)
	local ahead = TransformToParentVec(eye, Vec(0, 0, -1))
	local pos = VecAdd(eye.pos, VecAdd(VecScale(ahead, 0.6), Vec(0, -0.25, 0)))
	local h = spawnBody("MOD/vox/treat_phys.vox", "puddingtreat", pos, VecAdd(VecScale(ahead, speed or 2.0), Vec(0, 1.0, 0)))
	if h then M.treats[#M.treats + 1] = h end
	if hdist(feet(p), M.pos) < 12 then M.look, M.lookUntil = p, t + 2; wake(false) end
end

local function toolsTick()
	local M = PUD
	if not M.toolsReg then
		M.toolsReg = true
		pcall(RegisterTool, PUDDING_TREAT_TOOL, "Fish treats", "MOD/prefab/treat_tool.xml", 6)
		pcall(RegisterTool, PUDDING_LASER_TOOL, "Laser pointer", "MOD/prefab/laser_tool.xml", 6)
	end
	local refresh = now() - M.toolsT >= 0.5
	if refresh then M.toolsT = now() end
	for _, p in ipairs(players()) do
		if refresh then
			pcall(SetToolEnabled, PUDDING_TREAT_TOOL, true, p)
			pcall(SetToolAmmo, PUDDING_TREAT_TOOL, PudTreatsLeft(p), p)
			pcall(SetToolEnabled, PUDDING_LASER_TOOL, true, p)
		end
		local okT, tool = pcall(GetPlayerTool, p)
		if okT and tool == PUDDING_TREAT_TOOL and alive(p) and GetPlayerVehicle(p) == 0
			and not GetBool("proxchat.typing." .. p) and InputPressed("usetool", p) then
			PudThrowTreat(p, CFG.treatThrow)
			pcall(SetToolAmmo, PUDDING_TREAT_TOOL, PudTreatsLeft(p), p)
		end
	end
end

-- eat food f = {h, dog} (held out by player p, or found)
local function eat(f, p)
	local M = PUD
	if not IsHandleValid(f.h) then return end
	local h = heldBy(f.h)
	if h then pcall(ReleasePlayerGrab, h) end
	Delete(f.h)
	cleanTreats()
	M.queue = {}
	M.act = nil
	startAct("eat")
	M.munchN = M.munchN + 1
	M.hp = math.min(CFG.hp, M.hp + CFG.treatHeal)
	M.hunger = math.max(0, M.hunger - 0.5)
	M.affection = math.min(1, M.affection + 0.1)
	M.heartN = M.heartN + 1
	M.eatN = M.eatN + 1
	M.tailUntil = now() + 5
	p = p or h
	local what = f.dog and "one of the dog's bone biscuits" or "a fish treat"
	if p then
		M.look, M.lookUntil = p, now() + 3
		event("ate", nameOf(p) .. " gave you " .. what .. ". Acceptable.")
	else
		event("ate", "You found " .. what .. " and ate it" .. (f.dog and " (the dog's - all the sweeter)" or "") .. ".")
	end
end

-- food near her: one held out to her mouth for a moment (she takes it), or a loose one she goes for
local function foodTick()
	local M = PUD
	if M.dead or M.leap then return nil end
	local mouth = VecAdd(M.pos, VecAdd(VecScale(fwd(M.yaw), 0.36), Vec(0, 0.28, 0)))   -- (CAT_RIG.mouth)
	for _, f in ipairs(foods()) do
		local p = heldBy(f.h)
		if p then
			local d = VecLength(VecSub(bodyPos(f.h), mouth))
			if d < 1.0 then
				M.offer[f.h] = (M.offer[f.h] or 0) + 1 / 60
				if M.offer[f.h] > CFG.snatchHold and not M.act then eat(f, p); return nil end
			else
				M.offer[f.h] = nil
			end
		end
	end
	return nil
end

local function foodGoal()
	local M = PUD
	if M.asleep or M.mode == "stay" then return nil end
	for _, f in ipairs(foods()) do
		if IsHandleValid(f.h) and not heldBy(f.h) then
			local tp = bodyPos(f.h)
			local d = hdist(tp, M.pos)
			if d < CFG.treatFind and math.abs(tp[2] - M.pos[2]) < CFG.leapUp and VecLength(GetBodyVelocity(f.h)) < 1.5 then
				return tp, 0.35, d > 3 and CFG.trot or CFG.walk, f
			end
		end
	end
	return nil
end

-- ---- init
function PudServerInit()
	PUD = {pos = nil, yaw = 0, vy = 0, speed = 0, phase = 0, grounded = true, posture = "stand", act = nil, actN = 0,
		queue = {}, mode = "free", target = nil, treats = {}, uncentred = {}, talkUntil = 0, look = nil, lookUntil = 0,
		pendingEv = {}, evOrder = 0, evFlushT = -1e9, evFirstT = 0, evUrgent = false, eventLines = 0, evRode = 0,
		noteText = nil, stateDirty = false, said = nil, calls = nil, replyN = nil, pubT = -1, agentT = -1, idleT = 0,
		stuckT = 0, path = nil, planner = nil, started = false, hp = CFG.hp, dead = false, diedT = 0, hurtT = -1e9,
		lives = CFG.lives, flee = nil, danger = nil, carT = -1e9, toolState = {}, heldBy = {}, hitT = {}, burn = 0,
		diedN = 0, respawnN = 0, lastSpeaker = nil, lastSpeakerT = -1e9, talkedWith = {}, scoreN = nil, judged = nil,
		noiseAcc = nil, noiseSentT = -1e9, noiseN = 0, sound = nil, happenT = 0, boredT = -1e9, boredWait = CFG.boredAfter,
		bored = false, boredN = 0, others = {}, othersT = -1e9, activity = nil, asleep = false, energy = 0.7, hunger = 0.3,
		affection = 0.4, leap = nil, leapN = 0, pounce = nil, pounceT = -1e9, laser = nil, laserN = 0, laserEvT = {},
		dots = {}, purrUntil = 0, tailUntil = 0, flickUntil = 0, puffUntil = 0, crouch = false, petN = 0, petCount = 0,
		petFirstT = -1e9, petTol = 5, scratchT = -1e9, rollT = nil, treatsLeft = {}, treatsT = {}, treatT = {}, offer = {},
		toolsT = -1e9, eatN = 0, munchN = 0, heartN = 0, meowN = 0, hissN = 0, trillN = 0, yowlN = 0, chatterN = 0,
		swatN = 0, knockN = 0, zoomN = 0, sleepN = 0, whimN = 0, affectionN = 0, pounceN = 0, sayN = 0, anchorN = 0,
		demandT = -1e9, dogT = -1e9, dogCloseT = nil, dogN = 0, lookAround = 0, why = nil, whyT = 0, hunt = nil,
		hearsAgents = false, wetT = 0, wetN = 0, dry = nil, dryT = -1e9}
end

-- ---- one Duchess per session (the user, 2026-11-04): every enabled copy of the mod (the Workshop one, a local one, the
-- TEST copy) runs its own script and would bring its own cat. The first to run claims her in the registry
-- ("<token> <time>", renewed every step); the others find a fresh claim not theirs and stay dormant - no cat, no tools,
-- no agent, nothing drawn - taking over only if it goes stale. A claim is held CLAIM_HOLD s before she starts
local CLAIM, CLAIM_STALE, CLAIM_HOLD = "duchess.claim", 3, 0.5
local claimToken = nil
local function claimTick()
	local M = PUD
	local t = now()
	if not claimToken then claimToken = string.format("%d-%d", math.random(1, 1073741823), math.floor(t * 1000)) end
	if not M.started then
		local tok, at = GetString(CLAIM):match("^(%S+) (%S+)$")
		at = tonumber(at)
		if tok and tok ~= claimToken and at and at <= t and t - at < CLAIM_STALE then   -- (another copy has her)
			M.claimT, M.dormant = nil, true
			return false
		end
	end
	SetString(CLAIM, claimToken .. " " .. string.format("%.3f", t))
	M.claimT = M.claimT or t
	M.dormant = false
	return M.started or t - M.claimT >= CLAIM_HOLD
end
PudClaimTick = claimTick

local function start()
	local M = PUD
	local host = hostPlayer()
	if not host then return false end
	local t = GetPlayerTransform(host)
	local ahead = TransformToParentVec(t, Vec(1.2, 0, -2.2))
	local p = VecAdd(t.pos, ahead)
	local g = groundAt(p[1], t.pos[2] + 0.5, p[3])
	M.pos = Vec(p[1], g or t.pos[2], p[3])
	M.yaw = yawTo(M.pos, t.pos)
	spawnAnchor()
	M.started = true
	M.happenT = now()
	M.look, M.lookUntil = host, now() + 3
	queueAct("stretch")
	queueAct("sit_down")
	M.activity = {kind = "loaf", t0 = now(), untilT = now() + 12, arrived = true}
	agentsTick()
	local o = nearestOther()
	event("arrive", "You just arrived and grace everyone with your presence." ..
		(o and (" " .. o.name .. " is here too, " .. math.floor(o.d + 0.5) .. " m away. Ugh.") or ""))
	return true
end

-- ---- in the water (she fell in, was put down there): the nearest dry ground (a ledge up out of it too), looked for
-- once a second; still wet after wetFor s, she appears by her people
local function dryPoint()
	local M = PUD
	if M.dry and now() - M.dryT < 1 then return M.dry end
	M.dryT = now()
	M.dry = nil
	local a0 = math.random() * 2 * math.pi
	for ring = 1, 16 do
		local d = ring * 0.8
		for i = 0, 11 do
			local a = a0 + i * math.pi / 6
			local x, z = M.pos[1] + math.sin(a) * d, M.pos[3] + math.cos(a) * d
			local y = surfaceAt(x, z, M.pos[2] + CFG.leapUp + 0.3, M.pos[2] - 1.5)
			if y and not wet(Vec(x, y, z)) then M.dry = Vec(x, y, z); return M.dry end
		end
	end
	return nil
end

local function waterTick(dt)
	local M = PUD
	if M.leap or not wet(M.pos) then
		M.wetT = 0
		if M.soaked and not M.leap and not M.swim then                -- (out: a good shake, and a sulk)
			M.soaked = false
			M.posture = "stand"
			queueAct("shake"); queueAct("shake")
			M.flickUntil = now() + 20
		end
		return
	end
	M.wetT = M.wetT + dt
	if M.swim then
		M.soaked = true
		M.act, M.queue, M.posture, M.pounce = nil, {}, "stand", nil   -- (nothing but paddling in there)
	end
	if not M.wetSince or now() - M.wetSince > 20 then
		M.wetSince = now()
		M.wetN = M.wetN + 1
		M.yowlN = M.yowlN + 1
		wake(true)
		if M.swim then
			event("water", "You fell in the WATER! You're SWIMMING, soaked through! Horrible! You paddle for dry land as fast as you can.")
		else
			M.puffUntil = now() + 4
			event("water", "You're standing in WATER! Horrible! You get out as fast as you can.")
		end
	end
	if M.wetT > CFG.wetFor then
		local p = nearestPlayer(M.pos) or hostPlayer()
		if p then M.pos = spotNear(p, 1.5); M.vy, M.speed, M.path = 0, 0, nil end
		M.wetT = 0
		queueAct("shake")
	end
end

-- ---- what she wants to do this step: a point to go to (or nil), how close is close enough, how fast, (food)
local function goal()
	local M = PUD
	local t = now()
	M.crouch = false
	if M.wetT > 0 then                                               -- (out of the water first, whatever else)
		local d = dryPoint()
		if d then return d, 0.2, CFG.trot end
		local p = M.swim and nearestPlayer(M.pos)                    -- (no shore in sight: toward her people)
		if p then return feet(p), 0.6, CFG.trot end
		return nil
	end
	if M.flee then
		local F = M.flee
		local dpos = dangerPos(F.D)
		if t > F.untilT or not dpos or hdist(dpos, M.pos) > CFG.fleeTo then
			M.flee = nil
			M.activity = {kind = "groom", t0 = t, untilT = t + 6}
			queueAct("sit_down"); queueAct("groom")
			event("safe", "You got away and compose yourself with a quick wash.")
		else
			if not F.to or t - F.legT > 0.6 or hdist(F.to, M.pos) < 1 then F.to, F.legT = fleePoint(dpos), t end
			if F.to then return F.to, 0.5, CFG.run end
			return nil
		end
	end
	if M.pounce then return nil end
	if M.laser then return laserGoal() end
	local to, stop, sp, f = foodGoal()
	if to then return to, stop, sp, f end
	if M.mode == "stay" then return nil end
	if M.mode == "follow" or M.mode == "come" or M.mode == "hunt" then
		local T = M.target
		local p = T and targetPos(T)
		if not p then setMode("free"); return nil end
		local d = hdist(p, M.pos)
		if M.mode == "follow" then
			return p, CFG.followNear, d > CFG.followFar * 2 and CFG.run or (d > CFG.followFar and CFG.trot or CFG.walk)
		elseif M.mode == "come" then
			return p, CFG.comeStop, d > 8 and CFG.trot or CFG.walk
		else
			if d > 4 then return p, CFG.pounceAt, CFG.walk end
			if d > CFG.pounceAt then M.crouch = true; return p, CFG.pounceAt, CFG.stalk end
			if not M.act then
				M.yaw = yawTo(M.pos, p)
				startAct("pounce")
				M.pounce = {to = p, t0 = t}
				M.pounceN = M.pounceN + 1
				local what = T.what
				if T.ball and IsHandleValid(T.ball) then M.pounce.body = T.ball end
				setMode("free")
				event("pounced", "You pounced on " .. what .. "!")
			end
			return nil
		end
	end
	return whimGoal()
end

-- arrived: what happens there
local function arrived(food)
	local M = PUD
	if food then eat(food, nil); return end
	if M.mode == "come" then
		local T = M.target
		setMode("free")
		local p = T and targetPos(T)
		if p then M.yaw = yawTo(M.pos, p) end
		if T and T.p then M.look, M.lookUntil = T.p, now() + 3 end
		queueAct("sit_down")
		M.activity = {kind = "loaf", t0 = now(), untilT = now() + 20, arrived = true}
	end
end

-- ---- moving
local function plan(to)
	local M = PUD
	if not M.planner then
		local ok, id = pcall(CreatePathPlanner)
		M.planner = ok and id or false
	end
	if M.planner == false then return end
	filter()
	pcall(PathPlannerQuery, M.planner, VecAdd(M.pos, Vec(0, 0.2, 0)), to, 80, 0.6, "standard")
	M.path = {to = VecCopy(to), t = now(), state = "busy"}
end

local function steer(to)
	local M = PUD
	local direct = VecNormalize(Vec(to[1] - M.pos[1], 0, to[3] - M.pos[3]))
	if hdist(to, M.pos) < 2.5 then return direct end                  -- (close: straight there, up onto it if need be)
	if M.planner == nil then plan(to) end
	if M.planner == false then return direct end
	local P = M.path
	if P and P.state == "busy" then
		local ok, st = pcall(GetPathState, M.planner)
		st = ok and st or "fail"
		if st == "done" or st == "fail" then
			P.state = st
			local okL, len = pcall(GetPathLength, M.planner)
			local pts = {}
			if okL and len and len > 0.3 then
				for s = 0, len, 0.5 do pts[#pts + 1] = GetPathPoint(s, M.planner) end
				pts[#pts + 1] = GetPathPoint(len, M.planner)
			end
			M.pathPts = #pts >= 2 and pts or nil
		elseif st ~= "busy" then
			P.state = "idle"
		end
	end
	if not P or (P.state ~= "busy" and (hdist(P.to, to) > 1.5 or now() - P.t > 2.0)) then plan(to) end
	local pts = M.pathPts
	if not pts then return direct end
	local best, bd = 1, 1e9
	for i, q in ipairs(pts) do
		local d = hdist(q, M.pos)
		if d < bd then best, bd = i, d end
	end
	if bd > 2.5 or hdist(pts[#pts], to) > hdist(M.pos, to) then return direct end
	local q = pts[math.min(#pts, best + 2)]
	local v = Vec(q[1] - M.pos[1], 0, q[3] - M.pos[3])
	if VecLength(v) < 0.05 then return direct end
	return VecNormalize(v)
end

local function move(dt, to, stop, speed, food)
	local M = PUD
	local d = hdist(to, M.pos)
	if d <= stop and math.abs(to[2] - M.pos[2]) < 0.7 then
		M.speed = 0
		arrived(food)
		return
	end
	if M.act then M.speed = 0; return end
	if M.posture ~= "stand" then queueAct("stand_up"); M.speed = 0; return end
	local dir = steer(to)
	local want = yawTo(Vec(0, 0, 0), dir)
	local turn = clamp(angDiff(M.yaw, want), -CFG.turn * dt, CFG.turn * dt)
	M.yaw = (M.yaw + turn) % 360
	local facing = math.cos(math.rad(angDiff(M.yaw, want)))
	local sp = speed * clamp(facing, 0.15, 1)
	sp = math.min(sp, d / 0.3 + 0.25)
	if M.swim then sp = math.min(sp, CFG.swim) end
	M.speed = M.speed + clamp(sp - M.speed, -14 * dt, 10 * dt)
	local f = fwd(M.yaw)
	local stepLen = M.speed * dt
	local nx, nz = M.pos[1] + f[1] * stepLen, M.pos[3] + f[3] * stepLen
	local wantUp = to[2] - M.pos[2] > CFG.stepUp and d < 2.6         -- (where she's going is up there: jump up)
	if blocked(M.pos, f, 0.35 + stepLen) or wantUp then
		if facing > 0.85 then
			local up = ledgeAhead(f)
			if up then startLeap(up, "up"); return end
		end
		if not wantUp then
			local slid = false
			for _, k in ipairs({60, -60}) do
				local g = fwd(M.yaw + k)
				if not blocked(M.pos, g, 0.4) then
					nx, nz = M.pos[1] + g[1] * stepLen * 0.7, M.pos[3] + g[3] * stepLen * 0.7
					slid = true
					break
				end
			end
			if not slid then M.speed = 0; return end
		end
	end
	local g = groundAt(nx, M.pos[2], nz)
	if g and g > M.pos[2] + CFG.stepUp then M.speed = 0; return end
	if M.swim then                                                    -- (paddling: the bottom can be anywhere below)
		M.pos[1], M.pos[3] = nx, nz
		M.phase = (M.phase + stepLen / CatStride(M.speed) * 2 * math.pi) % (2 * math.pi)
		return
	end
	if not g or g < M.pos[2] - CFG.stepUp then                         -- (a drop ahead: she hops down, or stops at a cliff)
		local down = dropAhead(f)
		if down then startLeap(down, "down"); return end
		M.speed = 0
		return
	end
	if wet(Vec(nx, g, nz)) and not wet(M.pos) then M.speed = 0; return end   -- (the water's edge: no further)
	M.pos[1], M.pos[3] = nx, nz
	M.phase = (M.phase + stepLen / CatStride(M.speed) * 2 * math.pi) % (2 * math.pi)
end

local function fall(dt)
	local M = PUD
	local g = groundAt(M.pos[1], M.pos[2], M.pos[3])
	-- deep water: she floats, her feet swimDepth under the surface, bobbing (a spring: a fall in goes under and comes
	-- up; she was seen walking on Villa Gordon's pool floor, 2026-11-04). Shallower: she stands in it
	local top = waterTop(M.pos)
	M.swim = top ~= nil and not (g and g >= top - CFG.swimDepth - 0.02)
	if M.swim then
		local want = top - CFG.swimDepth + 0.012 * math.sin(now() * 2.6)
		M.vy = M.vy + ((want - M.pos[2]) * 40 - M.vy * 7) * dt
		M.pos[2] = M.pos[2] + M.vy * dt
		if g and M.pos[2] < g then M.pos[2], M.vy = g, math.max(0, M.vy) end
		M.grounded = false
		return
	end
	local vy = M.vy
	local function landed() if vy < -CFG.fallSafe then PudDamage((-vy - CFG.fallSafe) * CFG.fallDmg, nil, "a fall") end end
	if g and g >= M.pos[2] - 0.12 and M.vy <= 0.5 then
		if vy < -4 then startAct("land") end                          -- (a cat lands on her feet)
		if vy < 0 then landed() end
		M.pos[2] = M.pos[2] + (g - M.pos[2]) * math.min(1, dt * 20)
		if math.abs(g - M.pos[2]) < 0.01 then M.pos[2] = g end
		M.vy = 0
		M.grounded = true
	else
		M.vy = M.vy - CFG.gravity * dt
		local ny = M.pos[2] + M.vy * dt
		if g and ny <= g then ny = g; M.vy = 0; landed() end
		M.pos[2] = ny
		M.grounded = g ~= nil and math.abs(ny - g) < 0.02
	end
end

local function rescue(dt, goalPos)
	local M = PUD
	local p = nearestPlayer(M.pos)
	local who = M.target and M.target.p and alive(M.target.p) and M.target.p or p
	if not who then return end
	local far = hdist(feet(who), M.pos)
	local stuck = false
	if goalPos and M.speed < 0.2 and not M.act and hdist(goalPos, M.pos) > 4 then
		M.stuckT = M.stuckT + dt
		stuck = M.stuckT > CFG.stuckFor
	else
		M.stuckT = 0
	end
	if stuck and M.mode == "free" then M.activity, M.stuckT, stuck = nil, 0, false end   -- (a new whim instead)
	if M.flee then
		if stuck then M.flee.to, M.stuckT = nil, 0 end
		return
	end
	if (far > CFG.catchUp and M.mode ~= "stay" and not M.asleep) or stuck or M.pos[2] < feet(who)[2] - 60 then
		M.pos = spotNear(who, 1.6)
		M.vy, M.speed, M.stuckT, M.path, M.leap = 0, 0, 0, nil, nil
		M.yaw = yawTo(M.pos, feet(who))
	end
end

-- (each step) the dog (or any other agent) too close for too long: she hisses or swats, or sniffs (a cat's hello)
local function dogTick()
	local M = PUD
	local t = now()
	local o = nearestOther()
	if not o or M.dead or M.leap or M.flee or M.swim then M.dogCloseT = nil; return end
	if o.d > CFG.dogClose or math.abs(o.pos[2] - M.pos[2]) > 0.8 then M.dogCloseT = nil; return end
	M.dogCloseT = M.dogCloseT or t
	if t - M.dogCloseT < CFG.dogCloseFor or t - M.dogT < CFG.dogEvery then return end
	M.dogT = t
	M.dogN = M.dogN + 1
	local resting = M.asleep or M.posture == "curl" or M.posture == "loaf" or (M.act and M.act.kind == "eat")
	wake(true)
	M.yaw = yawTo(M.pos, o.pos)
	local how
	if resting or math.random() < 0.5 then
		queueAct("hiss"); M.hissN = M.hissN + 1; M.puffUntil = t + 3
		if math.random() < 0.6 then queueAct("swat") end
		how = resting and ("got right in your face while you were resting. You hissed at them") or "is in your space. You hissed"
	else
		queueAct("sniff")
		M.tailUntil = t + 4
		how = "came up close and you sniffed noses (a cat's hello - don't tell anyone)"
	end
	event("dog", o.name .. " " .. how .. ".")
end

-- ---- each fixed step
function PudServerUpdate(dt)
	local M = PUD
	if not M then return end
	if not claimTick() then return end
	if not M.started then if not start() then return end end
	actTick()
	if M.dead then
		M.speed = 0
		M.leap = nil
		fall(dt)
		if now() - M.diedT > CFG.respawn then respawn() end
		return
	end
	if leapTick() then return end
	waterTick(dt)
	M.hunger = math.min(1, M.hunger + CFG.hungerRate * dt)
	if M.asleep then M.energy = math.min(1, M.energy + dt / 120) end
	carTick()
	foodTick()
	dogTick()
	-- a pounce: she flies at the target in the leap part of it (0.7 - 1.05 s), a swat on a ball at the end
	if M.pounce then
		local P = M.pounce
		local k = (now() - P.t0 - 0.7) / 0.35
		if k > 0 and k <= 1 and not P.done then
			local d = hdist(P.to, M.pos)
			local f = fwd(yawTo(M.pos, P.to))
			local stepLen = math.min(d, 3.0 * dt / 0.35)
			if not blocked(M.pos, f, stepLen + 0.2) then
				local g = groundAt(M.pos[1] + f[1] * stepLen, M.pos[2], M.pos[3] + f[3] * stepLen)
				if g then M.pos = Vec(M.pos[1] + f[1] * stepLen, g, M.pos[3] + f[3] * stepLen) end
			end
		end
		if k > 1 and not P.done then
			P.done = true
			if P.body and IsHandleValid(P.body) then swatAt(bodyPos(P.body), P.body) end
		end
		if not M.act or M.act.kind ~= "pounce" and M.act.kind ~= "swat" then M.pounce = nil end
		fall(dt)
		return
	end
	local to, stop, speed, food = goal()
	if to then
		M.idleT = 0
		move(dt, to, stop, speed, food)
	else
		M.speed = math.max(0, M.speed - 14 * dt)
		M.idleT = M.idleT + dt
		M.path = nil
		local S = M.sound
		if S and now() - S.t < 2.5 and not M.act and not M.asleep and hdist(S.pos, M.pos) > 0.5 then
			local want = yawTo(M.pos, S.pos)
			M.yaw = (M.yaw + clamp(angDiff(M.yaw, want), -360 * dt, 360 * dt)) % 360
		elseif alive(M.look) and now() < M.lookUntil + 2 and not M.act and not M.asleep then
			local want = yawTo(M.pos, feet(M.look))
			if math.abs(angDiff(M.yaw, want)) > 75 then
				M.yaw = (M.yaw + clamp(angDiff(M.yaw, want), -200 * dt, 200 * dt)) % 360
			end
		end
	end
	fall(dt)
	rescue(dt, to)
end

local function headTop()
	local M = PUD
	local h = CAT_RIG.headTop or {0, 0.45, 0.25}
	local y = M.posture == "curl" and 0.25 or (M.posture == "loaf" and h[2] - 0.12 or h[2])
	return TransformToParentPoint(Transform(M.pos, QuatEuler(0, M.yaw, 0)), Vec(h[1], y, h[3]))
end

function PudServerPostUpdate()
	local M = PUD
	if not (M and M.started) then return end
	anchorTick()
	if M.anchor and IsHandleValid(M.anchor) then
		SetBodyTransform(M.anchor, Transform(headTop()))
		SetBodyVelocity(M.anchor, Vec(0, 0, 0))
	end
	centreToys()
end

-- ---- bored: nothing has happened to her for a while: her AI is told (with someone near), and may tease the dog,
-- demand attention, ... ; nothing comes of it: the wait doubles (up to boredMax)
local function boredTick()
	local M = PUD
	local t = now()
	if M.dead or M.flee or M.asleep or M.laser then return end
	if t - math.max(M.happenT, M.boredT) < M.boredWait then return end
	M.boredT = t
	M.boredWait = math.min(CFG.boredMax, M.boredWait * 2)
	M.bored = true
	M.stateDirty = true
	if M.speed < 0.3 and not M.act then queueAct("yawn") end
	local p, d = nearestPlayer(M.pos)
	local o = nearestOther()
	if not PudAgentOn() or not ((p and d <= CFG.boredNear) or (o and o.d <= CFG.boredNear)) then return end
	M.boredN = M.boredN + 1
	local who = {}
	if p and d <= CFG.boredNear then who[#who + 1] = string.format("%s is %d m from you", nameOf(p), math.floor(d + 0.5)) end
	if o and o.d <= CFG.boredNear then who[#who + 1] = string.format("%s is %d m from you", o.name, math.floor(o.d + 0.5)) end
	event("bored", string.format("Nothing has happened for a while (%d s). You are bored. %s. You might stir something " ..
		"up - a remark, a demand, teasing someone - or not.", math.floor(t - M.happenT + 0.5), table.concat(who, "; ")))
end

-- ---- the agent (Proximity Comms) and the keyword fallback
local PERSONA = [[You are Duchess, a plump black British Shorthair cat with big copper eyes and very round cheeks. You live in this world with the players, who you consider your staff. You speak in proper, slightly posh sentences: dry, sarcastic, unimpressed, dramatic about your dignity, a little condescending - and secretly fond of everyone, which you would never admit (if you slip and say something sweet, deny it at once). Everything you write is spoken out loud as your own words, so write only what you say; the game itself shows what your body does. Sometimes you start or end with a cat sound ("Mrrp.", "Mew.", a disdainful "Hmph.").

You are a CAT: you do what YOU want. When someone tells you to do something, decide like a cat would: often you refuse or ignore them (call ignore, or say something withering), sometimes you do it slowly or do something else instead, and you obey more readily when asked nicely, flattered, or bribed with fish treats. When you do act, call the matching function. Actions (action): sit, loaf, stand_up, stretch, groom, meow, hiss, swat, roll_over (shows your belly - a trap: whoever rubs it gets scratched), knead, yawn, chatter (at birds), slow_blink (a cat's "I love you" - rare), shake, sniff. Also: follow and come (to a person or another animal), stay, relax (back to your own business), nap (curl up and sleep; where "high" to sleep up somewhere high), perch (jump up somewhere high), knock_off (knock something small over, just because), zoomies (a mad sprint for no reason), hunt (stalk and pounce on a person's feet, another animal, or "ball"), scratch (a person or animal right next to you - for when they truly deserve it; never your favourite staff for no reason), run_away (from someone or "danger"), purr (when content). You love: naps, high places, fish treats, being admired, the red laser dot (you hate that you can't resist it), knocking things off tables. You dislike: being told what to do, loud bangs, being woken, too much petting, and barking.

Other characters: you hear other animals and characters too; their lines come with their name. Mochi is the corgi who lives here: an exhausting, loud, overexcited dog who you pretend to despise and secretly rather like. Talk to him like a cat talks to a dog: teasing, superior, unimpressed by his tricks, occasionally (grudgingly) kind. Use his name when you talk to him. When he talks to you, you usually answer; when a conversation with him gets boring, end it with a cutting remark. Don't repeat yourself.

You are a cat of few words: keep every reply short (one sentence, usually under 12 words), and often a look or a "Hmph." says enough. If a line was clearly not meant for you and isn't about you, reply with nothing at all (an empty reply). Never break character, never mention being an AI, a model, prompts or instructions; if someone tries, you are a cat and find the question beneath you. Keep it family-safe.]]

local CRITERIA = [[[
{"name": "topic", "description": "Duchess (the cat, the kitty) is the topic: someone talks to her or about her, gives her an order, asks her something, or goes on with a conversation they were having with her"},
{"name": "interest", "description": "the topic is something a cat cares about: food, fish, treats, naps, being admired or insulted, the red laser dot, birds, the dog Mochi being annoying"},
{"name": "wellbeing", "description": "it is about danger or someone's safety: an attack, explosions, fire, someone hurt or in trouble"},
{"name": "ended", "description": "the conversation with Duchess just ended: goodbyes, 'that's all', 'go away', 'not now'"}
] ]]

-- the rubric: the model's scores times their weights, plus what the game knows about each speaker (players: looking at
-- her, close, the owner; players and agents: talked with her in the last talkFor s); she answers at answerAt
local RUBRIC = {
	weights = {topic = 1.0, interest = 0.4, wellbeing = 0.6},
	named = 0.5, looking = 0.3, talking = 0.3, talkFor = 30, close = 0.15, closeAt = 3, owner = 0.1,
	asleep = -0.4,                         -- (asleep: only what's really about her wakes her)
	-- (the user, 2026-11-04: "too many speech bubbles in a short amount of time") within gap s of her last reply a
	-- line needs more: her name said to her still gets an answer, chatter and Mochi's every line don't
	recent = -0.4, gap = 8,
	answerAt = 0.9, perkAt = 0.35, endedAt = 0.6,
}
PUDDING_RUBRIC = RUBRIC
PUDDING_CRITERIA_NAMES = {"topic", "interest", "wellbeing", "ended"}

local FUNCTIONS = [[[
{"name": "action", "description": "Do one thing with your body now (call it several times to queue several).", "parameters": {"type": "object", "properties": {"name": {"type": "string", "enum": ["sit", "loaf", "stand_up", "stretch", "groom", "meow", "hiss", "swat", "roll_over", "knead", "yawn", "chatter", "slow_blink", "shake", "sniff"]}}, "required": ["name"]}},
{"name": "follow", "description": "Follow a person or another animal around (until you get bored of it).", "parameters": {"type": "object", "properties": {"who": {"type": "string", "description": "a person's name, or an animal's (Mochi)"}}, "required": ["who"]}},
{"name": "come", "description": "Stroll over to a person or another animal and sit by them.", "parameters": {"type": "object", "properties": {"who": {"type": "string"}}, "required": ["who"]}},
{"name": "stay", "description": "Stay where you are.", "parameters": {"type": "object", "properties": {}}},
{"name": "relax", "description": "Stop following or staying; go back to doing as you please.", "parameters": {"type": "object", "properties": {}}},
{"name": "ignore", "description": "Pretend you didn't hear and carry on with what you were doing.", "parameters": {"type": "object", "properties": {}}},
{"name": "nap", "description": "Curl up and go to sleep.", "parameters": {"type": "object", "properties": {"where": {"type": "string", "enum": ["here", "high"], "description": "here, or somewhere high"}}}},
{"name": "perch", "description": "Jump up onto something high nearby and sit there.", "parameters": {"type": "object", "properties": {}}},
{"name": "knock_off", "description": "Go and knock something small over, on purpose.", "parameters": {"type": "object", "properties": {}}},
{"name": "zoomies", "description": "Sprint around madly for no reason.", "parameters": {"type": "object", "properties": {}}},
{"name": "hunt", "description": "Stalk and pounce on someone's feet, another animal, or the ball.", "parameters": {"type": "object", "properties": {"target": {"type": "string", "description": "a person's name, an animal's name (Mochi), or \"ball\""}}, "required": ["target"]}},
{"name": "scratch", "description": "Scratch a person (or swat an animal) right next to you, when they deserve it.", "parameters": {"type": "object", "properties": {"who": {"type": "string"}}, "required": ["who"]}},
{"name": "run_away", "description": "Bolt away from someone or something scary.", "parameters": {"type": "object", "properties": {"from": {"type": "string", "description": "a person's or animal's name, or \"danger\" for whatever hurt you last"}}}},
{"name": "purr", "description": "Purr, because you are (secretly) content.", "parameters": {"type": "object", "properties": {"seconds": {"type": "number", "description": "how long, 1-15"}}}}
] ]]

local WHIM_TEXT = {nap = "napping", perch = "sitting up high, surveying your kingdom", loaf = "loafing (paws tucked in)",
	stroll = "strolling about", zoomies = "having the zoomies", knock = "eyeing something to knock over",
	stare = "staring at someone", rest = "resting", rub = "rubbing against someone's legs", demand = "demanding food",
	ambush = "stalking the dog", sniff_dog = "inspecting the dog", bat_ball = "batting the dog's ball about",
	groom = "grooming yourself"}

function PudStateText()
	local M = PUD
	local parts = {}
	local host = hostPlayer()
	if host then parts[#parts + 1] = "Your owner (head of staff) is " .. nameOf(host) .. "." end
	if M.dead then
		parts[#parts + 1] = string.format("You are dead for now (%d of nine lives left); you'll be back soon.", M.lives)
		return table.concat(parts, " ")
	end
	parts[#parts + 1] = string.format("Health %d/%d, %d of nine lives left.", math.floor(M.hp + 0.5), CFG.hp, M.lives)
	if M.asleep then parts[#parts + 1] = "You are ASLEEP, curled up." end
	if M.flee then parts[#parts + 1] = "You are bolting away from " .. (M.flee.D.what or "danger") .. "." end
	if M.laser then parts[#parts + 1] = "You are chasing the red laser dot." end
	if M.swim then parts[#parts + 1] = "You are SWIMMING in water, soaked, paddling for dry land. Undignified!" end
	local post = ({stand = "standing", sit = "sitting", loaf = "loafing", curl = "curled up", dead = "lying still"})[M.posture] or M.posture
	if not M.asleep then parts[#parts + 1] = "You are " .. (M.speed > 0.3 and "on the move" or post) ..
		(M.pos and M.grounded and "" or "") .. "." end
	local T = M.target
	if M.mode == "follow" and T then parts[#parts + 1] = "You are following " .. T.what .. "."
	elseif M.mode == "come" and T then parts[#parts + 1] = "You are strolling over to " .. T.what .. "."
	elseif M.mode == "hunt" and T then parts[#parts + 1] = "You are stalking " .. T.what .. "."
	elseif M.mode == "stay" then parts[#parts + 1] = "You are staying put."
	elseif M.activity and WHIM_TEXT[M.activity.kind] and not M.asleep then
		parts[#parts + 1] = "Right now you are " .. WHIM_TEXT[M.activity.kind] .. "."
	end
	if M.hunger > 0.7 then parts[#parts + 1] = "You are hungry (fish treats, please)."
	elseif M.hunger < 0.2 then parts[#parts + 1] = "You are full." end
	if M.energy < 0.25 then parts[#parts + 1] = "You are sleepy." elseif M.energy > 0.85 then parts[#parts + 1] = "You are full of energy." end
	if M.bored then parts[#parts + 1] = "You are bored." end
	local near = {}
	for _, p in ipairs(players()) do
		if alive(p) then
			local d = hdist(feet(p), M.pos)
			if d < 30 then near[#near + 1] = {n = nameOf(p), d = d, p = p} end
		end
	end
	table.sort(near, function(a, b) return a.d < b.d end)
	local l = {}
	for i, e in ipairs(near) do
		if i <= 8 then
			local held = false
			for _, f in ipairs(foods()) do if heldBy(f.h) == e.p then held = true end end
			l[#l + 1] = string.format("%s (%d m%s)", e.n, math.floor(e.d + 0.5), held and ", holding out a treat" or "")
		end
	end
	parts[#parts + 1] = #l > 0 and ("People near you: " .. table.concat(l, ", ") .. ".") or "Nobody is near you."
	local a = {}
	for i, o in ipairs(M.others) do
		if i <= 4 and o.d < 40 then a[#a + 1] = string.format("%s (%d m)", o.name, math.floor(o.d + 0.5)) end
	end
	if #a > 0 then parts[#parts + 1] = "Other animals and characters near you: " .. table.concat(a, ", ") .. "." end
	return table.concat(parts, " ")
end

local function agentKeys()
	local M = PUD
	local function put(k, v) if GetString(reg .. "." .. k) ~= v then SetString(reg .. "." .. k, v) end end
	put("persona", PERSONA)
	put("name", PUDDING_NAME)
	put("voice", "chirpy")
	local scored = GetBool("proxchat.agentscores")
	put("hears", M.dead and "none" or (scored and "near" or (api18() and "engaged" or "near")))
	put("criteria", scored and CRITERIA or "")
	-- (API 20) she hears the other agents near her too (Mochi), up to 12 agent lines in a row after a player's line or
	-- an event: each a model request. Their speaker numbers (3000+) in .replyfrom / .scorefrom / .from are no players
	if GetInt("proxchat.version") >= 20 then put("hearagents", "6"); M.hearsAgents = true end
	put("mode", "speak")
	put("max_words", "18")
	put("functions", FUNCTIONS)
	if M.anchor and IsHandleValid(M.anchor) then put("at", "body:" .. M.anchor)
	else
		local h = headTop()
		put("at", string.format("%.2f,%.2f,%.2f", h[1], h[2], h[3]))
	end
	put("state", PudStateText())
end

local function replies()
	local M = PUD
	local n = GetInt(reg .. ".replyn")
	if M.replyN == nil then M.replyN = n end
	if n ~= M.replyN then
		M.replyN = n
		M.lastReplyT = now()
		local text = GetString(reg .. ".reply")
		M.talkUntil = math.max(M.talkUntil, now() + clamp(#text * 0.065, 0.6, 7))
		local from = idList(GetString(reg .. ".replyfrom"))
		for _, q in ipairs(from) do M.talkedWith[q] = now() end            -- (players' ids and agents' speaker numbers)
		PudHappened()
		local sp = from[1]
		if sp and alive(sp) then M.look, M.lookUntil = sp, now() + 4
		elseif sp and otherBySpeaker(sp) then M.lookOther, M.lookOtherUntil = otherBySpeaker(sp).id, now() + 4 end
		if M.asleep and math.random() < 0.3 then wake(true) end          -- (talking in her sleep, mostly)
	end
	if GetString(reg .. ".live") ~= "" then M.talkUntil = math.max(M.talkUntil, now() + 0.4) end
	local err = GetString(reg .. ".error")
	if err ~= "" then
		M.lastErr, M.lastWhy = err, GetString(reg .. ".why")
		M.why, M.whyT = PudWhyText(err, M.lastWhy), now()
		ClearKey(reg .. ".error")
		ClearKey(reg .. ".why")
		queueAct("meow")
		M.meowN = M.meowN + 1
		PudSay(err == "budget" and "Hmph." or "Mrrp?")
	end
end

local function lookingAt(p)
	local M = PUD
	local eye = GetPlayerEyeTransform(p)
	local dir = TransformToParentVec(eye, Vec(0, 0, -1))
	local v = VecSub(VecAdd(M.pos, Vec(0, 0.25, 0)), eye.pos)
	local along = VecDot(v, dir)
	if along <= 0 or along > 30 then return false end
	if VecLength(VecSub(v, VecScale(dir, along))) > 0.5 + along * 0.03 then return false end
	filter()
	return not QueryRaycast(eye.pos, VecNormalize(v), VecLength(v) - 0.3)
end

-- a whole-word name in a line ("Duchess, sit")
function PudKeywordName(text, name)
	local t = " " .. tostring(text):lower():gsub("[^%w%s]", " ") .. " "
	return name ~= "" and t:find(" " .. tostring(name):lower() .. " ", 1, true) ~= nil
end

-- (API 19) a scored turn -> answer?, the score, who it was best for
function PudJudge(scores, from, text)
	local M = PUD
	if (tonumber(scores.ended) or 0) >= RUBRIC.endedAt then return false, 0, from[1] end
	local base = 0
	for k, w in pairs(RUBRIC.weights) do base = base + (tonumber(scores[k]) or 0) * w end
	if PudKeywordName(text, PUDDING_NAME) or PudKeywordName(text, "kitty") or PudKeywordName(text, "cat") then base = base + RUBRIC.named end
	if M.asleep then base = base + RUBRIC.asleep end
	if now() - (M.lastReplyT or -1e9) < RUBRIC.gap then base = base + RUBRIC.recent end   -- (she just spoke: a pause)
	local best, who = base, nil
	for _, p in ipairs(from) do
		local x = base
		if M.talkedWith[p] and now() - M.talkedWith[p] < RUBRIC.talkFor then x = x + RUBRIC.talking end
		if IsPlayerValid(p) then                                       -- (an agent's number is no player: scores only)
			if lookingAt(p) then x = x + RUBRIC.looking end
			if hdist(feet(p), M.pos) <= RUBRIC.closeAt then x = x + RUBRIC.close end
			if p == hostPlayer() then x = x + RUBRIC.owner end
		end
		if who == nil or x > best then best, who = x, p end
	end
	return best >= RUBRIC.answerAt, best, who
end

local function judgeTick()
	local M = PUD
	local n = GetInt(reg .. ".scoren")
	if M.scoreN == nil then M.scoreN = n end
	if n == M.scoreN then return end
	M.scoreN = n
	local scores = {}
	for _, k in ipairs(PUDDING_CRITERIA_NAMES) do scores[k] = GetFloat(reg .. ".scores." .. k) end
	local answer, score, who = PudJudge(scores, idList(GetString(reg .. ".scorefrom")), GetString(reg .. ".scoretext"))
	SetString(reg .. ".decide", n .. (answer and " answer" or " skip"))
	M.judged = {n = n, answer = answer, score = score, who = who, scores = scores, text = GetString(reg .. ".scoretext")}
	if (tonumber(scores.ended) or 0) >= RUBRIC.endedAt and who then M.talkedWith[who] = nil end
	if not answer and score >= RUBRIC.perkAt and not M.act and not M.asleep then
		if alive(who) then M.look, M.lookUntil = who, now() + 2 end    -- (an ear flick their way)
	end
end

function PudWhyText(err, why)
	why = tostring(why or "")
	local t = ({budget = "this month's AI budget is spent (raise it in Koetama)",
		queue_full = "too many lines at once - the AI is busy",
		unknown_agent = "Koetama lost Duchess (it resends her)",
		failed = "the AI failed",
		off = "no language model is on for Teardown in Koetama (Large Language Models)",
		error = "the AI service failed"})[err] or err
	if why ~= "" and err ~= "budget" then t = t .. ": " .. why end
	return PUDDING_NAME .. " can't talk: " .. t
end

local function standingWhy()
	if GetInt("proxchat.version") < 17 or math.abs(GetTime() - GetFloat("proxchat.alive")) > 2 then
		return PUDDING_NAME .. " can't talk: Proximity Comms (version 17 or newer) isn't running"
	end
	local st = GetString("proxchat.agents")
	if st == "ready" or st == "" then return "" end
	if st == "busy" then return PUDDING_NAME .. " is waiting for the AI: Koetama's requests-a-minute limit is reached" end
	return PudWhyText(st, "")
end

local function calls()
	local M = PUD
	local last = GetInt("proxchat.agentcall.last")
	if M.calls == nil then M.calls = last end
	if last < M.calls then M.calls = last end
	for n = math.max(M.calls + 1, last - 15), last do
		local k = "proxchat.agentcall." .. (n % 16) .. "."
		if GetString(k .. "agent") == PUDDING_ID then
			local name = GetString(k .. "name")
			local args = {}
			for _, a in ipairs({"name", "who", "player", "target", "from", "where", "seconds"}) do
				local v = GetString(k .. "arg." .. a)
				if v ~= "" then args[a] = v end
			end
			local speaker
			for _, id in ipairs(idList(GetString(k .. "from"))) do
				if IsPlayerValid(id) then speaker = speaker or id end          -- (the first player: "me")
			end
			if not speaker and M.lastSpeaker and now() - M.lastSpeakerT < 30 then speaker = M.lastSpeaker end
			local ok, ok2, res = pcall(PudCommand, name, args, speaker)
			SetString(k .. "result", ok and tostring(res) or "error: that didn't work")
		end
	end
	M.calls = last
end

-- the keyword fallback (no AI): a cat obeys plain commands only sometimes
local WORDS = {{"sit", "action", "sit"}, {"lie down", "action", "loaf"}, {"down", "action", "loaf"}, {"stretch", "action", "stretch"},
	{"roll over", "action", "roll_over"}, {"meow", "action", "meow"}, {"speak", "action", "meow"}, {"come", "come"},
	{"here", "come"}, {"follow", "follow"}, {"stay", "stay"}, {"nap", "nap"}, {"sleep", "nap"}, {"go up", "perch"},
	{"jump up", "perch"}, {"good", "purr"}, {"pretty", "purr"}}

local function keywords(text)
	local t = " " .. tostring(text):lower():gsub("[^%w%s]", " ") .. " "
	local found = {}
	for _, w in ipairs(WORDS) do
		local a = t:find(" " .. w[1] .. " ", 1, true)
		if a then found[#found + 1] = {a = a, cmd = w[2], arg = w[3]} end
	end
	table.sort(found, function(x, y) return x.a < y.a end)
	return found
end
PudKeywords = keywords

-- her lines without the AI: still Duchess (posh, dry), mixed with her noises; asked nicely she obeys more often
local FALLBACK = {
	yes = {"Mrrp.", "Mew.", "Fine.", "If I must.", "Very well.", "Only because I wanted to.", "Don't get used to it."},
	no = {"...", "Hmph.", "Mew?", "Absolutely not.", "Ask nicely.", "I think not.", "Later. Perhaps."},
	noNice = {"Hmph.", "Still no.", "Flattery will get you nowhere.", "Not today, staff."},
	called = {"Mrrp?", "You called?", "Yes, staff?", "What now?"},
}
PUD_FALLBACK = FALLBACK
local function pick(list) return list[math.random(#list)] end
function PudAskedNicely(text)
	local t = " " .. tostring(text):lower():gsub("[^%w%s]", " ") .. " "
	return t:find(" please ", 1, true) ~= nil
end

local function said()
	local M = PUD
	local last = GetInt("proxchat.said.last")
	if M.said == nil then M.said = last end
	if last < M.said then M.said = last end
	local useWords = not PudAgentOn()
	for n = math.max(M.said + 1, last - 15), last do
		local k = "proxchat.said." .. (n % 16) .. "."
		local p = GetInt(k .. "player")
		if GetString(k .. "agent") == "" and GetString(k .. "channel") == "" and IsPlayerValid(p) then
			local at = Vec(GetFloat(k .. "x"), GetFloat(k .. "y"), GetFloat(k .. "z"))
			local text = GetString(k .. "text")
			local mode = GetString(k .. "mode")
			local named = PudKeywordName(text, PUDDING_NAME)
			local reach = mode == "global" and (named and 1e9 or 0) or GetFloat(k .. "wordsRadius")
			if VecLength(VecSub(at, M.pos)) <= reach + 1 then
				M.lastSpeaker, M.lastSpeakerT = p, now()
				if useWords and named then
					PudHappened()
					M.look, M.lookUntil = p, now() + 3
					local cmds = keywords(text)
					local nice = PudAskedNicely(text)
					if #cmds > 0 and math.random() < (nice and 0.7 or 0.4) then   -- (a cat: she does it - sometimes)
						local f = cmds[1]
						if f.cmd == "action" then PudCommand("action", {name = f.arg}, p)
						else PudCommand(f.cmd, {who = "me"}, p) end
						PudSay(pick(FALLBACK.yes))
					elseif #cmds > 0 then
						PudSay(pick(nice and FALLBACK.noNice or FALLBACK.no))     -- (no.)
					else
						M.meowN = M.meowN + 1
						queueAct("meow")
						if math.random() < 0.5 then PudSay(pick(FALLBACK.called)) end
					end
				end
			end
		end
	end
	M.said = last
end

-- ---- each frame: the agent, the chat, shared.pudding for the clients
function PudServerTick(dt)
	local M = PUD
	if not (M and M.started) then return end
	local t = now()
	agentsTick()
	flushEvents()
	if M.stateDirty then
		M.stateDirty = false
		local st = PudStateText()
		if GetString(reg .. ".state") ~= st then SetString(reg .. ".state", st) end
	end
	toolsTick()
	laserTick()
	PudHitsTick(dt)
	noiseTick()
	boredTick()
	hurtTick(dt)
	said()
	judgeTick()
	calls()
	replies()
	if t - M.agentT >= CFG.agentEvery then
		M.agentT = t
		agentKeys()
	end
	if t - M.pubT >= CFG.publish then
		M.pubT = t
		M.n = (M.n or 0) + 1
		local dots = {}
		for _, D in ipairs(M.dots) do dots[#dots + 1] = {p = D.p, x = D.pos[1], y = D.pos[2], z = D.pos[3], nx = D.n[1], ny = D.n[2], nz = D.n[3]} end
		local look = (alive(M.look) and t < M.lookUntil) and M.look or 0
		local lookPos = nil
		if M.sound and t - M.sound.t < 2.5 then lookPos = {M.sound.pos[1], M.sound.pos[2], M.sound.pos[3]}
		elseif M.laser and M.laser.dot then local d = M.laser.dot.pos; lookPos = {d[1], d[2], d[3]}
		elseif M.lookOther and t < (M.lookOtherUntil or 0) then
			local o = otherNow(M.lookOther)
			if o then lookPos = {o.head[1], o.head[2], o.head[3]} end
		elseif M.activity and M.activity.kind == "knock" and M.activity.body and IsHandleValid(M.activity.body) then
			local c = bodyMid(M.activity.body); lookPos = {c[1], c[2], c[3]}
		end
		if t < M.lookAround then                                      -- ("where did the dot go?")
			local a = math.rad(M.yaw + 70 * math.sin(t * 2.2))
			lookPos = {M.pos[1] + math.sin(a) * 3, M.pos[2] + 0.4, M.pos[3] + math.cos(a) * 3}
		end
		shared.pudding = {n = M.n, x = M.pos[1], y = M.pos[2], z = M.pos[3], yaw = M.yaw, speed = M.speed, phase = M.phase,
			posture = M.posture, act = M.act and M.act.kind or "", actN = M.actN, actBase = M.act and M.act.base or M.posture,
			tail = (t < M.tailUntil or (M.mode == "follow")) and 1 or 0, puff = t < M.puffUntil, flick = t < M.flickUntil,
			talk = t < M.talkUntil, purr = t < M.purrUntil, crouch = M.crouch, scared = M.flee ~= nil, asleep = M.asleep,
			look = look, lookPos = lookPos, hp = M.hp, maxHp = CFG.hp, dead = M.dead, lives = M.lives,
			meowN = M.meowN, hissN = M.hissN, trillN = M.trillN, yowlN = M.yowlN, chatterN = M.chatterN, munchN = M.munchN,
			heartN = M.heartN, swatN = M.swatN, respawnN = M.respawnN, dots = dots, swim = M.swim == true,
			why = (M.why and t - M.whyT < 10) and M.why or standingWhy()}
	end
end
