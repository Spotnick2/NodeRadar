-- The secret round (/fp steps nr secret, SecretRound.lua): what a hover on the minimap reads
-- when its text is secret. Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")
rawset(_G, "Screenshot", function() end)
rawset(_G, "EnumerateFrames", function() return nil end)

local callbacks = {}
rawset(_G, "EventRegistry", { RegisterCallback = function(_, name, fn) callbacks[name] = fn end })

-- The override-binding globals (the kit has the handle methods only).
rawset(_G, "SetOverrideBindingClick", function(owner, priority, key, name, button)
    WoW.overrideBindings[key] = { owner = owner, name = name, button = button, priority = priority }
end)
rawset(_G, "ClearOverrideBindings", function(owner)
    for k, b in pairs(WoW.overrideBindings) do if b.owner == owner then WoW.overrideBindings[k] = nil end end
end)

-- What the client answers, as the test sets it.
local SECRET_NAME = "SECRETNODENAME"
local secretText = WoW.MarkSecret(SECRET_NAME, "leftText")
local data
C_TooltipInfo.GetMinimapMouseover = function() return data end
local function hoverData(text)
    return { type = 21, id = 0, lines = { { leftText = text, type = 0, leftColor = { r = 1, g = 0.5, b = 0.25, a = 1 } } } }
end
local leftText = secretText
rawset(_G, "GameTooltipTextLeft1", {
    GetText = function() return leftText end,
    GetTextColor = function() return 1, 1, 1, 1 end,
    HasSecretValues = function() return true end,
    HasAnySecretAspect = function() return true end,
})
rawset(_G, "GameTooltipTextRight1", { GetText = function() return nil end })
GameTooltip.NumLines = function() return 1 end
GameTooltip._owner = Minimap
rawset(_G, "canaccesssecrets", function() return false end)
rawset(_G, "hasanysecretvalues", function(t) return true end)
rawset(_G, "C_Secrets", { HasSecretRestrictions = function() return true end })

local NR = loadAddon()
local FP = loadForeverProbe()
local ns = loadProbe()
local fp = function(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local X = ns._secret

NodeRadarDB.moveScan = true
WoW.combat = false
WoW.focus = Minimap
WoW.advance(6)                       -- past the driver's grace after load

local function d() return NodeRadarProbeDB.secret end
local function at() local _, rec = FP.Steps.Active(); return rec and rec.at end
local function bound() local n = 0 for _ in pairs(WoW.overrideBindings) do n = n + 1 end return n end
local function lines() return d() and d().lines or {} end
local function has(list, p) for _, l in ipairs(list) do if l:find(p, 1, true) then return true end end return false end
local function result(i) return FP.db.steps.records["NodeRadarProbe/secret"].results[i] end
-- tests/wow_stubs.lua's WoW.click always sends LeftButton (its check buttons), so a key click is
-- driven here with the mouse button the binding names, as the client sends it.
local function press(key, quick, down)
    if not quick then WoW.advance(0.5) end
    local b = WoW.overrideBindings[key]
    if not b then return false end
    local target = rawget(_G, b.name)
    if down == nil then down = true end
    target._scripts.OnClick(target, b.button or "LeftButton", down)
    return true
end

-- The field walk: a secret leftText is marked, plain values kept, colours one level deeper.
local out = {}
X.walk(hoverData(secretText), "data", 1, out)
check(has(out, "data.lines[1].leftText=string:<secret>"), "the walk marks a secret leftText: " .. table.concat(out, " | "))
check(has(out, "data.lines[1].type=number:0") and has(out, "data.type=number:21"), "plain numbers keep their value")
check(has(out, "data.lines[1].leftColor.g=number:0.5"), "a colour table is walked one level deeper")
local out2 = {}
X.walk(hoverData("Peacebloom"), "data", 1, out2)
check(has(out2, 'data.lines[1].leftText=string:"Peacebloom"'), "a plain string keeps its value")
for _, l in ipairs(out) do check(not l:find(SECRET_NAME, 1, true), "the walk never carries the secret's text") end

-- Start: the setup pauses the scan, binds the keys.
data = hoverData(secretText)
fp("steps nr secret")
WoW.advance(1.1)
check(at() == 1, "the round starts at the setup step")
check(bound() == 0, "no key is bound before Start")
FP.Steps.Run()
WoW.advance(0.2)
check(NodeRadarDB.moveScan == false and d().scanOwed == true, "Start turns NodeRadar's scan off and owes it back")
check(bound() == 6 and WoW.overrideBindings.F9.name == "NodeRadarProbeSecretKeys", "Start binds the answer keys")
check(d().build ~= nil and d().postRegistered == true, "the build and the post-call registration are recorded")
check(at() == 2, "the real-hover step is current")

-- The real hover: samples every frame the top focus is Minimap, deduped by signature.
WoW.advance(1.1)
local b = d().steps["node-hover"]
check(b and b.samples >= 10, "the hover step samples each frame (" .. tostring(b and b.samples) .. ")")
check(#b.shapes == 1 and b.shapes[1].count == b.samples, "identical samples dedupe into one shape with a count (" .. #b.shapes .. " shapes)")
check(b.tally["data.lines[1].leftText"].secret == b.samples, "every sample's leftText counted secret")
check(has(b.shapes[1].facts, "gtt.left1=string:<secret>") and has(b.shapes[1].facts, "gtt.left1.HasSecretValues=boolean:true"), "GameTooltip's text and its secret flag are recorded")
check(has(b.shapes[1].facts, "C_Secrets.HasSecretRestrictions=boolean:true") and has(b.shapes[1].facts, "canaccesssecrets=boolean:false")
    and has(b.shapes[1].facts, "hasanysecretvalues(data)=boolean:true"), "the global secrecy state is recorded")
check(has(b.shapes[1].facts, "GameTooltip:GetOwner==Minimap=Minimap") and has(b.shapes[1].facts, "GameTooltip:GetTooltipData=absent"), "the owner, and an absent method as 'absent'")

-- A different shape is a second shape; a plain text reads plain.
data = hoverData("Peacebloom")
WoW.advance(0.5)
check(#b.shapes == 2 and b.tally["data.lines[1].leftText"].plain > 0, "a changed read is a new shape")
-- Past the cap, shapes are dropped and counted.
for i = 1, 30 do X.addShape(b, "shapes", { "distinct=" .. i }) end
check(#b.shapes == X.MAX_SHAPES and (b.shapesDropped or 0) > 0, "shapes stop at the cap and the rest are counted (" .. #b.shapes .. ", dropped " .. tostring(b.shapesDropped) .. ")")
data = hoverData(secretText)
-- A per-frame id changing between otherwise identical samples is one shape; a real change is another.
local vb = { shapes = {}, postShapes = {}, shapesDropped = 0, postShapesDropped = 0 }
for i = 1, 30 do X.addShape(vb, "shapes", { "data.dataInstanceID=number:" .. (1000 + i), "data.type=number:21" }) end
check(#vb.shapes == 1 and vb.shapes[1].count == 30 and (vb.shapesDropped or 0) == 0, "a changing dataInstanceID dedupes into one shape (" .. #vb.shapes .. ")")
check(vb.shapes[1].idsFirst["data.dataInstanceID"] == "number:1001" and vb.shapes[1].idsLast["data.dataInstanceID"] == "number:1030", "the first and last id are kept in the shape")
X.addShape(vb, "shapes", { "data.dataInstanceID=number:2000", "data.type=number:99" })
check(#vb.shapes == 2, "a real change next to a volatile id is a new shape")
X.addShape(vb, "postShapes", { "post.data.dataInstanceID=number:1", "x=1" })
X.addShape(vb, "postShapes", { "post.data.dataInstanceID=number:2", "x=1" })
check(#vb.postShapes == 1 and vb.postShapes[1].count == 2, "the post-call shapes ignore the volatile id too")

-- The post-call: fires on a MinimapMouseover build, records the data it receives.
WoW.buildMinimapTooltip(GameTooltip)
check(b.postFired == 1 and #b.postShapes == 1, "the post-call fired once and recorded a shape")
check(has(b.postShapes[1].facts, "post.data.lines[1].leftText=string:<secret>"), "the post-call's walk marks the secret leftText")
check(b.tally["post.data.lines[1].leftText"].secret == 1, "and tallies it")

-- Off the map: counted, not sampled.
WoW.focus = nil
local before = b.samples
WoW.advance(0.3)
check(b.samples == before and b.offMap > 0, "off the map nothing is sampled")
WoW.focus = Minimap

-- The step finishes by itself after the hold; then the keys answer.
WoW.advance(4)
check(at() == 3, "the hover step completes after 3 s on the map (step " .. tostring(at()) .. ")")
check(press("F9") and at() == 4 and result(3).status == "yes", "F9 answers yes on a question")
press("F9", true)   -- the key's other edge, at once
check(at() == 4, "a second click within the debounce is ignored")
-- A held key: the release, long after the debounce, answers nothing (one edge per press).
check(press("F9", false, false) and at() == 4, "a key's release edge, past the debounce, answers nothing")
check(press("NUMPAD2") and at() == 5 and result(4).status == "no", "Numpad 2 answers no")
check(press("F11") and at() == 6 and result(5).status == "skipped", "F11 skips the control hover")
check(press("F11") and at() == 7 and result(6).status == "unsure", "F11 answers not sure")
check(bound() == 6, "the keys stay bound until the finish")

-- Never a secret in the saved table.
local function scan(t, path, seen)
    seen = seen or {}
    if seen[t] then return end
    seen[t] = true
    for k, v in pairs(t) do
        check(not issecretvalue(k) and type(k) ~= "userdata", "no secret key at " .. path)
        check(not issecretvalue(v) and type(v) ~= "userdata", "no secret value at " .. path .. "." .. tostring(k))
        if type(v) == "string" then check(not v:find(SECRET_NAME, 1, true), "the secret's text is nowhere in the saved table: " .. path .. "." .. tostring(k)) end
        if type(v) == "table" then scan(v, path .. "." .. tostring(k), seen) end
    end
end
scan(NodeRadarProbeDB.secret, "secret")

-- Finish: keys cleared, scan back, summary in the log.
press("F9")
check(bound() == 0, "Finish clears every key itself, before the driver would")
check(NodeRadarDB.moveScan == true and not d().scanOwed, "Finish puts NodeRadar's scan back")
check(has(lines(), "summary node-hover"), "the summary lines are in the saved log")

-- A Stop clears the keys and puts the scan back.
fp("steps nr secret")
WoW.advance(1.1)
FP.Steps.Run()
WoW.advance(0.2)
check(bound() == 6 and NodeRadarDB.moveScan == false, "a second run binds and pauses again")
FP.Steps.Stop("test")
WoW.advance(0.3)
check(bound() == 0 and NodeRadarDB.moveScan == true, "a Stop clears the keys and restores the scan")

-- A Stop in combat leaves the keys pending until combat ends.
fp("steps nr secret")
WoW.advance(1.1)
FP.Steps.Run()
WoW.advance(0.2)
WoW.combat = true
FP.Steps.Stop("test")
WoW.advance(0.5)
check(bound() == 6, "no binding is touched in combat")
WoW.combat = false
WoW.advance(0.5)
check(bound() == 0 and NodeRadarDB.moveScan == true, "the keys are cleared once combat ends")

-- Start refuses in combat.
WoW.combat = true
fp("steps nr secret")
WoW.advance(1.1)
FP.Steps.Run()
WoW.advance(0.2)
check(bound() == 0 and NodeRadarDB.moveScan == true, "Start in combat binds nothing and leaves the scan alone")
WoW.combat = false
FP.Steps.Stop("test")

done("test_probe_secret")
