local ADDON, ns = ...

-- Threat lab: how much threat each of your abilities really makes, measured from the changes in
-- your threat on the enemies you fight (UnitDetailedThreatSituation's raw threat). Two methods
-- share the same reading and log:
--   1. clean samples (below): one ability alone between two updates; exact, but rare once
--      auto-attack is on, and a warrior needs auto-attack for rage;
--   2. the fit ("Method 2" further down): every window from normal play, solved together by
--      least squares into threat per point of damage and each ability's bonus threat.
--
-- How a change is attributed. Your threat on every enemy we can read (your target and each
-- nameplate) is read as it changes. Everything you do goes into a short log: casts
-- (UNIT_SPELLCAST_SUCCEEDED), swings (PLAYER_SWING), damage and misses on your target and on you
-- (UNIT_COMBAT), rage gained, target and stance changes. When your threat on an enemy changes,
-- the change is put down to the one action of yours since its previous change, but only when
-- that's clean:
--   * exactly one action: one ability, with no plain weapon swing (an on-next-swing ability such
--     as Heroic Strike or Cleave replaces the swing it lands on, so that swing belongs to it);
--   * nothing else that makes threat: rage from Bloodrage or talents, healing (solo), a DoT of
--     yours ticking (Rend, Deep Wounds), extra damage on the target (procs, someone else);
--   * the same target throughout, no stance change, and the action recent enough (threat
--     updates from the server lag a little; the usual lag is learned as you go).
-- Anything else is discarded but counted, by reason. An action that makes no change at all is
-- "settled" after a while; if it was a miss, dodge or parry on your target, that's recorded as
-- a sample of 0 (misses normally make no threat, which is worth seeing).
--
-- Where the game hides the numbers (dungeons: secret values), nothing is read or compared: the
-- lab only says so.

local Lab = {}
ns.Lab = Lab

local issecret, Safe = FrogLib.issecret, FrogLib.Safe

-- Tuning (seconds).
local T = {
    LOOKBACK = 3.0,     -- a window never looks further back than this
    GRACE = 0.35,       -- a threat change is judged this long after it, so its hit/miss can arrive
    PAIR = 0.3,         -- a swing and an on-next-swing ability this close are the same attack
    QUEUE_MAX = 4.0,    -- an on-next-swing ability queued this long before its swing still pairs
    NEAR = 0.4,         -- damage on the target this close to the action is the action's
    RESULT = 0.2,       -- an action's own hit or miss comes this close to it (the fit pairs them)
    EARLY = 0.1,        -- a cast reported this soon after a change may still be its cause
    RAGE_NEAR = 0.3,    -- rage gained this close to a hit you took came from the hit
    SETTLE_MIN = 0.8,   -- an action that changed nothing for this long (at least) made no threat
    SETTLE_MAX = 1.4,   -- ... and at most: under a global cooldown, so the next one stays apart
    LAG_SEED = 0.4,     -- the update lag assumed until some is measured
    KEEP = 10,          -- seconds of log kept
    POLL = 0.1,         -- how often threat is read besides on the game's own updates
    FORGET = 30,        -- enemies not seen for this long are dropped
}
Lab.T = T

local SAMPLES_PER_SPELL = 20
local MAX_KEYS = 3000
local MAX_SPELLS = 150
local MAIN_HAND = (Enum and Enum.PlayerSwingType and Enum.PlayerSwingType.MainHand) or 0
local RAGE = (Enum and Enum.PowerType and Enum.PowerType.Rage) or 1

local function Set(...)
    local t = {}
    for i = 1, select("#", ...) do t[select(i, ...)] = true end
    return t
end

-- On-next-swing abilities: Heroic Strike, Cleave (and the druid's Maul, the hunter's Raptor Strike).
local NEXT_SWING = Set(78, 284, 285, 1608, 11564, 11565, 11566, 11567, 25286,
    845, 7369, 11608, 11609, 20569,
    6807, 6808, 6809, 8972, 9745, 9880, 9881,
    2973, 14260, 14261, 14262, 14263, 14264, 14265, 14266)
local NEXT_SWING_NAMES = Set("Heroic Strike", "Cleave", "Maul", "Raptor Strike")
-- Abilities that set or force threat rather than add it: recorded but not averaged.
local SETS_THREAT = Set(355, 694, 7400, 7402, 20559, 20560, 1161, 6795, 5209)
-- Stance and form changes.
local STANCE_SPELLS = Set(71, 2457, 2458, 5487, 9634, 768, 783)
-- Not actions of their own (their swings are logged as swings).
local IGNORE = Set(6603, 75)
-- Your damage over time on an enemy, by its debuff's spell ID: the seconds between ticks.
local DOTS = { [772] = 3, [6546] = 3, [6547] = 3, [6548] = 3, [11572] = 3, [11573] = 3, [11574] = 3,
    [12721] = 3 }
-- Buffs on you that give rage over time (rage gained makes threat): Bloodrage.
local RAGE_BUFFS = { 29131, 2687 }

-- Outcomes. "landed": no hit or miss was reported (an ability without damage, like Sunder
-- Armor); "side": another enemy than your target (Thunder Clap, Cleave, shouts).
local MISSES = Set("miss", "dodge", "parry", "block", "resist", "immune", "evade", "deflect", "reflect")
Lab.MISSES = MISSES
local COMBAT_OUTCOME = {
    DODGE = "dodge", PARRY = "parry", MISS = "miss", BLOCK = "block", RESIST = "resist",
    IMMUNE = "immune", EVADE = "evade", DEFLECT = "deflect", REFLECT = "reflect", ABSORB = "absorb",
}

local REASONS = {
    noaction = "threat changed with no action of yours (DoT, proc, rage or a late update)",
    several = "more than one action before the update",
    swing = "an auto-attack swing in the window",
    target = "you changed target",
    stance = "you changed stance",
    rage = "rage gained from Bloodrage, talents or procs",
    healed = "you were healed (healing makes threat)",
    late = "the update came too long after the action",
    extra = "other damage on the target (DoT, proc or someone else)",
    dot = "your DoT ticked (Rend, Deep Wounds)",
    dropped = "threat dropped (an enemy ability or a reset)",
    hidden = "the game hid what you cast",
    proc = "a proc or DoT of yours (combat log)",
}
Lab.REASONS = REASONS

------------------------------------------------------------------------------
-- The game: small wrappers, each safe where the API is missing
------------------------------------------------------------------------------

local function Now() return GetTime() end

local function Call(fn, ...)
    if not fn then return nil end
    local ok, a, b, c, d, e, f = pcall(fn, ...)
    if ok then return a, b, c, d, e, f end
    return nil
end

local STANCE_BY_FORM = { [17] = "battle", [18] = "def", [19] = "bers", [5] = "bear", [8] = "bear", [1] = "cat" }
local STANCE_BY_SPELL = { [2457] = "battle", [71] = "def", [2458] = "bers", [5487] = "bear", [9634] = "bear",
    [768] = "cat" }

function Lab.Stance()
    local id = Safe(Call(GetShapeshiftFormID))
    if id and STANCE_BY_FORM[id] then return STANCE_BY_FORM[id] end
    local index = Safe(Call(GetShapeshiftForm))
    if index and index > 0 then
        local _, _, _, spell = Call(GetShapeshiftFormInfo, index)
        spell = Safe(spell)
        if spell and STANCE_BY_SPELL[spell] then return STANCE_BY_SPELL[spell] end
        return "form" .. index
    end
    return "none"
end

local function SpellName(id)
    local name = C_Spell and Call(C_Spell.GetSpellName, id)
    if not name and GetSpellInfo then name = Call(GetSpellInfo, id) end
    return Safe(name)
end

local function SpellRank(id)
    local rank = C_Spell and Call(C_Spell.GetSpellSubtext, id)
    if rank == nil and GetSpellSubtext then rank = Call(GetSpellSubtext, id) end
    rank = Safe(rank)
    if rank == "" then return nil end
    return rank
end

local function SpellIcon(id)
    local icon = C_Spell and Call(C_Spell.GetSpellTexture, id)
    return Safe(icon)
end

local function Harmful(id)
    local h = C_Spell and Call(C_Spell.IsSpellHarmful, id)
    if h == nil and IsHarmfulSpell then h = Call(IsHarmfulSpell, id) end
    return Safe(h) == true
end

-- Rage the spell costs (shown units: 0-100).
local function RageCost(id)
    local costs = C_Spell and Call(C_Spell.GetSpellPowerCost, id)
    if type(costs) ~= "table" then return nil end
    for _, c in ipairs(costs) do
        local kind, name, cost = Safe(c.type), Safe(c.name), Safe(c.cost)
        if (kind == RAGE or name == "RAGE") and type(cost) == "number" then
            local max = Safe(Call(UnitPowerMax, "player", RAGE))
            if max and max > 0 and cost > max then cost = cost / 10 end
            return cost
        end
    end
    return nil
end

-- The global cooldown running as the cast is reported: its length, 0 when there's none (an
-- ability off the global cooldown), nil unknown. Each ability keeps the least seen (Record).
local function GcdAfterCast(now)
    local info = C_Spell and Call(C_Spell.GetSpellCooldown, 61304)
    if type(info) ~= "table" then return nil end
    local start, duration = Safe(info.startTime), Safe(info.duration)
    if type(start) ~= "number" or type(duration) ~= "number" then return nil end
    -- The cooldown starts when you press the key; the cast is reported once the server agrees.
    if duration == 0 then return 0 end
    if duration <= 2 and now - start < 1.2 then return duration end
    return nil
end

local function NextSwingQueued()
    local isCurrent = (C_Spell and C_Spell.IsCurrentSpell) or IsCurrentSpell
    if not isCurrent then return false end
    for id in pairs(NEXT_SWING) do
        if Safe(Call(isCurrent, id)) == true then return true end
    end
    return false
end

local function RageBuffUp()
    if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return false end
    for _, id in ipairs(RAGE_BUFFS) do
        local aura = Call(C_UnitAuras.GetPlayerAuraBySpellID, id)
        if not issecret(aura) and aura ~= nil then return true end
    end
    return false
end

-- Your DoTs on the unit: { { exp, dur, period } ..., unknown = true when they can't be timed }.
local function Dots(unit)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return nil end
    local list
    for i = 1, 40 do
        local a = Call(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL|PLAYER")
        if issecret(a) or a == nil then break end
        local id = Safe(a.spellId)
        if id == nil then
            list = list or {}
            list.unknown = true
        elseif DOTS[id] then
            list = list or {}
            local exp, dur = Safe(a.expirationTime), Safe(a.duration)
            if type(exp) == "number" and type(dur) == "number" and dur > 0 then
                list[#list + 1] = { id = id, exp = exp, dur = dur, period = DOTS[id] }
            else
                list.unknown = true
            end
        end
    end
    return list
end

local function Snapshot(unit)
    return {
        level = Safe(UnitLevel(unit)),
        cls = Safe(UnitClassification(unit)),
        name = Safe(UnitName(unit)),
    }
end

local function Zone()
    local z = Safe(Call(GetRealZoneText)) or Safe(Call(GetZoneText))
    if z == "" then return nil end
    return z
end

-- The Defiance talent (Protection: more threat in Defensive Stance), if this client's talent API
-- answers: rank, max rank.
function Lab.Defiance()
    if not (GetNumTalentTabs and GetNumTalents and GetTalentInfo) then return nil end
    local tabs = Safe(Call(GetNumTalentTabs)) or 0
    for tab = 1, tabs do
        local n = Safe(Call(GetNumTalents, tab)) or 0
        for i = 1, n do
            local name, _, _, _, rank, maxRank = Call(GetTalentInfo, tab, i)
            if Safe(name) == "Defiance" then return Safe(rank), Safe(maxRank) end
        end
    end
    return nil
end

------------------------------------------------------------------------------
-- Saved data (per character): aggregates and the last few samples of each ability
------------------------------------------------------------------------------

local function NewData()
    return {
        version = 1,
        agg = {},        -- key -> { s, st, lv, d, o, n, sum, sq, mn, mx, r, rn, dm, dn, dt }
        nagg = 0,
        spells = {},     -- spellID -> { name, rank, icon, nma, sets, gcd, cast }
        nspells = 0,
        samples = {},    -- spellID -> the last SAMPLES_PER_SPELL samples, newest last
        fit = {},        -- "stance:level" -> the fit's sums (see Method 2)
        nfit = 0,
        verbose = false,
        units = "auto",  -- threat units: "auto", 1 or 100 (raw threat per point of threat)
        ui = { stance = "def", outcome = "hits", lvMin = 1, lvMax = 80, method = "fit" },
    }
end

function Lab:Load()
    local db = EnmityListLab
    if type(db) ~= "table" or db.version ~= 1 then db = NewData() end
    local fresh = NewData()
    for k, v in pairs(fresh) do
        if db[k] == nil then db[k] = v end
    end
    for k, v in pairs(fresh.ui) do
        if db.ui[k] == nil then db.ui[k] = v end
    end
    EnmityListLab = db
    self.db = db
end

function Lab:Reset()
    local keep = self.db
    EnmityListLab = NewData()
    self.db = EnmityListLab
    -- Filters and switches stay as they were.
    if keep then
        self.db.ui, self.db.verbose, self.db.units = keep.ui, keep.verbose, keep.units
    end
    self:ResetSession()
end

function Lab:ResetSession()
    self.session = { samples = 0, discards = {}, discarded = 0, started = Now(), fitUsed = 0, fitSkipped = {} }
    self.fitVersion = (self.fitVersion or 0) + 1
    self.check, self.fitCache, self.mCache = nil, nil, nil
end

-- Player level bucket: 1-4, 5-9, 10-14 ... as its lower bound.
local function LevelBucket(level)
    if not level or level < 1 then return 0 end
    return math.floor(level / 5) * 5
end

-- Enemy level minus yours, kept within -5..+5; 99 for a boss (level ??).
local function DiffBucket(mine, theirs)
    if not mine or not theirs then return nil end
    if theirs < 0 then return 99 end
    local d = theirs - mine
    if d < -5 then d = -5 elseif d > 5 then d = 5 end
    return d
end
Lab.DiffBucket = DiffBucket
Lab.LevelBucket = LevelBucket

function Lab:Meta(spell)
    local db = self.db
    local m = db.spells[spell]
    if not m then
        if db.nspells >= MAX_SPELLS then return nil end
        m = {}
        db.spells[spell] = m
        db.nspells = db.nspells + 1
    end
    m.name = m.name or SpellName(spell) or ("Spell " .. spell)
    m.rank = SpellRank(spell) or m.rank
    m.icon = SpellIcon(spell) or m.icon
    m.nma = NEXT_SWING[spell] or NEXT_SWING_NAMES[m.name] or nil
    m.sets = SETS_THREAT[spell] or nil
    return m
end

local function IsNextSwing(spell)
    if NEXT_SWING[spell] then return true end
    local name = SpellName(spell)
    return name ~= nil and NEXT_SWING_NAMES[name] == true
end

function Lab:Record(w, a, outcome, damage)
    local db = self.db
    local meta = self:Meta(a.spell)
    if not meta then return end
    if a.gcd ~= nil then meta.gcd = meta.gcd and math.min(meta.gcd, a.gcd) or a.gcd end

    if self.defiance == nil then self.defiance, self.defianceMax = Lab.Defiance() end
    local level = Safe(UnitLevel("player"))
    local info = w.info or {}
    local lv, d = LevelBucket(level), DiffBucket(level, info.level)
    local key = table.concat({ a.spell, a.stance or "none", lv, d or "?", outcome }, ":")
    local g = db.agg[key]
    if not g then
        if db.nagg >= MAX_KEYS then return end
        g = { s = a.spell, st = a.stance or "none", lv = lv, d = d, o = outcome,
            n = 0, sum = 0, sq = 0, r = 0, rn = 0, dm = 0, dn = 0, dt = 0 }
        db.agg[key] = g
        db.nagg = db.nagg + 1
    end
    local th = w.delta
    g.n = g.n + 1
    g.sum = g.sum + th
    g.sq = g.sq + th * th
    if not g.mn or th < g.mn then g.mn = th end
    if not g.mx or th > g.mx then g.mx = th end
    if a.cost then
        g.r = g.r + a.cost
        g.rn = g.rn + 1
    end
    if damage and damage > 0 then
        g.dm = g.dm + damage
        g.dn = g.dn + 1
        g.dt = g.dt + th
    end

    local list = db.samples[a.spell]
    if not list then
        list = {}
        db.samples[a.spell] = list
    end
    list[#list + 1] = {
        at = time and time() or 0, th = th, o = outcome, dmg = damage, r = a.cost,
        lv = level, ml = info.level, c = info.cls, mob = info.name, st = a.stance,
        tk = w.status, z = Zone(), df = self.defiance, lag = w.lag,
    }
    while #list > SAMPLES_PER_SPELL do table.remove(list, 1) end

    self.session.samples = self.session.samples + 1
    if db.verbose then
        local scale = self:Scale()
        print(string.format("|cffe08080EnmityList lab|r: %s%s %s%d threat (%s%s%s)",
            meta.name, meta.rank and (" (" .. meta.rank .. ")") or "",
            th >= 0 and "+" or "", math.floor(th / scale + 0.5), outcome,
            damage and (", " .. damage .. " damage") or "",
            a.cost and (", " .. a.cost .. " rage") or ""))
    end
    if self.OnSample then self.OnSample() end
end

function Lab:Discard(w, reason)
    if w.quiet then return end
    local s = self.session
    s.discards[reason] = (s.discards[reason] or 0) + 1
    s.discarded = s.discarded + 1
    if self.OnSample then self.OnSample() end
end

------------------------------------------------------------------------------
-- The log
------------------------------------------------------------------------------

function Lab:Log(kind, e)
    e.kind = kind
    e.t = e.t or Now()
    local log = self.log
    log[#log + 1] = e
    return e
end

-- When an action took effect: an on-next-swing ability at its swing; nil while one is still
-- queued and waiting for its swing.
function Lab:Effective(e, now)
    if e.kind == "swing" then return e.t end
    if not e.nma then return e.t end
    if e.swing then return math.max(e.t, e.swing.t) end
    -- Not paired yet. If the game reported it when it was queued (it was still queued then) and
    -- something still is, it's waiting for its swing; otherwise it landed on a swing the game
    -- didn't report, as it was cast.
    if e.queued and self.queuedNow and now - e.t < T.QUEUE_MAX then return nil end
    return e.t
end

-- Actions: casts (all but auto attack) and plain swings (not paired with an on-next-swing ability).
local function IsAction(e)
    if e.kind == "cast" then return true end
    if e.kind == "swing" then return e.pair == nil end
    return false
end

function Lab:PairSwing(s)
    if s.hand ~= MAIN_HAND then return end
    for i = #self.log, 1, -1 do
        local e = self.log[i]
        if s.t - e.t > T.QUEUE_MAX then break end
        if e.kind == "cast" and e.nma and not e.swing then
            local dt = s.t - e.t
            if math.abs(dt) <= T.PAIR or (dt > 0 and s.queued) then
                e.swing, s.pair = s, e
                return
            end
        end
    end
end

function Lab:PairCast(c)
    for i = #self.log, 1, -1 do
        local e = self.log[i]
        if c.t - e.t > T.PAIR then break end
        if e.kind == "swing" and e.hand == MAIN_HAND and not e.pair then
            e.pair, c.swing = c, e
            return
        end
    end
end

------------------------------------------------------------------------------
-- Reading threat
------------------------------------------------------------------------------

-- How long an action may go without changing threat before it's taken to have made none.
function Lab:Settle()
    local lag = self.lag or T.LAG_SEED
    return math.max(T.SETTLE_MIN, math.min(T.SETTLE_MAX, lag * 2.5 + 0.2))
end

-- Closes windows for actions that changed nothing on this enemy: once a run of actions is
-- followed by `settle` seconds of nothing, it becomes a "quiet" window with a change of 0, so the
-- next change is judged on its own. `upTo`: runs that ended this long ago are settled.
function Lab:QuietClose(guid, m, upTo)
    local settle = self:Settle()
    local now = Now()
    for _ = 1, 20 do
        local effs = {}
        for _, e in ipairs(self.log) do
            if IsAction(e) and not (e.usedBy and e.usedBy[guid]) then
                local eff = self:Effective(e, now)
                if eff and eff > m.t then effs[#effs + 1] = eff end
            end
        end
        if #effs == 0 then return end
        table.sort(effs)
        -- The run of actions ends where a gap of `settle` follows one.
        local close, last
        for i = 1, #effs do
            if i == #effs or effs[i + 1] > effs[i] + settle then
                last, close = effs[i], effs[i] + settle
                break
            end
        end
        -- Damage on it after the run (a DoT tick, a proc) makes threat of its own: the quiet
        -- window ends before it.
        for _, e in ipairs(self.log) do
            if e.kind == "hit" and e.guid == guid and e.t > last + T.NEAR and e.t <= close
                and e.ev == "WOUND" and type(e.amount) == "number" and e.amount > 0 then
                close = e.t - 0.001
            end
        end
        if close > upTo then return end
        local w = { guid = guid, tOpen = m.t, tClose = close, delta = 0, quiet = true,
            info = m.info, status = m.status, onList = m.onList }
        m.t = w.tClose
        self:Evaluate(w)
    end
end

function Lab:Read(unit, now)
    if not Safe(UnitExists(unit)) then return end
    local guid = Safe(UnitGUID(unit))
    if not guid then return end
    if Safe(UnitIsDead(unit)) then
        self.mobs[guid] = nil
        return
    end
    if not Safe(UnitCanAttack("player", unit)) then return end
    local isTanking, status, _, _, raw = UnitDetailedThreatSituation("player", unit)
    if issecret(raw) or issecret(status) or issecret(isTanking) then
        -- Hidden by the game here: nothing to measure.
        self.hiddenAt = now
        self.mobs[guid] = nil
        return
    end
    self.readAt = now
    local m = self.mobs[guid]
    local info = Snapshot(unit)
    local isTarget = Safe(UnitIsUnit(unit, "target")) == true
    if not m then
        -- First sight: a baseline (0 when you're not on its threat list yet, so a pull counts).
        self.mobs[guid] = { value = raw or 0, t = now, info = info, status = status, seen = now,
            dots = isTarget and Dots(unit) or nil, onList = raw ~= nil }
        return
    end
    m.seen, m.info, m.onList = now, info, raw ~= nil
    local value = raw or 0
    if value == m.value then
        m.status = status
        return
    end
    -- Gone from its threat list (it reset, evaded or died): a fresh start, not a sample.
    if raw == nil then
        m.value, m.t, m.status = 0, now, status
        return
    end
    -- Actions before this change that changed nothing are settled first.
    self:QuietClose(guid, m, now)
    local dots = Dots(unit)
    local w = { guid = guid, tOpen = m.t, tClose = now, delta = value - m.value, status = status,
        tanking = isTanking, info = info, evalAt = now + T.GRACE, dots = dots, prevDots = m.dots,
        onList = true }
    m.value, m.t, m.status, m.dots = value, now, status, dots
    self.pending[#self.pending + 1] = w
end

------------------------------------------------------------------------------
-- Judging a window
------------------------------------------------------------------------------

local function Outcome(hit)
    local ev, flags, amount = hit.ev, hit.flags, hit.amount
    if ev == nil then return "hit" end
    if ev == "WOUND" then
        if amount == 0 then
            if flags == "BLOCK" then return "block" end
            if flags == "RESIST" then return "resist" end
            if flags == "ABSORB" then return "absorb" end
            return "miss"
        end
        if flags == "CRITICAL" or flags == "CRUSHING" then return "crit" end
        if flags == "GLANCING" then return "glance" end
        if flags == "BLOCK_REDUCED" then return "pblock" end
        return "hit"
    end
    return COMBAT_OUTCOME[ev] or "hit"
end
Lab.Outcome = Outcome

-- Whether a DoT of yours ticked between from and to. `newer`: the later snapshot, whose DoTs
-- replace the same ones here (a DoT refreshed since has its ticks timed anew).
local function TickIn(dots, from, to, newer)
    if not dots then return false end
    if dots.unknown then return true end
    local replaced = {}
    for _, d in ipairs(newer or {}) do replaced[d.id] = true end
    for _, d in ipairs(dots) do
        if not replaced[d.id] then
            local start = d.exp - d.dur
            local n = math.floor(d.dur / d.period + 0.5)
            for k = 1, n do
                local tick = start + k * d.period
                if tick > from - 0.25 and tick <= to + 0.1 then return true end
            end
        end
    end
    return false
end

-- An action already put down to a change on this enemy isn't counted again.
local function Used(e, guid)
    return e.usedBy ~= nil and e.usedBy[guid] == true
end

local function Use(e, guid)
    e.usedBy = e.usedBy or {}
    e.usedBy[guid] = true
end

-- Everything in a window, gathered once for both methods:
--   actions  your casts (not stance changes or hidden ones), swings  your plain swings,
--   flags    what else happened (target/stance change, hidden cast, rage, healing),
--   clean    the first reason the clean method would set it aside,
--   candidates  hits and misses on this enemy, rage  rage gained from elsewhere, heal  healing.
function Lab:Collect(w)
    local now = Now()
    local c = {
        from = math.max(w.tOpen, w.tClose - T.LOOKBACK),
        actions = {}, swings = {}, candidates = {}, flags = {}, rage = 0, heal = 0,
    }
    local from, log = c.from, self.log
    local function Flag(reason, cleanToo)
        c.flags[reason] = true
        if cleanToo ~= false then c.clean = c.clean or reason end
    end

    for i, e in ipairs(log) do
        local k = e.kind
        if IsAction(e) then
            local eff = self:Effective(e, now)
            if eff and eff > from and eff <= w.tClose and not Used(e, w.guid) then
                if k == "swing" then
                    c.swings[#c.swings + 1] = e
                    c.clean = c.clean or "swing"
                elseif e.hidden then
                    Flag("hidden")
                elseif STANCE_SPELLS[e.spell] then
                    Flag("stance")
                else
                    c.actions[#c.actions + 1] = e
                end
            end
        elseif e.t > from and e.t <= w.tClose then
            if k == "target" then
                Flag("target")
            elseif k == "stance" then
                Flag("stance")
            elseif k == "energize" then
                c.clean = c.clean or "rage"
            elseif k == "heal" then
                if c.solo == nil then c.solo = not Safe(Call(IsInGroup)) end
                if c.solo then c.clean = c.clean or "healed" end
                if type(e.amount) == "number" then c.heal = c.heal + e.amount else c.flags.healHidden = true end
            elseif k == "rage" and self.sawPlayerCombat then
                -- Rage from a hit you took makes no threat, nor does the refund when your
                -- ability is dodged, parried or missed.
                local explained = false
                for j = math.max(1, i - 30), math.min(#log, i + 30) do
                    local o = log[j]
                    if o.kind == "taken" and math.abs(o.t - e.t) <= T.RAGE_NEAR then explained = true end
                    if o.kind == "hit" and MISSES[Outcome(o)] and math.abs(o.t - e.t) <= T.NEAR then
                        explained = true
                    end
                end
                if not explained then
                    c.clean = c.clean or "rage"
                    c.rage = c.rage + (e.amount or 0)
                end
            end
        end
        -- Hits and misses on this enemy, not already claimed by another window.
        if k == "hit" and e.guid == w.guid and e.t > from and e.t <= w.tClose + T.GRACE
            and (e.claimedBy == nil or e.claimedBy == w) then
            c.candidates[#c.candidates + 1] = e
        end
    end
    if self.rageBuffAt and self.rageBuffAt > from - 0.5 then c.clean = c.clean or "rage" end

    -- The server's update came a moment before the game reported the cast: take the one cast
    -- just after the change, when nothing in the window explains the change (no damage on it).
    local damaged = false
    for _, e in ipairs(c.candidates) do
        if e.t <= w.tClose and e.ev == "WOUND" and e.amount ~= 0 then damaged = true end
    end
    if #c.actions == 0 and #c.swings == 0 and not c.clean and not w.quiet and not damaged then
        local early
        for _, e in ipairs(log) do
            if e.kind == "cast" and not e.hidden and not STANCE_SPELLS[e.spell] and not Used(e, w.guid) then
                local eff = self:Effective(e, now)
                if eff and eff > w.tClose and eff <= w.tClose + T.EARLY then
                    if early then
                        early = nil
                        break
                    end
                    early = e
                end
            end
        end
        if early then
            c.actions[1] = early
            c.early = early
            Use(early, w.guid)
        end
    end
    return c
end

-- Which action each hit or miss on this enemy is the result of: the nearest action within
-- T.RESULT (or `within`), each action taking one at most (preferring actions aimed at this enemy). Returns
-- hit -> action.
function Lab:Pair(w, hits, items, within)
    local now = Now()
    within = within or T.RESULT
    local pairs_, taken = {}, {}
    local list = {}
    for _, h in ipairs(hits) do
        for _, it in ipairs(items) do
            local d = math.abs(h.t - (self:Effective(it, now) or it.t))
            if d <= within then
                -- Ties: an action aimed at this enemy, and a miss over damage (a DoT tick can
                -- land in the same moment as your dodged ability; it can't be dodged itself).
                local miss = MISSES[Outcome(h)] and 0 or 0.0001
                list[#list + 1] = { h = h, it = it, d = d + miss + ((it.guid == w.guid) and 0 or 1) }
            end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    for _, c in ipairs(list) do
        if not pairs_[c.h] and not taken[c.it] then
            pairs_[c.h], taken[c.it] = c.it, true
        end
    end
    return pairs_
end

-- The window's hits: before the change, or within T.EARLY after it when it's the result of one
-- of the window's actions (see Pair). Anything else just after the change, a DoT tick say, is the next
-- window's: its threat comes with the next update.
function Lab:Hits(w, c)
    local before, after = {}, {}
    for _, e in ipairs(c.candidates) do
        if e.t <= w.tClose then before[#before + 1] = e else after[#after + 1] = e end
    end
    local items = {}
    for _, e in ipairs(c.actions) do items[#items + 1] = e end
    for _, e in ipairs(c.swings) do items[#items + 1] = e end
    local hits = {}
    for _, e in ipairs(before) do hits[#hits + 1] = e end
    if #after > 0 then
        -- Actions whose result already came before the change don't take another.
        local had = self:Pair(w, before, items)
        local open = {}
        local done = {}
        for _, it in pairs(had) do done[it] = true end
        for _, it in ipairs(items) do
            if not done[it] then open[#open + 1] = it end
        end
        for h in pairs(self:Pair(w, after, open, T.EARLY)) do
            -- Not if another action of yours came between the change and it.
            local ok = true
            for _, o in ipairs(self.log) do
                if o ~= c.early and IsAction(o) and o.t > w.tClose and o.t <= h.t then ok = false end
            end
            if ok then hits[#hits + 1] = h end
        end
        table.sort(hits, function(x, y) return x.t < y.t end)
    end
    for _, e in ipairs(hits) do e.claimedBy = w end
    return hits
end

function Lab:Evaluate(w)
    local c = self:Collect(w)
    c.hits = self:Hits(w, c)
    self:Fit(w, c)
    self:Clean(w, c)
end

-- Method 1, clean samples: one ability alone in the window.
function Lab:Clean(w, c)
    local now = Now()
    local from, actions, dirt, hits = c.from, c.actions, c.clean, c.hits

    if #actions == 0 then
        -- A swing, a hidden cast or the like alone: that's the reason; otherwise nothing seen.
        return self:Discard(w, dirt or "noaction")
    end
    if #actions > 1 then return self:Discard(w, "several") end
    if dirt then return self:Discard(w, dirt) end

    local a = actions[1]
    local eff = self:Effective(a, now)
    local lag = math.max(0, w.tClose - eff)
    if not w.quiet and lag > T.SETTLE_MAX + 0.1 then return self:Discard(w, "late") end
    local onTarget = a.guid ~= nil and a.guid == w.guid

    local outcome, damage = "side", nil
    if onTarget then
        if #hits > 1 then return self:Discard(w, "extra") end
        if #hits == 1 then
            local hit = hits[1]
            if math.abs(hit.t - eff) > T.NEAR then return self:Discard(w, "extra") end
            outcome = Outcome(hit)
            if hit.ev == "WOUND" and type(hit.amount) == "number" and hit.amount > 0 then damage = hit.amount end
        else
            outcome = "landed"
        end
    end

    -- The combat log, where the game gives it to addons: it names the source, so it's exact.
    if self.cleu then
        for _, e in ipairs(self.log) do
            if e.kind == "cl" and e.t > from and e.t <= w.tClose + T.GRACE then
                if e.spell == a.spell and e.dest == w.guid and not e.periodic then
                    outcome = e.outcome
                    damage = e.amount
                elseif e.dest == w.guid or e.energize or e.heal then
                    if not (e.swing and a.nma) then return self:Discard(w, "proc") end
                end
            end
        end
    end

    if not w.quiet and (TickIn(w.dots, from, w.tClose) or TickIn(w.prevDots, from, w.tClose, w.dots)) then
        return self:Discard(w, "dot")
    end
    local sets = SETS_THREAT[a.spell]
    if w.delta < 0 and not sets then return self:Discard(w, "dropped") end
    if w.quiet then
        -- Nothing changed: worth a sample only for a miss on your target (or a taunt that found
        -- you on top already).
        if not onTarget then return end
        if not (MISSES[outcome] or (sets and outcome == "landed")) then return end
    else
        -- A clean change: learn the usual lag.
        self.lag = (self.lag or T.LAG_SEED) * 0.8 + lag * 0.2
        w.lag = lag
    end
    self:Record(w, a, outcome, damage)
end

------------------------------------------------------------------------------
-- Method 2, the fit: every window from normal play, auto-attack and all.
--
-- In Classic-era rules your threat on an enemy is your damage to it times your stance's
-- multiplier, plus each ability's fixed bonus threat (also multiplied; it's measured as is), plus
-- a little for rage gained from Bloodrage and the like. So for every window:
--     change in threat = m x damage + sum over abilities (bonus x uses) [+ r x rage, + h x healing]
-- Damage is what the enemy took in the window (UNIT_COMBAT on it: alone, that's yours), with
-- DoT ticks and procs included, which is right: their threat is damage x m too. The unknowns
-- (m, one bonus per ability and outcome, swings', rage's) are solved by least squares. Only the
-- sums the solve needs are kept (A'A, A'b, b'b, per stance and level bucket), so it costs a few
-- numbers per window and nothing has to be stored per fight.
------------------------------------------------------------------------------

local FIT = {
    MAX_MODELS = 60,   -- stance x level bucket
    MAX_VARS = 48,     -- unknowns per model
    MIN_SEEN = 8,      -- windows an unknown must appear in to be shown
    MIN_WINDOWS = 30,  -- windows before the fit is shown at all
}
Lab.FIT = FIT

-- The unknown for an action: an ability (spellID, "s" when on another enemy than the one whose
-- threat this is, "m" when it missed) or a swing ("w" .. hand, "s" likewise).
local function VarKey(item, side, miss)
    if item.kind == "swing" then
        return "w" .. (item.hand or 0) .. (side and "s" or "")
    end
    return tostring(item.spell) .. (side and "s" or "") .. (miss and "m" or "")
end

function Lab.ParseKey(key)
    local hand, side = key:match("^w(%d)(s?)$")
    if hand then return { swing = tonumber(hand), side = side == "s" } end
    local spell, s, m = key:match("^(%d+)(s?)(m?)$")
    if spell then return { spell = tonumber(spell), side = s == "s", miss = m == "m" } end
    return nil
end

function Lab:FitSkip(w, reason)
    if w.quiet then return end
    local s = self.session
    s.fitSkipped[reason] = (s.fitSkipped[reason] or 0) + 1
end

function Lab:Fit(w, c)
    local items = {}
    for _, e in ipairs(c.actions) do items[#items + 1] = e end
    for _, e in ipairs(c.swings) do items[#items + 1] = e end
    local hits = c.hits
    -- A quiet window with nothing in it, or an enemy you're not fighting: nothing to learn.
    if #items == 0 and #hits == 0 and w.delta == 0 then return end
    if not w.onList then return end

    if Safe(Call(IsInGroup)) or Safe(UnitExists("pet")) then return self:FitSkip(w, "group") end
    if c.flags.target then return self:FitSkip(w, "target") end
    if c.flags.stance then return self:FitSkip(w, "stance") end
    if c.flags.hidden or c.flags.healHidden then return self:FitSkip(w, "hidden") end
    if w.delta < 0 then return self:FitSkip(w, "dropped") end
    if w.tOpen < w.tClose - T.LOOKBACK then return self:FitSkip(w, "long") end
    for _, e in ipairs(c.actions) do
        if SETS_THREAT[e.spell] then return self:FitSkip(w, "taunt") end
    end
    if #items == 0 and #hits == 0 and c.rage == 0 and c.heal == 0 then
        return self:FitSkip(w, "noaction")
    end

    -- Damage taken by the enemy, and which action each hit or miss belongs to (the nearest one,
    -- preferring those aimed at this enemy).
    local now = Now()
    local damage = 0
    local eff = {}
    for _, it in ipairs(items) do eff[it] = self:Effective(it, now) or it.t end
    local latest = 0
    local got = {}
    local paired = self:Pair(w, hits, items)
    for _, h in ipairs(hits) do
        if h.ev == nil or (h.ev == "WOUND" and type(h.amount) ~= "number") then
            return self:FitSkip(w, "hidden")
        end
        local amount = (h.ev == "WOUND" and h.amount) or 0
        damage = damage + amount
        if h.t > latest then latest = h.t end
        local best = paired[h]
        if best then
            got[best] = { damage = amount, miss = MISSES[Outcome(h)] or false }
        end
    end
    for _, it in ipairs(items) do
        if eff[it] > latest then latest = eff[it] end
    end
    -- The change came long after anything happened: a late update, not this window's doing.
    if not w.quiet and w.delta > 0 and w.tClose - latest > T.SETTLE_MAX + 0.1 and c.rage == 0 and c.heal == 0 then
        return self:FitSkip(w, "late")
    end

    -- The row of the least-squares problem.
    local x = {}
    if damage > 0 then x.dmg = damage end
    local uses = {}
    for _, it in ipairs(items) do
        local g = got[it]
        local key = VarKey(it, it.guid ~= w.guid, g and g.miss)
        x[key] = (x[key] or 0) + 1
        uses[#uses + 1] = { key = key, damage = g and g.damage or 0, cost = it.cost }
    end
    if c.rage > 0 then x.rage = c.rage end
    if c.heal > 0 then x.heal = c.heal end

    local lv = LevelBucket(Safe(UnitLevel("player")))
    local stance = (items[1] and items[1].stance) or Lab.Stance()
    local key = stance .. ":" .. lv
    if self:Outlier(key, x, w.delta) then return self:FitSkip(w, "outlier") end
    if not self:Accumulate(key, x, w.delta, uses) then return self:FitSkip(w, "full") end
    self.session.fitUsed = self.session.fitUsed + 1
    self.fitVersion = (self.fitVersion or 0) + 1
    if self.OnSample then self.OnSample() end
end

-- Least squares is thrown by the odd window that's badly wrong (a hit put down to the wrong
-- action, something the lab can't see). Once a model has enough windows, one whose change is
-- more than 5 standard deviations off what the current solution predicts is left out. The
-- solution used for this is refreshed every 100 windows.
function Lab:Outlier(key, x, b)
    local model = self.db.fit[key]
    if not model or model.n < 200 then return false end
    self.check = self.check or {}
    local c = self.check[key]
    if not c or model.n - c.n >= 100 or c.n > model.n then
        c = { n = model.n, sol = Lab.Solve(model) }
        self.check[key] = c
    end
    local sol = c.sol
    if not sol or sol.sigma <= 0 then return false end
    local pred = 0
    for k, v in pairs(x) do
        local beta = sol.beta[k]
        if beta == nil then return false end -- something new: can't judge it
        pred = pred + beta * v
    end
    return math.abs(b - pred) > 5 * sol.sigma + 100
end

local function NewModel(stance, lv)
    return { stance = stance, lv = lv, n = 0, bb = 0, ata = {}, atb = {}, seen = {}, nvars = 0,
        uses = {}, dmg = {}, cost = {}, costN = {} }
end

function Lab:Accumulate(key, x, b, uses)
    local db = self.db
    local model = db.fit[key]
    if not model then
        if db.nfit >= FIT.MAX_MODELS then return false end
        local stance, lv = key:match("^(.-):(%d+)$")
        model = NewModel(stance, tonumber(lv))
        db.fit[key] = model
        db.nfit = db.nfit + 1
    end
    local new = 0
    for k in pairs(x) do
        if not model.seen[k] then new = new + 1 end
    end
    if model.nvars + new > FIT.MAX_VARS then return false end
    model.nvars = model.nvars + new
    for i, xi in pairs(x) do
        model.seen[i] = (model.seen[i] or 0) + 1
        model.atb[i] = (model.atb[i] or 0) + xi * b
        local row = model.ata[i]
        if not row then
            row = {}
            model.ata[i] = row
        end
        for j, xj in pairs(x) do row[j] = (row[j] or 0) + xi * xj end
    end
    model.n = model.n + 1
    model.bb = model.bb + b * b
    for _, u in ipairs(uses) do
        model.uses[u.key] = (model.uses[u.key] or 0) + 1
        model.dmg[u.key] = (model.dmg[u.key] or 0) + u.damage
        if u.cost then
            model.cost[u.key] = (model.cost[u.key] or 0) + u.cost
            model.costN[u.key] = (model.costN[u.key] or 0) + 1
        end
    end
    return true
end

-- The fit's sums for one stance over a range of your levels (summing them is exact).
function Lab:FitModel(stance, lvMin, lvMax)
    local merged = NewModel(stance, nil)
    local any = false
    for _, model in pairs(self.db.fit) do
        if model.stance == stance and model.lv + 4 >= (lvMin or 1) and model.lv <= (lvMax or 999) then
            any = true
            merged.n = merged.n + model.n
            merged.bb = merged.bb + model.bb
            for i, row in pairs(model.ata) do
                local mrow = merged.ata[i]
                if not mrow then
                    mrow = {}
                    merged.ata[i] = mrow
                end
                for j, v in pairs(row) do mrow[j] = (mrow[j] or 0) + v end
            end
            for _, f in ipairs({ "atb", "seen", "uses", "dmg", "cost", "costN" }) do
                for k, v in pairs(model[f]) do merged[f][k] = (merged[f][k] or 0) + v end
            end
        end
    end
    return any and merged or nil
end

-- Solves the normal equations (A'A) beta = A'b by Gauss-Jordan elimination, with the inverse for
-- the standard errors: se_i = sqrt(sigma^2 * inv(A'A)_ii), sigma^2 = residual sum / (n - p).
-- A whisker of ridge keeps unknowns that always appear together solvable (their errors show it).
function Lab.Solve(model)
    local vars = {}
    for k in pairs(model.atb) do vars[#vars + 1] = k end
    table.sort(vars, function(a, b)
        if a == "dmg" or b == "dmg" then return a == "dmg" end
        return a < b
    end)
    local p = #vars
    if p == 0 then return nil end
    local M, y = {}, {}
    for i, vi in ipairs(vars) do
        local row = {}
        local src = model.ata[vi] or {}
        for j, vj in ipairs(vars) do row[j] = src[vj] or 0 end
        row[i] = row[i] * (1 + 1e-9) + 1e-9
        -- The identity alongside, to come out as the inverse.
        for j = 1, p do row[p + j] = (i == j) and 1 or 0 end
        M[i] = row
        y[i] = model.atb[vi] or 0
    end
    for col = 1, p do
        local pivot, best = col, math.abs(M[col][col])
        for r = col + 1, p do
            if math.abs(M[r][col]) > best then pivot, best = r, math.abs(M[r][col]) end
        end
        if best == 0 then return nil end
        M[col], M[pivot] = M[pivot], M[col]
        local prow = M[col]
        local d = prow[col]
        for j = col, 2 * p do prow[j] = prow[j] / d end
        for r = 1, p do
            if r ~= col then
                local row = M[r]
                local f = row[col]
                if f ~= 0 then
                    for j = col, 2 * p do row[j] = row[j] - f * prow[j] end
                end
            end
        end
    end
    local beta = {}
    for i = 1, p do
        local s = 0
        for j = 1, p do s = s + M[i][p + j] * y[j] end
        beta[i] = s
    end
    -- Residual sum of squares: b'b - 2 beta'A'b + beta'(A'A)beta.
    local fit2, quad = 0, 0
    for i, vi in ipairs(vars) do
        fit2 = fit2 + beta[i] * y[i]
        local src = model.ata[vi] or {}
        for j, vj in ipairs(vars) do quad = quad + beta[i] * (src[vj] or 0) * beta[j] end
    end
    local sse = math.max(0, model.bb - 2 * fit2 + quad)
    local dof = model.n - p
    local sigma2 = sse / math.max(1, dof)
    local out = { n = model.n, p = p, dof = dof, sigma = math.sqrt(sigma2), beta = {}, se = {}, seen = {} }
    for i, vi in ipairs(vars) do
        out.beta[vi] = beta[i]
        out.se[vi] = math.sqrt(math.max(0, sigma2 * M[i][p + i]))
        out.seen[vi] = model.seen[vi] or 0
    end
    return out
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------

local function Trim(self, now)
    local log = self.log
    local cut = 0
    for i = 1, #log do
        if now - log[i].t > T.KEEP then cut = i else break end
    end
    if cut > 0 then
        local kept = {}
        for i = cut + 1, #log do kept[#kept + 1] = log[i] end
        self.log = kept
    end
end

function Lab:Units()
    local units = { "target" }
    for i = 1, 40 do
        local u = "nameplate" .. i
        if Safe(UnitExists(u)) then units[#units + 1] = u end
    end
    return units
end

function Lab:Tick()
    local now = Now()
    local inCombat = Safe(UnitAffectingCombat("player")) == true
    self.queuedNow = NextSwingQueued()
    if RageBuffUp() then self.rageBuffAt = now end
    if inCombat or next(self.mobs) then
        for _, unit in ipairs(self:Units()) do self:Read(unit, now) end
    end
    -- Changes whose outcome has had time to arrive.
    local still = {}
    for _, w in ipairs(self.pending) do
        if w.evalAt <= now then self:Evaluate(w) else still[#still + 1] = w end
    end
    self.pending = still
    for guid, m in pairs(self.mobs) do
        self:QuietClose(guid, m, now - T.GRACE)
        if now - m.seen > T.FORGET then self.mobs[guid] = nil end
    end
    Trim(self, now)
end

function Lab:Flush()
    for _, w in ipairs(self.pending) do self:Evaluate(w) end
    self.pending = {}
    self.mobs = {}
end

function Lab:OnEvent(event, ...)
    local now = Now()
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit ~= "player" then return end
        local spell = Safe(spellID)
        if spell == nil then
            self:Log("cast", { hidden = true, t = now })
            return
        end
        if IGNORE[spell] then return end
        local c = self:Log("cast", {
            spell = spell, t = now,
            guid = Safe(UnitGUID("target")),
            stance = Lab.Stance(),
            cost = RageCost(spell),
            nma = IsNextSwing(spell) or nil,
            queued = nil,
        })
        if c.nma then
            c.queued = NextSwingQueued()
            self:PairCast(c)
        else
            c.gcd = GcdAfterCast(now)
        end
        if STANCE_SPELLS[spell] then self.stance = Lab.Stance() end
    elseif event == "PLAYER_SWING" then
        local _, swingType = ...
        local s = self:Log("swing", { hand = Safe(swingType) or MAIN_HAND, t = now, queued = NextSwingQueued(),
            guid = Safe(UnitGUID("target")), stance = self.stance })
        self:PairSwing(s)
    elseif event == "UNIT_COMBAT" then
        local unit, ev, flags, amount = ...
        ev, flags, amount = Safe(ev), Safe(flags), Safe(amount)
        if unit == "player" then
            self.sawPlayerCombat = true
            if ev == "ENERGIZE" then
                self:Log("energize", { t = now, amount = amount })
            elseif ev == "HEAL" then
                self:Log("heal", { t = now, amount = amount })
            elseif ev == "WOUND" or ev == nil then
                self:Log("taken", { t = now, ev = ev })
            end
            return
        end
        if ev == "HEAL" or ev == "ENERGIZE" then return end
        if not unit or not Safe(UnitCanAttack("player", unit)) then return end
        local guid = Safe(UnitGUID(unit))
        if not guid then return end
        -- The same hit comes once for each token the enemy has (target, nameplate).
        local log = self.log
        for i = #log, math.max(1, #log - 12), -1 do
            local o = log[i]
            if o.t ~= now then break end
            if o.kind == "hit" and o.guid == guid and o.ev == ev and o.flags == flags and o.amount == amount then
                return
            end
        end
        self:Log("hit", { t = now, guid = guid, ev = ev, flags = flags, amount = amount })
    elseif event == "UNIT_POWER_UPDATE" then
        local unit, power = ...
        if unit ~= "player" or power ~= "RAGE" then return end
        local rage = Safe(UnitPower("player", RAGE))
        if rage and self.rage and rage > self.rage then
            self:Log("rage", { t = now, amount = rage - self.rage })
        end
        self.rage = rage
    elseif event == "PLAYER_TARGET_CHANGED" then
        self:Log("target", { t = now })
    elseif event == "UPDATE_SHAPESHIFT_FORM" then
        local stance = Lab.Stance()
        if stance ~= self.stance then
            self.stance = stance
            self:Log("stance", { t = now })
        end
    elseif event == "UNIT_THREAT_LIST_UPDATE" or event == "UNIT_THREAT_SITUATION_UPDATE" then
        local unit = ...
        if unit and unit ~= "player" then self:Read(unit, now) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        self:Flush()
    elseif event == "CHARACTER_POINTS_CHANGED" or event == "PLAYER_TALENT_UPDATE"
        or event == "PLAYER_ENTERING_WORLD" then
        self.defiance, self.defianceMax = Lab.Defiance()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        self:CombatLog(now)
    end
end

-- The combat log. Midnight-era clients keep it from addons; this only runs where the game still
-- gives it out (CombatLogGetCurrentEventInfo exists and the event registered).
local CL_MISS = { DODGE = "dodge", PARRY = "parry", MISS = "miss", BLOCK = "block", RESIST = "resist",
    IMMUNE = "immune", EVADE = "evade", DEFLECT = "deflect", REFLECT = "reflect", ABSORB = "absorb" }
function Lab:CombatLog(now)
    local _, sub, _, src, _, _, _, dest, _, _, _, a12, _, _, a15, _, _, _, _, _, a21 = CombatLogGetCurrentEventInfo()
    if issecret(sub) or issecret(src) or src ~= self.guid then return end
    if issecret(dest) then return end
    local e = { t = now, dest = dest }
    if sub == "SWING_DAMAGE" or sub == "SWING_MISSED" then
        e.swing = true
    elseif sub == "SPELL_DAMAGE" then
        e.spell, e.amount = Safe(a12), Safe(a15)
        e.outcome = Safe(a21) and "crit" or "hit"
    elseif sub == "SPELL_MISSED" then
        e.spell, e.outcome, e.amount = Safe(a12), CL_MISS[Safe(a15)] or "miss", nil
    elseif sub == "SPELL_PERIODIC_DAMAGE" then
        e.spell, e.periodic = Safe(a12), true
    elseif sub == "SPELL_ENERGIZE" or sub == "SPELL_PERIODIC_ENERGIZE" then
        e.spell, e.energize = Safe(a12), true
    elseif sub == "SPELL_HEAL" or sub == "SPELL_PERIODIC_HEAL" then
        e.spell, e.heal = Safe(a12), true
    else
        return
    end
    self:Log("cl", e)
end

function Lab:Init()
    self.log, self.pending, self.mobs = {}, {}, {}
    self.guid = Safe(UnitGUID("player"))
    self.stance = Lab.Stance()
    self.rage = Safe(UnitPower("player", RAGE))
    self.defiance, self.defianceMax = Lab.Defiance()
    self:ResetSession()

    local f = CreateFrame("Frame")
    self.frame = f
    for _, event in ipairs({ "PLAYER_SWING", "PLAYER_TARGET_CHANGED", "UPDATE_SHAPESHIFT_FORM",
        "UNIT_THREAT_LIST_UPDATE", "UNIT_THREAT_SITUATION_UPDATE", "PLAYER_REGEN_ENABLED",
        "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE", "PLAYER_ENTERING_WORLD" }) do
        pcall(f.RegisterEvent, f, event)
    end
    pcall(f.RegisterUnitEvent, f, "UNIT_SPELLCAST_SUCCEEDED", "player")
    pcall(f.RegisterUnitEvent, f, "UNIT_POWER_UPDATE", "player")
    -- Every unit's: your target, each enemy's nameplate, and you.
    pcall(f.RegisterEvent, f, "UNIT_COMBAT")
    -- Only where the combat log is still the addons' to read.
    if CombatLogGetCurrentEventInfo then
        self.cleu = pcall(f.RegisterEvent, f, "COMBAT_LOG_EVENT_UNFILTERED") and true or nil
    end
    f:SetScript("OnEvent", function(_, event, ...) self:OnEvent(event, ...) end)
    local elapsed = 0
    f:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= T.POLL then
            elapsed = 0
            self:Tick()
        end
    end)
end

------------------------------------------------------------------------------
-- Reading the results (for the window and the slash command)
------------------------------------------------------------------------------

-- Raw threat per point of threat as the game shows it. Classic-era clients report threat x100;
-- "auto" checks that against your measured threat per point of damage.
function Lab:Scale()
    local units = self.db and self.db.units
    if units == 1 or units == 100 then return units, "set" end
    -- Asked for every number shown: worked out again only when the data changes.
    local stamp = tostring(self.fitVersion) .. ":" .. tostring(self.db and self.db.nagg) .. ":"
        .. tostring(self.session and self.session.samples)
    if self.scaleCache and self.scaleCache.stamp == stamp then
        return self.scaleCache.scale, self.scaleCache.how
    end
    local scale, how = self:ScaleNow()
    self.scaleCache = { stamp = stamp, scale = scale, how = how }
    return scale, how
end

function Lab:ScaleNow()
    local dm, dt = 0, 0
    for _, g in pairs(self.db and self.db.agg or {}) do
        if not SETS_THREAT[g.s] then
            dm, dt = dm + g.dm, dt + g.dt
        end
    end
    if dm >= 200 then
        local ratio = dt / dm
        if ratio >= 20 then return 100, "measured" end
        if ratio > 0 and ratio < 5 then return 1, "measured" end
    end
    -- Or the fit's threat per point of damage (about 1.3 in game units in Defensive Stance).
    local m = self:FitM()
    if m then
        if m >= 20 then return 100, "measured" end
        if m > 0 and m < 5 then return 1, "measured" end
    end
    return 100, "assumed"
end

-- The fit's raw threat per point of damage, in the stance with the most windows.
function Lab:FitM()
    if self.mCache and self.mCache.version == self.fitVersion then return self.mCache.m end
    local count = {}
    for _, model in pairs(self.db and self.db.fit or {}) do
        count[model.stance] = (count[model.stance] or 0) + model.n
    end
    local best, bestN
    for stance, n in pairs(count) do
        if not bestN or n > bestN then best, bestN = stance, n end
    end
    local m
    if best and bestN >= FIT.MIN_WINDOWS then
        local sol = Lab.Solve(self:FitModel(best, 1, 999))
        m = sol and sol.beta.dmg
    end
    self.mCache = { version = self.fitVersion, m = m }
    return m
end

local function SwingName(hand)
    if hand == 1 then return "Auto attack (off hand)" end
    if hand == 2 then return "Auto shot / ranged" end
    return "Auto attack"
end

-- The fit for the window's filters: { n, m, mSe, rage, rows = { per ability and outcome } }, or
-- { needStance = true } when "All stances" is picked (each stance has its own multiplier).
function Lab:FitView(f)
    if f.stance == "any" then return { needStance = true, n = 0 } end
    local key = table.concat({ f.stance, f.lvMin or 1, f.lvMax or 999, f.outcome, self.fitVersion or 0 }, ":")
    if self.fitCache and self.fitCache.key == key then return self.fitCache.view end
    local model = self:FitModel(f.stance, f.lvMin, f.lvMax)
    local view = { n = model and model.n or 0, rows = {} }
    local sol = model and model.n >= FIT.MIN_WINDOWS and Lab.Solve(model) or nil
    if sol then
        view.sol = sol
        view.m, view.mSe = sol.beta.dmg, sol.se.dmg
        view.rage, view.rageSe = sol.beta.rage, sol.se.rage
        local m = view.m or 0
        for k, beta in pairs(sol.beta) do
            local info = Lab.ParseKey(k)
            local show = info ~= nil
            if show and f.outcome == "hits" and info.miss then show = false end
            if show and f.outcome == "misses" and not info.miss then show = false end
            if show then
                local uses = model.uses[k] or 0
                local row = {
                    key = k, info = info, bonus = beta, se = sol.se[k], seen = sol.seen[k],
                    uses = uses, enough = sol.seen[k] >= FIT.MIN_SEEN,
                    avgDmg = uses > 0 and model.dmg[k] / uses or 0,
                    cost = (model.costN[k] or 0) > 0 and model.cost[k] / model.costN[k] or nil,
                }
                if info.swing then
                    row.name, row.icon = SwingName(info.swing), SpellIcon(6603)
                    row.swing = true
                else
                    local meta = self:Meta(info.spell) or {}
                    row.name, row.rank, row.icon = meta.name or ("Spell " .. info.spell), meta.rank, meta.icon
                    row.nma, row.gcd = meta.nma, meta.gcd
                end
                if info.side then row.name = row.name .. " - other enemies" end
                if info.miss then row.name = row.name .. " - missed" end
                row.fromDamage = m * row.avgDmg
                row.total = math.max(0, beta) + row.fromDamage
                view.rows[#view.rows + 1] = row
            end
        end
        table.sort(view.rows, function(a, b)
            if a.enough ~= b.enough then return a.enough end
            if a.total ~= b.total then return a.total > b.total end
            return a.key < b.key
        end)
    end
    self.fitCache = { key = key, view = view }
    return view
end

local function Matches(g, f)
    if f.stance ~= "any" and g.st ~= f.stance then return false end
    if g.lv + 4 < (f.lvMin or 1) or g.lv > (f.lvMax or 999) then return false end
    if f.outcome == "hits" then
        if MISSES[g.o] or g.o == "absorb" then return false end
    elseif f.outcome == "misses" then
        if not MISSES[g.o] then return false end
    end
    return true
end
Lab.Matches = Matches

local function Add(into, g)
    into.n = into.n + g.n
    into.sum = into.sum + g.sum
    into.sq = into.sq + g.sq
    into.r = into.r + g.r
    into.rn = into.rn + g.rn
    into.dm = into.dm + g.dm
    into.dn = into.dn + g.dn
    into.dt = into.dt + g.dt
    if g.mn and (not into.mn or g.mn < into.mn) then into.mn = g.mn end
    if g.mx and (not into.mx or g.mx > into.mx) then into.mx = g.mx end
end

local function RankNumber(rank)
    return tonumber(type(rank) == "string" and rank:match("(%d+)") or nil) or 0
end
Lab.RankNumber = RankNumber

local function Empty(extra)
    local t = { n = 0, sum = 0, sq = 0, r = 0, rn = 0, dm = 0, dn = 0, dt = 0 }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end

-- One row per ability (all its ranks together), sorted by average threat per use; abilities
-- that set threat go last.
function Lab:Rows(f)
    local byName = {}
    for _, g in pairs(self.db.agg) do
        if Matches(g, f) then
            local meta = self.db.spells[g.s] or {}
            local name = meta.name or ("Spell " .. g.s)
            local row = byName[name]
            if not row then
                row = Empty({ name = name, ids = {}, sets = meta.sets, nma = meta.nma })
                byName[name] = row
            end
            Add(row, g)
            row.ids[g.s] = true
            -- Shown with its highest rank measured.
            if not row.top or RankNumber(meta.rank) > RankNumber(row.rank) then
                row.top, row.rank, row.icon, row.gcd = g.s, meta.rank, meta.icon, meta.gcd
            end
            row.icon = row.icon or meta.icon
        end
    end
    local rows = {}
    for _, row in pairs(byName) do rows[#rows + 1] = row end
    table.sort(rows, function(a, b)
        if (a.sets and 1 or 0) ~= (b.sets and 1 or 0) then return not a.sets end
        local aa, ba = a.sum / a.n, b.sum / b.n
        if aa ~= ba then return aa > ba end
        return a.name < b.name
    end)
    return rows
end

-- Breakdown of one ability (by name) under the filter: { title, groups = { { label, stats } } }.
function Lab:Breakdown(name, f)
    local by = { rank = {}, level = {}, diff = {}, outcome = {}, stance = {} }
    local ids = {}
    for _, g in pairs(self.db.agg) do
        local meta = self.db.spells[g.s] or {}
        if (meta.name or ("Spell " .. g.s)) == name then
            ids[g.s] = true
            local function Put(kind, key, sort)
                local t = by[kind][key]
                if not t then
                    t = Empty({ key = key, sort = sort })
                    by[kind][key] = t
                end
                Add(t, g)
            end
            if Matches(g, f) then
                Put("rank", meta.rank or ("#" .. g.s), -g.s)
                Put("level", g.lv, g.lv)
                Put("diff", g.d or "?", type(g.d) == "number" and g.d or 100)
                Put("outcome", g.o, MISSES[g.o] and 1 or 0)
            end
            -- Stances regardless of the stance filter, to compare them.
            local any = {}
            for k, v in pairs(f) do any[k] = v end
            any.stance = "any"
            if Matches(g, any) then Put("stance", g.st, 0) end
        end
    end
    local out = {}
    for _, kind in ipairs({ "rank", "level", "diff", "outcome", "stance" }) do
        local list = {}
        for _, t in pairs(by[kind]) do list[#list + 1] = t end
        table.sort(list, function(a, b)
            if a.sort ~= b.sort then return a.sort < b.sort end
            return tostring(a.key) < tostring(b.key)
        end)
        out[kind] = list
    end
    -- Recent samples of every rank, newest first.
    local recent = {}
    for id in pairs(ids) do
        for _, s in ipairs(self.db.samples[id] or {}) do
            recent[#recent + 1] = { id = id, s = s }
        end
    end
    table.sort(recent, function(a, b) return (a.s.at or 0) > (b.s.at or 0) end)
    out.recent = recent
    return out
end

-- What the lab is doing now, for the status line.
function Lab:State()
    local now = Now()
    if self.hiddenAt and now - self.hiddenAt < 5 then return "hidden" end
    if not Safe(UnitAffectingCombat("player")) then return "idle" end
    if not Safe(UnitExists("target")) and not next(self.mobs or {}) then return "notarget" end
    return "measuring"
end

------------------------------------------------------------------------------
-- Startup
------------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        Lab:Load()
    elseif event == "PLAYER_LOGIN" then
        if not Lab.db then Lab:Load() end
        Lab:Init()
    end
end)
