-- NodeRadar: the background frame rate while the scan runs (#104, `scanFps`, per character, off).
--
-- WoW caps a window without keyboard focus at maxFPSBk (30 by default). At 30 fps a scan look fits
-- one locate window in its 250 ms, against five to seven in the foreground, so a node can take a
-- minute to get its icon (measured on 70888; the reads themselves work in the background). With
-- the option on, while a search is under way on this character (Locate.Busy, and HOLD seconds
-- after, so back-to-back searches don't flap it), maxFPSBk is raised to 60, the player's value
-- saved first and put back after. A presence look fits in one look: 30 fps does for it.
--
-- The rules (Codex's review of the plan, issue #104):
-- - claimed only from a readable value between 0 and 60 with the background cap on (useMaxFPSBk):
--   an uncapped or unlimited one, or one already at 60 or more, is the player's and left alone;
-- - "a search under way": the option on, the scan on (MS.On), no lasting reason it can't
--   (MS.Trouble), and search windows open (the owner, 2026-11-12: not the whole time it's on);
-- - put back only while still ours; an unreadable value or a put-back that didn't read back keeps
--   the claim (NodeRadarDB.fpsClaim = { old, ours }) and is tried again, the scan off or not;
-- - any other value seen while claimed is the player's: the claim dropped, their value kept, and
--   no claim again on this character until the option is turned off and on (scanFpsCancelled);
-- - at logout ours put back, the claim kept (a read-back doesn't prove the file got it); at login
--   the old value means that stuck (claimed again only if it runs), ours means it didn't;
-- - nothing written in combat; read again on every CVAR_UPDATE and once a second.
-- Two clients sharing one Config.wtf can't be coordinated: each owns only what it set.

local NR = NodeRadar
local API = NR.API
local FS = {}
NR.ScanFps = FS

FS.CVAR = "maxFPSBk"
FS.CAP = "useMaxFPSBk"
FS.TARGET = "60"
FS.EVERY = 1             -- seconds between checks
FS.HOLD = 5              -- seconds it stays raised after a search ends

local writing = false     -- inside our own SetCVar: its CVAR_UPDATE is ours
local ready = false       -- from the first PLAYER_ENTERING_WORLD
local loginRead = false   -- the first check after login: the old value may be our put-back that stuck
local lastSearch = -math.huge -- when a search was last seen under way

local function get(name)
    if not (C_CVar and C_CVar.GetCVar) then return nil end
    local ok, v = pcall(C_CVar.GetCVar, name)
    if not ok or v == nil or API.IsSecret(v) then return nil end
    return tostring(v)
end
local function num(v) return v ~= nil and tonumber(v) or nil end
local function same(a, b) return a == b or (num(a) ~= nil and num(a) == num(b)) end
local function put(value)
    if not (C_CVar and C_CVar.SetCVar) then return false end
    writing = true
    pcall(C_CVar.SetCVar, FS.CVAR, value)
    writing = false
    return same(get(FS.CVAR), value)
end

function FS.On() return NR.charDb ~= nil and NR.charDb.scanFps == true end

-- Whether a search is under way on this character now, or ended within HOLD seconds (a lasting
-- refusal is no scanning).
function FS.Active(now)
    if not FS.On() or NR.charDb.scanFpsCancelled then return false end
    local MS = NR.MoveScan
    if not (MS and MS.On and MS.On()) then return false end
    local ok, trouble = pcall(MS.Trouble, now)
    if not ok or trouble ~= nil then return false end
    local okB, busy = pcall(function() return NR.Locate and NR.Locate.Busy() end)
    if okB and busy then lastSearch = now end
    return now - lastSearch <= FS.HOLD
end

-- A value we may raise: readable, the cap on, above 0 and below the target.
local function raisable(cur)
    local n = num(cur)
    if not n or n <= 0 or n >= num(FS.TARGET) then return false end
    local cap = get(FS.CAP)
    return cap == nil or not same(cap, "0")
end

-- One check: the claim reconciled, then claimed or put back.
function FS.Update(now)
    if not ready or not NR.db or not NR.charDb then return end
    if InCombatLockdown() then return end
    now = now or GetTime()
    local fromOld = loginRead
    loginRead = false
    local c = NR.db.fpsClaim
    local cur = get(FS.CVAR)
    if c then
        if cur == nil then return end                    -- unreadable: kept, tried again
        if same(cur, c.ours) then
            if not FS.Active(now) then
                if put(c.old) then
                    NR.db.fpsClaim = nil
                    API.Trace(("scan fps: put back %s -> %s"):format(tostring(c.ours), tostring(c.old)))
                else
                    API.Trace("scan fps: the put-back didn't read back; kept, tried again")
                end
            end
        elseif fromOld and same(cur, c.old) then
            -- Login: our logout put-back stuck. Claimed again only if the scan runs.
            NR.db.fpsClaim = nil
            if FS.Active(now) and raisable(cur) and put(FS.TARGET) then
                NR.db.fpsClaim = { old = cur, ours = FS.TARGET }
                API.Trace(("scan fps: login, claimed again %s -> %s"):format(cur, FS.TARGET))
            end
        else
            -- Someone else's value: theirs kept, no claim again until the option is off and on.
            NR.db.fpsClaim = nil
            NR.charDb.scanFpsCancelled = true
            API.Trace(("scan fps: %s changed to %s by someone else; left, no claim until the option is off and on")
                :format(FS.CVAR, cur))
        end
        return
    end
    if FS.Active(now) and raisable(cur) then
        if put(FS.TARGET) then
            NR.db.fpsClaim = { old = cur, ours = FS.TARGET }
            API.Trace(("scan fps: claimed %s -> %s"):format(cur, FS.TARGET))
        else
            API.Trace(("scan fps: the raise to %s didn't read back (%s)"):format(FS.TARGET, tostring(get(FS.CVAR))))
        end
    end
end

-- The option turned on or off (Options): a fresh start for this character, then a check.
function FS.Toggle()
    if NR.charDb then NR.charDb.scanFpsCancelled = nil end
    FS.Update(GetTime())
end

-- At logout, best effort: ours put back, the claim kept for the next login's check.
local function atLogout()
    local c = NR.db and NR.db.fpsClaim
    if not c or InCombatLockdown() then return end
    if same(get(FS.CVAR), c.ours) then
        local ok = put(c.old)
        API.Trace(("scan fps: logout, put back %s -> %s (%s); the claim kept"):format(tostring(c.ours), tostring(c.old),
            ok and "read back" or "not read back"))
    end
end

local frame = CreateFrame("Frame")
local since = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    since = since + elapsed
    if since < FS.EVERY then return end
    since = 0
    FS.Update(GetTime())
end)
API.RegisterEvents(frame, { "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "CVAR_UPDATE", "PLAYER_REGEN_ENABLED" })
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        if not ready then ready, loginRead = true, true end
        FS.Update(GetTime())
    elseif event == "PLAYER_LOGOUT" then
        atLogout()
    elseif event == "CVAR_UPDATE" then
        if not writing then FS.Update(GetTime()) end
    else
        FS.Update(GetTime())
    end
end)

FS._test = {
    ready = function() return ready end,
    reset = function() writing, ready, loginRead, since, lastSearch = false, false, false, 0, -math.huge end,
}
