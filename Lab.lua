local ADDON, ns = ...

-- Threat lab: how much threat each of your abilities makes, measured from the changes in your raw
-- threat on the enemies you fight (UnitDetailedThreatSituation). Two methods share one reading and
-- log: clean samples (one ability alone between two updates: exact, but rare) and the fit (every
-- window of normal play solved together). Where the game hides the numbers, nothing is read.
-- Since Forever 1.60.1.70938 the game hides every hit's size, everywhere: the fit can't use a
-- window with a landed hit, and clean samples get each ability's whole threat without its damage.

local Lab = {}
ns.Lab = Lab

local issecret, Safe = FrogLib.issecret, FrogLib.Safe

-- Tuning (seconds).
local TUNING = {
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

local SAMPLES_PER_SPELL = 20
local MAX_KEYS = 3000
local MAX_SPELLS = 150
local MAIN_HAND = (Enum and Enum.PlayerSwingType and Enum.PlayerSwingType.MainHand) or 0
local RAGE = (Enum and Enum.PowerType and Enum.PowerType.Rage) or 1

local function Set(...)
    local set = {}
    for i = 1, select("#", ...) do set[select(i, ...)] = true end
    return set
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
local COMBAT_OUTCOME = {
    DODGE = "dodge", PARRY = "parry", MISS = "miss", BLOCK = "block", RESIST = "resist",
    IMMUNE = "immune", EVADE = "evade", DEFLECT = "deflect", REFLECT = "reflect", ABSORB = "absorb",
}

------------------------------------------------------------------------------
-- The game: small wrappers, each safe where the API is missing
------------------------------------------------------------------------------

local function Now() return GetTime() end

local function Call(Function, ...)
    if not Function then return nil end
    local ok, first, second, third, fourth, fifth, sixth = pcall(Function, ...)
    if ok then return first, second, third, fourth, fifth, sixth end
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

-- Rage the spell costs (shown units: 0-100).
local function RageCost(id)
    local costs = C_Spell and Call(C_Spell.GetSpellPowerCost, id)
    if type(costs) ~= "table" then return nil end
    for _, entry in ipairs(costs) do
        local kind, name, cost = Safe(entry.type), Safe(entry.name), Safe(entry.cost)
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

-- Your DoTs on the unit: { { id, expires, duration, period } ..., unknown = true when they can't
-- be timed }.
local function Dots(unit)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return nil end
    local list
    for i = 1, 40 do
        local aura = Call(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL|PLAYER")
        if issecret(aura) or aura == nil then break end
        local id = Safe(aura.spellId)
        if id == nil then
            list = list or {}
            list.unknown = true
        elseif DOTS[id] then
            list = list or {}
            local expires, duration = Safe(aura.expirationTime), Safe(aura.duration)
            if type(expires) == "number" and type(duration) == "number" and duration > 0 then
                list[#list + 1] = { id = id, expires = expires, duration = duration, period = DOTS[id] }
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
        classification = Safe(UnitClassification(unit)),
        name = Safe(UnitName(unit)),
    }
end

local function Zone()
    local zone = Safe(Call(GetRealZoneText)) or Safe(Call(GetZoneText))
    if zone == "" then return nil end
    return zone
end

-- The Defiance talent (Protection: more threat in Defensive Stance), if this client's talent API
-- answers: rank, max rank.
function Lab.Defiance()
    if not (GetNumTalentTabs and GetNumTalents and GetTalentInfo) then return nil end
    local tabs = Safe(Call(GetNumTalentTabs)) or 0
    for tab = 1, tabs do
        local count = Safe(Call(GetNumTalents, tab)) or 0
        for i = 1, count do
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
        spells = {},     -- spellID -> { name, rank, icon, nma, sets, gcd }
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
    for key, value in pairs(fresh) do
        if db[key] == nil then db[key] = value end
    end
    for key, value in pairs(fresh.ui) do
        if db.ui[key] == nil then db.ui[key] = value end
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
    local difference = theirs - mine
    if difference < -5 then difference = -5 elseif difference > 5 then difference = 5 end
    return difference
end

function Lab:Meta(spell)
    local db = self.db
    local meta = db.spells[spell]
    if not meta then
        if db.nspells >= MAX_SPELLS then return nil end
        meta = {}
        db.spells[spell] = meta
        db.nspells = db.nspells + 1
    end
    meta.name = meta.name or SpellName(spell) or ("Spell " .. spell)
    meta.rank = SpellRank(spell) or meta.rank
    meta.icon = SpellIcon(spell) or meta.icon
    meta.nma = NEXT_SWING[spell] or NEXT_SWING_NAMES[meta.name] or nil
    meta.sets = SETS_THREAT[spell] or nil
    return meta
end

local function IsNextSwing(spell)
    if NEXT_SWING[spell] then return true end
    local name = SpellName(spell)
    return name ~= nil and NEXT_SWING_NAMES[name] == true
end

function Lab:Record(window, action, outcome, damage)
    local db = self.db
    local meta = self:Meta(action.spell)
    if not meta then return end
    if action.gcd ~= nil then meta.gcd = meta.gcd and math.min(meta.gcd, action.gcd) or action.gcd end

    if self.defiance == nil then self.defiance, self.defianceMax = Lab.Defiance() end
    local level = Safe(UnitLevel("player"))
    local info = window.info or {}
    local levelBucket, diff = LevelBucket(level), DiffBucket(level, info.level)
    local key = table.concat({ action.spell, action.stance or "none", levelBucket, diff or "?", outcome }, ":")
    local aggregate = db.agg[key]
    if not aggregate then
        if db.nagg >= MAX_KEYS then return end
        aggregate = { s = action.spell, st = action.stance or "none", lv = levelBucket, d = diff, o = outcome,
            n = 0, sum = 0, sq = 0, r = 0, rn = 0, dm = 0, dn = 0, dt = 0 }
        db.agg[key] = aggregate
        db.nagg = db.nagg + 1
    end
    local threat = window.delta
    aggregate.n = aggregate.n + 1
    aggregate.sum = aggregate.sum + threat
    aggregate.sq = aggregate.sq + threat * threat
    if not aggregate.mn or threat < aggregate.mn then aggregate.mn = threat end
    if not aggregate.mx or threat > aggregate.mx then aggregate.mx = threat end
    if action.cost then
        aggregate.r = aggregate.r + action.cost
        aggregate.rn = aggregate.rn + 1
    end
    if damage and damage > 0 then
        aggregate.dm = aggregate.dm + damage
        aggregate.dn = aggregate.dn + 1
        aggregate.dt = aggregate.dt + threat
    end

    local list = db.samples[action.spell]
    if not list then
        list = {}
        db.samples[action.spell] = list
    end
    list[#list + 1] = {
        at = time and time() or 0, th = threat, o = outcome, dmg = damage, r = action.cost,
        lv = level, ml = info.level, c = info.classification, mob = info.name, st = action.stance,
        tk = window.status, z = Zone(), df = self.defiance, lag = window.lag,
    }
    while #list > SAMPLES_PER_SPELL do table.remove(list, 1) end

    self.session.samples = self.session.samples + 1
    if db.verbose then
        local scale = self:Scale()
        print(string.format("|cffe08080EnmityList lab|r: %s%s %s%d threat (%s%s%s)",
            meta.name, meta.rank and (" (" .. meta.rank .. ")") or "",
            threat >= 0 and "+" or "", math.floor(threat / scale + 0.5), outcome,
            damage and (", " .. damage .. " damage") or "",
            action.cost and (", " .. action.cost .. " rage") or ""))
    end
    if self.OnSample then self.OnSample() end
end

function Lab:Discard(window, reason)
    if window.quiet then return end
    local session = self.session
    session.discards[reason] = (session.discards[reason] or 0) + 1
    session.discarded = session.discarded + 1
    if self.OnSample then self.OnSample() end
end

------------------------------------------------------------------------------
-- The log: casts, swings, damage and misses on your target and on you, rage, target and stance
------------------------------------------------------------------------------

function Lab:Log(kind, entry)
    entry.kind = kind
    entry.t = entry.t or Now()
    local log = self.log
    log[#log + 1] = entry
    return entry
end

-- When an action took effect: an on-next-swing ability at its swing; nil while one is still
-- queued and waiting for its swing.
function Lab:Effective(entry, now)
    if entry.kind == "swing" then return entry.t end
    if not entry.nma then return entry.t end
    if entry.swing then return math.max(entry.t, entry.swing.t) end
    -- Not paired yet: waiting for its swing if it was queued when reported and something still is;
    -- otherwise it landed on a swing the game didn't report, as it was cast.
    if entry.queued and self.queuedNow and now - entry.t < TUNING.QUEUE_MAX then return nil end
    return entry.t
end

-- Actions: casts (all but auto attack) and plain swings (not paired with an on-next-swing ability).
local function IsAction(entry)
    if entry.kind == "cast" then return true end
    if entry.kind == "swing" then return entry.pair == nil end
    return false
end

function Lab:PairSwing(swing)
    if swing.hand ~= MAIN_HAND then return end
    for i = #self.log, 1, -1 do
        local entry = self.log[i]
        if swing.t - entry.t > TUNING.QUEUE_MAX then break end
        if entry.kind == "cast" and entry.nma and not entry.swing then
            local gap = swing.t - entry.t
            if math.abs(gap) <= TUNING.PAIR or (gap > 0 and swing.queued) then
                entry.swing, swing.pair = swing, entry
                return
            end
        end
    end
end

function Lab:PairCast(cast)
    for i = #self.log, 1, -1 do
        local entry = self.log[i]
        if cast.t - entry.t > TUNING.PAIR then break end
        if entry.kind == "swing" and entry.hand == MAIN_HAND and not entry.pair then
            entry.pair, cast.swing = cast, entry
            return
        end
    end
end

------------------------------------------------------------------------------
-- Reading threat
------------------------------------------------------------------------------

-- How long an action may go without changing threat before it's taken to have made none.
function Lab:Settle()
    local lag = self.lag or TUNING.LAG_SEED
    return math.max(TUNING.SETTLE_MIN, math.min(TUNING.SETTLE_MAX, lag * 2.5 + 0.2))
end

-- A run of actions followed by `settle` seconds of nothing on this enemy becomes a "quiet" window
-- with a change of 0, so the next change is judged alone. Runs that ended by `upTo` are settled.
function Lab:QuietClose(guid, mob, upTo)
    local settle = self:Settle()
    local now = Now()
    for _ = 1, 20 do
        local times = {}
        for _, entry in ipairs(self.log) do
            if IsAction(entry) and not (entry.usedBy and entry.usedBy[guid]) then
                local at = self:Effective(entry, now)
                if at and at > mob.t then times[#times + 1] = at end
            end
        end
        if #times == 0 then return end
        table.sort(times)
        -- The run of actions ends where a gap of `settle` follows one.
        local close, last
        for i = 1, #times do
            if i == #times or times[i + 1] > times[i] + settle then
                last, close = times[i], times[i] + settle
                break
            end
        end
        -- Damage on it after the run (a DoT tick, a proc) makes threat of its own: the quiet
        -- window ends before it. No amount: a hit whose size the game hid.
        for _, entry in ipairs(self.log) do
            if entry.kind == "hit" and entry.guid == guid and entry.t > last + TUNING.NEAR and entry.t <= close
                and entry.ev == "WOUND" and entry.amount ~= 0 then
                close = entry.t - 0.001
            end
        end
        if close > upTo then return end
        local window = { guid = guid, tOpen = mob.t, tClose = close, delta = 0, quiet = true,
            info = mob.info, status = mob.status, onList = mob.onList }
        mob.t = window.tClose
        self:Evaluate(window)
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
        -- Hidden by the game here: nothing to measure. What's kept for the mob stays (the same mob through another
        -- token, your target, may read plainly: threat is secret through nameplate tokens).
        self.hiddenAt = now
        return
    end
    self.readAt = now
    local mob = self.mobs[guid]
    local info = Snapshot(unit)
    local isTarget = Safe(UnitIsUnit(unit, "target")) == true
    if not mob then
        -- First sight: a baseline (0 when you're not on its threat list yet, so a pull counts).
        self.mobs[guid] = { value = raw or 0, t = now, info = info, status = status, seen = now,
            dots = isTarget and Dots(unit) or nil, onList = raw ~= nil }
        return
    end
    mob.seen, mob.info, mob.onList = now, info, raw ~= nil
    local value = raw or 0
    if value == mob.value then
        mob.status = status
        return
    end
    -- Gone from its threat list (it reset, evaded or died): a fresh start, not a sample.
    if raw == nil then
        mob.value, mob.t, mob.status = 0, now, status
        return
    end
    -- Actions before this change that changed nothing are settled first.
    self:QuietClose(guid, mob, now)
    local dots = Dots(unit)
    local window = { guid = guid, tOpen = mob.t, tClose = now, delta = value - mob.value, status = status,
        tanking = isTanking, info = info, evalAt = now + TUNING.GRACE, dots = dots, prevDots = mob.dots,
        onList = true }
    mob.value, mob.t, mob.status, mob.dots = value, now, status, dots
    self.pending[#self.pending + 1] = window
end

------------------------------------------------------------------------------
-- Judging a window
------------------------------------------------------------------------------

local function Outcome(hit)
    local kind, flags, amount = hit.ev, hit.flags, hit.amount
    if kind == nil then return "hit" end
    if kind == "WOUND" then
        -- With its size hidden (nil), a plain "BLOCK" is still a full block (partial is BLOCK_REDUCED).
        if amount == nil and flags == "BLOCK" then return "block" end
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
    return COMBAT_OUTCOME[kind] or "hit"
end

-- Whether a DoT of yours ticked between from and to. `newer`: the later snapshot, whose DoTs
-- replace the same ones here (a DoT refreshed since has its ticks timed anew).
local function TickIn(dots, from, to, newer)
    if not dots then return false end
    if dots.unknown then return true end
    local replaced = {}
    for _, dot in ipairs(newer or {}) do replaced[dot.id] = true end
    for _, dot in ipairs(dots) do
        if not replaced[dot.id] then
            local start = dot.expires - dot.duration
            for tick = 1, math.floor(dot.duration / dot.period + 0.5) do
                local at = start + tick * dot.period
                if at > from - 0.25 and at <= to + 0.1 then return true end
            end
        end
    end
    return false
end

-- An action already put down to a change on this enemy isn't counted again.
local function Used(entry, guid)
    return entry.usedBy ~= nil and entry.usedBy[guid] == true
end

local function Use(entry, guid)
    entry.usedBy = entry.usedBy or {}
    entry.usedBy[guid] = true
end

-- Everything in a window, gathered once for both methods: actions, plain swings, flags (what else
-- happened), clean (the first reason the clean method sets it aside), candidates (hits and misses).
function Lab:Collect(window)
    local now = Now()
    local gathered = {
        from = math.max(window.tOpen, window.tClose - TUNING.LOOKBACK),
        actions = {}, swings = {}, candidates = {}, flags = {}, rage = 0, heal = 0,
    }
    local from, log = gathered.from, self.log
    local function Flag(reason, cleanToo)
        gathered.flags[reason] = true
        if cleanToo ~= false then gathered.clean = gathered.clean or reason end
    end

    for i, entry in ipairs(log) do
        local kind = entry.kind
        if IsAction(entry) then
            local at = self:Effective(entry, now)
            if at and at > from and at <= window.tClose and not Used(entry, window.guid) then
                if kind == "swing" then
                    gathered.swings[#gathered.swings + 1] = entry
                    gathered.clean = gathered.clean or "swing"
                elseif entry.hidden then
                    Flag("hidden")
                elseif STANCE_SPELLS[entry.spell] then
                    Flag("stance")
                else
                    gathered.actions[#gathered.actions + 1] = entry
                end
            end
        elseif entry.t > from and entry.t <= window.tClose then
            if kind == "target" then
                Flag("target")
            elseif kind == "stance" then
                Flag("stance")
            elseif kind == "energize" then
                gathered.clean = gathered.clean or "rage"
            elseif kind == "heal" then
                if gathered.solo == nil then gathered.solo = not Safe(Call(IsInGroup)) end
                if gathered.solo then gathered.clean = gathered.clean or "healed" end
                if type(entry.amount) == "number" then
                    gathered.heal = gathered.heal + entry.amount
                else
                    gathered.flags.healHidden = true
                end
            elseif kind == "rage" and self.sawPlayerCombat then
                -- Rage from a hit you took makes no threat, nor does the refund when your
                -- ability is dodged, parried or missed.
                local explained = false
                for nearby = math.max(1, i - 30), math.min(#log, i + 30) do
                    local other = log[nearby]
                    if other.kind == "taken" and math.abs(other.t - entry.t) <= TUNING.RAGE_NEAR then explained = true end
                    if other.kind == "hit" and MISSES[Outcome(other)] and math.abs(other.t - entry.t) <= TUNING.NEAR then
                        explained = true
                    end
                end
                if not explained then
                    gathered.clean = gathered.clean or "rage"
                    gathered.rage = gathered.rage + (entry.amount or 0)
                end
            end
        end
        -- Hits and misses on this enemy, not already claimed by another window.
        if kind == "hit" and entry.guid == window.guid and entry.t > from and entry.t <= window.tClose + TUNING.GRACE
            and (entry.claimedBy == nil or entry.claimedBy == window) then
            gathered.candidates[#gathered.candidates + 1] = entry
        end
    end
    if self.rageBuffAt and self.rageBuffAt > from - 0.5 then gathered.clean = gathered.clean or "rage" end

    -- The server's update came a moment before the game reported the cast: take the one cast
    -- right after the change, when nothing in the window explains the change (no damage on it).
    local damaged = false
    for _, entry in ipairs(gathered.candidates) do
        if entry.t <= window.tClose and entry.ev == "WOUND" and entry.amount ~= 0 then damaged = true end
    end
    if #gathered.actions == 0 and #gathered.swings == 0 and not gathered.clean and not window.quiet and not damaged then
        local early
        for _, entry in ipairs(log) do
            if entry.kind == "cast" and not entry.hidden and not STANCE_SPELLS[entry.spell] and not Used(entry, window.guid) then
                local at = self:Effective(entry, now)
                if at and at > window.tClose and at <= window.tClose + TUNING.EARLY then
                    if early then
                        early = nil
                        break
                    end
                    early = entry
                end
            end
        end
        if early then
            gathered.actions[1] = early
            gathered.early = early
            Use(early, window.guid)
        end
    end
    return gathered
end

-- Which action each hit or miss on this enemy came from: the nearest within TUNING.RESULT (or
-- `within`), each taking one at most, preferring actions aimed at this enemy. hit -> action.
function Lab:Pair(window, hits, items, within)
    local now = Now()
    within = within or TUNING.RESULT
    local cameFrom, taken = {}, {}
    local candidates = {}
    for _, hit in ipairs(hits) do
        for _, item in ipairs(items) do
            local gap = math.abs(hit.t - (self:Effective(item, now) or item.t))
            if gap <= within then
                -- Ties: an action aimed at this enemy, and a miss over damage (a DoT tick can
                -- land in the same moment as your dodged ability; it can't be dodged itself).
                local missFirst = MISSES[Outcome(hit)] and 0 or 0.0001
                candidates[#candidates + 1] = { hit = hit, item = item,
                    rank = gap + missFirst + ((item.guid == window.guid) and 0 or 1) }
            end
        end
    end
    table.sort(candidates, function(first, second) return first.rank < second.rank end)
    for _, candidate in ipairs(candidates) do
        if not cameFrom[candidate.hit] and not taken[candidate.item] then
            cameFrom[candidate.hit], taken[candidate.item] = candidate.item, true
        end
    end
    return cameFrom
end

-- The window's hits: before the change, or within TUNING.EARLY after it when it's one of the
-- window's actions' results (see Pair); anything else right after belongs to the next window.
function Lab:Hits(window, gathered)
    local before, after = {}, {}
    for _, entry in ipairs(gathered.candidates) do
        if entry.t <= window.tClose then before[#before + 1] = entry else after[#after + 1] = entry end
    end
    local items = {}
    for _, entry in ipairs(gathered.actions) do items[#items + 1] = entry end
    for _, entry in ipairs(gathered.swings) do items[#items + 1] = entry end
    local hits = {}
    for _, entry in ipairs(before) do hits[#hits + 1] = entry end
    if #after > 0 then
        -- Actions whose result already came before the change don't take another.
        local had = self:Pair(window, before, items)
        local open = {}
        local done = {}
        for _, item in pairs(had) do done[item] = true end
        for _, item in ipairs(items) do
            if not done[item] then open[#open + 1] = item end
        end
        for hit in pairs(self:Pair(window, after, open, TUNING.EARLY)) do
            -- Not if another action of yours came between the change and it.
            local ok = true
            for _, other in ipairs(self.log) do
                if other ~= gathered.early and IsAction(other) and other.t > window.tClose and other.t <= hit.t then ok = false end
            end
            if ok then hits[#hits + 1] = hit end
        end
        table.sort(hits, function(first, second) return first.t < second.t end)
    end
    for _, entry in ipairs(hits) do entry.claimedBy = window end
    return hits
end

function Lab:Evaluate(window)
    local gathered = self:Collect(window)
    gathered.hits = self:Hits(window, gathered)
    self:Fit(window, gathered)
    self:Clean(window, gathered)
end

-- Method 1, clean samples: one ability alone in the window (an on-next-swing ability owns the swing
-- it lands on), nothing else making threat, the same target and stance, and the update soon after.
function Lab:Clean(window, gathered)
    local now = Now()
    local from, actions, reason, hits = gathered.from, gathered.actions, gathered.clean, gathered.hits

    if #actions == 0 then
        -- A swing, a hidden cast or the like alone: that's the reason; otherwise nothing seen.
        return self:Discard(window, reason or "noaction")
    end
    if #actions > 1 then return self:Discard(window, "several") end
    if reason then return self:Discard(window, reason) end

    local action = actions[1]
    local at = self:Effective(action, now)
    local lag = math.max(0, window.tClose - at)
    if not window.quiet and lag > TUNING.SETTLE_MAX + 0.1 then return self:Discard(window, "late") end
    local onTarget = action.guid ~= nil and action.guid == window.guid

    local outcome, damage = "side", nil
    if onTarget then
        if #hits > 1 then return self:Discard(window, "extra") end
        if #hits == 1 then
            local hit = hits[1]
            if math.abs(hit.t - at) > TUNING.NEAR then return self:Discard(window, "extra") end
            outcome = Outcome(hit)
            if hit.ev == "WOUND" and type(hit.amount) == "number" and hit.amount > 0 then damage = hit.amount end
        else
            outcome = "landed"
        end
    end

    -- The combat log, where the game gives it to addons: it names the source, so it's exact.
    if self.readsCombatLog then
        for _, entry in ipairs(self.log) do
            if entry.kind == "cl" and entry.t > from and entry.t <= window.tClose + TUNING.GRACE then
                if entry.spell == action.spell and entry.dest == window.guid and not entry.periodic then
                    outcome = entry.outcome
                    damage = entry.amount
                elseif entry.dest == window.guid or entry.energize or entry.heal then
                    if not (entry.swing and action.nma) then return self:Discard(window, "proc") end
                end
            end
        end
    end

    if not window.quiet and (TickIn(window.dots, from, window.tClose)
        or TickIn(window.prevDots, from, window.tClose, window.dots)) then
        return self:Discard(window, "dot")
    end
    local sets = SETS_THREAT[action.spell]
    if window.delta < 0 and not sets then return self:Discard(window, "dropped") end
    if window.quiet then
        -- Nothing changed: worth a sample only for a miss on your target (or a taunt that found
        -- you on top already).
        if not onTarget then return end
        if not (MISSES[outcome] or (sets and outcome == "landed")) then return end
    else
        -- A clean change: learn the usual lag.
        self.lag = (self.lag or TUNING.LAG_SEED) * 0.8 + lag * 0.2
        window.lag = lag
    end
    self:Record(window, action, outcome, damage)
end

------------------------------------------------------------------------------
-- Method 2, the fit: every window from normal play, auto-attack and all
------------------------------------------------------------------------------

-- Threat is damage x the stance's multiplier plus each ability's bonus (and some for rage), solved
-- by least squares from sums kept per stance and level bucket (A'A, A'b, b'b): a few numbers a window.
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

local function ParseKey(key)
    local hand, sideMark = key:match("^w(%d)(s?)$")
    if hand then return { swing = tonumber(hand), side = sideMark == "s" } end
    local spell, otherMark, missMark = key:match("^(%d+)(s?)(m?)$")
    if spell then return { spell = tonumber(spell), side = otherMark == "s", miss = missMark == "m" } end
    return nil
end

function Lab:FitSkip(window, reason)
    if window.quiet then return end
    local session = self.session
    session.fitSkipped[reason] = (session.fitSkipped[reason] or 0) + 1
end

function Lab:Fit(window, gathered)
    local items = {}
    for _, entry in ipairs(gathered.actions) do items[#items + 1] = entry end
    for _, entry in ipairs(gathered.swings) do items[#items + 1] = entry end
    local hits = gathered.hits
    -- A quiet window with nothing in it, or an enemy you're not fighting: nothing to learn.
    if #items == 0 and #hits == 0 and window.delta == 0 then return end
    if not window.onList then return end

    if Safe(Call(IsInGroup)) or Safe(UnitExists("pet")) then return self:FitSkip(window, "group") end
    if gathered.flags.target then return self:FitSkip(window, "target") end
    if gathered.flags.stance then return self:FitSkip(window, "stance") end
    if gathered.flags.hidden then return self:FitSkip(window, "hidden") end
    if gathered.flags.healHidden then return self:FitSkip(window, "size") end
    if window.delta < 0 then return self:FitSkip(window, "dropped") end
    if window.tOpen < window.tClose - TUNING.LOOKBACK then return self:FitSkip(window, "long") end
    for _, entry in ipairs(gathered.actions) do
        if SETS_THREAT[entry.spell] then return self:FitSkip(window, "taunt") end
    end
    if #items == 0 and #hits == 0 and gathered.rage == 0 and gathered.heal == 0 then
        return self:FitSkip(window, "noaction")
    end

    -- Damage taken by the enemy, and which action each hit or miss belongs to (the nearest one,
    -- preferring those aimed at this enemy).
    local now = Now()
    local damage = 0
    local effective = {}
    for _, item in ipairs(items) do effective[item] = self:Effective(item, now) or item.t end
    local latest = 0
    local results = {}
    local paired = self:Pair(window, hits, items)
    for _, hit in ipairs(hits) do
        if hit.ev == nil then return self:FitSkip(window, "hidden") end
        -- A hit whose size the game hid: its damage can't go in the sum.
        if hit.ev == "WOUND" and type(hit.amount) ~= "number" then return self:FitSkip(window, "size") end
        local amount = (hit.ev == "WOUND" and hit.amount) or 0
        damage = damage + amount
        if hit.t > latest then latest = hit.t end
        local action = paired[hit]
        if action then
            results[action] = { damage = amount, miss = MISSES[Outcome(hit)] or false }
        end
    end
    for _, item in ipairs(items) do
        if effective[item] > latest then latest = effective[item] end
    end
    -- The change came long after anything happened: a late update, not this window's doing.
    if not window.quiet and window.delta > 0 and window.tClose - latest > TUNING.SETTLE_MAX + 0.1
        and gathered.rage == 0 and gathered.heal == 0 then
        return self:FitSkip(window, "late")
    end

    -- The row of the least-squares problem.
    local row = {}
    if damage > 0 then row.dmg = damage end
    local uses = {}
    for _, item in ipairs(items) do
        local result = results[item]
        local key = VarKey(item, item.guid ~= window.guid, result and result.miss)
        row[key] = (row[key] or 0) + 1
        uses[#uses + 1] = { key = key, damage = result and result.damage or 0, cost = item.cost }
    end
    if gathered.rage > 0 then row.rage = gathered.rage end
    if gathered.heal > 0 then row.heal = gathered.heal end

    local levelBucket = LevelBucket(Safe(UnitLevel("player")))
    local stance = (items[1] and items[1].stance) or Lab.Stance()
    local key = stance .. ":" .. levelBucket
    if self:Outlier(key, row, window.delta) then return self:FitSkip(window, "outlier") end
    if not self:Accumulate(key, row, window.delta, uses) then return self:FitSkip(window, "full") end
    self.session.fitUsed = self.session.fitUsed + 1
    self.fitVersion = (self.fitVersion or 0) + 1
    if self.OnSample then self.OnSample() end
end

local Solve

-- Once a model has 200 windows, one whose change is more than 5 standard deviations off the
-- solution (refreshed every 100 windows) is left out: least squares is thrown by the odd bad one.
function Lab:Outlier(key, row, change)
    local model = self.db.fit[key]
    if not model or model.n < 200 then return false end
    self.check = self.check or {}
    local check = self.check[key]
    if not check or model.n - check.n >= 100 or check.n > model.n then
        check = { n = model.n, sol = Solve(model) }
        self.check[key] = check
    end
    local solution = check.sol
    if not solution or solution.sigma <= 0 then return false end
    local predicted = 0
    for name, value in pairs(row) do
        local beta = solution.beta[name]
        if beta == nil then return false end -- something new: can't judge it
        predicted = predicted + beta * value
    end
    return math.abs(change - predicted) > 5 * solution.sigma + 100
end

local function NewModel(stance, level)
    return { stance = stance, lv = level, n = 0, bb = 0, ata = {}, atb = {}, seen = {}, nvars = 0,
        uses = {}, dmg = {}, cost = {}, costN = {} }
end

function Lab:Accumulate(key, row, change, uses)
    local db = self.db
    local model = db.fit[key]
    if not model then
        if db.nfit >= FIT.MAX_MODELS then return false end
        local stance, level = key:match("^(.-):(%d+)$")
        model = NewModel(stance, tonumber(level))
        db.fit[key] = model
        db.nfit = db.nfit + 1
    end
    local added = 0
    for name in pairs(row) do
        if not model.seen[name] then added = added + 1 end
    end
    if model.nvars + added > FIT.MAX_VARS then return false end
    model.nvars = model.nvars + added
    for first, firstValue in pairs(row) do
        model.seen[first] = (model.seen[first] or 0) + 1
        model.atb[first] = (model.atb[first] or 0) + firstValue * change
        local sums = model.ata[first]
        if not sums then
            sums = {}
            model.ata[first] = sums
        end
        for second, secondValue in pairs(row) do sums[second] = (sums[second] or 0) + firstValue * secondValue end
    end
    model.n = model.n + 1
    model.bb = model.bb + change * change
    for _, use in ipairs(uses) do
        model.uses[use.key] = (model.uses[use.key] or 0) + 1
        model.dmg[use.key] = (model.dmg[use.key] or 0) + use.damage
        if use.cost then
            model.cost[use.key] = (model.cost[use.key] or 0) + use.cost
            model.costN[use.key] = (model.costN[use.key] or 0) + 1
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
            for first, sums in pairs(model.ata) do
                local mergedSums = merged.ata[first]
                if not mergedSums then
                    mergedSums = {}
                    merged.ata[first] = mergedSums
                end
                for second, value in pairs(sums) do mergedSums[second] = (mergedSums[second] or 0) + value end
            end
            for _, field in ipairs({ "atb", "seen", "uses", "dmg", "cost", "costN" }) do
                for key, value in pairs(model[field]) do merged[field][key] = (merged[field][key] or 0) + value end
            end
        end
    end
    return any and merged or nil
end

-- The normal equations (A'A) beta = A'b by Gauss-Jordan, with the inverse for the standard errors;
-- a whisker of ridge keeps unknowns that always appear together solvable (their errors show it).
function Solve(model)
    local names = {}
    for name in pairs(model.atb) do names[#names + 1] = name end
    table.sort(names, function(first, second)
        if first == "dmg" or second == "dmg" then return first == "dmg" end
        return first < second
    end)
    local count = #names
    if count == 0 then return nil end
    local matrix, rhs = {}, {}
    for i, name in ipairs(names) do
        local row = {}
        local source = model.ata[name] or {}
        for column, other in ipairs(names) do row[column] = source[other] or 0 end
        row[i] = row[i] * (1 + 1e-9) + 1e-9
        -- The identity alongside, to come out as the inverse.
        for column = 1, count do row[count + column] = (i == column) and 1 or 0 end
        matrix[i] = row
        rhs[i] = model.atb[name] or 0
    end
    for column = 1, count do
        local pivot, best = column, math.abs(matrix[column][column])
        for rowIndex = column + 1, count do
            if math.abs(matrix[rowIndex][column]) > best then pivot, best = rowIndex, math.abs(matrix[rowIndex][column]) end
        end
        if best == 0 then return nil end
        matrix[column], matrix[pivot] = matrix[pivot], matrix[column]
        local pivotRow = matrix[column]
        local divisor = pivotRow[column]
        for cell = column, 2 * count do pivotRow[cell] = pivotRow[cell] / divisor end
        for rowIndex = 1, count do
            if rowIndex ~= column then
                local row = matrix[rowIndex]
                local factor = row[column]
                if factor ~= 0 then
                    for cell = column, 2 * count do row[cell] = row[cell] - factor * pivotRow[cell] end
                end
            end
        end
    end
    local beta = {}
    for i = 1, count do
        local sum = 0
        for column = 1, count do sum = sum + matrix[i][count + column] * rhs[column] end
        beta[i] = sum
    end
    -- Residual sum of squares: b'b - 2 beta'A'b + beta'(A'A)beta.
    local explained, quadratic = 0, 0
    for i, name in ipairs(names) do
        explained = explained + beta[i] * rhs[i]
        local source = model.ata[name] or {}
        for column, other in ipairs(names) do quadratic = quadratic + beta[i] * (source[other] or 0) * beta[column] end
    end
    local residual = math.max(0, model.bb - 2 * explained + quadratic)
    local freedom = model.n - count
    local sigma2 = residual / math.max(1, freedom)
    local solution = { n = model.n, p = count, dof = freedom, sigma = math.sqrt(sigma2), beta = {}, se = {}, seen = {} }
    for i, name in ipairs(names) do
        solution.beta[name] = beta[i]
        solution.se[name] = math.sqrt(math.max(0, sigma2 * matrix[i][count + i]))
        solution.seen[name] = model.seen[name] or 0
    end
    return solution
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------

local function Trim(self, now)
    local log = self.log
    local cut = 0
    for i = 1, #log do
        if now - log[i].t > TUNING.KEEP then cut = i else break end
    end
    if cut > 0 then
        local kept = {}
        for i = cut + 1, #log do kept[#kept + 1] = log[i] end
        self.log = kept
    end
end

-- Your target, then each other mob with a plate: your target's own plate is skipped (the same mob, whose threat reads
-- as secret through its plate but plainly as your target).
function Lab:Units()
    local units = { "target" }
    local targetPlate = C_NamePlate.GetNamePlateForUnit("target")
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if Safe(UnitExists(unit)) and (not targetPlate or C_NamePlate.GetNamePlateForUnit(unit) ~= targetPlate) then
            units[#units + 1] = unit
        end
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
    -- Changes whose outcome has had time to arrive (the rest kept in place, no new list each tick).
    local pending, kept = self.pending, 0
    for i = 1, #pending do
        local window = pending[i]
        if window.evalAt <= now then
            self:Evaluate(window)
        else
            kept = kept + 1
            pending[kept] = window
        end
    end
    for i = #pending, kept + 1, -1 do pending[i] = nil end
    for guid, mob in pairs(self.mobs) do
        self:QuietClose(guid, mob, now - TUNING.GRACE)
        if now - mob.seen > TUNING.FORGET then self.mobs[guid] = nil end
    end
    Trim(self, now)
    -- Nothing left to look at (out of combat, no enemy, nothing waiting, the log run out): the ticks stop till an
    -- event of the lab's comes (OnEvent starts them again).
    if not inCombat and not next(self.mobs) and #pending == 0 and #self.log == 0 then self.frame:Hide() end
end

function Lab:Flush()
    for _, window in ipairs(self.pending) do self:Evaluate(window) end
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
        local cast = self:Log("cast", {
            spell = spell, t = now,
            guid = Safe(UnitGUID("target")),
            stance = Lab.Stance(),
            cost = RageCost(spell),
            nma = IsNextSwing(spell) or nil,
            queued = nil,
        })
        if cast.nma then
            cast.queued = NextSwingQueued()
            self:PairCast(cast)
        else
            cast.gcd = GcdAfterCast(now)
        end
        if STANCE_SPELLS[spell] then self.stance = Lab.Stance() end
    elseif event == "PLAYER_SWING" then
        local _, swingType = ...
        local swing = self:Log("swing", { hand = Safe(swingType) or MAIN_HAND, t = now, queued = NextSwingQueued(),
            guid = Safe(UnitGUID("target")), stance = self.stance })
        self:PairSwing(swing)
    elseif event == "UNIT_COMBAT" then
        local unit, kind, flags, amount = ...
        kind, flags, amount = Safe(kind), Safe(flags), Safe(amount)
        if unit == "player" then
            self.sawPlayerCombat = true
            if kind == "ENERGIZE" then
                self:Log("energize", { t = now, amount = amount })
            elseif kind == "HEAL" then
                self:Log("heal", { t = now, amount = amount })
            elseif kind == "WOUND" or kind == nil then
                self:Log("taken", { t = now, ev = kind })
            end
            return
        end
        if kind == "HEAL" or kind == "ENERGIZE" then return end
        if not unit or not Safe(UnitCanAttack("player", unit)) then return end
        local guid = Safe(UnitGUID(unit))
        if not guid then return end
        -- Whether the game hides how hard hits land, for the window to say so.
        if kind == "WOUND" then self.sizesHidden = amount == nil end
        -- The same hit comes once for each token the enemy has (target, nameplate); the same token
        -- twice in one moment is a second hit, which with sizes hidden looks the same as the first.
        if self.seenAt ~= now then
            wipe(self.seen)
            self.seenAt = now
        end
        local seen, signature = self.seen, guid .. "|" .. tostring(kind) .. "|" .. tostring(flags)
        local mine = signature .. "|" .. unit
        local times = (seen[mine] or 0) + 1
        seen[mine] = times
        if times <= (seen[signature] or 0) then return end
        seen[signature] = times
        self:Log("hit", { t = now, guid = guid, ev = kind, flags = flags, amount = amount })
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
local LOG_MISS = { DODGE = "dodge", PARRY = "parry", MISS = "miss", BLOCK = "block", RESIST = "resist",
    IMMUNE = "immune", EVADE = "evade", DEFLECT = "deflect", REFLECT = "reflect", ABSORB = "absorb" }
function Lab:CombatLog(now)
    local _, subevent, _, source, _, _, _, dest, _, _, _, spellID, _, _, amountOrMiss, _, _, _, _, _, critical =
        CombatLogGetCurrentEventInfo()
    if issecret(subevent) or issecret(source) or source ~= self.guid then return end
    if issecret(dest) then return end
    local entry = { t = now, dest = dest }
    if subevent == "SWING_DAMAGE" or subevent == "SWING_MISSED" then
        entry.swing = true
    elseif subevent == "SPELL_DAMAGE" then
        entry.spell, entry.amount = Safe(spellID), Safe(amountOrMiss)
        entry.outcome = Safe(critical) and "crit" or "hit"
    elseif subevent == "SPELL_MISSED" then
        entry.spell, entry.outcome, entry.amount = Safe(spellID), LOG_MISS[Safe(amountOrMiss)] or "miss", nil
    elseif subevent == "SPELL_PERIODIC_DAMAGE" then
        entry.spell, entry.periodic = Safe(spellID), true
    elseif subevent == "SPELL_ENERGIZE" or subevent == "SPELL_PERIODIC_ENERGIZE" then
        entry.spell, entry.energize = Safe(spellID), true
    elseif subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL" then
        entry.spell, entry.heal = Safe(spellID), true
    else
        return
    end
    self:Log("cl", entry)
end

function Lab:Init()
    self.log, self.pending, self.mobs, self.seen = {}, {}, {}, {}
    self.guid = Safe(UnitGUID("player"))
    self.stance = Lab.Stance()
    self.rage = Safe(UnitPower("player", RAGE))
    self.defiance, self.defianceMax = Lab.Defiance()
    self:ResetSession()

    local frame = CreateFrame("Frame")
    self.frame = frame
    for _, event in ipairs({ "PLAYER_SWING", "PLAYER_TARGET_CHANGED", "UPDATE_SHAPESHIFT_FORM",
        "UNIT_THREAT_LIST_UPDATE", "UNIT_THREAT_SITUATION_UPDATE", "PLAYER_REGEN_ENABLED",
        "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE", "PLAYER_ENTERING_WORLD" }) do
        pcall(frame.RegisterEvent, frame, event)
    end
    pcall(frame.RegisterUnitEvent, frame, "UNIT_SPELLCAST_SUCCEEDED", "player")
    pcall(frame.RegisterUnitEvent, frame, "UNIT_POWER_UPDATE", "player")
    -- Every unit's: your target, each enemy's nameplate, and you.
    pcall(frame.RegisterEvent, frame, "UNIT_COMBAT")
    -- Only where the combat log is still the addons' to read.
    if CombatLogGetCurrentEventInfo then
        self.readsCombatLog = pcall(frame.RegisterEvent, frame, "COMBAT_LOG_EVENT_UNFILTERED") and true or nil
    end
    pcall(frame.RegisterEvent, frame, "PLAYER_REGEN_DISABLED")
    frame:SetScript("OnEvent", function(_, event, ...)
        frame:Show() -- (the ticks, stopped while there was nothing to look at)
        self:OnEvent(event, ...)
    end)
    local waited = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        waited = waited + elapsed
        if waited >= TUNING.POLL then
            waited = 0
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
    local damage, threat = 0, 0
    for _, aggregate in pairs(self.db and self.db.agg or {}) do
        if not SETS_THREAT[aggregate.s] then
            damage, threat = damage + aggregate.dm, threat + aggregate.dt
        end
    end
    if damage >= 200 then
        local ratio = threat / damage
        if ratio >= 20 then return 100, "measured" end
        if ratio > 0 and ratio < 5 then return 1, "measured" end
    end
    -- Or the fit's threat per point of damage (about 1.3 in game units in Defensive Stance).
    local perDamage = self:FitM()
    if perDamage then
        if perDamage >= 20 then return 100, "measured" end
        if perDamage > 0 and perDamage < 5 then return 1, "measured" end
    end
    return 100, "assumed"
end

-- The fit's raw threat per point of damage, in the stance with the most windows.
function Lab:FitM()
    if self.mCache and self.mCache.version == self.fitVersion then return self.mCache.m end
    local windows = {}
    for _, model in pairs(self.db and self.db.fit or {}) do
        windows[model.stance] = (windows[model.stance] or 0) + model.n
    end
    local best, bestCount
    for stance, count in pairs(windows) do
        if not bestCount or count > bestCount then best, bestCount = stance, count end
    end
    local perDamage
    if best and bestCount >= FIT.MIN_WINDOWS then
        local solution = Solve(self:FitModel(best, 1, 999))
        perDamage = solution and solution.beta.dmg
    end
    self.mCache = { version = self.fitVersion, m = perDamage }
    return perDamage
end

local function SwingName(hand)
    if hand == 1 then return "Auto attack (off hand)" end
    if hand == 2 then return "Auto shot / ranged" end
    return "Auto attack"
end

-- The fit for the window's filters: { n, m, mSe, rage, rows = { per ability and outcome } }, or
-- { needStance = true } when "All stances" is picked (each stance has its own multiplier).
function Lab:FitView(filter)
    if filter.stance == "any" then return { needStance = true, n = 0 } end
    local key = table.concat({ filter.stance, filter.lvMin or 1, filter.lvMax or 999, filter.outcome,
        self.fitVersion or 0 }, ":")
    if self.fitCache and self.fitCache.key == key then return self.fitCache.view end
    local model = self:FitModel(filter.stance, filter.lvMin, filter.lvMax)
    local view = { n = model and model.n or 0, rows = {} }
    local solution = model and model.n >= FIT.MIN_WINDOWS and Solve(model) or nil
    if solution then
        view.sol = solution
        view.m, view.mSe = solution.beta.dmg, solution.se.dmg
        view.rage, view.rageSe = solution.beta.rage, solution.se.rage
        local perDamage = view.m or 0
        for name, beta in pairs(solution.beta) do
            local info = ParseKey(name)
            local show = info ~= nil
            if show and filter.outcome == "hits" and info.miss then show = false end
            if show and filter.outcome == "misses" and not info.miss then show = false end
            if show then
                local uses = model.uses[name] or 0
                local row = {
                    key = name, info = info, bonus = beta, se = solution.se[name], seen = solution.seen[name],
                    uses = uses, enough = solution.seen[name] >= FIT.MIN_SEEN,
                    avgDmg = uses > 0 and model.dmg[name] / uses or 0,
                    cost = (model.costN[name] or 0) > 0 and model.cost[name] / model.costN[name] or nil,
                }
                if info.swing then
                    row.name, row.icon = SwingName(info.swing), SpellIcon(6603)
                    row.swing = true
                else
                    local meta = self:Meta(info.spell) or {}
                    row.name, row.rank, row.icon = meta.name or ("Spell " .. info.spell), meta.rank, meta.icon
                    row.nma, row.gcd = meta.nma, meta.gcd
                end
                if info.side then row.name = row.name .. " (other enemies)" end
                if info.miss then row.name = row.name .. " (missed)" end
                row.fromDamage = perDamage * row.avgDmg
                row.total = math.max(0, beta) + row.fromDamage
                view.rows[#view.rows + 1] = row
            end
        end
        table.sort(view.rows, function(first, second)
            if first.enough ~= second.enough then return first.enough end
            if first.total ~= second.total then return first.total > second.total end
            return first.key < second.key
        end)
    end
    self.fitCache = { key = key, view = view }
    return view
end

local function Matches(aggregate, filter)
    if filter.stance ~= "any" and aggregate.st ~= filter.stance then return false end
    if aggregate.lv + 4 < (filter.lvMin or 1) or aggregate.lv > (filter.lvMax or 999) then return false end
    if filter.outcome == "hits" then
        if MISSES[aggregate.o] or aggregate.o == "absorb" then return false end
    elseif filter.outcome == "misses" then
        if not MISSES[aggregate.o] then return false end
    end
    return true
end

local function Add(into, aggregate)
    into.n = into.n + aggregate.n
    into.sum = into.sum + aggregate.sum
    into.sq = into.sq + aggregate.sq
    into.r = into.r + aggregate.r
    into.rn = into.rn + aggregate.rn
    into.dm = into.dm + aggregate.dm
    into.dn = into.dn + aggregate.dn
    into.dt = into.dt + aggregate.dt
    if aggregate.mn and (not into.mn or aggregate.mn < into.mn) then into.mn = aggregate.mn end
    if aggregate.mx and (not into.mx or aggregate.mx > into.mx) then into.mx = aggregate.mx end
end

local function RankNumber(rank)
    return tonumber(type(rank) == "string" and rank:match("(%d+)") or nil) or 0
end

local function Empty(extra)
    local totals = { n = 0, sum = 0, sq = 0, r = 0, rn = 0, dm = 0, dn = 0, dt = 0 }
    for key, value in pairs(extra or {}) do totals[key] = value end
    return totals
end

-- One row per ability (all its ranks together), sorted by average threat per use; abilities
-- that set threat go last.
function Lab:Rows(filter)
    local byName = {}
    for _, aggregate in pairs(self.db.agg) do
        if Matches(aggregate, filter) then
            local meta = self.db.spells[aggregate.s] or {}
            local name = meta.name or ("Spell " .. aggregate.s)
            local row = byName[name]
            if not row then
                row = Empty({ name = name, ids = {}, sets = meta.sets, nma = meta.nma })
                byName[name] = row
            end
            Add(row, aggregate)
            row.ids[aggregate.s] = true
            -- Shown with its highest rank measured.
            if not row.top or RankNumber(meta.rank) > RankNumber(row.rank) then
                row.top, row.rank, row.icon, row.gcd = aggregate.s, meta.rank, meta.icon, meta.gcd
            end
            row.icon = row.icon or meta.icon
        end
    end
    local rows = {}
    for _, row in pairs(byName) do rows[#rows + 1] = row end
    table.sort(rows, function(first, second)
        if (first.sets and 1 or 0) ~= (second.sets and 1 or 0) then return not first.sets end
        local firstAverage, secondAverage = first.sum / first.n, second.sum / second.n
        if firstAverage ~= secondAverage then return firstAverage > secondAverage end
        return first.name < second.name
    end)
    return rows
end

-- Breakdown of one ability (by name) under the filter: lists by rank, level, level difference,
-- outcome and stance, and its recent samples ({ id, sample }, newest first).
function Lab:Breakdown(name, filter)
    local by = { rank = {}, level = {}, diff = {}, outcome = {}, stance = {} }
    local ids = {}
    for _, aggregate in pairs(self.db.agg) do
        local meta = self.db.spells[aggregate.s] or {}
        if (meta.name or ("Spell " .. aggregate.s)) == name then
            ids[aggregate.s] = true
            local function Put(kind, key, sort)
                local totals = by[kind][key]
                if not totals then
                    totals = Empty({ key = key, sort = sort })
                    by[kind][key] = totals
                end
                Add(totals, aggregate)
            end
            if Matches(aggregate, filter) then
                Put("rank", meta.rank or ("#" .. aggregate.s), -aggregate.s)
                Put("level", aggregate.lv, aggregate.lv)
                Put("diff", aggregate.d or "?", type(aggregate.d) == "number" and aggregate.d or 100)
                Put("outcome", aggregate.o, MISSES[aggregate.o] and 1 or 0)
            end
            -- Stances regardless of the stance filter, to compare them.
            local any = {}
            for key, value in pairs(filter) do any[key] = value end
            any.stance = "any"
            if Matches(aggregate, any) then Put("stance", aggregate.st, 0) end
        end
    end
    local breakdown = {}
    for _, kind in ipairs({ "rank", "level", "diff", "outcome", "stance" }) do
        local list = {}
        for _, totals in pairs(by[kind]) do list[#list + 1] = totals end
        table.sort(list, function(first, second)
            if first.sort ~= second.sort then return first.sort < second.sort end
            return tostring(first.key) < tostring(second.key)
        end)
        breakdown[kind] = list
    end
    -- Recent samples of every rank, newest first.
    local recent = {}
    for id in pairs(ids) do
        for _, sample in ipairs(self.db.samples[id] or {}) do
            recent[#recent + 1] = { id = id, sample = sample }
        end
    end
    table.sort(recent, function(first, second) return (first.sample.at or 0) > (second.sample.at or 0) end)
    breakdown.recent = recent
    return breakdown
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
loader:SetScript("OnEvent", function(_, event, addonName)
    if event == "ADDON_LOADED" and addonName == ADDON then
        Lab:Load()
    elseif event == "PLAYER_LOGIN" then
        if not Lab.db then Lab:Load() end
        Lab:Init()
    end
end)
