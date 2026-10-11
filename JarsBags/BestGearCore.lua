-- BestGearCore.lua
-- Shared gear-scoring and equip-plan engine.
-- Loaded by JarsBags; BestGear declares it as a dependency so it can piggyback.
-- All symbols live in the BestGearCore global table — no addon-local namespace leakage.

BestGearCore = BestGearCore or {}
local Core = BestGearCore

---------------------------------------------------------------------------
-- Scoring modes
---------------------------------------------------------------------------

Core.MODES = {
    { key = "ILVL",    label = "iLvl"       },
    { key = "HASTE",   label = "Haste"      },
    { key = "CRIT",    label = "Crit"       },
    { key = "MASTERY", label = "Mastery"    },
    { key = "VERS",    label = "Vers"       },
}

Core.MODE_BY_KEY = {}
Core.MODE_LABELS = {}
for _, m in ipairs(Core.MODES) do
    Core.MODE_BY_KEY[m.key] = m
    Core.MODE_LABELS[m.key] = m.label
end

-- English substrings used to match stat values out of tooltip lines.
Core.STAT_TEXT = {
    HASTE   = "Haste",
    CRIT    = "Critical Strike",
    MASTERY = "Mastery",
    VERS    = "Versatility",
}

---------------------------------------------------------------------------
-- Slot mappings
---------------------------------------------------------------------------

-- INVTYPE → single inventory slot ID.
-- Dual-slot types (rings/trinkets) are absent — handled via DUAL_INVTYPES.
Core.INVTYPE_TO_SLOT = {
    INVTYPE_HEAD           = 1,
    INVTYPE_NECK           = 2,
    INVTYPE_SHOULDER       = 3,
    INVTYPE_CHEST          = 5,
    INVTYPE_ROBE           = 5,
    INVTYPE_WAIST          = 6,
    INVTYPE_LEGS           = 7,
    INVTYPE_FEET           = 8,
    INVTYPE_WRIST          = 9,
    INVTYPE_HAND           = 10,
    INVTYPE_CLOAK          = 15,
    INVTYPE_2HWEAPON       = 16,
    INVTYPE_WEAPONMAINHAND = 16,
    INVTYPE_WEAPON         = 16,
    INVTYPE_RANGED         = 16,
    INVTYPE_RANGEDRIGHT    = 16,
    INVTYPE_WEAPONOFFHAND  = 17,
    INVTYPE_SHIELD         = 17,
    INVTYPE_HOLDABLE       = 17,
}

-- INVTYPE → list of possible slot IDs (used when building equip plans).
Core.INVTYPE_TO_SLOTS = {
    INVTYPE_HEAD           = { 1 },
    INVTYPE_NECK           = { 2 },
    INVTYPE_SHOULDER       = { 3 },
    INVTYPE_CHEST          = { 5 },
    INVTYPE_ROBE           = { 5 },
    INVTYPE_WAIST          = { 6 },
    INVTYPE_LEGS           = { 7 },
    INVTYPE_FEET           = { 8 },
    INVTYPE_WRIST          = { 9 },
    INVTYPE_HAND           = { 10 },
    INVTYPE_FINGER         = { 11, 12 },
    INVTYPE_TRINKET        = { 13, 14 },
    INVTYPE_CLOAK          = { 15 },
    INVTYPE_WEAPON         = { 16, 17 },
    INVTYPE_SHIELD         = { 17 },
    INVTYPE_2HWEAPON       = { 16 },
    INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND  = { 17 },
    INVTYPE_HOLDABLE       = { 17 },
    INVTYPE_RANGED         = { 16 },
    INVTYPE_RANGEDRIGHT    = { 16 },
}

-- INVTYPE strings whose items can fill either of two slots.
Core.DUAL_INVTYPES = {
    INVTYPE_FINGER  = true,
    INVTYPE_TRINKET = true,
}

-- Ordered list of dual-slot pairs with their inventory slot IDs.
Core.DUAL_SLOT_PAIRS = {
    { slots = { 11, 12 }, name = "Finger"  },
    { slots = { 13, 14 }, name = "Trinket" },
}

-- Single-slot entries used by the equip-plan loop.
Core.EQUIP_SLOTS = {
    { id = 1,  name = "Head"      },
    { id = 2,  name = "Neck"      },
    { id = 3,  name = "Shoulder"  },
    { id = 5,  name = "Chest"     },
    { id = 6,  name = "Waist"     },
    { id = 7,  name = "Legs"      },
    { id = 8,  name = "Feet"      },
    { id = 9,  name = "Wrist"     },
    { id = 10, name = "Hands"     },
    { id = 15, name = "Back"      },
    { id = 16, name = "Main Hand" },
    { id = 17, name = "Off Hand"  },
}

Core.SLOT_NAMES = {
    [1]="Head", [2]="Neck",      [3]="Shoulder", [5]="Chest",
    [6]="Waist",[7]="Legs",      [8]="Feet",     [9]="Wrist",
    [10]="Hands",[11]="Ring 1",  [12]="Ring 2",  [13]="Trinket 1",
    [14]="Trinket 2",[15]="Back",[16]="Main Hand",[17]="Off Hand",
}


-- locale safe stat keys for C_Item.GetItemStats
Core.STAT_KEYS = {
    HASTE   = "ITEM_MOD_HASTE_RATING_SHORT",
    CRIT    = "ITEM_MOD_CRIT_RATING_SHORT",
    MASTERY = "ITEM_MOD_MASTERY_RATING_SHORT",
    VERS    = "ITEM_MOD_VERSATILITY",
}

---------------------------------------------------------------------------
-- Scoring
---------------------------------------------------------------------------

local statCache = {}   -- [link .. mode] = value

-- Pull a secondary stat value. GetItemStats first, tooltip text as fallback
function Core.ScanStat(link, modeKey)
    if not link or link == "" then return 0 end
    local ck = link .. modeKey
    if statCache[ck] then return statCache[ck] end

    local key = Core.STAT_KEYS[modeKey]
    local stats = key and C_Item.GetItemStats(link)
    if stats and next(stats) then
        statCache[ck] = stats[key] or 0
        return statCache[ck]
    end

    local pattern = Core.STAT_TEXT[modeKey]
    if not pattern then return 0 end
    local data = C_TooltipInfo.GetHyperlink(link)
    if not data or not data.lines then return 0 end
    for _, line in ipairs(data.lines) do
        local text = line.leftText
        if text then
            local numStr = text:match("([%d,]+)%s+" .. pattern)
            if numStr then
                return tonumber((numStr:gsub(",", ""))) or 0
            end
        end
    end
    return 0
end

-- Score a single item link. Pass knownIlvl for bag/equipped items
function Core.ScoreItem(link, modeKey, knownIlvl)
    if modeKey == "ILVL" then
        if knownIlvl and knownIlvl > 0 then return knownIlvl end
        -- return select(4, GetItemInfo(link)) or 0
        return C_Item.GetDetailedItemLevelInfo(link) or 0
    end
    return Core.ScanStat(link, modeKey)
end

-- actual ilvl of whats equipped, same basis as bag items
function Core.EquippedIlvl(invSlotID)
    local loc = ItemLocation:CreateFromEquipmentSlot(invSlotID)
    if not C_Item.DoesItemExist(loc) then return 0 end
    return C_Item.GetCurrentItemLevel(loc) or 0
end

-- Score whatever is currently equipped in a given inventory slot.
-- Returns 0 when nothing is equipped (treated as "no competition").
function Core.EquippedScore(invSlotID, modeKey)
    local link = GetInventoryItemLink("player", invSlotID)
    if not link then return 0 end
    return Core.ScoreItem(link, modeKey, Core.EquippedIlvl(invSlotID))
end

---------------------------------------------------------------------------
-- Bag scanning
---------------------------------------------------------------------------

-- Returns a flat list of every equippable item currently in the player's bags.
function Core.ScanBagsForEquippable()
    local results = {}
    local maxBag  = NUM_BAG_SLOTS or 4
    for bag = 0, maxBag do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for bagSlot = 1, numSlots do
            local info     = C_Container.GetContainerItemInfo(bag, bagSlot)
            local itemLink = info and info.hyperlink
            if itemLink then
                local _, _, _, equipLoc = C_Item.GetItemInfoInstant(itemLink)
                local validSlots = equipLoc and Core.INVTYPE_TO_SLOTS[equipLoc]
                if validSlots then
                    local loc  = ItemLocation:CreateFromBagAndSlot(bag, bagSlot)
                    local ilvl = C_Item.GetCurrentItemLevel(loc) or 0
                    table.insert(results, {
                        bag        = bag,
                        slot       = bagSlot,
                        itemLink   = itemLink,
                        equipLoc   = equipLoc,
                        validSlots = validSlots,
                        ilvl       = ilvl,
                        name       = info.itemName or itemLink,
                    })
                end
            end
        end
    end
    return results
end

-- bag items the game says we can actually put in this slot
local slotScratch = {}
function Core.GetBagCandidates(invSlotID)
    local out = {}
    wipe(slotScratch)
    GetInventoryItemsForSlot(invSlotID, slotScratch)
    for location in pairs(slotScratch) do
        local d = EquipmentManager_GetLocationData(location)
        if d.isBags and not d.isBank and d.bag and d.slot then
            local info = C_Container.GetContainerItemInfo(d.bag, d.slot)
            if info and info.hyperlink then
                local _, _, _, equipLoc, _, _, subClassID = C_Item.GetItemInfoInstant(info.hyperlink)
                out[#out + 1] = {
                    bag        = d.bag,
                    slot       = d.slot,
                    _key       = d.bag .. "," .. d.slot,
                    itemLink   = info.hyperlink,
                    equipLoc   = equipLoc,
                    subClassID = subClassID,
                    ilvl       = C_Item.GetCurrentItemLevel(ItemLocation:CreateFromBagAndSlot(d.bag, d.slot)) or 0,
                    name       = info.itemName or info.hyperlink,
                }
            end
        end
    end
    return out
end

local function EquippedEntry(invSlotID)
    local link = GetInventoryItemLink("player", invSlotID)
    if not link then return nil end
    local _, _, _, equipLoc, _, _, subClassID = C_Item.GetItemInfoInstant(link)
    return {
        equipped = true, slotID = invSlotID, itemLink = link, _key = "eq" .. invSlotID,
        equipLoc = equipLoc, subClassID = subClassID,
        ilvl = Core.EquippedIlvl(invSlotID),
        name = C_Item.GetItemInfo(link) or link,
    }
end

---------------------------------------------------------------------------
-- Equip plan
---------------------------------------------------------------------------

local ARMOR_SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 15 }
local TITANS_GRIP = 46917

local function IsTwoHand(e)
    if not e or not e.equipLoc then return false end
    if e.equipLoc == "INVTYPE_2HWEAPON" or e.equipLoc == "INVTYPE_RANGED" then return true end
    -- guns/xbows are 2h, wands arent
    return e.equipLoc == "INVTYPE_RANGEDRIGHT" and e.subClassID ~= Enum.ItemWeaponSubclass.Wand
end

-- Works out every slot. Returns plan { bag, slot, targetSlot, itemLink } and a per-slot report
function Core.ComputePlan(modeKey)
    modeKey = modeKey or "ILVL"
    local plan, report, used = {}, {}, {}

    local function score(e)
        if not e or not e.itemLink then return 0 end
        if e.score == nil then e.score = Core.ScoreItem(e.itemLink, modeKey, e.ilvl) end
        return e.score
    end

    local function add(slotID, best, swap)
        report[#report + 1] = { slotID = slotID, best = best, score = score(best), swap = swap }
        if swap then
            plan[#plan + 1] = { bag = best.bag, slot = best.slot, targetSlot = slotID, itemLink = best.itemLink }
            used[best._key] = true
        end
    end

    -- Dual slots first (rings, trinkets)
    for _, pair in ipairs(Core.DUAL_SLOT_PAIRS) do
        local pool = {}
        for _, s in ipairs(pair.slots) do
            local eq = EquippedEntry(s)
            if eq then pool[#pool + 1] = eq end
        end
        for _, e in ipairs(Core.GetBagCandidates(pair.slots[1])) do
            if not used[e._key] then pool[#pool + 1] = e end
        end
        -- ties go to whats already equipped
        table.sort(pool, function(a, b)
            if score(a) ~= score(b) then return score(a) > score(b) end
            return a.equipped and not b.equipped
        end)

        local keep, incoming = {}, {}
        for i = 1, math.min(#pair.slots, #pool) do
            local e = pool[i]
            if e.equipped then keep[e.slotID] = e else incoming[#incoming + 1] = e end
        end
        -- new stuff goes in whichever slot lost its item
        for _, s in ipairs(pair.slots) do
            if keep[s] then
                add(s, keep[s], false)
            elseif incoming[1] then
                add(s, table.remove(incoming, 1), true)
            else
                add(s, nil, false)
            end
        end
    end

    -- Armor + neck + back
    for _, s in ipairs(ARMOR_SLOTS) do
        local eq = EquippedEntry(s)
        local best, bestScore = nil, eq and score(eq) or -math.huge
        for _, e in ipairs(Core.GetBagCandidates(s)) do
            if not used[e._key] and score(e) > bestScore then
                best, bestScore = e, score(e)
            end
        end
        if best then add(s, best, true) else add(s, eq, false) end
    end

    -- Weapons. 2h fills both 16 and 17 so compare it to MH+OH together
    local titanGrip = C_SpellBook.IsSpellKnown(TITANS_GRIP)
    local function twoHand(e) return not titanGrip and IsTwoHand(e) end
    local function value(e)
        if not e then return 0 end
        if modeKey == "ILVL" and twoHand(e) then return score(e) * 2 end
        return score(e)
    end
    local function pick(list, filter, skipKey)
        local best
        for _, e in ipairs(list) do
            if e and not used[e._key] and e._key ~= skipKey and filter(e)
               and (not best or value(e) > value(best) or (value(e) == value(best) and e.equipped)) then
                best = e
            end
        end
        return best
    end

    local eqMH, eqOH = EquippedEntry(16), EquippedEntry(17)
    local mhList = Core.GetBagCandidates(16)
    local ohList = Core.GetBagCandidates(17)
    if eqMH then table.insert(mhList, 1, eqMH) end
    if eqOH then table.insert(ohList, 1, eqOH) end

    local best2H = pick(mhList, twoHand)
    local bestMH = pick(mhList, function(e) return not twoHand(e) end)
    local bestOH = pick(ohList, function() return true end, bestMH and bestMH._key)
    local totalA = value(best2H)
    local totalB = value(bestMH) + value(bestOH)

    local use2H
    if twoHand(eqMH) then use2H = best2H and totalA >= totalB else use2H = best2H and totalA > totalB end

    if use2H then
        add(16, best2H, not best2H.equipped)
        add(17, { name = "(two-hander)" }, false)
    else
        add(16, bestMH, bestMH and not bestMH.equipped)
        add(17, bestOH, bestOH and not bestOH.equipped)
    end

    return plan, report
end

---------------------------------------------------------------------------
-- Highlight lookup  (used by JarsBags bag display)
---------------------------------------------------------------------------

-- Returns a table keyed by "bagID-slotID" = true for every bag item the
-- equip plan would put on, under modeKey.
function Core.BuildBestGearLookup(modeKey)
    local lookup = {}
    local plan = Core.ComputePlan(modeKey or "ILVL")
    for _, p in ipairs(plan) do
        lookup[p.bag .. "-" .. p.slot] = true
    end
    return lookup
end

-- Build the full equip plan and print every slot decision to chat.
-- Returns list of { bag, slot, targetSlot, itemLink }.
function Core.BuildEquipPlan(modeKey)
    local modeLabel = Core.MODE_LABELS[modeKey] or modeKey
    local plan, report = Core.ComputePlan(modeKey)

    print("|cFFFFD100BestGear scan|r — mode: |cFF00FF88" .. modeLabel .. "|r")
    for _, r in ipairs(report) do
        local sName = Core.SLOT_NAMES[r.slotID] or ("Slot " .. r.slotID)
        local iName = r.best and (r.best.name or r.best.itemLink) or "(empty)"
        local tag   = r.swap and "|cFFFFCC00SWAP|r" or "|cFF888888keep|r"
        local sc    = (r.score and r.score > 0) and (" [" .. r.score .. "]") or ""
        print("  " .. tag .. " " .. sName .. ": " .. iName .. sc)
    end

    return plan
end
