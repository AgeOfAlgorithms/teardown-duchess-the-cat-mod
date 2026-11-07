-- Duchess the Cat: the cat drawn on every machine (client). Include cat_rig.lua and cat_anim.lua before it. No #version
-- line (included). Globals: PudClientInit(), PudClientTick(dt), PudClientRender(dt), PudClientDraw().
--
-- As Mochi's dog_view.lua: the server publishes the cat in shared.pudding (~20 times a second); each machine spawns its
-- own model (one body per part, collision filtered off, moved with SetBodyTransform from client.render) and poses it with
-- CatPose, blending each change of state. Here too: her sounds, Zz while she sleeps, hearts, the laser pointer's red dots,
-- the fish treats' models, E to pet her, the tools held in the hand.

PUD_VIEW = {spawned = false, parts = nil}

local V = PUD_VIEW
local PET_RANGE, PET_ANGLE = 2.4, 30          -- m, degrees off the view
local HINT_RANGE = 8
local BLEND = 0.22
local LAYER = 32

local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local function angDiff(a, b) local d = (b - a) % 360 if d > 180 then d = d - 360 end return d end

local snd = {}
local function load(name, n)
	local l = {}
	for i = 0, n - 1 do
		local f = "MOD/snd/" .. name .. i .. ".ogg"
		if HasFile(f) then l[#l + 1] = LoadSound(f) end
	end
	return l
end

function PudClientInit()
	snd.meow = load("meow", 4)
	snd.trill = load("trill", 2)
	snd.hiss = load("hiss", 2)
	snd.yowl = load("yowl", 2)
	snd.growl = load("growl", 1)
	snd.munch = load("munch", 2)
	snd.chatter = load("chatter", 1)
	snd.purr = HasFile("MOD/snd/purr0.ogg") and LoadLoop("MOD/snd/purr0.ogg") or nil
	snd.splash, snd.paddle = {}, {}                                   -- (the game's own water sounds)
	for i = 0, 3 do
		snd.splash[#snd.splash + 1] = LoadSound("water/splash-m" .. i .. ".ogg")
		snd.paddle[#snd.paddle + 1] = LoadSound("water/splash-s" .. i .. ".ogg")
	end
	V.dot = HasFile("MOD/img/dot.png") and LoadSprite("MOD/img/dot.png") or nil
	V.anim = {st = "stand", t = 0, base = "stand", phase = 0, speed = 0, tail = 0, talk = 0, time = 0}
	V.out = {}
	V.hearts = {}
	V.zs = {}
end

local function play(list, pos, vol, pitch)
	if not list or #list == 0 then return end
	PlaySound(list[math.random(#list)], pos, vol or 1, false, pitch or (0.95 + math.random() * 0.1))
end

-- ---- the model
local function spawnPart(p, scale, tag)
	tag = tag or "puddingcat"
	local ok, ents = pcall(Spawn, string.format(
		"<body dynamic='true' tags='%s'><vox tags='%s' file='%s' scale='%.3f'/></body>", tag, tag, p.file, scale or CAT_RIG.voxScale or 0.25),
		Transform(Vec(0, -400, 0)))
	if not ok or type(ents) ~= "table" then return nil end
	for _, h in ipairs(ents) do
		if GetEntityType(h) == "body" then
			local shapes = GetBodyShapes(h) or {}
			for _, s in ipairs(shapes) do SetShapeCollisionFilter(s, LAYER, 0) end
			return {name = p.name, body = h, shapes = shapes, centred = false}
		end
	end
	return nil
end

-- each part's voxel box centred on its body's origin (a fresh shape can read 0 in its spawn frame: waits)
local function centre(q)
	if q.centred then return true end
	for _, sh in ipairs(q.shapes) do
		if not IsHandleValid(sh) then return false end
		local x, y, z, vs = GetShapeSize(sh)
		if not x or x <= 0 or not vs or vs <= 0 then return false end
	end
	for _, sh in ipairs(q.shapes) do
		local t = GetShapeLocalTransform(sh)
		local x, y, z, vs = GetShapeSize(sh)
		local c = TransformToParentPoint(t, Vec(x * vs / 2, y * vs / 2, z * vs / 2))
		SetShapeLocalTransform(sh, Transform(VecSub(t.pos, c), t.rot))
	end
	q.centred = true
	return true
end

local function spawnModel()
	V.parts = {}
	for _, p in ipairs(CAT_RIG.parts) do
		local q = spawnPart(p)
		if q then V.parts[#V.parts + 1] = q end
	end
	V.spawned = true
end

local function deleteModel()
	for _, q in ipairs(V.parts or {}) do if IsHandleValid(q.body) then Delete(q.body) end end
	V.parts, V.spawned = nil, false
end

-- ---- the fish treats' detailed models on the server's invisible physics bodies (found by tag)
V.toys = {}
local function toyMiddle(h)
	local sh = (GetBodyShapes(h) or {})[1]
	if not sh then return nil end
	local wt = GetShapeWorldTransform(sh)
	local x, y, z, vs = GetShapeSize(sh)
	if not x or not vs then return nil end
	return TransformToParentPoint(wt, Vec(x * vs / 2, y * vs / 2, z * vs / 2)), wt.rot
end

local function renderToys()
	local now = GetTime()
	if now - (V.toyT or -1) > 0.2 or now < (V.toyT or 0) then
		V.toyT, V.toyList = now, FindBodies("puddingtreat", true) or {}
	end
	local seen, zero = {}, Vec(0, 0, 0)
	for _, h in ipairs(V.toyList) do
		if IsHandleValid(h) then
			seen[h] = true
			local q = V.toys[h]
			if q == nil then q = spawnPart({file = "MOD/vox/treat.vox", name = "toy"}, CAT_RIG.propScale or 0.25, "puddingtoy"); V.toys[h] = q or false end
			local c, rot = toyMiddle(h)
			if q and c and IsHandleValid(q.body) then
				centre(q)
				SetBodyTransform(q.body, Transform(c, rot))
				SetBodyVelocity(q.body, zero)
				SetBodyAngularVelocity(q.body, zero)
			end
		end
	end
	for h, q in pairs(V.toys) do
		if not seen[h] then
			if q and IsHandleValid(q.body) then Delete(q.body) end
			V.toys[h] = nil
		end
	end
end

-- ---- following the server's cat
local function readShared()
	local m = shared.pudding
	if type(m) ~= "table" or type(m.n) ~= "number" then return nil end
	return m
end

local function track(m, dt)
	local target = Vec(m.x, m.y, m.z)
	if not V.pos or VecLength(VecSub(target, V.pos)) > 4 then
		V.pos, V.yaw = target, m.yaw
	else
		local leaping = m.act == "leap"
		local k = 1 - math.exp(-dt * (leaping and 30 or 14))           -- (a leap follows the arc closely)
		V.pos = VecLerp(V.pos, target, k)
		V.yaw = (V.yaw + angDiff(V.yaw, m.yaw) * (1 - math.exp(-dt * 12))) % 360
	end
end

local ACT_SOUND = {meow = "meow", hiss = "hiss", chatter = "chatter", eat = "munch"}
local function state(m, now)
	if m.actN ~= V.actN then
		if V.actN ~= nil and m.act ~= "" then V.actT0 = now end
		if V.actN == nil and m.act ~= "" then V.actT0 = now - 0.2 end
		V.actN = m.actN
		V.newAct = m.act
	end
	if m.act ~= "" and V.actT0 then return m.act, now - V.actT0, m.actBase end
	if m.swim then return "swim", 0, "stand" end
	if m.speed > 0.2 then return "walk", 0, "stand" end
	return m.posture, 0, m.posture
end

local keep, mixed = {}, {}
local function ease(cur, want, rate, dt) return (cur or 0) + (want - (cur or 0)) * (1 - math.exp(-dt * rate)) end

-- water: a splash as she falls in (and as she leaps out), white water round her neck while she paddles
local function splash(pos, n, up)
	ParticleReset()
	ParticleType("plain")
	ParticleColor(0.85, 0.9, 0.95)
	ParticleRadius(0.05, 0.02)
	ParticleAlpha(0.8, 0)
	ParticleGravity(-9)
	ParticleDrag(0.3)
	for _ = 1, n do
		local a = math.random() * 2 * math.pi
		local s = 0.3 + math.random() * 0.9
		SpawnParticle(pos, Vec(math.sin(a) * s, up * (0.5 + math.random()), math.cos(a) * s), 0.5 + math.random() * 0.4)
	end
end

local function waterFx(m, now)
	local swim = m.swim == true
	if swim ~= (V.swim == true) and V.pos then
		local p = VecAdd(V.pos, Vec(0, 0.32, 0))
		pcall(splash, p, swim and 26 or 14, swim and 2.2 or 1.4)
		play(snd.splash, p, swim and 0.9 or 0.6)
	end
	V.swim = swim
	if not swim or not V.pos or now < (V.paddleT or 0) then return end
	V.paddleT = now + 0.35 + math.random() * 0.25
	local f = Vec(math.sin(math.rad(V.yaw or 0)), 0, math.cos(math.rad(V.yaw or 0)))
	local p = VecAdd(V.pos, VecAdd(VecScale(f, 0.22), Vec(0, 0.32, 0)))
	pcall(splash, p, m.speed > 0.2 and 4 or 2, 0.6)
	if math.random() < 0.5 then play(snd.paddle, p, 0.25) end
end

function PudClientRender(dt)
	local m = readShared()
	if not m then
		if V.spawned then deleteModel() end
		if V.purrOn then V.purrOn = false end
		return
	end
	if not V.anim then PudClientInit() end
	if not V.spawned then spawnModel() end
	renderToys()
	local now = GetTime()
	local lastPos = V.pos and VecCopy(V.pos)
	track(m, dt)
	waterFx(m, now)
	local a = V.anim
	local st, t, base = state(m, now)
	if st ~= a.st or base ~= a.base then
		if V.lastP then CatPoseCopy(V.lastP, keep); V.blendT0 = now end
	end
	a.st, a.t, a.base = st, t, base
	a.speed = m.speed
	if lastPos and st == "walk" then
		local d = VecLength(Vec(V.pos[1] - lastPos[1], 0, V.pos[3] - lastPos[3]))
		if d < 1 then a.phase = (a.phase + d / CatStride(math.max(0.3, m.speed)) * 2 * math.pi) % (2 * math.pi) end
	end
	a.tail = ease(a.tail, m.tail or 0, 4, dt)
	a.puff = ease(a.puff, m.puff and 1 or 0, 10, dt)
	a.flick = ease(a.flick, m.flick and 1 or 0, 5, dt)
	a.talk = ease(a.talk, m.talk and 1 or 0, 10, dt)
	a.purr = ease(a.purr, m.purr and 1 or 0, 3, dt)
	a.crouch = ease(a.crouch, m.crouch and 1 or 0, 6, dt)
	a.scared = ease(a.scared, m.scared and 1 or 0, 8, dt)
	a.time = now
	-- the head turns toward whoever / whatever she looks at
	local ly, lp = 0, 0
	local target = nil
	if type(m.lookPos) == "table" and m.lookPos[3] then target = Vec(m.lookPos[1], m.lookPos[2], m.lookPos[3])
	elseif m.look and m.look ~= 0 and IsPlayerValid(m.look) then target = GetPlayerEyeTransform(m.look).pos end
	if target and not m.asleep then
		local head = VecAdd(V.pos, Vec(0, 0.36, 0))
		local d = VecSub(target, head)
		local h = math.sqrt(d[1] * d[1] + d[3] * d[3])
		ly = angDiff(V.yaw, math.deg(math.atan2(d[1], d[3])))
		lp = math.deg(math.atan2(d[2], math.max(0.2, h)))
		if math.abs(ly) > 110 then ly, lp = 0, 0 end
	end
	V.ly = ease(V.ly, ly, 6, dt)
	V.lp = ease(V.lp, lp, 6, dt)
	a.lookYaw, a.lookPitch = V.ly, V.lp
	local P = CatDescribe(a)
	if V.blendT0 and now - V.blendT0 < BLEND then
		local s = (now - V.blendT0) / BLEND
		s = s * s * (3 - 2 * s)
		CatPoseCopy(keep, mixed)
		CatPoseMix(mixed, P, s)
		P = mixed
	end
	V.lastP = V.lastP or {}
	CatPoseCopy(P, V.lastP)
	CatSolve(P, V.out)
	local root = Transform(V.pos, QuatEuler(0, V.yaw, 0))
	local zero = Vec(0, 0, 0)
	for _, q in ipairs(V.parts) do
		centre(q)
		local tr = V.out[q.name]
		if tr and IsHandleValid(q.body) then
			SetBodyTransform(q.body, TransformToParentTransform(root, tr))
			SetBodyVelocity(q.body, zero)
			SetBodyAngularVelocity(q.body, zero)
		end
	end
	local ht = CAT_RIG.headTop
	if not V.headC then
		for _, p in ipairs(CAT_RIG.parts) do if p.name == "head" then V.headC = Vec(p.center[1], p.center[2], p.center[3]) end end
	end
	V.headTop = (V.out.head and V.headC)                               -- (over her head wherever it is: curled, loafing)
		and TransformToParentPoint(root, TransformToParentPoint(V.out.head, VecSub(Vec(ht[1], ht[2], ht[3]), V.headC)))
		or TransformToParentPoint(root, Vec(ht[1], ht[2], ht[3]))
	V.mid = TransformToParentPoint(root, Vec(0, 0.22, 0.05))
	local mouth = V.out.__mouth and TransformToParentPoint(root, V.out.__mouth) or V.headTop
	-- sounds (each counter a new one) and hearts
	if V.newAct then
		local s = ACT_SOUND[V.newAct]
		if s then play(snd[s], mouth, s == "munch" and 0.6 or 0.8) end
		V.newAct = nil
	end
	local function was(key) local changed = V[key] ~= nil and m[key] ~= V[key]; V[key] = m[key]; return changed end
	if was("yowlN") then play(#snd.yowl > 0 and snd.yowl or snd.hiss, mouth, 1.0) end
	if was("trillN") then play(snd.trill, mouth, 0.7) end
	if was("heartN") then
		for i = 1, 2 do V.hearts[#V.hearts + 1] = {t0 = now + (i - 1) * 0.25, x = (math.random() - 0.5) * 0.25, z = (math.random() - 0.5) * 0.25} end
	end
	if was("respawnN") then play(snd.meow, mouth, 0.8) end
	V.purrOn = m.purr and not m.dead
	if V.purrOn and snd.purr then PlayLoop(snd.purr, V.mid, 0.55) end
	if m.dead and not V.dead then play(snd.yowl, mouth, 0.9, 0.85) end
	V.dead = m.dead
	-- asleep: a Z rises now and then
	if m.asleep and now >= (V.zT or 0) then
		V.zT = now + 1.1
		V.zs[#V.zs + 1] = {t0 = now, x = (math.random() - 0.5) * 0.1}
	end
end

-- ---- the laser pointer's dots (client.tick: DrawSprite and lights are drawn from tick). My own dot from my own aim
-- each frame (no lag); everyone else's from shared.pudding.dots
local function laserDot(pos, n)
	if not V.dot then return end
	local nn = VecNormalize(Vec(n[1], n[2], n[3]))
	local p = VecAdd(pos, VecScale(nn, 0.01))
	local rot = QuatLookAt(p, VecAdd(p, nn))
	local flick = 0.9 + math.random() * 0.1
	DrawSprite(V.dot, Transform(p, rot), 0.045, 0.045, 1, 0.15, 0.1, flick, true, true)
	DrawSprite(V.dot, Transform(p, rot), 0.14, 0.14, 1, 0.05, 0.05, 0.35 * flick, true, true)
	PointLight(VecAdd(pos, VecScale(nn, 0.04)), 1, 0.08, 0.05, 0.15)
end

local function drawDots(me, m)
	local mine = nil
	local okT, tool = pcall(GetPlayerTool, me)
	if okT and tool == PUDDING_LASER_TOOL and IsPlayerValid(me) and GetPlayerHealth(me) > 0 and InputDown("usetool")
		and not GetBool("proxchat.typing." .. me) and GetPlayerVehicle(me) == 0 then
		local eye = GetPlayerEyeTransform(me)
		local dir = TransformToParentVec(eye, Vec(0, 0, -1))
		QueryRejectPlayer(me)
		QueryCollisionMask(255 - LAYER)
		local hit, d, n = QueryRaycast(eye.pos, dir, PUDDING_CFG and PUDDING_CFG.laserRange or 40)
		if hit then mine = true; laserDot(VecAdd(eye.pos, VecScale(dir, d)), n or Vec(0, 1, 0)) end
	end
	for _, D in ipairs(m and m.dots or {}) do
		if not (mine and D.p == me) then laserDot(Vec(D.x, D.y, D.z), Vec(D.nx, D.ny, D.nz)) end
	end
end

-- the fish treats / the laser pointer in the hand: placed by the script every frame (Mochi's lesson: the prefab's
-- eye_space locations alone did nothing), low at the right side in third person
local function holdItem(me)
	local okT, tool = pcall(GetPlayerTool, me)
	if not okT or (tool ~= PUDDING_TREAT_TOOL and tool ~= PUDDING_LASER_TOOL) then return end
	local t
	if GetBool("game.thirdperson") then
		local okC, c = pcall(GetPlayerCrouch, me)
		t = Transform(Vec(0.3, -0.55 + (okC and c or 0) * 0.2, -0.2), QuatEuler(0, 5, 0))
		local okG, grip = pcall(GetToolLocationLocalTransform, "tp_action_rh", me)
		SetToolHandPoseLocalTransform(okG and grip or Transform(Vec(0, 0, -0.025), QuatEuler(0, 90, 0)), nil)
	else
		t = tool == PUDDING_LASER_TOOL and Transform(Vec(0.25, -0.3, -0.45), QuatEuler(3, 2, 0))
			or Transform(Vec(0.28, -0.42, -0.45), QuatEuler(5, 10, 0))
	end
	SetToolTransform(t, 0.6)
end

local function typing(me) return GetBool("proxchat.typing." .. me) end

local function canPet(me)
	if not (V.mid and IsPlayerValid(me) and GetPlayerHealth(me) > 0) or V.dead then return false end
	if GetPlayerVehicle(me) ~= 0 then return false end
	local cam = GetPlayerCameraTransform(me)
	local to = VecSub(V.mid, cam.pos)
	local feet = GetPlayerTransform(me).pos
	if VecLength(Vec(V.mid[1] - feet[1], 0, V.mid[3] - feet[3])) > PET_RANGE then return false end
	if math.abs(V.mid[2] - feet[2]) > 2.2 then return false end
	local f = TransformToParentVec(cam, Vec(0, 0, -1))
	return VecDot(VecNormalize(to), f) > math.cos(math.rad(PET_ANGLE))
end

function PudClientTick(dt)
	local me = GetLocalPlayer()
	local m = readShared()
	if not m then return end                                       -- (no cat from this copy: another copy has her)
	holdItem(me)
	drawDots(me, m)
	if typing(me) then V.petOk = false; return end
	V.petOk = canPet(me)
	if V.petOk and InputPressed("interact") then ServerCall("server.pudding_pet", me) end
end

local function key(label, text, x, y)
	UiPush()
	UiTranslate(x, y)
	UiAlign("center middle")
	UiFont("bold.ttf", 22)
	local w = UiGetTextSize(text)
	UiColor(0, 0, 0, 0.55)
	UiImageBox("ui/common/box-solid-10.png", w + 64, 38, 10, 10)
	UiTranslate(-w / 2 - 6, 0)
	UiColor(1, 1, 1, 0.95)
	UiImageBox("ui/common/box-outline-6.png", 26, 26, 6, 6)
	UiFont("bold.ttf", 18)
	UiText(label)
	UiTranslate(w / 2 + 22, 0)
	UiFont("bold.ttf", 22)
	UiText(text)
	UiPop()
end

function PudClientDraw()
	local m = readShared()
	if not m or not V.headTop then return end
	local me = GetLocalPlayer()
	local now = GetTime()
	-- hearts rise from her head
	for i = #V.hearts, 1, -1 do
		local h = V.hearts[i]
		local age = now - h.t0
		if age > 1.6 then table.remove(V.hearts, i)
		elseif age >= 0 then
			local x, y, dist = UiWorldToPixel(VecAdd(V.headTop, Vec(h.x, 0.08 + age * 0.4, h.z)))
			if dist and dist > 0 and dist < 40 then
				UiPush()
				UiTranslate(x, y)
				UiAlign("center middle")
				UiScale(clamp(1.4 / dist, 0.12, 1.0) * (0.7 + 0.3 * math.min(1, age * 4)))
				UiColor(1, 1, 1, 1 - math.max(0, age - 1.0) / 0.6)
				UiImage("MOD/img/heart.png")
				UiPop()
			end
		end
	end
	-- Zz while she sleeps
	for i = #V.zs, 1, -1 do
		local z = V.zs[i]
		local age = now - z.t0
		if age > 2.4 then table.remove(V.zs, i)
		else
			local x, y, dist = UiWorldToPixel(VecAdd(V.headTop, Vec(z.x + age * 0.06, 0.05 + age * 0.22, 0)))
			if dist and dist > 0 and dist < 30 then
				UiPush()
				UiTranslate(x, y)
				UiAlign("center middle")
				UiFont("bold.ttf", math.floor(clamp(70 / dist, 12, 48) * (0.6 + age * 0.25)))
				UiColor(0.85, 0.9, 1, 0.85 * (1 - age / 2.4))
				UiText("z")
				UiPop()
			end
		end
	end
	if PUDDING_NO_HUD then return end
	if not m.dead and m.hp and m.maxHp and m.hp < m.maxHp - 0.5 then
		local x, y, dist = UiWorldToPixel(VecAdd(V.headTop, Vec(0, 0.28, 0)))
		if dist and dist > 0 and dist < 25 then
			local f = clamp(m.hp / m.maxHp, 0, 1)
			local w, h = 80 * clamp(4 / dist, 0.5, 1.4), 8 * clamp(4 / dist, 0.6, 1.3)
			UiPush()
			UiTranslate(x - w / 2, y - h / 2)
			UiColor(0, 0, 0, 0.6)
			UiRect(w + 4, h + 4)
			UiTranslate(2, 2)
			UiColor(1 - f, 0.25 + 0.6 * f, 0.2, 0.95)
			UiRect(w * f, h)
			UiPop()
		end
	end
	if typing(me) or not IsPlayerValid(me) or GetPlayerHealth(me) <= 0 then return end
	if V.petOk then
		local x, y, dist = UiWorldToPixel(VecAdd(V.headTop, Vec(0, 0.22, 0)))
		if dist and dist > 0 then key("E", "Pet " .. PUDDING_NAME, x, y) end
	end
	local feet = GetPlayerTransform(me).pos
	local okH, isHost = pcall(IsPlayerHost, me)
	if okH and isHost and type(m.why) == "string" and m.why ~= "" and VecLength(VecSub(V.mid, feet)) < 15 then
		UiPush()
		UiTranslate(UiCenter(), UiHeight() - 120)
		UiAlign("center middle")
		UiFont("bold.ttf", 18)
		UiColor(1, 0.65, 0.3, 0.9)
		UiText(m.why)
		UiPop()
	end
	if VecLength(VecSub(V.mid, feet)) < HINT_RANGE then
		UiPush()
		UiTranslate(UiCenter(), UiHeight() - 34)
		UiAlign("center middle")
		UiFont("bold.ttf", 18)
		UiColor(1, 1, 1, 0.75)
		UiText("Fish treats and the laser pointer: in your tools")
		UiPop()
	end
end
