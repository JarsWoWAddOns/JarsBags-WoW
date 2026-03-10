-- JarsBags: All-in-one bag replacement
-- Combines all bags, categorizes items, highlights equipment sets, quality indicators

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local SLOT_SIZE = 36
local SLOT_SPACING = 4
local COLUMNS = 10
local HEADER_HEIGHT = 22
local BAG_IDS = { 0, 1, 2, 3, 4, 5 } -- backpack + 4 bags + reagent bag
local FONT = "Fonts\\FRIZQT__.TTF"

local CATEGORY_ORDER = { "Equipment", "Consumables", "Quest", "Crafting", "Junk", "Other" }
local CATEGORY_CLASSIDS = {
    Equipment   = { [2] = true, [4] = true },                  -- Weapon, Armor
    Consumables = { [0] = true },                               -- Consumable
    Crafting    = { [5] = true, [7] = true, [9] = true, [19] = true }, -- Reagent, Trade Goods, Recipe, Profession
    Quest       = { [12] = true },                              -- Quest
}

-- Quality colors (2=green, 3=blue, 4=purple, 5=orange, 6=artifact, 7=heirloom)
local QUALITY_COLORS = {
    [2] = { 0.12, 1.0, 0.0 },
    [3] = { 0.0, 0.44, 0.87 },
    [4] = { 0.64, 0.21, 0.93 },
    [5] = { 1.0, 0.5, 0.0 },
    [6] = { 0.9, 0.8, 0.5 },
    [7] = { 0.0, 0.8, 1.0 },
}

---------------------------------------------------------------------------
-- UI Style (matching JarsAddonConfig)
---------------------------------------------------------------------------
local UI = {
    bg        = { 0.10, 0.10, 0.12, 0.95 },
    header    = { 0.13, 0.13, 0.16, 1 },
    accent    = { 1.0,  0.55, 0.0,  1 },
    text      = { 0.90, 0.90, 0.90, 1 },
    textDim   = { 0.55, 0.55, 0.58, 1 },
    border    = { 0.22, 0.22, 0.26, 1 },
    btnNormal = { 0.18, 0.18, 0.22, 1 },
    btnHover  = { 0.24, 0.24, 0.28, 1 },
    slotBg    = { 0.15, 0.15, 0.18, 1 },
    setGlow   = { 0.2, 1.0, 0.4, 0.7 },
}

local backdrop_main = {
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local DEFAULTS = {
    highlightSets      = true,
    highlightSoulbound = false,
    highlightBestGear  = false,
    bestGearMode       = "ILVL",
    showItemLevel      = true,
    showUpgradeTrack   = true,
    bagScale           = 1.0,
    lockMovement       = false,
}
local mainFrame = nil
local itemButtons = {}        -- pool of item button frames
local activeButtons = {}      -- currently visible buttons
local categoryHeaders = {}    -- pool of header frames
local activeHeaders = {}      -- currently visible headers
local equipSetLookup = {}     -- ["bagID-slotID"] = true
local pendingRefresh = false
local refreshTimer = nil

-- One parent frame per bag ID. ContainerFrameItemButtonTemplate uses GetParent():GetID()
-- to determine the bag for click actions. Buttons are reparented here in LayoutItems
-- so the template gets the correct bag ID without any addon closures on the secure button.
local bagParentFrames = {}
for _, bagID in ipairs(BAG_IDS) do
    local f = CreateFrame("Frame")
    f:SetID(bagID)
    f:SetFrameStrata("HIGH")
    f:Show()
    bagParentFrames[bagID] = f
end

---------------------------------------------------------------------------
-- Saved Variables
---------------------------------------------------------------------------
JarsBagsDB = JarsBagsDB or {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function FormatGold(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop = copper % 100
    return string.format("|cFFFFD700%d|rg |cFFC0C0C0%d|rs |cFFB87333%d|rc", gold, silver, cop)
end

local function ClassifyItem(classID, quality)
    if quality == 0 then return "Junk" end
    for cat, ids in pairs(CATEGORY_CLASSIDS) do
        if ids[classID] then return cat end
    end
    return "Other"
end

---------------------------------------------------------------------------
-- Equipment Set Lookup (tooltip scanning)
---------------------------------------------------------------------------
-- Hidden tooltip used to scan for "Equipment Set:" text
local scanTooltip = CreateFrame("GameTooltip", "JarsBagsScanTooltip", nil, "GameTooltipTemplate")
scanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")

-- Upgrade track patterns: "Veteran 3/8", "Champion 4/8", "Hero 2/6", "Myth 1/6"
local TRACK_PATTERNS = {
    { pattern = "Veteran %d",  letter = "V", color = {0.12, 1.0, 0.0} },   -- green
    { pattern = "Champion %d", letter = "C", color = {0.0, 0.44, 0.87} },   -- blue
    { pattern = "Hero %d",     letter = "H", color = {0.64, 0.21, 0.93} },  -- purple
    { pattern = "Myth %d",     letter = "M", color = {1.0, 0.5, 0.0} },     -- orange
}

local function ScanTooltipForFlags(bagID, slotID)
    scanTooltip:ClearLines()
    scanTooltip:SetBagItem(bagID, slotID)
    local isSet, isBound = false, false
    local trackLetter, trackColor = nil, nil
    for i = 1, scanTooltip:NumLines() do
        local left = _G["JarsBagsScanTooltipTextLeft" .. i]
        if left then
            local text = left:GetText()
            if text then
                if text:find("Equipment Sets:") then isSet = true end
                if text == ITEM_SOULBOUND or text == ITEM_ACCOUNTBOUND
                   or text == ITEM_BNETACCOUNTBOUND then
                    isBound = true
                end
                if not trackLetter then
                    for _, tp in ipairs(TRACK_PATTERNS) do
                        if text:find(tp.pattern) then
                            trackLetter = tp.letter
                            trackColor = tp.color
                            break
                        end
                    end
                end
            end
        end
    end
    return isSet, isBound, trackLetter, trackColor
end

local function IsInEquipmentSet(bagID, slotID)
    local isSet = ScanTooltipForFlags(bagID, slotID)
    return isSet
end

local soulboundLookup = {}   -- ["bagID-slotID"] = true
local trackLookup = {}       -- ["bagID-slotID"] = { letter = "V", color = {r,g,b} }

local function RebuildTooltipLookups()
    wipe(equipSetLookup)
    wipe(soulboundLookup)
    wipe(trackLookup)
    for _, bagID in ipairs(BAG_IDS) do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slotID = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bagID, slotID)
            if info and info.itemID then
                local isSet, isBound, tLetter, tColor = ScanTooltipForFlags(bagID, slotID)
                local key = bagID .. "-" .. slotID
                if isSet then equipSetLookup[key] = true end
                if isBound then soulboundLookup[key] = true end
                if tLetter then trackLookup[key] = { letter = tLetter, color = tColor } end
            end
        end
    end
end


---------------------------------------------------------------------------
-- CRITICAL API REFERENCE — DO NOT CHANGE ITEM USE/CLICK BEHAVIOR
--
-- The buttons use "ContainerFrameItemButtonTemplate" which provides secure
-- click actions (right-click to use, drag to move, etc.) via Blizzard's
-- ContainerFrameItemButton_OnClick and related secure handlers.
--
-- How it works:
--   1. Each button is an ItemButton inheriting ContainerFrameItemButtonTemplate.
--   2. btn:SetID(slotID) sets the slot the template operates on.
--   3. btn:SetParent(bagParentFrames[bagID]) — the template calls
--      GetParent():GetID() to determine the bag ID for secure actions.
--   4. bagParentFrames[bagID] is a plain Frame with f:SetID(bagID).
--
-- APIs used internally by the template (DO NOT override or hook these):
--   ContainerFrameItemButton_OnClick(self, button)   — item use/equip
--   ContainerFrameItemButton_OnDrag(self)             — item pickup
--   ContainerFrameItemButton_OnModifiedClick(self)    — split stack / chat link
--
-- If click actions break, check:
--   - btn:SetID(slotID) is called in LayoutItems ✓
--   - btn:SetParent(bagParentFrames[item.bagID]) is called in LayoutItems ✓
--   - bagParentFrames[bagID]:SetID(bagID) is set at init ✓
--   - btn:SetScript("OnEvent", nil) and ("OnShow", nil) only kill
--     auto-update, NOT click handlers (those are on the template XML) ✓
--
-- DO NOT: replace the button template, add custom OnClick, reparent to
-- content directly, or call C_Container.UseContainerItem manually.
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Item Button Pool
-- Uses ContainerFrameItemButtonTemplate for secure click/use/drag.
-- We suppress template visuals and draw our own.
---------------------------------------------------------------------------
local itemButtonIndex = 0
local function GetItemButton()
    local btn
    if #itemButtons > 0 then
        btn = table.remove(itemButtons)
        -- parent is set per-slot in LayoutItems via btn:SetParent(bagParentFrames[bagID])
    else
        itemButtonIndex = itemButtonIndex + 1
        -- ContainerFrameItemButtonTemplate handles all click/use behavior securely.
        -- We use UIParent as initial parent; buttons are reparented to bagParentFrames in LayoutItems
        -- so GetParent():GetID() returns the correct bag ID without any addon closures on the button.
        btn = CreateFrame("ItemButton", "JarsBagsItemBtn" .. itemButtonIndex, UIParent,
            "ContainerFrameItemButtonTemplate")
        btn:SetSize(SLOT_SIZE, SLOT_SIZE)
        -- Kill template auto-update scripts - we drive all updates ourselves
        btn:SetScript("OnEvent", nil)
        btn:SetScript("OnShow", nil)

        -- Resize the template's icon to 32x32 centered (same as old version: SLOT_SIZE - 4)
        -- Template default fills the entire button, which makes it look "too big"
        btn.icon:ClearAllPoints()
        btn.icon:SetSize(SLOT_SIZE - 4, SLOT_SIZE - 4)
        btn.icon:SetPoint("CENTER")
        btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        -- Hide the template's NormalTexture (slot art) so our dark background shows
        local nt = btn:GetNormalTexture()
        if nt then nt:SetAlpha(0) end

        -- Dark slot background with 1px border (matches old version's BackdropTemplate look)
        local _bdr = btn:CreateTexture(nil, "BACKGROUND", nil, -2)
        _bdr:SetAllPoints()
        _bdr:SetColorTexture(unpack(UI.border))

        local _bg = btn:CreateTexture(nil, "BACKGROUND", nil, -1)
        _bg:SetPoint("TOPLEFT", 1, -1)
        _bg:SetPoint("BOTTOMRIGHT", -1, 1)
        _bg:SetColorTexture(unpack(UI.slotBg))

        -- Suppress all template overlays we don't want and permanently block their OnShow
        local function blockOverlay(tex)
            if tex then tex:Hide() tex:SetScript("OnShow", function(s) s:Hide() end) end
        end
        blockOverlay(btn.NewItemTexture)
        blockOverlay(btn.BattlepayItemTexture)
        blockOverlay(btn.JunkIcon)
        blockOverlay(btn.UpgradeIcon)
        blockOverlay(btn.ItemContextMatchResult)
        -- Hide the template's built-in quality border (we draw our own)
        if btn.IconBorder then btn.IconBorder:Hide() btn.IconBorder:SetScript("OnShow", function(s) s:Hide() end) end

        -- Quality border (thin colored lines at icon edges)
        local qbSize = 1.5
        btn.qualityBorders = {}
        for _, side in ipairs({"TOP", "BOTTOM", "LEFT", "RIGHT"}) do
            local tex = btn:CreateTexture(nil, "OVERLAY")
            if side == "TOP" then
                tex:SetHeight(qbSize)
                tex:SetPoint("TOPLEFT", btn.icon, "TOPLEFT", 0, 0)
                tex:SetPoint("TOPRIGHT", btn.icon, "TOPRIGHT", 0, 0)
            elseif side == "BOTTOM" then
                tex:SetHeight(qbSize)
                tex:SetPoint("BOTTOMLEFT", btn.icon, "BOTTOMLEFT", 0, 0)
                tex:SetPoint("BOTTOMRIGHT", btn.icon, "BOTTOMRIGHT", 0, 0)
            elseif side == "LEFT" then
                tex:SetWidth(qbSize)
                tex:SetPoint("TOPLEFT", btn.icon, "TOPLEFT", 0, 0)
                tex:SetPoint("BOTTOMLEFT", btn.icon, "BOTTOMLEFT", 0, 0)
            else
                tex:SetWidth(qbSize)
                tex:SetPoint("TOPRIGHT", btn.icon, "TOPRIGHT", 0, 0)
                tex:SetPoint("BOTTOMRIGHT", btn.icon, "BOTTOMRIGHT", 0, 0)
            end
            tex:Hide()
            table.insert(btn.qualityBorders, tex)
        end

        -- Equipment set border (corner brackets style)
        btn.setBrackets = {}
        local bLen, bThick = 8, 2
        local setColor = UI.setGlow
        for _, corner in ipairs({
            {"TOPLEFT", "TOPLEFT", bLen, bThick, 0, 0},      -- top-left horizontal
            {"TOPLEFT", "TOPLEFT", bThick, bLen, 0, 0},      -- top-left vertical
            {"TOPRIGHT", "TOPRIGHT", bLen, bThick, 0, 0},    -- top-right horizontal
            {"TOPRIGHT", "TOPRIGHT", bThick, bLen, 0, 0},    -- top-right vertical
            {"BOTTOMLEFT", "BOTTOMLEFT", bLen, bThick, 0, 0},-- bottom-left horizontal
            {"BOTTOMLEFT", "BOTTOMLEFT", bThick, bLen, 0, 0},-- bottom-left vertical
            {"BOTTOMRIGHT", "BOTTOMRIGHT", bLen, bThick, 0, 0},-- bottom-right horizontal
            {"BOTTOMRIGHT", "BOTTOMRIGHT", bThick, bLen, 0, 0},-- bottom-right vertical
        }) do
            local t = btn:CreateTexture(nil, "OVERLAY", nil, 3)
            t:SetSize(corner[3], corner[4])
            t:SetPoint(corner[1], btn.icon, corner[2], corner[5], corner[6])
            t:SetColorTexture(setColor[1], setColor[2], setColor[3], setColor[4])
            t:Hide()
            table.insert(btn.setBrackets, t)
        end

        -- Soulbound highlight (subtle colored border, reuses same bracket approach)
        btn.soulboundBorders = {}
        local sbColor = { 0.6, 0.4, 1.0, 0.8 } -- soft purple
        for _, side in ipairs({"TOP", "BOTTOM", "LEFT", "RIGHT"}) do
            local tex = btn:CreateTexture(nil, "OVERLAY", nil, 1)
            if side == "TOP" then
                tex:SetHeight(2)
                tex:SetPoint("TOPLEFT", btn.icon, "TOPLEFT", 0, 0)
                tex:SetPoint("TOPRIGHT", btn.icon, "TOPRIGHT", 0, 0)
            elseif side == "BOTTOM" then
                tex:SetHeight(2)
                tex:SetPoint("BOTTOMLEFT", btn.icon, "BOTTOMLEFT", 0, 0)
                tex:SetPoint("BOTTOMRIGHT", btn.icon, "BOTTOMRIGHT", 0, 0)
            elseif side == "LEFT" then
                tex:SetWidth(2)
                tex:SetPoint("TOPLEFT", btn.icon, "TOPLEFT", 0, 0)
                tex:SetPoint("BOTTOMLEFT", btn.icon, "BOTTOMLEFT", 0, 0)
            else
                tex:SetWidth(2)
                tex:SetPoint("TOPRIGHT", btn.icon, "TOPRIGHT", 0, 0)
                tex:SetPoint("BOTTOMRIGHT", btn.icon, "BOTTOMRIGHT", 0, 0)
            end
            tex:SetColorTexture(sbColor[1], sbColor[2], sbColor[3], sbColor[4])
            tex:Hide()
            table.insert(btn.soulboundBorders, tex)
        end

        -- Best-in-Slot gold border
        btn.bestGearBorders = {}
        local bgBorderColor = { 1.0, 0.85, 0.0, 1.0 }
        for _, side in ipairs({"TOP", "BOTTOM", "LEFT", "RIGHT"}) do
            local tex = btn:CreateTexture(nil, "OVERLAY", nil, 2)
            if side == "TOP" then
                tex:SetHeight(2)
                tex:SetPoint("TOPLEFT",  btn.icon, "TOPLEFT",  0, 0)
                tex:SetPoint("TOPRIGHT", btn.icon, "TOPRIGHT", 0, 0)
            elseif side == "BOTTOM" then
                tex:SetHeight(2)
                tex:SetPoint("BOTTOMLEFT",  btn.icon, "BOTTOMLEFT",  0, 0)
                tex:SetPoint("BOTTOMRIGHT", btn.icon, "BOTTOMRIGHT", 0, 0)
            elseif side == "LEFT" then
                tex:SetWidth(2)
                tex:SetPoint("TOPLEFT",    btn.icon, "TOPLEFT",    0, 0)
                tex:SetPoint("BOTTOMLEFT", btn.icon, "BOTTOMLEFT", 0, 0)
            else
                tex:SetWidth(2)
                tex:SetPoint("TOPRIGHT",    btn.icon, "TOPRIGHT",    0, 0)
                tex:SetPoint("BOTTOMRIGHT", btn.icon, "BOTTOMRIGHT", 0, 0)
            end
            tex:SetColorTexture(bgBorderColor[1], bgBorderColor[2], bgBorderColor[3], bgBorderColor[4])
            tex:Hide()
            table.insert(btn.bestGearBorders, tex)
        end

        -- Item level text (top-left of icon)
        btn.ilvlText = btn:CreateFontString(nil, "OVERLAY")
        btn.ilvlText:SetFont(FONT, 10, "OUTLINE")
        btn.ilvlText:SetPoint("TOPLEFT", btn.icon, "TOPLEFT", 1, -1)
        btn.ilvlText:SetJustifyH("LEFT")
        btn.ilvlText:SetTextColor(1, 1, 1, 0.9)

        -- Upgrade track letter (bottom-left of icon)
        btn.trackText = btn:CreateFontString(nil, "OVERLAY")
        btn.trackText:SetFont(FONT, 20, "OUTLINE")
        btn.trackText:SetPoint("BOTTOMRIGHT", btn.icon, "BOTTOMRIGHT", -1, 1)
        btn.trackText:SetJustifyH("RIGHT")

        -- New-item glow (pulsing white overlay on the icon)
        btn.newItemGlow = btn:CreateTexture(nil, "OVERLAY", nil, 2)
        btn.newItemGlow:SetPoint("TOPLEFT", btn.icon, "TOPLEFT", -2, 2)
        btn.newItemGlow:SetPoint("BOTTOMRIGHT", btn.icon, "BOTTOMRIGHT", 2, -2)
        btn.newItemGlow:SetAtlas("bags-glow-white")
        btn.newItemGlow:SetBlendMode("ADD")
        btn.newItemGlow:SetAlpha(0.5)
        btn.newItemGlow:Hide()

        btn.newItemGlowAG = btn.newItemGlow:CreateAnimationGroup()
        btn.newItemGlowAG:SetLooping("REPEAT")
        local fadeOut = btn.newItemGlowAG:CreateAnimation("Alpha")
        fadeOut:SetFromAlpha(0.5)
        fadeOut:SetToAlpha(0.15)
        fadeOut:SetDuration(0.75)
        fadeOut:SetOrder(1)
        fadeOut:SetSmoothing("IN_OUT")
        local fadeIn = btn.newItemGlowAG:CreateAnimation("Alpha")
        fadeIn:SetFromAlpha(0.15)
        fadeIn:SetToAlpha(0.5)
        fadeIn:SetDuration(0.75)
        fadeIn:SetOrder(2)
        fadeIn:SetSmoothing("IN_OUT")

    end

    btn:Show()
    table.insert(activeButtons, btn)
    return btn
end

local function ReleaseAllButtons()
    for _, btn in ipairs(activeButtons) do
        btn:Hide()
        btn:ClearAllPoints()
        btn.hasItem = false
        SetItemButtonTexture(btn, nil)
        SetItemButtonCount(btn, 0)
        SetItemButtonDesaturated(btn, false)
        for _, tex in ipairs(btn.qualityBorders) do tex:Hide() end
        if btn.setBrackets then
            for _, t in ipairs(btn.setBrackets) do t:Hide() end
        end
        if btn.soulboundBorders then
            for _, t in ipairs(btn.soulboundBorders) do t:Hide() end
        end
        if btn.bestGearBorders then
            for _, t in ipairs(btn.bestGearBorders) do t:Hide() end
        end
        if btn.ilvlText then btn.ilvlText:SetText("") end
        if btn.trackText then btn.trackText:SetText("") end
        if btn.newItemGlow then
            btn.newItemGlow:Hide()
            btn.newItemGlowAG:Stop()
        end
        table.insert(itemButtons, btn)
    end
    wipe(activeButtons)
end

---------------------------------------------------------------------------
-- Category Header Pool
---------------------------------------------------------------------------
local function GetCategoryHeader(parent)
    local hdr
    if #categoryHeaders > 0 then
        hdr = table.remove(categoryHeaders)
        hdr:SetParent(parent)
    else
        hdr = CreateFrame("Frame", nil, parent)
        hdr:SetHeight(HEADER_HEIGHT)

        hdr.label = hdr:CreateFontString(nil, "OVERLAY")
        hdr.label:SetFont(FONT, 10, "")
        hdr.label:SetTextColor(unpack(UI.textDim))
        hdr.label:SetPoint("LEFT", 2, 0)

        hdr.line = hdr:CreateTexture(nil, "ARTWORK")
        hdr.line:SetHeight(1)
        hdr.line:SetPoint("LEFT", hdr.label, "RIGHT", 6, 0)
        hdr.line:SetPoint("RIGHT", hdr, "RIGHT", 0, 0)
        hdr.line:SetColorTexture(unpack(UI.border))
    end

    hdr:Show()
    table.insert(activeHeaders, hdr)
    return hdr
end

local function ReleaseAllHeaders()
    for _, hdr in ipairs(activeHeaders) do
        hdr:Hide()
        hdr:ClearAllPoints()
        table.insert(categoryHeaders, hdr)
    end
    wipe(activeHeaders)
end

---------------------------------------------------------------------------
-- Bag Scanning & Categorization
---------------------------------------------------------------------------
local function ScanBags()
    local categories = {}
    for _, cat in ipairs(CATEGORY_ORDER) do
        categories[cat] = {}
    end

    for _, bagID in ipairs(BAG_IDS) do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slotID = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bagID, slotID)
            if info and info.itemID then
                local itemName, _, baseQuality, _, _, _, _, _, _, _, _, classID = C_Item.GetItemInfo(info.itemID)
                local name = itemName or ""
                local cID = classID or 15 -- default to Miscellaneous

                -- Determine quality: prefer the actual item link color (accounts for scaling)
                -- info.quality is the instance quality from the bag (scaled/upgraded)
                -- baseQuality from GetItemInfo is just the base item template quality
                -- Also parse hyperlink color as ultimate fallback
                local quality = info.quality
                if not quality and info.hyperlink then
                    local hexColor = info.hyperlink:match("|cff(%x%x%x%x%x%x)")
                    if hexColor then
                        -- Match hex color to quality
                        local colorMap = {
                            ["9d9d9d"] = 0, -- Poor
                            ["ffffff"] = 1, -- Common
                            ["1eff00"] = 2, -- Uncommon
                            ["0070dd"] = 3, -- Rare
                            ["a335ee"] = 4, -- Epic
                            ["ff8000"] = 5, -- Legendary
                            ["e6cc80"] = 6, -- Artifact
                            ["00ccff"] = 7, -- Heirloom
                        }
                        quality = colorMap[hexColor:lower()] or baseQuality or 1
                    end
                end
                quality = quality or baseQuality or 1

                local category = ClassifyItem(cID, quality)

                table.insert(categories[category], {
                    bagID = bagID,
                    slotID = slotID,
                    itemID = info.itemID,
                    name = name,
                    icon = info.iconFileID,
                    count = info.stackCount,
                    quality = quality,
                    classID = cID,
                    isLocked = info.isLocked,
                    hyperlink = info.hyperlink,
                })
            end
        end
    end

    -- Sort each category: quality descending, then name ascending
    for _, cat in ipairs(CATEGORY_ORDER) do
        table.sort(categories[cat], function(a, b)
            if a.quality ~= b.quality then
                return a.quality > b.quality
            end
            return a.name < b.name
        end)
    end

    return categories
end

---------------------------------------------------------------------------
-- BestGear Integration  (delegates to BestGearCore)
-- BestGearCore.lua is loaded first by the TOC and exposes all shared
-- scoring, lookup, and equip-plan logic via the BestGearCore global.
---------------------------------------------------------------------------

local bestGearLookup = {}

local function BG_BuildBestGearLookup(modeKey)
    bestGearLookup = BestGearCore.BuildBestGearLookup(modeKey)
end

-- Aliases so the toolbar UI code below can keep its existing short names.
local BG_MODES       = BestGearCore.MODES
local BG_MODE_LABELS = BestGearCore.MODE_LABELS

---------------------------------------------------------------------------
-- Layout Engine
---------------------------------------------------------------------------
local newItemCache = {}   -- ["bagID-slotID"] = true, rebuilt each RefreshBags

local function LayoutItems(content, categories)
    ReleaseAllButtons()
    ReleaseAllHeaders()

    local gridWidth = COLUMNS * (SLOT_SIZE + SLOT_SPACING) - SLOT_SPACING
    local yOffset = 0
    local showSets = JarsBagsDB.highlightSets
    local showSoulbound = JarsBagsDB.highlightSoulbound
    local showBestGear  = JarsBagsDB.highlightBestGear
    local showIlvl = JarsBagsDB.showItemLevel
    local showTrack = JarsBagsDB.showUpgradeTrack

    -- Active filters
    local filterNew = mainFrame and mainFrame.filterNewItems
    local filterText = mainFrame and mainFrame.searchFilter or ""
    if filterText == "" then filterText = nil end

    if showSets or showSoulbound or showTrack then
        RebuildTooltipLookups()
    end
    if showBestGear then
        BG_BuildBestGearLookup(JarsBagsDB.bestGearMode or "ILVL")
    end

    for _, catName in ipairs(CATEGORY_ORDER) do
        local items = categories[catName]
        if items and #items > 0 then
            -- Apply filters
            if filterNew or filterText then
                local filtered = {}
                for _, item in ipairs(items) do
                    local pass = true
                    if filterNew then
                        local nk = item.bagID .. "-" .. item.slotID
                        if not newItemCache[nk] then
                            pass = false
                        end
                    end
                    if pass and filterText then
                        if not item.name or not item.name:lower():find(filterText, 1, true) then
                            pass = false
                        end
                    end
                    if pass then filtered[#filtered + 1] = item end
                end
                items = filtered
            end
        end
        if items and #items > 0 then
            -- Category header
            local hdr = GetCategoryHeader(content)
            hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOffset)
            hdr:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            hdr.label:SetText(string.upper(catName) .. " (" .. #items .. ")")
            yOffset = yOffset + HEADER_HEIGHT + 4

            -- Item grid
            for i, item in ipairs(items) do
                local col = (i - 1) % COLUMNS
                local row = math.floor((i - 1) / COLUMNS)

                local btn = GetItemButton()
                btn:SetParent(bagParentFrames[item.bagID])
                btn:SetID(item.slotID)
                btn.hasItem = true
                btn:SetPoint("TOPLEFT", content, "TOPLEFT",
                    col * (SLOT_SIZE + SLOT_SPACING),
                    -(yOffset + row * (SLOT_SIZE + SLOT_SPACING)))

                -- Force icon to 32x32 centered every layout pass
                btn.icon:ClearAllPoints()
                btn.icon:SetSize(SLOT_SIZE - 4, SLOT_SIZE - 4)
                btn.icon:SetPoint("CENTER")
                btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                local nt = btn:GetNormalTexture()
                if nt then nt:SetAlpha(0) end

                -- Icon, lock, and stack count via template globals
                SetItemButtonTexture(btn, item.icon)
                SetItemButtonDesaturated(btn, item.isLocked)
                SetItemButtonCount(btn, item.count or 0)

                -- Quality border (suppressed when BestGear highlight is active)
                local qColor = QUALITY_COLORS[item.quality]
                if qColor and not showBestGear then
                    for _, tex in ipairs(btn.qualityBorders) do
                        tex:SetColorTexture(qColor[1], qColor[2], qColor[3], 1)
                        tex:Show()
                    end
                else
                    for _, tex in ipairs(btn.qualityBorders) do tex:Hide() end
                end

                -- New-item glow (suppressed when BestGear highlight is active)
                local nk = item.bagID .. "-" .. item.slotID
                local isNew = newItemCache[nk]
                if isNew and not showBestGear then
                    btn.newItemGlow:Show()
                    if not btn.newItemGlowAG:IsPlaying() then
                        btn.newItemGlowAG:Play()
                    end
                else
                    btn.newItemGlow:Hide()
                    btn.newItemGlowAG:Stop()
                end

                -- Item level display
                if showIlvl and (item.classID == 2 or item.classID == 4) then
                    local ilvl = C_Item.GetCurrentItemLevel(
                        ItemLocation:CreateFromBagAndSlot(item.bagID, item.slotID))
                    if ilvl and ilvl > 1 then
                        btn.ilvlText:SetText(ilvl)
                    else
                        btn.ilvlText:SetText("")
                    end
                else
                    btn.ilvlText:SetText("")
                end

                -- Equipment set highlight (suppressed when BestGear highlight is active)
                local key = item.bagID .. "-" .. item.slotID
                if showSets and not showBestGear and equipSetLookup[key] then
                    for _, t in ipairs(btn.setBrackets) do t:Show() end
                else
                    for _, t in ipairs(btn.setBrackets) do t:Hide() end
                end

                -- Upgrade track letter
                if showTrack and trackLookup[key] then
                    local t = trackLookup[key]
                    btn.trackText:SetText(t.letter)
                    btn.trackText:SetTextColor(t.color[1], t.color[2], t.color[3], 1)
                else
                    btn.trackText:SetText("")
                end

                -- Soulbound highlight (suppressed when BestGear highlight is active)
                if showSoulbound and not showBestGear and soulboundLookup[key] then
                    for _, t in ipairs(btn.soulboundBorders) do t:Show() end
                else
                    for _, t in ipairs(btn.soulboundBorders) do t:Hide() end
                end

                -- Best-in-Slot gold highlight
                if showBestGear and bestGearLookup[key] then
                    for _, t in ipairs(btn.bestGearBorders) do t:Show() end
                else
                    for _, t in ipairs(btn.bestGearBorders) do t:Hide() end
                end
            end

            local numRows = math.ceil(#items / COLUMNS)
            yOffset = yOffset + numRows * (SLOT_SIZE + SLOT_SPACING) + 8
        end
    end

    content:SetHeight(math.max(yOffset, 100))
end

---------------------------------------------------------------------------
-- Main Frame Creation
---------------------------------------------------------------------------
local function CreateBagFrame()
    if mainFrame then return mainFrame end

    local gridWidth = COLUMNS * (SLOT_SIZE + SLOT_SPACING) - SLOT_SPACING
    local frameWidth = gridWidth + 40 -- 20px padding each side

    local frame = CreateFrame("Frame", "JarsBagsFrame", UIParent, "BackdropTemplate")
    frame:SetSize(frameWidth, 500)
    frame:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)
    frame:SetBackdrop(backdrop_main)
    frame:SetBackdropColor(unpack(UI.bg))
    frame:SetBackdropBorderColor(unpack(UI.border))
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not JarsBagsDB.lockMovement then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "JarsBagsFrame")

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetHeight(30)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)
    titleBar:SetBackdrop(backdrop_main)
    titleBar:SetBackdropColor(unpack(UI.header))
    titleBar:SetBackdropBorderColor(unpack(UI.border))

    local titleText = titleBar:CreateFontString(nil, "OVERLAY")
    titleText:SetFont(FONT, 12, "")
    titleText:SetTextColor(unpack(UI.accent))
    titleText:SetPoint("LEFT", 12, 0)
    titleText:SetText("Jar's Bags")

    -- Gold display
    local goldText = titleBar:CreateFontString(nil, "OVERLAY")
    goldText:SetFont(FONT, 11, "")
    goldText:SetPoint("RIGHT", titleBar, "RIGHT", -80, 0)
    frame.goldText = goldText

    -- Close button
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(30, 30)
    closeBtn:SetPoint("RIGHT", -2, 0)
    closeBtn.label = closeBtn:CreateFontString(nil, "OVERLAY")
    closeBtn.label:SetFont(FONT, 14, "")
    closeBtn.label:SetTextColor(unpack(UI.textDim))
    closeBtn.label:SetPoint("CENTER")
    closeBtn.label:SetText("x")
    closeBtn:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 0.35, 0.35) end)
    closeBtn:SetScript("OnLeave", function(self) self.label:SetTextColor(unpack(UI.textDim)) end)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    -- Sort button
    local sortBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    sortBtn:SetSize(44, 22)
    sortBtn:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
    sortBtn:SetBackdrop(backdrop_main)
    sortBtn:SetBackdropColor(unpack(UI.btnNormal))
    sortBtn:SetBackdropBorderColor(unpack(UI.border))
    sortBtn.label = sortBtn:CreateFontString(nil, "OVERLAY")
    sortBtn.label:SetFont(FONT, 10, "")
    sortBtn.label:SetTextColor(unpack(UI.accent))
    sortBtn.label:SetPoint("CENTER")
    sortBtn.label:SetText("Sort")
    sortBtn:SetScript("OnEnter", function(self) self:SetBackdropColor(unpack(UI.btnHover)) end)
    sortBtn:SetScript("OnLeave", function(self) self:SetBackdropColor(unpack(UI.btnNormal)) end)
    sortBtn:SetScript("OnClick", function()
        C_Container.SortBags()
    end)

    -- Toolbar row (below title bar)
    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetHeight(24)
    toolbar:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 12, -4)
    toolbar:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", -12, -4)

    -- Equipment set highlight checkbox
    local setCheck = CreateFrame("CheckButton", nil, toolbar)
    setCheck:SetSize(16, 16)
    setCheck:SetPoint("LEFT", 0, 0)

    setCheck.bg = setCheck:CreateTexture(nil, "BACKGROUND")
    setCheck.bg:SetAllPoints()
    setCheck.bg:SetColorTexture(unpack(UI.border))

    setCheck.check = setCheck:CreateTexture(nil, "ARTWORK")
    setCheck.check:SetSize(12, 12)
    setCheck.check:SetPoint("CENTER")
    setCheck.check:SetColorTexture(unpack(UI.accent))

    local setLabel = toolbar:CreateFontString(nil, "OVERLAY")
    setLabel:SetFont(FONT, 10, "")
    setLabel:SetTextColor(unpack(UI.text))
    setLabel:SetPoint("LEFT", setCheck, "RIGHT", 6, 0)
    setLabel:SetText("Highlight Set Items")

    setCheck:SetScript("OnClick", function(self)
        JarsBagsDB.highlightSets = not JarsBagsDB.highlightSets
        self.check:SetShown(JarsBagsDB.highlightSets)
        if frame:IsShown() then
            frame:RefreshBags()
        end
    end)

    -- Soulbound highlight checkbox
    local sbCheck = CreateFrame("CheckButton", nil, toolbar)
    sbCheck:SetSize(16, 16)
    sbCheck:SetPoint("LEFT", setLabel, "RIGHT", 14, 0)

    sbCheck.bg = sbCheck:CreateTexture(nil, "BACKGROUND")
    sbCheck.bg:SetAllPoints()
    sbCheck.bg:SetColorTexture(unpack(UI.border))

    sbCheck.check = sbCheck:CreateTexture(nil, "ARTWORK")
    sbCheck.check:SetSize(12, 12)
    sbCheck.check:SetPoint("CENTER")
    sbCheck.check:SetColorTexture(0.6, 0.4, 1.0, 1)

    local sbLabel = toolbar:CreateFontString(nil, "OVERLAY")
    sbLabel:SetFont(FONT, 10, "")
    sbLabel:SetTextColor(unpack(UI.text))
    sbLabel:SetPoint("LEFT", sbCheck, "RIGHT", 6, 0)
    sbLabel:SetText("Soulbound")

    sbCheck:SetScript("OnClick", function(self)
        JarsBagsDB.highlightSoulbound = not JarsBagsDB.highlightSoulbound
        self.check:SetShown(JarsBagsDB.highlightSoulbound)
        if frame:IsShown() then
            frame:RefreshBags()
        end
    end)
    frame.sbCheck = sbCheck

    -- New Items filter checkbox
    local newCheck = CreateFrame("CheckButton", nil, toolbar)
    newCheck:SetSize(16, 16)
    newCheck:SetPoint("LEFT", sbLabel, "RIGHT", 14, 0)

    newCheck.bg = newCheck:CreateTexture(nil, "BACKGROUND")
    newCheck.bg:SetAllPoints()
    newCheck.bg:SetColorTexture(unpack(UI.border))

    newCheck.check = newCheck:CreateTexture(nil, "ARTWORK")
    newCheck.check:SetSize(12, 12)
    newCheck.check:SetPoint("CENTER")
    newCheck.check:SetColorTexture(1.0, 0.82, 0.0, 1)  -- gold
    newCheck.check:Hide()

    local newLabel = toolbar:CreateFontString(nil, "OVERLAY")
    newLabel:SetFont(FONT, 10, "")
    newLabel:SetTextColor(unpack(UI.text))
    newLabel:SetPoint("LEFT", newCheck, "RIGHT", 6, 0)
    newLabel:SetText("New Items")

    frame.filterNewItems = false
    newCheck:SetScript("OnClick", function(self)
        frame.filterNewItems = not frame.filterNewItems
        self.check:SetShown(frame.filterNewItems)
        if frame:IsShown() then
            frame:RefreshBags()
        end
    end)
    frame.newCheck = newCheck

    -- Bag slot count display
    local slotText = toolbar:CreateFontString(nil, "OVERLAY")
    slotText:SetFont(FONT, 10, "")
    slotText:SetTextColor(unpack(UI.textDim))
    slotText:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)
    frame.slotText = slotText

    -- Second toolbar row: BestGear controls
    local toolbar2 = CreateFrame("Frame", nil, frame)
    toolbar2:SetHeight(22)
    toolbar2:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -2)
    toolbar2:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -2)

    local bgCheck = CreateFrame("CheckButton", nil, toolbar2)
    bgCheck:SetSize(16, 16)
    bgCheck:SetPoint("LEFT", 0, 0)
    bgCheck.bg = bgCheck:CreateTexture(nil, "BACKGROUND")
    bgCheck.bg:SetAllPoints()
    bgCheck.bg:SetColorTexture(unpack(UI.border))
    bgCheck.check = bgCheck:CreateTexture(nil, "ARTWORK")
    bgCheck.check:SetSize(12, 12)
    bgCheck.check:SetPoint("CENTER")
    bgCheck.check:SetColorTexture(1.0, 0.85, 0.0, 1)
    bgCheck.check:SetShown(JarsBagsDB.highlightBestGear or false)
    local bgLabel = toolbar2:CreateFontString(nil, "OVERLAY")
    bgLabel:SetFont(FONT, 10, "")
    bgLabel:SetTextColor(unpack(UI.text))
    bgLabel:SetPoint("LEFT", bgCheck, "RIGHT", 6, 0)
    bgLabel:SetText("Best Gear")
    bgCheck:SetScript("OnClick", function(self)
        JarsBagsDB.highlightBestGear = not JarsBagsDB.highlightBestGear
        self.check:SetShown(JarsBagsDB.highlightBestGear)
        if frame:IsShown() then frame:RefreshBags() end
    end)
    frame.bgCheck = bgCheck

    local bgModeBtn = CreateFrame("Button", nil, toolbar2, "BackdropTemplate")
    bgModeBtn:SetSize(52, 18)
    bgModeBtn:SetPoint("LEFT", bgLabel, "RIGHT", 8, 0)
    bgModeBtn:SetBackdrop(backdrop_main)
    bgModeBtn:SetBackdropColor(unpack(UI.btnNormal))
    bgModeBtn:SetBackdropBorderColor(unpack(UI.border))
    bgModeBtn.label = bgModeBtn:CreateFontString(nil, "OVERLAY")
    bgModeBtn.label:SetFont(FONT, 10, "")
    bgModeBtn.label:SetTextColor(unpack(UI.accent))
    bgModeBtn.label:SetPoint("CENTER")
    bgModeBtn.label:SetText(BG_MODE_LABELS[JarsBagsDB.bestGearMode or "ILVL"] or "iLvl")
    bgModeBtn:SetScript("OnClick", function(self)
        local cur = JarsBagsDB.bestGearMode or "ILVL"
        local idx = 1
        for i, m in ipairs(BG_MODES) do if m.key == cur then idx=i; break end end
        local nxt = BG_MODES[(idx % #BG_MODES)+1]
        JarsBagsDB.bestGearMode = nxt.key
        self.label:SetText(nxt.label)
        if frame:IsShown() and JarsBagsDB.highlightBestGear then frame:RefreshBags() end
    end)
    bgModeBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(unpack(UI.btnHover))
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Best Gear Mode", 1, 0.82, 0)
        GameTooltip:AddLine("Click to cycle scoring mode:\niLvl / Haste / Crit / Mastery / Vers", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    bgModeBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(unpack(UI.btnNormal))
        GameTooltip:Hide()
    end)
    frame.bgModeBtn = bgModeBtn

    -- Search bar row
    local searchRow = CreateFrame("Frame", nil, frame)
    searchRow:SetHeight(22)
    searchRow:SetPoint("TOPLEFT", toolbar2, "BOTTOMLEFT", 0, -4)
    searchRow:SetPoint("TOPRIGHT", toolbar2, "BOTTOMRIGHT", 0, -4)

    local searchIcon = searchRow:CreateFontString(nil, "OVERLAY")
    searchIcon:SetFont(FONT, 10, "")
    searchIcon:SetTextColor(unpack(UI.textDim))
    searchIcon:SetPoint("LEFT", 0, 0)
    searchIcon:SetText("Search:")

    local searchBox = CreateFrame("EditBox", "JarsBagsSearchBox", searchRow, "BackdropTemplate")
    searchBox:SetSize(0, 20)
    searchBox:SetPoint("LEFT", searchIcon, "RIGHT", 6, 0)
    searchBox:SetPoint("RIGHT", searchRow, "RIGHT", 0, 0)
    searchBox:SetBackdrop(backdrop_main)
    searchBox:SetBackdropColor(0.08, 0.08, 0.08, 1)
    searchBox:SetBackdropBorderColor(unpack(UI.border))
    searchBox:SetFont(FONT, 11, "")
    searchBox:SetTextColor(1, 1, 1, 1)
    searchBox:SetTextInsets(6, 6, 0, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(40)
    searchBox:EnableMouse(true)

    searchBox:SetScript("OnTextChanged", function(self)
        frame.searchFilter = self:GetText():lower()
        if frame:IsShown() then
            frame:RefreshBags()
        end
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    frame.searchBox = searchBox
    frame.searchFilter = ""

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", searchRow, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 8)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(gridWidth)
    scrollFrame:SetScrollChild(content)
    frame.content = content

    -- Reparent bag ID frames into scroll child so buttons scroll/clip correctly
    for _, f in pairs(bagParentFrames) do
        f:SetParent(content)
    end

    local initialRefreshDone = false   -- not persisted; resets every UI reload

    frame:HookScript("OnShow", function()
        content:SetWidth(gridWidth)
        -- Defer one extra refresh after the very first UI-load show so the
        -- scroll child has valid screen coords for cross-parent anchoring.
        if not initialRefreshDone then
            initialRefreshDone = true
            C_Timer.After(0, function()
                if frame:IsShown() then frame:RefreshBags() end
            end)
        end
    end)

    -- Debounced refresh: coalesces rapid events into a single layout pass
    function frame:ScheduleRefresh()
        if pendingRefresh then return end
        pendingRefresh = true
        refreshTimer = C_Timer.After(0, function()
            pendingRefresh = false
            refreshTimer = nil
            if self:IsShown() then
                self:RefreshBags()
            end
        end)
    end

    -- Refresh function
    function frame:RefreshBags()
        -- Snapshot new-item flags every refresh (cache is used by filter & glow)
        wipe(newItemCache)
        if C_NewItems then
            for _, bagID in ipairs(BAG_IDS) do
                local numSlots = C_Container.GetContainerNumSlots(bagID)
                for slotID = 1, numSlots do
                    if C_NewItems.IsNewItem(bagID, slotID) then
                        newItemCache[bagID .. "-" .. slotID] = true
                    end
                end
            end
        end

        local categories = ScanBags()
        LayoutItems(self.content, categories)

        -- Update gold
        self.goldText:SetText(FormatGold(GetMoney()))

        -- Update free slots
        local totalSlots, usedSlots = 0, 0
        for _, bagID in ipairs(BAG_IDS) do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            totalSlots = totalSlots + numSlots
            for slotID = 1, numSlots do
                local info = C_Container.GetContainerItemInfo(bagID, slotID)
                if info then usedSlots = usedSlots + 1 end
            end
        end
        self.slotText:SetText((totalSlots - usedSlots) .. " free / " .. totalSlots .. " slots")

        -- Update checkbox visuals
        setCheck.check:SetShown(JarsBagsDB.highlightSets)
        sbCheck.check:SetShown(JarsBagsDB.highlightSoulbound)
        newCheck.check:SetShown(self.filterNewItems)
        if frame.bgCheck then
            frame.bgCheck.check:SetShown(JarsBagsDB.highlightBestGear or false)
        end
        if frame.bgModeBtn then
            frame.bgModeBtn.label:SetText(BG_MODE_LABELS[JarsBagsDB.bestGearMode or "ILVL"] or "iLvl")
        end
    end

    frame:HookScript("OnHide", function(self)
        self.filterNewItems = false
        newCheck.check:Hide()
        searchBox:SetText("")
        self.searchFilter = ""
    end)

    frame:Hide()
    mainFrame = frame
    return frame
end

---------------------------------------------------------------------------
-- Default Bag Suppression & Hooks
---------------------------------------------------------------------------
local bagsHooked = false

local function HookDefaultBags()
    if bagsHooked then return end
    bagsHooked = true

    local frame = CreateBagFrame()

    -- Suppress the default bag frames once at init so they never appear.
    -- ContainerFrameCombinedBags (retail combined view)
    if ContainerFrameCombinedBags then
        ContainerFrameCombinedBags:UnregisterAllEvents()
        ContainerFrameCombinedBags:SetScript("OnShow", function(self) self:Hide() end)
        ContainerFrameCombinedBags:Hide()
    end
    -- Legacy individual container frames (1-13)
    for i = 1, 13 do
        local cf = _G["ContainerFrame" .. i]
        if cf then
            cf:UnregisterAllEvents()
            cf:SetScript("OnShow", function(self) self:Hide() end)
            cf:Hide()
        end
    end

    -- Single hook on ToggleAllBags handles the bag button / keybind.
    -- We intentionally do NOT hook OpenAllBags/CloseAllBags separately,
    -- because ToggleAllBags calls them internally and double-hooking
    -- causes the show/hide to fight itself.
    hooksecurefunc("ToggleAllBags", function()
        if frame:IsShown() then
            frame:Hide()
        else
            frame:Show()
            frame:RefreshBags()
        end
    end)

    -- OpenAllBags is called by vendors, mail, etc. — just make sure our frame opens.
    hooksecurefunc("OpenAllBags", function()
        if not frame:IsShown() then
            frame:Show()
            frame:RefreshBags()
        end
    end)

    hooksecurefunc("CloseAllBags", function()
        frame:Hide()
    end)
end

---------------------------------------------------------------------------
-- Event Handler
---------------------------------------------------------------------------
local CreateBestGearUI  -- defined below; forward-declared so PLAYER_LOGIN can call it

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("EQUIPMENT_SETS_CHANGED")
eventFrame:RegisterEvent("ITEM_LOCK_CHANGED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        JarsBagsDB = JarsBagsDB or {}
        for k, v in pairs(DEFAULTS) do
            if JarsBagsDB[k] == nil then
                JarsBagsDB[k] = v
            end
        end

        CreateBagFrame()
        HookDefaultBags()
        CreateBestGearUI()

        -- Apply saved scale
        if mainFrame and JarsBagsDB.bagScale then
            mainFrame:SetScale(JarsBagsDB.bagScale)
        end

        print("|cff00ccffJar's Bags|r loaded. |cff00ff00/jb|r to toggle, |cff00ff00/jb options|r for settings.")

    elseif event == "BAG_UPDATE_DELAYED" then
        if mainFrame and mainFrame:IsShown() then
            mainFrame:ScheduleRefresh()
        end

    elseif event == "EQUIPMENT_SETS_CHANGED" then
        if mainFrame and mainFrame:IsShown() and JarsBagsDB.highlightSets then
            mainFrame:ScheduleRefresh()
        end

    elseif event == "ITEM_LOCK_CHANGED" then
        if mainFrame and mainFrame:IsShown() then
            mainFrame:ScheduleRefresh()
        end
    end
end)

---------------------------------------------------------------------------
-- Slash Commands
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Options Panel
---------------------------------------------------------------------------
local optionsFrame = nil

local function CreateOptionsPanel()
    if optionsFrame then
        optionsFrame:SetShown(not optionsFrame:IsShown())
        return
    end

    local f = CreateFrame("Frame", "JarsBagsOptions", UIParent, "BackdropTemplate")
    f:SetSize(280, 250)
    f:SetPoint("CENTER")
    f:SetBackdrop(backdrop_main)
    f:SetBackdropColor(unpack(UI.bg))
    f:SetBackdropBorderColor(unpack(UI.border))
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "JarsBagsOptions")

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY")
    title:SetFont(FONT, 12, "")
    title:SetTextColor(unpack(UI.accent))
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Jar's Bags Options")

    -- Close
    local cBtn = CreateFrame("Button", nil, f)
    cBtn:SetSize(24, 24)
    cBtn:SetPoint("TOPRIGHT", -4, -4)
    cBtn.label = cBtn:CreateFontString(nil, "OVERLAY")
    cBtn.label:SetFont(FONT, 14, "")
    cBtn.label:SetTextColor(unpack(UI.textDim))
    cBtn.label:SetPoint("CENTER")
    cBtn.label:SetText("x")
    cBtn:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 0.35, 0.35) end)
    cBtn:SetScript("OnLeave", function(self) self.label:SetTextColor(unpack(UI.textDim)) end)
    cBtn:SetScript("OnClick", function() f:Hide() end)

    local yPos = -34

    -- Helper: create a checkbox option
    local function MakeCheck(label, dbKey, onChange)
        local cb = CreateFrame("CheckButton", nil, f)
        cb:SetSize(16, 16)
        cb:SetPoint("TOPLEFT", 16, yPos)

        cb.bg = cb:CreateTexture(nil, "BACKGROUND")
        cb.bg:SetAllPoints()
        cb.bg:SetColorTexture(unpack(UI.border))

        cb.check = cb:CreateTexture(nil, "ARTWORK")
        cb.check:SetSize(12, 12)
        cb.check:SetPoint("CENTER")
        cb.check:SetColorTexture(unpack(UI.accent))
        cb.check:SetShown(JarsBagsDB[dbKey])

        local lbl = f:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(FONT, 10, "")
        lbl:SetTextColor(unpack(UI.text))
        lbl:SetPoint("LEFT", cb, "RIGHT", 8, 0)
        lbl:SetText(label)

        cb:SetScript("OnClick", function(self)
            JarsBagsDB[dbKey] = not JarsBagsDB[dbKey]
            self.check:SetShown(JarsBagsDB[dbKey])
            if onChange then onChange(JarsBagsDB[dbKey]) end
            if mainFrame and mainFrame:IsShown() then mainFrame:RefreshBags() end
        end)

        yPos = yPos - 28
        return cb
    end

    -- Show Item Level
    MakeCheck("Show Item Level", "showItemLevel")

    -- Show Upgrade Track
    MakeCheck("Show Upgrade Track (V/C/H/M)", "showUpgradeTrack")

    -- Lock Movement
    MakeCheck("Lock Bag Position", "lockMovement")

    -- Scale slider
    local scaleLabel = f:CreateFontString(nil, "OVERLAY")
    scaleLabel:SetFont(FONT, 10, "")
    scaleLabel:SetTextColor(unpack(UI.text))
    scaleLabel:SetPoint("TOPLEFT", 16, yPos)
    scaleLabel:SetText("Scale")

    local scaleValue = f:CreateFontString(nil, "OVERLAY")
    scaleValue:SetFont(FONT, 10, "")
    scaleValue:SetTextColor(unpack(UI.accent))
    scaleValue:SetPoint("TOPRIGHT", -16, yPos)

    yPos = yPos - 22

    -- Scale: minus button, track with thumb, plus button
    local function ApplyScale(value)
        value = math.max(0.5, math.min(1.5, value))
        value = math.floor(value * 20 + 0.5) / 20
        JarsBagsDB.bagScale = value
        scaleValue:SetText(string.format("%.0f%%", value * 100))
        if mainFrame then mainFrame:SetScale(value) end
    end

    local minusBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    minusBtn:SetSize(20, 20)
    minusBtn:SetPoint("TOPLEFT", 16, yPos)
    minusBtn:SetBackdrop(backdrop_main)
    minusBtn:SetBackdropColor(unpack(UI.btnNormal))
    minusBtn:SetBackdropBorderColor(unpack(UI.border))
    minusBtn.label = minusBtn:CreateFontString(nil, "OVERLAY")
    minusBtn.label:SetFont(FONT, 12, "")
    minusBtn.label:SetTextColor(unpack(UI.text))
    minusBtn.label:SetPoint("CENTER", 0, 1)
    minusBtn.label:SetText("-")
    minusBtn:SetScript("OnEnter", function(self) self:SetBackdropColor(unpack(UI.btnHover)) end)
    minusBtn:SetScript("OnLeave", function(self) self:SetBackdropColor(unpack(UI.btnNormal)) end)
    minusBtn:SetScript("OnClick", function()
        ApplyScale((JarsBagsDB.bagScale or 1.0) - 0.05)
        slider:SetValue(JarsBagsDB.bagScale)
    end)

    local plusBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    plusBtn:SetSize(20, 20)
    plusBtn:SetPoint("TOPRIGHT", -16, yPos)
    plusBtn:SetBackdrop(backdrop_main)
    plusBtn:SetBackdropColor(unpack(UI.btnNormal))
    plusBtn:SetBackdropBorderColor(unpack(UI.border))
    plusBtn.label = plusBtn:CreateFontString(nil, "OVERLAY")
    plusBtn.label:SetFont(FONT, 12, "")
    plusBtn.label:SetTextColor(unpack(UI.text))
    plusBtn.label:SetPoint("CENTER", 0, 1)
    plusBtn.label:SetText("+")
    plusBtn:SetScript("OnEnter", function(self) self:SetBackdropColor(unpack(UI.btnHover)) end)
    plusBtn:SetScript("OnLeave", function(self) self:SetBackdropColor(unpack(UI.btnNormal)) end)
    plusBtn:SetScript("OnClick", function()
        ApplyScale((JarsBagsDB.bagScale or 1.0) + 0.05)
        slider:SetValue(JarsBagsDB.bagScale)
    end)

    local slider = CreateFrame("Slider", nil, f, "BackdropTemplate")
    slider:SetSize(190, 20)
    slider:SetPoint("LEFT", minusBtn, "RIGHT", 4, 0)
    slider:SetPoint("RIGHT", plusBtn, "LEFT", -4, 0)
    slider:SetBackdrop(backdrop_main)
    slider:SetBackdropColor(unpack(UI.btnNormal))
    slider:SetBackdropBorderColor(unpack(UI.border))
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(0.5, 1.5)
    slider:SetValueStep(0.05)
    slider:SetObeyStepOnDrag(true)
    slider:EnableMouse(true)
    slider:SetValue(JarsBagsDB.bagScale or 1.0)

    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(12, 18)
    thumb:SetColorTexture(unpack(UI.accent))
    slider:SetThumbTexture(thumb)

    slider:EnableMouseWheel(true)
    slider:SetScript("OnMouseWheel", function(self, delta)
        ApplyScale((JarsBagsDB.bagScale or 1.0) + delta * 0.05)
        self:SetValue(JarsBagsDB.bagScale)
    end)

    scaleValue:SetText(string.format("%.0f%%", (JarsBagsDB.bagScale or 1.0) * 100))

    slider:SetScript("OnValueChanged", function(self, value)
        ApplyScale(value)
    end)

    optionsFrame = f
end

-- Global opener for JarsAddonConfig integration
function JarsBags_OpenConfig()
    CreateOptionsPanel()
    if optionsFrame then optionsFrame:Show() end
end

---------------------------------------------------------------------------
-- Slash Commands
---------------------------------------------------------------------------
SLASH_JARSBAGS1 = "/jb"
SLASH_JARSBAGS2 = "/jarsbags"
SlashCmdList["JARSBAGS"] = function(msg)
    msg = (msg or ""):lower():trim()
    if msg == "options" or msg == "config" or msg == "settings" then
        CreateOptionsPanel()
        return
    end
    local frame = CreateBagFrame()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        frame:RefreshBags()
    end
end
---------------------------------------------------------------------------
-- BestGear CharacterFrame Panel + Equip Engine
-- (All scoring logic lives in BestGearCore.lua loaded ahead of this file)
---------------------------------------------------------------------------

local bgEquipQueue  = {}
local bgModeButton  -- forward ref, set in CreateBestGearUI
local bgPanelCreated = false

local function BG_FindItemInBags(hyperlink)
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for bagSlot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, bagSlot)
            if info and info.hyperlink == hyperlink then
                return bag, bagSlot
            end
        end
    end
    return nil, nil
end

local function BG_ProcessEquipQueue()
    if #bgEquipQueue == 0 then return end
    local item = table.remove(bgEquipQueue, 1)

    local bag, bagSlot = item.bag, item.slot
    local verify = C_Container.GetContainerItemInfo(bag, bagSlot)
    if not verify or verify.hyperlink ~= item.itemLink then
        bag, bagSlot = BG_FindItemInBags(item.itemLink)
    end

    if bag and bagSlot then
        ClearCursor()
        C_Container.PickupContainerItem(bag, bagSlot)
        EquipCursorItem(item.targetSlot)
    else
        print("|cFFFF4444BestGear:|r Could not find " .. (item.itemLink or "item") .. " — skipped.")
    end

    if #bgEquipQueue > 0 then
        C_Timer.After(0.5, BG_ProcessEquipQueue)
    end
end

local function BG_EquipBestGear()
    if InCombatLockdown() then
        print("|cFFFF4444BestGear:|r Cannot equip gear in combat.")
        return
    end
    local modeKey = JarsBagsDB.bestGearMode or "ILVL"
    local plan    = BestGearCore.BuildEquipPlan(modeKey)
    if #plan == 0 then
        print("|cFF00FF88BestGear:|r Nothing to swap — already optimal.")
        return
    end
    print(string.format("|cFF00FF88BestGear:|r Equipping |cFFFFD100%d|r item(s)…", #plan))
    bgEquipQueue = plan
    BG_ProcessEquipQueue()
end

local function BG_CycleMode()
    local cur   = JarsBagsDB.bestGearMode or "ILVL"
    local modes = BestGearCore.MODES
    local idx   = 1
    for i, m in ipairs(modes) do if m.key == cur then idx = i; break end end
    local nxt = modes[(idx % #modes) + 1]
    JarsBagsDB.bestGearMode = nxt.key
    if bgModeButton then bgModeButton:SetText(nxt.label) end
    -- If bag window is open and highlight is on, refresh to show new mode
    if mainFrame and mainFrame:IsShown() and JarsBagsDB.highlightBestGear then
        mainFrame:RefreshBags()
    end
    print("|cFFFFD100BestGear mode:|r " .. nxt.label)
end

CreateBestGearUI = function()
    if bgPanelCreated then return end
    bgPanelCreated = true

    local backdrop = {
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    }

    local panel = CreateFrame("Frame", "BestGearPanel", UIParent, "BackdropTemplate")
    panel:SetSize(130, 82)
    panel:SetFrameStrata("HIGH")
    panel:SetBackdrop(backdrop)
    panel:SetBackdropColor(0.08, 0.08, 0.10, 0.95)
    panel:SetBackdropBorderColor(0.30, 0.30, 0.35, 1)
    panel:Hide()

    local titleLabel = panel:CreateFontString(nil, "OVERLAY")
    titleLabel:SetFont(FONT, 9, "")
    titleLabel:SetTextColor(0.55, 0.55, 0.58, 1)
    titleLabel:SetPoint("TOP", panel, "TOP", 0, -5)
    titleLabel:SetText("BEST GEAR")

    local equipBtn = CreateFrame("Button", "BestGearEquipButton", panel, "UIPanelButtonTemplate")
    equipBtn:SetSize(118, 24)
    equipBtn:SetPoint("TOP", titleLabel, "BOTTOM", 0, -4)
    equipBtn:SetText("Equip Best")
    equipBtn:SetScript("OnClick", BG_EquipBestGear)
    equipBtn:SetScript("OnEnter", function(self)
        local modeLabel = BestGearCore.MODE_LABELS[JarsBagsDB.bestGearMode or "ILVL"] or "iLvl"
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Equip Best Gear", 1, 0.82, 0)
        GameTooltip:AddLine("Scans bags, dumps each slot to chat,\nthen equips any upgrades.", 1, 1, 1, true)
        GameTooltip:AddLine("Mode: |cFF00FF88" .. modeLabel .. "|r", 1, 1, 1)
        GameTooltip:Show()
    end)
    equipBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    bgModeButton = CreateFrame("Button", "BestGearModeButton", panel, "UIPanelButtonTemplate")
    bgModeButton:SetSize(118, 22)
    bgModeButton:SetPoint("TOP", equipBtn, "BOTTOM", 0, -4)
    bgModeButton:SetText(BestGearCore.MODE_LABELS[JarsBagsDB.bestGearMode or "ILVL"] or "iLvl")
    bgModeButton:SetScript("OnClick", BG_CycleMode)
    bgModeButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Scoring Mode", 1, 0.82, 0)
        GameTooltip:AddLine("Click to cycle:\niLvl > Haste > Crit > Mastery > Vers", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    bgModeButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local function ShowPanel()
        panel:ClearAllPoints()
        panel:SetPoint("TOPLEFT", CharacterFrame, "TOPRIGHT", 6, -60)
        panel:Show()
    end

    CharacterFrame:HookScript("OnShow", ShowPanel)
    CharacterFrame:HookScript("OnHide", function() panel:Hide() end)
    if CharacterFrame:IsShown() then ShowPanel() end
end

SLASH_BESTGEAR1 = "/bestgear"
SLASH_BESTGEAR2 = "/bg"
SlashCmdList["BESTGEAR"] = function(msg)
    msg = strtrim(msg or ""):lower()
    local modeKey = JarsBagsDB.bestGearMode or "ILVL"
    if msg == "" then
        BG_EquipBestGear()
    elseif msg == "scan" or msg == "dump" then
        BestGearCore.BuildEquipPlan(modeKey)   -- prints to chat, no equip
    elseif msg == "mode" or msg == "cycle" then
        BG_CycleMode()
    else
        for _, m in ipairs(BestGearCore.MODES) do
            if m.label:lower():find(msg, 1, true) then
                JarsBagsDB.bestGearMode = m.key
                if bgModeButton then bgModeButton:SetText(m.label) end
                print("|cFFFFD100BestGear mode set to:|r " .. m.label)
                return
            end
        end
        print("|cFFFFD100BestGear|r commands:")
        print("  /bestgear          - equip best gear + dump results to chat")
        print("  /bestgear scan     - dump only (no equip)")
        print("  /bestgear mode     - cycle scoring mode")
        print("  /bestgear mastery  - set mode by name")
    end
end