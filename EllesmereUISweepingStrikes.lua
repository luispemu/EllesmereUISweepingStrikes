-------------------------------------------------------------------------------
--  EllesmereUISweepingStrikes
--  Standalone EllesmereUI plugin: shows Arms Warrior Sweeping Strikes charges
--  as the class resource bar -- exactly like Fury Whirlwind stacks pips in
--  EllesmereUIResourceBars -- WITHOUT modifying any core EllesmereUI file, so
--  it survives EllesmereUI updates.
--
--  How it slots in: EllesmereUIResourceBars creates and positions its
--  secondary/class-resource frame (ERB_SecondaryFrame) even for specs that
--  have no secondary resource (kept sized at zero alpha as an anchor target).
--  For Arms that slot is empty, so this plugin anchors its pips 1:1 onto that
--  frame and styles them from the "Class Resource Bar" options panel:
--  Width/Height, Border Size/Color, Bar Spacing (+ gap color), Empty Bar
--  Overlay (pip background), Opacity, Fill Color modes (dark theme /
--  resource colored / class colored / custom) and Resource Text.
--  Orientation is not supported (horizontal only). If ResourceBars is not
--  loaded, it falls back to a free draggable bar (/euiss unlock).
--
--  Mechanics (Midnight charge rework):
--    Sweeping Strikes (260708) grants 12 charges (18 with Improved Sweeping
--    Strikes 383155). Single-target damaging abilities consume 1 charge each
--    to strike an additional enemy within ~8 yd; a charge is only consumed
--    when a sweep partner is actually in range ("less waste" design).
--    Broad Strokes (1261049): Colossus Smash / Warbreaker also activate
--    Sweeping Strikes. Buff: 30 s duration, 30 s cooldown.
--    12.1: charges from the ability and Broad Strokes stack; we track only up
--    to the visual cap, so either source simply refreshes to max.
--
--  Tracking is manual via UNIT_SPELLCAST_SUCCEEDED (12.0+ secret-value safe,
--  same pattern as the core Whirlwind tracker) -- aura stack data can be
--  secret and the combat log is deliberately not used.
--
--  Slash: /euiss
-------------------------------------------------------------------------------

local ADDON_NAME = ...
local EUI = _G.EllesmereUI

local math_max = math.max

-------------------------------------------------------------------------------
--  Saved variables / defaults
-------------------------------------------------------------------------------
local DEFAULTS = {
    attach   = true,    -- ride the ERB class-resource slot when available
    -- Free-mode (detached / no ResourceBars) settings:
    point   = "CENTER", x = 0, y = -260,
    scale   = 1,
    width   = 214,      -- matches EllesmereUIResourceBars default pip row width
    height  = 20,       -- matches default pip height
    mode    = "smart",  -- free mode only: "always" | "combat" | "smart"
    -- Shared (each *Custom=false follows the Class Resource Bar options):
    spacing = 1,
    spacingCustom = false,
    showText = false,
    textCustom = false,
    colorCustom = false,
    color   = { r = 0.8510, g = 0.4157, b = 0.3373 },
}

local db

local function InitDB()
    EllesmereUISweepingStrikesDB = EllesmereUISweepingStrikesDB or {}
    db = EllesmereUISweepingStrikesDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then
            if type(v) == "table" then
                local t = {}
                for k2, v2 in pairs(v) do t[k2] = v2 end
                db[k] = t
            else
                db[k] = v
            end
        end
    end
    -- Attached size always follows the Class Resource Bar Width/Height
    -- options via the slot anchors; the old sizeMode setting is obsolete.
    db.sizeMode = nil
end

-------------------------------------------------------------------------------
--  Sweeping Strikes charge tracker (self-contained)
-------------------------------------------------------------------------------
local GetSweepingStrikes, HandleSweepingStrikes, RefreshSpellKnown
do
    local stacks, expiresAt = 0, nil
    local BASE_MAX     = 12
    local IMPROVED_MAX = 18
    local DURATION = 30
    local SWEEP    = 260708
    local IMPROVED = 383155   -- Improved Sweeping Strikes: 12 -> 18 charges
    local BROAD    = 1261049  -- Broad Strokes: Colossus Smash activates Sweep

    local FERVOR = 202316  -- Fervor of Battle: Cleave/WW on 3+ targets also Slams

    -- IsSpellKnown results cached: GetSweepingStrikes is polled every 0.1 s
    -- by the bar's OnUpdate, and talents can't change mid-combat anyway.
    -- Refreshed on spec/talent/world events (RefreshSpellKnown).
    local sweepKnown, improvedKnown, broadKnown, fervorKnown = false, false, false, false

    function RefreshSpellKnown()
        local sb = C_SpellBook
        sweepKnown    = (sb and sb.IsSpellKnown(SWEEP)) or false
        improvedKnown = (sb and sb.IsSpellKnown(IMPROVED)) or false
        broadKnown    = (sb and sb.IsSpellKnown(BROAD)) or false
        fervorKnown   = (sb and sb.IsSpellKnown(FERVOR)) or false
    end

    local function MaxStacks()
        return improvedKnown and IMPROVED_MAX or BASE_MAX
    end

    -- Broad Strokes generators (only count with the talent known)
    local CS_GENERATORS = {
        [167105] = true,  -- Colossus Smash
        [262161] = true,  -- Warbreaker (replaces Colossus Smash)
    }

    -- Single-target damaging cast IDs whose damage effects sit in the
    -- Sweeping Strikes affected-spells list (wowhead spell=260708), mapped
    -- to how many charges each cast consumes.
    -- Rend and Storm Bolt do NOT sweep and are deliberately absent.
    local SPENDERS = {
        [12294]   = 1,  -- Mortal Strike
        [7384]    = 1,  -- Overpower
        [1464]    = 1,  -- Slam
        [163201]  = 1,  -- Execute (Arms)
        [5308]    = 1,  -- Execute (base)
        [260643]  = 1,  -- Skullsplitter
        [34428]   = 1,  -- Victory Rush
        [202168]  = 1,  -- Impending Victory
        [1715]    = 1,  -- Hamstring
        [1269383] = 1,  -- Heroic Strike (Midnight, replaces Slam)
        [436358]  = 2,  -- Demolish: the channel sweeps twice (damage IDs
                        -- 440884/440886) -- confirmed in-game, 2 per cast
    }

    -- Fervor of Battle: the triggered Slam happens on Cleave/Whirlwind casts
    local FOB_TRIGGERS = {
        [1680] = true,  -- Whirlwind (Arms)
        [845]  = true,  -- Cleave
    }
    local fobWindow = 0  -- suppress a possibly-echoed Slam cast event

    -- Deduplicate cast events via GUID (mirrors the core Whirlwind tracker)
    local seenGUID = {}
    local guidCount = 0

    -- A charge is only consumed when the strike can sweep onto a second
    -- enemy (~8 yd). Count the hostile target plus enemy nameplates inside
    -- the index-2 interact probe (~11 yd, slightly generous; same probe the
    -- core Whirlwind tracker uses). `need` = how many enemies must be in
    -- reach (2 for a sweep partner, 3 for a Fervor of Battle trigger).
    -- NOTE: relies on enemy nameplates showing for off-target enemies.
    local function EnemiesInReach(need)
        local function InReach(u)
            if not (UnitExists(u) and UnitCanAttack("player", u) and not UnitIsDead(u)) then
                return false
            end
            return CheckInteractDistance(u, 2) or false
        end
        local count, targetPlated = 0, false
        for i = 1, 40 do
            local u = "nameplate" .. i
            if InReach(u) then
                count = count + 1
                if UnitIsUnit(u, "target") then targetPlated = true end
                if count >= need then return true end
            end
        end
        -- Target without a visible nameplate still counts as one body
        if not targetPlated and InReach("target") then count = count + 1 end
        return count >= need
    end

    function HandleSweepingStrikes(event, unit, castGUID, spellID)
        if event == "PLAYER_DEAD" or event == "PLAYER_ALIVE" then
            stacks, expiresAt = 0, nil
            fobWindow = 0
            wipe(seenGUID)
            guidCount = 0
            return
        end
        if event == "PLAYER_REGEN_ENABLED" then
            -- Clean up GUID cache on combat end to prevent unbounded growth
            wipe(seenGUID)
            guidCount = 0
            return
        end
        if event ~= "UNIT_SPELLCAST_SUCCEEDED" or unit ~= "player" then return end
        if not sweepKnown then return end

        if castGUID and seenGUID[castGUID] then return end
        if castGUID then
            seenGUID[castGUID] = true
            guidCount = guidCount + 1
            -- Safety: flush if table grows too large (shouldn't happen normally)
            if guidCount > 200 then wipe(seenGUID); guidCount = 0 end
        end

        if spellID == SWEEP
           or (CS_GENERATORS[spellID] and broadKnown) then
            stacks = MaxStacks()
            expiresAt = GetTime() + DURATION
        elseif FOB_TRIGGERS[spellID] and fervorKnown and stacks > 0 then
            -- Fervor of Battle: Cleave/Whirlwind hitting 3+ targets also
            -- Slams your primary target; that Slam sweeps and consumes a
            -- charge. The trigger itself is not a player cast event, so it
            -- is counted here off the Cleave/WW cast, gated on 3 enemies in
            -- reach (with 3+ up, a sweep partner necessarily exists).
            if not EnemiesInReach(3) then return end
            fobWindow = GetTime() + 0.3
            stacks = math_max(0, stacks - 1)
            if stacks == 0 then expiresAt = nil end
        elseif SPENDERS[spellID] and stacks > 0 then
            -- If the game echoes the Fervor-of-Battle Slam as a real cast
            -- event, skip it -- the charge was already counted above. A
            -- player-pressed Slam can't land inside the 0.3 s window (GCD).
            if spellID == 1464 and GetTime() < fobWindow then return end
            -- No sweep partner in range -> the game doesn't consume a charge
            if not EnemiesInReach(2) then return end
            stacks = math_max(0, stacks - SPENDERS[spellID])
            if stacks == 0 then expiresAt = nil end
        end
    end

    function GetSweepingStrikes()
        if not sweepKnown then return 0, 0 end
        if expiresAt and GetTime() >= expiresAt then
            stacks, expiresAt = 0, nil
        end
        return stacks, MaxStacks()
    end
end

-------------------------------------------------------------------------------
--  Helpers
-------------------------------------------------------------------------------
local ARMS_SPEC_ID = 71
local isArms = false
local inCombat = false
local unlocked = false
local attached = false   -- currently anchored onto ERB_SecondaryFrame

-- Combat/cast events are only registered while the active spec is Arms;
-- on any other warrior spec the addon sits idle on just the spec/world
-- events. (Non-warriors shut the whole addon down at load, see
-- ADDON_LOADED.) Assigned after the event frame exists.
local UpdateEventRegistration

local function RefreshSpec()
    local spec = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization()
    local specID = spec and C_SpecializationInfo.GetSpecializationInfo(spec)
    isArms = (specID == ARMS_SPEC_ID)
    if UpdateEventRegistration then UpdateEventRegistration() end
end

-- ERB "Class Resource" profile section (nil if ResourceBars not loaded).
-- _ERB_AceDB is intentionally exposed globally by EllesmereUIResourceBars
-- (the core nameplate/unitframe modules read it the same way).
local function GetERBSecondaryCfg()
    local adb = _G._ERB_AceDB
    return adb and adb.profile and adb.profile.secondary or nil
end

-- Fill color: mirror the Resource Bars "Class Resource" Fill Color options
-- exactly (same priority as ERB's UpdateSecondaryResource):
--   dark theme > Class Resource Color > class colored > custom fill color.
-- "SWEEPING_STRIKES" has no per-resource color in core, so the resource-color
-- mode falls back to the class color, just like ERB does for unknown types.
-- Reused result table: GetColor runs on the 0.1 s poll, so it must not
-- allocate (same discipline as the core's cached-spec-ID comment).
local _colorScratch = {}
local function _CS(r, g, b)
    _colorScratch.r, _colorScratch.g, _colorScratch.b = r, g, b
    return _colorScratch
end

local function GetColor()
    if db and db.colorCustom and db.color then
        local c = db.color
        return _CS(c.r, c.g, c.b)
    end
    local sp = GetERBSecondaryCfg()
    if sp and EUI then
        if sp.darkTheme and EUI.GetDarkModeFill then
            local r, g, b = EUI.GetDarkModeFill()
            if r then return _CS(r, g, b) end
        elseif sp.resourceColored then
            local c = EUI.GetClassResourceColor and EUI.GetClassResourceColor("SweepingStrikes")
            if c then return _CS(c.r, c.g, c.b) end
            c = EUI.GetClassColor and EUI.GetClassColor("WARRIOR")
            if c then return _CS(c.r, c.g, c.b) end
        elseif sp.classColored ~= false then
            local c = EUI.GetClassColor and EUI.GetClassColor("WARRIOR")
            if c then return _CS(c.r, c.g, c.b) end
        elseif sp.fillR then
            return _CS(sp.fillR, sp.fillG or 1, sp.fillB or 1)
        end
    end
    -- Prefer a core-defined color if a future EllesmereUI version adds one
    if EUI and EUI.GetClassResourceColor then
        local c = EUI.GetClassResourceColor("SweepingStrikes")
        if c then return _CS(c.r, c.g, c.b) end
    end
    local c = (db and db.color) or DEFAULTS.color
    return _CS(c.r, c.g, c.b)
end

-- Visual style pulled from the "Class Resource Bar" options panel when
-- attached (all keys defensive so a core rename degrades to defaults):
--   pip bg      = Empty Bar Overlay (bgR/G/B/A; dark theme -> opaque dark)
--   spacing     = Bar Spacing (pipSpacing) + gap color (gapR/G/B/A)
--   bar bg      = full-bar background behind pips (barBgR/G/B/A)
--   border      = Border Size + color (borderSize, borderR/G/B/A; solid only)
--   alpha       = Opacity (barAlpha)
--   text        = Resource Text (showText, textSize, text color)
-- Reused result table: GetStyle runs on the 0.1 s poll -- no allocations.
local _styleScratch = {}
local function GetStyle()
    local st = _styleScratch
    st.bgR, st.bgG, st.bgB, st.bgA = 0x11 / 255, 0x11 / 255, 0x11 / 255, 0.75
    st.spacing = (db and db.spacingCustom and db.spacing) or 1
    st.gapEnabled = false  -- opt-in "Bar Spacing" color (gapColorEnabled)
    st.gapR, st.gapG, st.gapB, st.gapA = 0, 0, 0, 1
    st.barBgR, st.barBgG, st.barBgB, st.barBgA = 0, 0, 0, 0.5
    st.borderSize, st.borderR, st.borderG, st.borderB, st.borderA = 1, 0, 0, 0, 1
    st.alpha = 1
    st.showText = (db and db.showText) or false
    st.textSize, st.textR, st.textG, st.textB, st.textA = 11, 1, 1, 1, 1
    local sp = attached and GetERBSecondaryCfg() or nil
    if sp then
        if sp.bgR ~= nil then
            st.bgR, st.bgG, st.bgB = sp.bgR, sp.bgG or st.bgG, sp.bgB or st.bgB
            st.bgA = sp.bgA or st.bgA
        end
        if not (db and db.spacingCustom) and sp.pipSpacing ~= nil then
            st.spacing = sp.pipSpacing
        end
        st.gapEnabled = not not sp.gapColorEnabled
        st.gapR, st.gapG, st.gapB = sp.gapR or 0, sp.gapG or 0, sp.gapB or 0
        st.gapA = sp.gapA or 1
        st.barBgR, st.barBgG, st.barBgB = sp.barBgR or 0, sp.barBgG or 0, sp.barBgB or 0
        st.barBgA = sp.barBgA or 0.5
        st.borderSize = sp.borderSize or 1
        st.borderR, st.borderG, st.borderB = sp.borderR or 0, sp.borderG or 0, sp.borderB or 0
        st.borderA = sp.borderA or 1
        st.alpha = sp.barAlpha or 1
        if not (db and db.textCustom) then st.showText = not not sp.showText end
        st.textSize = sp.textSize or 11
        if sp.textR ~= nil then
            st.textR, st.textG, st.textB = sp.textR, sp.textG or 1, sp.textB or 1
        end
        if sp.darkTheme then
            -- Dark theme: opaque dark pips over a solid black gap/background,
            -- same as ERB's dark-theme pip rows.
            if EUI and EUI.GetDarkModeBg then
                local dr, dg, dbb = EUI.GetDarkModeBg()
                if dr then st.bgR, st.bgG, st.bgB, st.bgA = dr, dg, dbb, 1 end
            end
            st.gapR, st.gapG, st.gapB, st.gapA = 0, 0, 0, 1
            st.barBgR, st.barBgG, st.barBgB, st.barBgA = 0, 0, 0, 1
        end
    end
    return st
end

local function GetFont()
    if EUI and EUI.GetFontPath then
        local ok, path = pcall(EUI.GetFontPath, "resourcebars")
        if ok and type(path) == "string" then return path end
    end
    return "Fonts\\FRIZQT__.TTF"
end

local function Print(msg)
    print("|cff0cd29fEllesmereUI|r Sweeping Strikes: " .. msg)
end

-------------------------------------------------------------------------------
--  Bar UI
-------------------------------------------------------------------------------
local bar
local pips = {}
local gaps = {}
local countText
local dragOverlay

local function SavePosition()
    local point, _, _, x, y = bar:GetPoint()
    db.point, db.x, db.y = point or "CENTER", x or 0, y or 0
end

-- Cover the ERB class-resource slot corner-to-corner: the slot frame is
-- sized by ResourceBars from the Class Resource Bar Width/Height options and
-- positioned by its movers, so the bar always matches the default resource
-- bar dimensions and placement with zero polling -- the anchors track both.
-- The slot frame exists (sized, zero-alpha) even for specs without a
-- secondary resource, and the parent main frame carries ERB's combat-fade
-- alpha, so visibility behavior is inherited too.
local function TryAttach()
    if not (db and db.attach) then return false end
    local main = _G.EllesmereUIResourceBarsFrame
    local slot = _G.ERB_SecondaryFrame
    if not (main and slot) then return false end
    bar:SetParent(main)
    bar:SetFrameStrata(slot:GetFrameStrata() or "MEDIUM")
    bar:SetFrameLevel((slot:GetFrameLevel() or 10) + 1)
    bar:SetScale(1)
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", slot, "TOPLEFT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", 0, 0)
    bar:EnableMouse(false)
    attached = true
    return true
end

local function ApplyFreePosition()
    attached = false
    bar:SetParent(UIParent)
    bar:SetFrameStrata("MEDIUM")
    bar:ClearAllPoints()
    bar:SetPoint(db.point or "CENTER", UIParent, db.point or "CENTER", db.x or 0, db.y or 0)
    bar:SetScale(db.scale or 1)
    bar:SetSize(db.width, db.height)
end

local function ApplyPosition()
    if not TryAttach() then ApplyFreePosition() end
end

-- Full-bar chrome: background behind the pips (shows through the gaps) and a
-- solid pixel border wrapping the bar, mirroring ERB's _barBg/_barBorder.
-- Border textures live on a child frame raised above the pip fills, like
-- ERB's default (non-"Show Behind") border.
local function ApplyChrome(st)
    if not bar._barBg then
        bar._barBg = bar:CreateTexture(nil, "BACKGROUND", nil, -1)
        bar._barBg:SetAllPoints(bar)
    end
    bar._barBg:SetColorTexture(st.barBgR, st.barBgG, st.barBgB, st.barBgA)

    if not bar._borderFrame then
        bar._borderFrame = CreateFrame("Frame", nil, bar)
        bar._borderFrame:SetAllPoints(bar)
        bar._borderT = {}
        for i = 1, 4 do
            bar._borderT[i] = bar._borderFrame:CreateTexture(nil, "OVERLAY")
        end
    end
    bar._borderFrame:SetFrameLevel(bar:GetFrameLevel() + 5)
    local bs = st.borderSize or 0
    local t = bar._borderT
    if bs <= 0 or st.borderA <= 0 then
        for i = 1, 4 do t[i]:Hide() end
        return
    end
    -- INSIDE the frame edges, like EllesmereUI's pixel borders (PP.CreateBorder):
    -- the border overlays the outermost pixels of the pips, so the bar's
    -- visual footprint equals the frame size exactly -- no 1px overhang.
    local T, B, L, R = t[1], t[2], t[3], t[4]
    T:ClearAllPoints()
    T:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    T:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, 0)
    T:SetHeight(bs)
    B:ClearAllPoints()
    B:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    B:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    B:SetHeight(bs)
    L:ClearAllPoints()
    L:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -bs)
    L:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, bs)
    L:SetWidth(bs)
    R:ClearAllPoints()
    R:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, -bs)
    R:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, bs)
    R:SetWidth(bs)
    for i = 1, 4 do
        t[i]:SetColorTexture(st.borderR, st.borderG, st.borderB, st.borderA)
        t[i]:Show()
    end
end

local function LayoutPips(maxC)
    if not maxC or maxC <= 0 then maxC = 12 end
    local W = attached and bar:GetWidth() or db.width
    local H = attached and bar:GetHeight() or db.height
    if not W or W <= 0 then W = db.width end
    if not H or H <= 0 then H = db.height end
    local st = GetStyle()
    local S = st.spacing
    if not attached then bar:SetSize(W, H) end
    local pipW = (W - (maxC - 1) * S) / maxC
    if pipW < 1 then pipW = 1 end

    for i = 1, maxC do
        local pip = pips[i]
        if not pip then
            pip = CreateFrame("Frame", nil, bar)
            pip._bg = pip:CreateTexture(nil, "BACKGROUND")
            pip._bg:SetAllPoints(pip)
            pip._fill = pip:CreateTexture(nil, "ARTWORK")
            pip._fill:SetAllPoints(pip)
            pip._fill:SetTexture("Interface\\Buttons\\WHITE8X8")
            pips[i] = pip
        end
        pip._bg:SetColorTexture(st.bgR, st.bgG, st.bgB, st.bgA)
        pip:ClearAllPoints()
        pip:SetPoint("TOPLEFT", bar, "TOPLEFT", (i - 1) * (pipW + S), 0)
        pip:SetSize(pipW, H)
        pip:Show()
    end
    for i = maxC + 1, #pips do pips[i]:Hide() end

    -- Gap fills between pips (opt-in "Bar Spacing" color; when off the
    -- full-bar background shows through the spacing, same as ERB)
    for i = 1, maxC - 1 do
        local gap = gaps[i]
        if st.gapEnabled and S > 0 then
            if not gap then
                gap = bar:CreateTexture(nil, "BACKGROUND", nil, 0)
                gaps[i] = gap
            end
            gap:SetColorTexture(st.gapR, st.gapG, st.gapB, st.gapA)
            gap:ClearAllPoints()
            gap:SetPoint("TOPLEFT", bar, "TOPLEFT", i * pipW + (i - 1) * S, 0)
            gap:SetSize(S, H)
            gap:Show()
        elseif gap then
            gap:Hide()
        end
    end
    for i = math_max(maxC, 1), #gaps do if gaps[i] then gaps[i]:Hide() end end

    ApplyChrome(st)
    bar._pipCount = maxC
end

local function UpdateBar()
    if not bar then return end
    local cur, maxC = GetSweepingStrikes()

    -- Visibility. Attached: mirror the real resource bar -- always rendered
    -- for the spec (empty pips and all, exactly like Fury's Whirlwind bar);
    -- ERB's own combat-fade / visibility settings apply via the parent frame.
    local show
    if unlocked then
        show = true
    elseif not isArms or maxC <= 0 then
        show = false
    elseif attached then
        local sp = GetERBSecondaryCfg()
        show = not (sp and sp.enabled == false)  -- respect "Show Class Resource"
    elseif db.mode == "always" then
        show = true
    elseif db.mode == "combat" then
        show = inCombat
    else -- smart
        show = inCombat or cur > 0
    end

    if not show then
        bar:Hide()
        return
    end
    if not bar:IsShown() then bar:Show() end

    -- Rebuild pips if the cap changed (12 <-> 18) or never built
    local pipMax = (maxC > 0) and maxC or 12
    if bar._pipCount ~= pipMax then LayoutPips(pipMax) end

    -- Unlock preview: show a full bar so it's easy to position
    if unlocked and maxC <= 0 then cur, maxC = 12, 12 end
    if unlocked and cur == 0 then cur = maxC end

    -- Dirty check: this runs on a 0.1 s poll, but charges/styles change far
    -- less often. Compare against the last applied state and bail before
    -- touching any widget -- an idle tick is then pure number comparisons
    -- with zero allocations and zero C calls.
    local st = GetStyle()
    local c = GetColor()
    local L = bar._last
    if L
       and L.cur == cur and L.maxC == maxC and L.unlocked == unlocked
       and L.cr == c.r and L.cg == c.g and L.cb == c.b
       and L.bgR == st.bgR and L.bgG == st.bgG and L.bgB == st.bgB and L.bgA == st.bgA
       and L.gapEnabled == st.gapEnabled
       and L.gapR == st.gapR and L.gapG == st.gapG and L.gapB == st.gapB and L.gapA == st.gapA
       and L.barBgR == st.barBgR and L.barBgG == st.barBgG and L.barBgB == st.barBgB and L.barBgA == st.barBgA
       and L.borderSize == st.borderSize
       and L.borderR == st.borderR and L.borderG == st.borderG and L.borderB == st.borderB and L.borderA == st.borderA
       and L.alpha == st.alpha and L.spacing == st.spacing
       and L.showText == st.showText and L.textSize == st.textSize
       and L.textR == st.textR and L.textG == st.textG and L.textB == st.textB then
        return
    end
    if not L then L = {}; bar._last = L end
    local geoDirty = L.spacing ~= st.spacing or L.borderSize ~= st.borderSize
                     or L.gapEnabled ~= st.gapEnabled
    L.cur, L.maxC, L.unlocked = cur, maxC, unlocked
    L.cr, L.cg, L.cb = c.r, c.g, c.b
    L.bgR, L.bgG, L.bgB, L.bgA = st.bgR, st.bgG, st.bgB, st.bgA
    L.gapEnabled = st.gapEnabled
    L.gapR, L.gapG, L.gapB, L.gapA = st.gapR, st.gapG, st.gapB, st.gapA
    L.barBgR, L.barBgG, L.barBgB, L.barBgA = st.barBgR, st.barBgG, st.barBgB, st.barBgA
    L.borderSize = st.borderSize
    L.borderR, L.borderG, L.borderB, L.borderA = st.borderR, st.borderG, st.borderB, st.borderA
    L.alpha, L.spacing = st.alpha, st.spacing
    L.showText, L.textSize = st.showText, st.textSize
    L.textR, L.textG, L.textB = st.textR, st.textG, st.textB

    -- Spacing/border/gap-mode changes move things: full re-layout
    if geoDirty then LayoutPips(bar._pipCount) end

    bar:SetAlpha(st.alpha or 1)

    for i = 1, bar._pipCount do
        local pip = pips[i]
        pip._bg:SetColorTexture(st.bgR, st.bgG, st.bgB, st.bgA)
        pip._fill:SetVertexColor(c.r, c.g, c.b, 1)
        if i <= cur then pip._fill:Show() else pip._fill:Hide() end
    end
    for i = 1, #gaps do
        if gaps[i] and gaps[i]:IsShown() then
            gaps[i]:SetColorTexture(st.gapR, st.gapG, st.gapB, st.gapA)
        end
    end
    ApplyChrome(st)

    if st.showText then
        -- SetFont invalidates the font object; only touch it when the
        -- size actually changed (font path changes require a /reload).
        if countText._size ~= st.textSize then
            countText:SetFont(GetFont(), st.textSize or 11, "OUTLINE")
            countText._size = st.textSize
        end
        countText:SetTextColor(st.textR, st.textG, st.textB, st.textA)
        countText:SetFormattedText("%d / %d", cur, maxC)
        countText:Show()
    else
        countText:Hide()
    end

    if unlocked and not attached then
        dragOverlay:Show(); bar._dragLabel:Show()
    else
        dragOverlay:Hide(); bar._dragLabel:Hide()
    end
end

local function BuildBar()
    if bar then return end
    bar = CreateFrame("Frame", "EllesmereUISweepingStrikesBar", UIParent)
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function(self)
        if unlocked and not attached then self:StartMoving() end
    end)
    bar:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    -- Attached mode: the slot/power bar resizes with profile/options changes;
    -- follow it by re-laying pips out whenever our anchored size changes.
    bar:SetScript("OnSizeChanged", function()
        if attached then
            LayoutPips(bar._pipCount or 12)
        end
    end)

    -- Count text parented above pip fills and border
    local textOverlay = CreateFrame("Frame", nil, bar)
    textOverlay:SetAllPoints(bar)
    textOverlay:SetFrameLevel(bar:GetFrameLevel() + 7)
    countText = textOverlay:CreateFontString(nil, "OVERLAY")
    countText:SetFont(GetFont(), 10, "OUTLINE")
    countText:SetPoint("CENTER", bar, "CENTER", 0, 0)
    countText:Hide()

    -- Unlock-mode overlay (free mode only)
    dragOverlay = bar:CreateTexture(nil, "OVERLAY", nil, 7)
    dragOverlay:SetAllPoints(bar)
    dragOverlay:SetColorTexture(0.05, 0.82, 0.62, 0.35)
    dragOverlay:Hide()
    bar._dragLabel = bar:CreateFontString(nil, "OVERLAY")
    bar._dragLabel:SetFont(GetFont(), 10, "OUTLINE")
    bar._dragLabel:SetPoint("BOTTOM", bar, "TOP", 0, 3)
    bar._dragLabel:SetText("Sweeping Strikes — drag to move, /euiss lock")
    bar._dragLabel:Hide()

    ApplyPosition()
    LayoutPips(12)
    bar:Hide()
end

local function RefreshAll()
    RefreshSpellKnown()
    RefreshSpec()
    if bar then
        ApplyPosition()
        LayoutPips(select(2, GetSweepingStrikes()))
    end
    UpdateBar()
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= ADDON_NAME then return end
        f:UnregisterEvent("ADDON_LOADED")

        -- Warrior-only: on any other class the addon shuts down completely
        -- (no saved vars, no frames, no events -- effectively not loaded).
        local _, playerClass = UnitClass("player")
        if playerClass ~= "WARRIOR" then
            f:UnregisterAllEvents()
            f:SetScript("OnEvent", nil)
            return
        end

        InitDB()
        BuildBar()

        f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
        f:RegisterEvent("PLAYER_ENTERING_WORLD")
        f:RegisterEvent("TRAIT_CONFIG_UPDATED")
        f:RegisterEvent("PLAYER_TALENT_UPDATE")

        -- Combat/cast tracking only while the active spec is Arms; Fury and
        -- Protection sessions keep just the four cheap events above.
        local castEventsOn = false
        UpdateEventRegistration = function()
            if isArms == castEventsOn then return end
            castEventsOn = isArms
            if isArms then
                f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
                f:RegisterEvent("PLAYER_DEAD")
                f:RegisterEvent("PLAYER_ALIVE")
                f:RegisterEvent("PLAYER_REGEN_ENABLED")
                f:RegisterEvent("PLAYER_REGEN_DISABLED")
                inCombat = UnitAffectingCombat("player") or false
            else
                f:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
                f:UnregisterEvent("PLAYER_DEAD")
                f:UnregisterEvent("PLAYER_ALIVE")
                f:UnregisterEvent("PLAYER_REGEN_ENABLED")
                f:UnregisterEvent("PLAYER_REGEN_DISABLED")
                -- Leaving Arms invalidates the manual tracker state
                HandleSweepingStrikes("PLAYER_DEAD")
            end
        end

        -- Expiry poll: the 30 s buff can run out with no event firing.
        -- OnUpdate lives on the bar so it only ticks while visible. Also
        -- follows live size changes and Class Resource Bar option edits.
        local elapsed = 0
        bar:SetScript("OnUpdate", function(_, dt)
            elapsed = elapsed + dt
            if elapsed < 0.1 then return end
            elapsed = 0
            -- Self-heal: if we should be riding the ERB slot but aren't
            -- (late load, profile swap re-created frames), re-attach.
            if db.attach and not attached then
                if TryAttach() then LayoutPips(bar._pipCount or 12) end
            end
            UpdateBar()
        end)
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...
        if unit == "player" then
            HandleSweepingStrikes(event, unit, castGUID, spellID)
            UpdateBar()
        end
    elseif event == "PLAYER_DEAD" or event == "PLAYER_ALIVE" then
        HandleSweepingStrikes(event)
        UpdateBar()
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        HandleSweepingStrikes(event)
        UpdateBar()
    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        UpdateBar()
    elseif event == "PLAYER_ENTERING_WORLD" then
        RefreshSpellKnown()
        RefreshSpec()
        UpdateBar()
        -- ERB builds its frames ~0.5 s after PLAYER_ENTERING_WORLD; attach
        -- once they exist (retry a few times to be safe on slow loads).
        local tries = 0
        local function AttachTick()
            tries = tries + 1
            if TryAttach() then
                RefreshAll()
            elseif tries < 10 and db.attach then
                C_Timer.After(0.5, AttachTick)
            end
        end
        C_Timer.After(0.7, AttachTick)
    else
        -- PLAYER_SPECIALIZATION_CHANGED / TRAIT_CONFIG_UPDATED /
        -- PLAYER_TALENT_UPDATE
        RefreshAll()
    end
end)

-------------------------------------------------------------------------------
--  Slash commands
-------------------------------------------------------------------------------
SLASH_EUISWEEPINGSTRIKES1 = "/euiss"
SLASH_EUISWEEPINGSTRIKES2 = "/sweepingstrikes"
SlashCmdList["EUISWEEPINGSTRIKES"] = function(msg)
    if not db then
        Print("Arms Warrior only — the addon is inactive on this character")
        return
    end
    msg = (msg or ""):lower()
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")

    if cmd == "attach" then
        db.attach = true
        if TryAttach() then
            RefreshAll()
            Print("attached to the EllesmereUI class-resource slot — styled by the Class Resource Bar options")
        else
            Print("Resource Bars frames not found yet — will attach automatically when they exist")
        end
    elseif cmd == "detach" then
        db.attach = false
        ApplyFreePosition()
        RefreshAll()
        Print("detached — free bar; /euiss unlock to move it")
    elseif cmd == "unlock" then
        if attached then
            Print("bar is attached to the resource bar slot — move it via EllesmereUI's unlock (Class Resource), or /euiss detach first")
            return
        end
        unlocked = true
        bar:EnableMouse(true)
        UpdateBar()
        Print("unlocked — drag the bar, then /euiss lock")
    elseif cmd == "lock" then
        unlocked = false
        bar:EnableMouse(false)
        UpdateBar()
        Print("locked")
    elseif cmd == "reset" then
        db.point, db.x, db.y, db.scale = DEFAULTS.point, DEFAULTS.x, DEFAULTS.y, DEFAULTS.scale
        db.width, db.height, db.spacing = DEFAULTS.width, DEFAULTS.height, DEFAULTS.spacing
        db.spacingCustom, db.textCustom, db.colorCustom = false, false, false
        db.attach = true
        RefreshAll()
        Print("settings reset")
    elseif cmd == "scale" then
        local n = tonumber(rest)
        if n and n > 0.2 and n <= 3 then db.scale = n; RefreshAll(); Print("scale " .. n .. (attached and " (only used when detached)" or ""))
        else Print("usage: /euiss scale 0.5–3") end
    elseif cmd == "width" then
        local n = tonumber(rest)
        if n and n >= 50 and n <= 800 then db.width = n; RefreshAll(); Print("width " .. n .. (attached and " (only used when detached)" or ""))
        else Print("usage: /euiss width 50–800") end
    elseif cmd == "height" then
        local n = tonumber(rest)
        if n and n >= 4 and n <= 100 then db.height = n; RefreshAll(); Print("height " .. n .. (attached and " (only used when detached)" or ""))
        else Print("usage: /euiss height 4–100") end
    elseif cmd == "spacing" then
        if rest == "default" then
            db.spacingCustom = false
            RefreshAll()
            Print("spacing follows the Class Resource Bar setting again")
        else
            local n = tonumber(rest)
            if n and n >= 0 and n <= 20 then
                db.spacing = n
                db.spacingCustom = true
                RefreshAll()
                Print("spacing " .. n)
            else
                Print("usage: /euiss spacing 0–20, or /euiss spacing default")
            end
        end
    elseif cmd == "text" then
        if rest == "default" then
            db.textCustom = false
            UpdateBar()
            Print("count text follows the Resource Text option again")
        elseif rest == "on" or rest == "off" then
            db.showText = (rest == "on")
            db.textCustom = true
            UpdateBar()
            Print("count text " .. rest)
        else
            Print("usage: /euiss text on | off | default")
        end
    elseif cmd == "mode" then
        if rest == "always" or rest == "combat" or rest == "smart" then
            db.mode = rest
            UpdateBar()
            Print("visibility mode: " .. rest .. (attached and " (only used when detached; attached mode follows Resource Bars visibility)" or ""))
        else
            Print("usage: /euiss mode always | combat | smart")
        end
    elseif cmd == "color" then
        if rest == "default" then
            db.colorCustom = false
            UpdateBar()
            Print("color follows the Fill Color options again")
        else
            local r, g, b = rest:match("^([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)$")
            r, g, b = tonumber(r), tonumber(g), tonumber(b)
            if r and g and b then
                -- Accept 0-255 input too
                if r > 1 or g > 1 or b > 1 then r, g, b = r / 255, g / 255, b / 255 end
                db.color = { r = r, g = g, b = b }
                db.colorCustom = true
                UpdateBar()
                Print(("color set to %.2f %.2f %.2f"):format(r, g, b))
            else
                Print("usage: /euiss color <r> <g> <b>  (0–1 or 0–255), or /euiss color default")
            end
        end
    else
        Print("commands:  (bar is " .. (attached and "ATTACHED to the class-resource slot" or "DETACHED / free") .. ")")
        print("  attached mode is styled by the Class Resource Bar options panel;")
        print("  the /euiss overrides below win until you set them back to 'default'.")
        print("  /euiss attach | detach     — ride the EllesmereUI class-resource slot, or float free")
        print("  /euiss text on|off|default — show 7 / 12 counter")
        print("  /euiss spacing <n>|default — gap between pips")
        print("  /euiss color <r> <g> <b> | color default")
        print("  detached only: /euiss unlock | lock | reset | scale <n> | width <n> | height <n> | mode always|combat|smart")
    end
end
