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

---------------------------------------------------------------------------
-- Scoring
---------------------------------------------------------------------------

-- Pull a secondary stat value from C_TooltipInfo (pure data, no frame needed).
function Core.ScanStat(link, modeKey)
    local pattern = Core.STAT_TEXT[modeKey]
    if not pattern or not link or link == "" then return 0 end
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

-- Score a single item link. Pass knownIlvl for bag items (avoids async GetItemInfo).
function Core.ScoreItem(link, modeKey, knownIlvl)
    if modeKey == "ILVL" then
        if knownIlvl and knownIlvl > 0 then return knownIlvl end
        return select(4, GetItemInfo(link)) or 0
    end
    return Core.ScanStat(link, modeKey)
end

-- Score whatever is currently equipped in a given inventory slot.
-- Returns 0 when nothing is equipped (treated as "no competition").
function Core.EquippedScore(invSlotID, modeKey)
    local link = GetInventoryItemLink("player", invSlotID)
    if not link then return 0 end
    if modeKey == "ILVL" then
        return select(4, GetItemInfo(link)) or 0
    end
    return Core.ScanStat(link, modeKey)
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
                local _, _, _, equipLoc = GetItemInfoInstant(itemLink)
                local validSlots = equipLoc and Core.INVTYPE_TO_SLOTS[equipLoc]
                if validSlots then
                    local loc  = ItemLocation:CreateFromBagAndSlot(bag, bagSlot)
                    local ilvl = C_Item.GetCurrentItemLevel(loc) or 0
                    local name = GetItemInfo(itemLink) or itemLink
                    table.insert(results, {
                        bag        = bag,
                        slot       = bagSlot,
                        itemLink   = itemLink,
                        equipLoc   = equipLoc,
                        validSlots = validSlots,
                        ilvl       = ilvl,
                        name       = name,
                    })
                end
            end
        end
    end
    return results
end

---------------------------------------------------------------------------
-- Highlight lookup  (used by JarsBags bag display)
---------------------------------------------------------------------------

-- Returns a table keyed by "bagID-slotID" = true for every bag item that would
-- be an upgrade over the currently equipped piece for its slot, under modeKey.
function Core.BuildBestGearLookup(modeKey)
    modeKey = modeKey or "ILVL"
    local lookup   = {}
    local slotPool = {}
    local dualPool = {}

    local maxBag = NUM_BAG_SLOTS or 4
    for bagID = 0, maxBag do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slotID = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bagID, slotID)
            local link = info and info.hyperlink
            if link then
                local _, _, _, equipLoc = GetItemInfoInstant(link)
                if equipLoc and equipLoc ~= "" then
                    local loc   = ItemLocation:CreateFromBagAndSlot(bagID, slotID)
                    local ilvl  = C_Item.GetCurrentItemLevel(loc) or 0
                    local score = Core.ScoreItem(link, modeKey, ilvl)
                    local entry = { key = bagID .. "-" .. slotID, score = score }

                    if Core.DUAL_INVTYPES[equipLoc] then
                        dualPool[equipLoc] = dualPool[equipLoc] or {}
                        table.insert(dualPool[equipLoc], entry)
                    else
                        local targetSlot = Core.INVTYPE_TO_SLOT[equipLoc]
                        if targetSlot then
                            slotPool[targetSlot] = slotPool[targetSlot] or {}
                            table.insert(slotPool[targetSlot], entry)
                        end
                    end
                end
            end
        end
    end

    -- Single slots: highlight only if the bag item beats what's equipped.
    for invSlot, pool in pairs(slotPool) do
        table.sort(pool, function(a, b) return a.score > b.score end)
        local best = pool[1]
        if best and best.score > Core.EquippedScore(invSlot, modeKey) then
            lookup[best.key] = true
        end
    end

    -- Dual slots (rings 11/12, trinkets 13/14):
    -- Mix bag items and equipped sentinels into one pool, sort, take top #slots.
    -- Only bag entries in the top positions get highlighted.
    local dualSlotMap = {
        INVTYPE_FINGER  = { 11, 12 },
        INVTYPE_TRINKET = { 13, 14 },
    }
    for invtype, pool in pairs(dualPool) do
        local slots = dualSlotMap[invtype]
        if slots then
            for _, s in ipairs(slots) do
                -- key=nil marks these as equipped sentinels (never highlighted)
                table.insert(pool, { key = nil, score = Core.EquippedScore(s, modeKey) })
            end
            table.sort(pool, function(a, b) return a.score > b.score end)
            for i = 1, math.min(#slots, #pool) do
                local entry = pool[i]
                if entry.key then
                    lookup[entry.key] = true
                end
            end
        end
    end

    return lookup
end

---------------------------------------------------------------------------
-- Equip plan  (used by BestGear's "Equip Best" button)
---------------------------------------------------------------------------

local function FindBestForSingleSlot(bagItems, slotID, modeKey, excludedKeys)
    local bestScore = -math.huge
    local bestEntry = nil

    local equippedLink = GetInventoryItemLink("player", slotID)
    if equippedLink then
        bestScore = Core.ScoreItem(equippedLink, modeKey, nil)
        bestEntry = {
            equipped = true, slotID = slotID, itemLink = equippedLink,
            name = GetItemInfo(equippedLink) or equippedLink,
        }
    end

    for _, item in ipairs(bagItems) do
        local key = item.bag .. "," .. item.slot
        if not excludedKeys[key] then
            for _, s in ipairs(item.validSlots) do
                if s == slotID then
                    local score = Core.ScoreItem(item.itemLink, modeKey, item.ilvl)
                    if score > bestScore then
                        bestScore = score
                        bestEntry = item
                    end
                    break
                end
            end
        end
    end

    return bestEntry, bestScore
end

local function FindBestPairForDualSlots(bagItems, slotA, slotB, modeKey)
    local pool = {}
    local seen = {}

    local eqA = GetInventoryItemLink("player", slotA)
    local eqB = GetInventoryItemLink("player", slotB)
    if eqA then
        local e = { equipped=true, slotID=slotA, itemLink=eqA, _key="eq"..slotA,
                    ilvl=select(4,GetItemInfo(eqA)) or 0, name=GetItemInfo(eqA) or eqA }
        table.insert(pool, e); seen[e._key] = true
    end
    if eqB then
        local e = { equipped=true, slotID=slotB, itemLink=eqB, _key="eq"..slotB,
                    ilvl=select(4,GetItemInfo(eqB)) or 0, name=GetItemInfo(eqB) or eqB }
        table.insert(pool, e); seen[e._key] = true
    end

    for _, item in ipairs(bagItems) do
        local key = item.bag .. "," .. item.slot
        if not seen[key] then
            for _, s in ipairs(item.validSlots) do
                if s == slotA or s == slotB then
                    table.insert(pool, item); seen[key] = true; break
                end
            end
        end
    end

    table.sort(pool, function(a, b)
        return Core.ScoreItem(a.itemLink, modeKey, a.ilvl) >
               Core.ScoreItem(b.itemLink, modeKey, b.ilvl)
    end)

    return pool[1], pool[2]
end

-- Build the full equip plan and print every slot decision to chat.
-- Returns list of { bag, slot, targetSlot, itemLink }.
function Core.BuildEquipPlan(modeKey)
    local bagItems  = Core.ScanBagsForEquippable()
    local plan      = {}
    local assigned  = {}
    local modeLabel = Core.MODE_LABELS[modeKey] or modeKey

    print("|cFFFFD100BestGear scan|r — mode: |cFF00FF88" .. modeLabel .. "|r")

    local function PrintSlot(slotID, best, score, swap)
        local sName = Core.SLOT_NAMES[slotID] or ("Slot " .. slotID)
        local iName = best and (best.name or best.itemLink) or "(empty)"
        local tag   = swap and "|cFFFFCC00SWAP|r" or "|cFF888888keep|r"
        local sc    = (score and score > 0) and (" [" .. score .. "]") or ""
        print("  " .. tag .. " " .. sName .. ": " .. iName .. sc)
    end

    -- Dual slots first (rings, trinkets)
    for _, pair in ipairs(Core.DUAL_SLOT_PAIRS) do
        local slotA, slotB = pair.slots[1], pair.slots[2]
        local bestA, bestB = FindBestPairForDualSlots(bagItems, slotA, slotB, modeKey)
        for i, best in ipairs({ bestA, bestB }) do
            local tgt  = pair.slots[i]
            local swap = best and not best.equipped
            local sc   = best and Core.ScoreItem(best.itemLink, modeKey, best.ilvl) or 0
            PrintSlot(tgt, best, sc, swap)
            if swap then
                table.insert(plan, { bag=best.bag, slot=best.slot,
                                     targetSlot=tgt, itemLink=best.itemLink })
                assigned[best._key or (best.bag .. "," .. best.slot)] = true
            end
        end
    end

    -- Single slots
    for _, slotEntry in ipairs(Core.EQUIP_SLOTS) do
        local best, score = FindBestForSingleSlot(bagItems, slotEntry.id, modeKey, assigned)
        local swap = best and not best.equipped
        PrintSlot(slotEntry.id, best, score, swap)
        if swap then
            table.insert(plan, { bag=best.bag, slot=best.slot,
                                 targetSlot=slotEntry.id, itemLink=best.itemLink })
            assigned[best.bag .. "," .. best.slot] = true
        end
    end

    return plan
end
