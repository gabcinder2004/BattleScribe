-- BattleScribe: Tracks highest normal and critical hits for each ability

BattleScribe = {}
BattleScribe.frame = nil
BattleScribe.showCurrentSessionOnly = false
BattleScribe.filterType = "all" -- "all", "damage", "healing"
BattleScribe.sortColumn = "name" -- "name", "normal", "crit"
BattleScribe.sortAscending = true
BattleScribe.lastUpdateTime = 0
BattleScribe.updateThrottle = 0.5 -- Only update display every 0.5 seconds
BattleScribe.pendingUpdate = false
BattleScribe.iconCache = {} -- Cache for spell icon textures
BattleScribe.wasShownBeforeCombat = false -- Track visibility state for hide in combat

-- Initialize saved variables
function BattleScribe:Initialize()
    -- Get character-specific key
    local playerName = UnitName("player")
    local realmName = GetRealmName()
    self.characterKey = playerName .. "-" .. realmName

    -- Initialize global DB structure
    if not BattleScribeDB then
        BattleScribeDB = {
            characters = {},
            settings = {
                frameX = nil,
                frameY = nil,
                frameWidth = 250,
                frameHeight = 280,
                isShown = true,
                perCharacter = true, -- Track per-character by default
                sortColumn = "name",
                sortAscending = true,
                showCurrentSessionOnly = false,
                hideInCombat = false
            }
        }
    end

    -- Backward compatibility: migrate old data structure
    if BattleScribeDB.abilities then
        -- Old structure detected, migrate to new per-character structure
        if not BattleScribeDB.characters then
            BattleScribeDB.characters = {}
        end
        BattleScribeDB.characters[self.characterKey] = {
            abilities = BattleScribeDB.abilities
        }
        BattleScribeDB.abilities = nil -- Remove old structure
    end

    -- Backward compatibility: add frameWidth if missing
    if not BattleScribeDB.settings.frameWidth then
        BattleScribeDB.settings.frameWidth = 250
    end

    -- Backward compatibility: add frameHeight if missing
    if not BattleScribeDB.settings.frameHeight then
        BattleScribeDB.settings.frameHeight = 280
    end

    -- Backward compatibility: add perCharacter setting if missing
    if BattleScribeDB.settings.perCharacter == nil then
        BattleScribeDB.settings.perCharacter = true
    end

    -- Backward compatibility: add sort settings if missing
    if not BattleScribeDB.settings.sortColumn then
        BattleScribeDB.settings.sortColumn = "name"
    end
    if BattleScribeDB.settings.sortAscending == nil then
        BattleScribeDB.settings.sortAscending = true
    end
    if BattleScribeDB.settings.showCurrentSessionOnly == nil then
        BattleScribeDB.settings.showCurrentSessionOnly = false
    end
    if BattleScribeDB.settings.hideInCombat == nil then
        BattleScribeDB.settings.hideInCombat = false
    end

    -- Restore sort settings
    self.sortColumn = BattleScribeDB.settings.sortColumn
    self.sortAscending = BattleScribeDB.settings.sortAscending

    -- Restore time filter setting
    self.showCurrentSessionOnly = BattleScribeDB.settings.showCurrentSessionOnly

    -- Initialize current character's data if it doesn't exist
    if not BattleScribeDB.characters[self.characterKey] then
        BattleScribeDB.characters[self.characterKey] = {
            abilities = {}
        }
    end

    -- Migrate old ability data to new format (add displayName field)
    local charAbilities = BattleScribeDB.characters[self.characterKey].abilities
    for abilityKey, data in pairs(charAbilities) do
        -- If data doesn't have displayName, it's old format - migrate it
        if not data.displayName then
            -- Extract the ability name from the key (remove "|type" suffix if present)
            local _, _, baseName = string.find(abilityKey, "(.+)|%w+$")
            data.displayName = baseName or abilityKey
        end
    end

    -- Session data (not persisted)
    self.sessionData = {}

    self:CreateUI()
    self:RegisterEvents()

    -- Build initial sort comparator
    self:BuildSortComparator()

    -- Update sort indicators to reflect loaded settings
    self:UpdateSortIndicators()

    -- Update time filter button to reflect loaded state
    if self.showCurrentSessionOnly then
        self.timeFilterBtn.text:SetText("Session")
    else
        self.timeFilterBtn.text:SetText("All Time")
    end

    if BattleScribeDB.settings.isShown then
        self.frame:Show()
    else
        self.frame:Hide()
    end

    -- Display any existing data
    self:UpdateDisplay()

    -- Welcome message showing current character
    DEFAULT_CHAT_FRAME:AddMessage("BattleScribe loaded for " .. playerName .. ". Type /bs for commands.")
end

-- Register combat events
function BattleScribe:RegisterEvents()
    -- Primary tracking events
    self.frame:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
    self.frame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
    self.frame:RegisterEvent("CHAT_MSG_SPELL_SELF_BUFF")
    self.frame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE")  -- DoT/AoE ticks
    self.frame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS")   -- HoT ticks

    -- Critical: These are where "suffers damage from your" messages appear
    self.frame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_DAMAGE")
    self.frame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE")
    self.frame:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLY_DEATH")
    self.frame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")

    self.frame:RegisterEvent("PLAYER_LOGOUT")

    -- Combat state events for hide in combat feature
    self.frame:RegisterEvent("PLAYER_REGEN_DISABLED")  -- Entering combat
    self.frame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- Leaving combat
end

-- Parse combat messages and track hits
function BattleScribe:OnEvent(event, arg1)
    if event == "PLAYER_LOGOUT" then
        -- Save frame position, width and height
        local frameLeft = self.frame:GetLeft()
        local frameTop = self.frame:GetTop()
        local uiParentBottom = UIParent:GetBottom()

        BattleScribeDB.settings.frameX = frameLeft
        BattleScribeDB.settings.frameY = frameTop - uiParentBottom
        BattleScribeDB.settings.frameWidth = self.frame:GetWidth()
        BattleScribeDB.settings.frameHeight = self.frame:GetHeight()

        -- Save sort settings
        BattleScribeDB.settings.sortColumn = self.sortColumn
        BattleScribeDB.settings.sortAscending = self.sortAscending

        -- Save time filter setting
        BattleScribeDB.settings.showCurrentSessionOnly = self.showCurrentSessionOnly
        return
    end

    if event == "PLAYER_REGEN_DISABLED" then
        -- Entering combat
        if BattleScribeDB.settings.hideInCombat then
            if self.frame:IsShown() then
                self.frame:Hide()
                self.wasShownBeforeCombat = true
            end
            -- Also hide settings window
            if self.settingsFrame:IsShown() then
                self.settingsFrame:Hide()
            end
        end
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        -- Leaving combat
        if BattleScribeDB.settings.hideInCombat and self.wasShownBeforeCombat then
            self.frame:Show()
            self.wasShownBeforeCombat = false
        end
        return
    end

    -- Debug: Show all combat events and messages
    if BattleScribeDB and BattleScribeDB.settings and BattleScribeDB.settings.debug then
        if arg1 then
            DEFAULT_CHAT_FRAME:AddMessage("[BattleScribe Debug] Event: " .. event, 0.5, 1, 1)
            DEFAULT_CHAT_FRAME:AddMessage("[BattleScribe Debug] Message: " .. arg1, 0.5, 1, 0.5)
        end
    end

    local abilityName, amount, isCrit, abilityType = self:ParseCombatMessage(arg1, event)

    if abilityName and amount then
        local maximumBroken = self:TrackHit(abilityName, amount, isCrit, abilityType)
        -- Only update display if a maximum was actually broken
        if maximumBroken then
            self:ScheduleUpdate()
        end
    end
end

-- Schedule a throttled display update
function BattleScribe:ScheduleUpdate()
    local currentTime = GetTime()

    -- If enough time has passed, update immediately
    if currentTime - self.lastUpdateTime >= self.updateThrottle then
        self:UpdateDisplay()
        self.lastUpdateTime = currentTime
        self.pendingUpdate = false
    else
        -- Otherwise, schedule an update if one isn't pending
        if not self.pendingUpdate then
            self.pendingUpdate = true
            -- Use OnUpdate to handle the delayed update
            self.frame:SetScript("OnUpdate", function()
                local now = GetTime()
                if now - BattleScribe.lastUpdateTime >= BattleScribe.updateThrottle then
                    BattleScribe:UpdateDisplay()
                    BattleScribe.lastUpdateTime = now
                    BattleScribe.pendingUpdate = false
                    BattleScribe.frame:SetScript("OnUpdate", nil) -- Remove OnUpdate handler
                end
            end)
        end
    end
end

-- Helper function for pattern matching (WoW 1.12 uses Lua 5.0 which doesn't have string.match)
local function match(str, pattern)
    local _, _, cap1, cap2, cap3 = string.find(str, pattern)
    return cap1, cap2, cap3
end

-- Parse combat log messages
function BattleScribe:ParseCombatMessage(msg, event)
    -- Guard against nil messages
    if not msg then
        return nil, nil, nil, nil
    end

    local abilityName, amount, isCrit

    if event == "CHAT_MSG_COMBAT_SELF_HITS" then
        -- Auto attack hits
        -- "You hit Target for 123." or "You crit Target for 456."
        local _, _, dmg = string.find(msg, "You hit .+ for (%d+)%.")
        if dmg then
            return "Auto Attack", tonumber(dmg), false, "damage"
        end

        _, _, dmg = string.find(msg, "You crit .+ for (%d+)%.")
        if dmg then
            return "Auto Attack", tonumber(dmg), true, "damage"
        end

    elseif event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
        -- Spell damage - try multiple patterns to support all formats

        -- Pattern 1: "Your Ability hits Target for 123 DamageType damage." (with damage type)
        local ability, dmg = match(msg, "Your (.+) hits .+ for (%d+) %w+ damage%.")
        if ability and dmg then
            return ability, tonumber(dmg), false, "damage"
        end

        -- Pattern 2: "Your Ability crits Target for 456 DamageType damage." (with damage type)
        ability, dmg = match(msg, "Your (.+) crits .+ for (%d+) %w+ damage%.")
        if ability and dmg then
            return ability, tonumber(dmg), true, "damage"
        end

        -- Pattern 3: "Your Ability hits Target for 123." (no damage type)
        ability, dmg = match(msg, "Your (.+) hits .+ for (%d+)%.")
        if ability and dmg then
            return ability, tonumber(dmg), false, "damage"
        end

        -- Pattern 4: "Your Ability crits Target for 456." (no damage type)
        ability, dmg = match(msg, "Your (.+) crits .+ for (%d+)%.")
        if ability and dmg then
            return ability, tonumber(dmg), true, "damage"
        end

        -- Pattern 5: "Your Ability hit Target for 123 DamageType damage." (singular "hit" with type)
        ability, dmg = match(msg, "Your (.+) hit .+ for (%d+) %w+ damage%.")
        if ability and dmg then
            return ability, tonumber(dmg), false, "damage"
        end

        -- Pattern 6: "Your Ability crit Target for 456 DamageType damage." (singular "crit" with type)
        ability, dmg = match(msg, "Your (.+) crit .+ for (%d+) %w+ damage%.")
        if ability and dmg then
            return ability, tonumber(dmg), true, "damage"
        end

        -- Pattern 7: "Target suffers 123 DamageType damage from your Ability." (DoT/AoE format)
        dmg, ability = match(msg, ".+ suffers (%d+) %w+ damage from your (.+)%.")
        if ability and dmg then
            return ability, tonumber(dmg), false, "damage"
        end

        -- Pattern 8: "Target suffers 123 damage from your Ability." (DoT/AoE without damage type)
        dmg, ability = match(msg, ".+ suffers (%d+) damage from your (.+)%.")
        if ability and dmg then
            return ability, tonumber(dmg), false, "damage"
        end

        -- Debug: Log unmatched spell damage messages
        if BattleScribeDB and BattleScribeDB.settings and BattleScribeDB.settings.debug then
            DEFAULT_CHAT_FRAME:AddMessage("[BattleScribe Debug] Unmatched SPELL_SELF_DAMAGE: " .. msg, 1, 0.5, 0)
        end

    elseif event == "CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE" then
        -- Periodic damage (DoT/AoE ticks)
        -- Example: "Defias Bandit suffers 26 Frost damage from your Blizzard."

        -- Pattern 1: "Target suffers 123 DamageType damage from your Ability."
        local dmg, ability = match(msg, ".+ suffers (%d+) %w+ damage from your (.+)%.")
        if ability and dmg then
            return ability, tonumber(dmg), false, "damage"
        end

        -- Pattern 2: DoT tick without damage type "Target suffers 123 damage from your Ability."
        dmg, ability = match(msg, ".+ suffers (%d+) damage from your (.+)%.")
        if ability and dmg then
            return ability, tonumber(dmg), false, "damage"
        end

        -- Pattern 3: "Your Ability hits Target for 123 DamageType damage."
        ability, dmg = match(msg, "Your (.+) hits .+ for (%d+) %w+ damage%.")
        if ability and dmg then
            return ability, tonumber(dmg), false, "damage"
        end

        -- Pattern 4: Simple format "Your Ability hits Target for 123."
        ability, dmg = match(msg, "Your (.+) hits .+ for (%d+)%.")
        if ability and dmg then
            return ability, tonumber(dmg), false, "damage"
        end

        -- Debug: Log unmatched periodic damage messages
        if BattleScribeDB and BattleScribeDB.settings and BattleScribeDB.settings.debug then
            DEFAULT_CHAT_FRAME:AddMessage("[BattleScribe Debug] Unmatched PERIODIC_SELF_DAMAGE: " .. msg, 1, 0.5, 0)
        end

    elseif event == "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE" or
           event == "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE" or
           event == "CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_DAMAGE" then
        -- AoE/DoT damage to creatures (this is where Blizzard messages appear!)
        -- Example: "Defias Bandit suffers 27 Frost damage from your Blizzard."

        -- Pattern 1: "Target suffers 123 DamageType damage from your Ability."
        local dmg, ability = match(msg, ".+ suffers (%d+) %w+ damage from your (.+)%.")
        if ability and dmg then
            return ability, tonumber(dmg), false, "damage"
        end

        -- Pattern 2: Without damage type
        dmg, ability = match(msg, ".+ suffers (%d+) damage from your (.+)%.")
        if ability and dmg then
            return ability, tonumber(dmg), false, "damage"
        end

    elseif event == "CHAT_MSG_SPELL_SELF_BUFF" or event == "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS" then
        -- Healing (filter out non-healing messages)

        -- Pattern 1: "Your Ability critically heals Target for 456." (crit heals - check this FIRST)
        -- Use non-greedy match to avoid capturing "critically" in the ability name
        local ability, heal = match(msg, "Your (.+) critically heals .+ for (%d+)%.")
        if ability and heal then
            -- Trim any trailing whitespace from ability name
            ability = string.gsub(ability, "%s+$", "")
            return ability, tonumber(heal), true, "healing"
        end

        -- Pattern 2: "Your Ability heals Target for 123." (normal heals)
        -- Must NOT match if "critically" appears before "heals"
        if not string.find(msg, "critically heals") then
            ability, heal = match(msg, "Your (.+) heals .+ for (%d+)%.")
            if ability and heal then
                return ability, tonumber(heal), false, "healing"
            end
        end

        -- Pattern 3: HoT tick format "Target gains 123 health from your Ability."
        heal, ability = match(msg, ".+ gains (%d+) health from your (.+)%.")
        if ability and heal then
            return ability, tonumber(heal), false, "healing"
        end
    end

    return nil, nil, nil, nil
end

-- Track hit data
function BattleScribe:TrackHit(abilityName, amount, isCrit, abilityType)
    -- Get current character's ability data
    local charAbilities = BattleScribeDB.characters[self.characterKey].abilities

    -- Create a unique key that includes both name and type for abilities that do both damage and healing
    -- Format: "AbilityName|type" (e.g., "Holy Nova|damage", "Holy Nova|healing")
    local abilityKey = abilityName .. "|" .. abilityType

    -- Track whether any maximum was broken
    local maximumBroken = false

    -- Initialize ability data if needed
    if not charAbilities[abilityKey] then
        charAbilities[abilityKey] = {
            maxNormal = 0,
            maxCrit = 0,
            minNormal = nil,
            minCrit = nil,
            normalCount = 0,
            critCount = 0,
            normalTotal = 0,
            critTotal = 0,
            type = abilityType,
            displayName = abilityName  -- Store original name for display/icon lookup
        }
        maximumBroken = true  -- New ability is a "broken maximum"
    end

    -- Ensure backward compatibility - add missing fields to old data
    if not charAbilities[abilityKey].normalCount then
        charAbilities[abilityKey].minNormal = nil
        charAbilities[abilityKey].minCrit = nil
        charAbilities[abilityKey].normalCount = 0
        charAbilities[abilityKey].critCount = 0
        charAbilities[abilityKey].normalTotal = 0
        charAbilities[abilityKey].critTotal = 0
    end

    if not self.sessionData[abilityKey] then
        self.sessionData[abilityKey] = {
            maxNormal = 0,
            maxCrit = 0,
            minNormal = nil,
            minCrit = nil,
            normalCount = 0,
            critCount = 0,
            normalTotal = 0,
            critTotal = 0,
            type = abilityType,
            displayName = abilityName
        }
        maximumBroken = true  -- New ability in session
    end

    -- Update all-time records and statistics for this character
    if isCrit then
        -- Update crit statistics
        charAbilities[abilityKey].critCount = charAbilities[abilityKey].critCount + 1
        charAbilities[abilityKey].critTotal = charAbilities[abilityKey].critTotal + amount
        self.sessionData[abilityKey].critCount = self.sessionData[abilityKey].critCount + 1
        self.sessionData[abilityKey].critTotal = self.sessionData[abilityKey].critTotal + amount

        -- Update max crit
        if amount > charAbilities[abilityKey].maxCrit then
            charAbilities[abilityKey].maxCrit = amount
            maximumBroken = true
        end
        if amount > self.sessionData[abilityKey].maxCrit then
            self.sessionData[abilityKey].maxCrit = amount
            maximumBroken = true
        end

        -- Update min crit
        if not charAbilities[abilityKey].minCrit or amount < charAbilities[abilityKey].minCrit then
            charAbilities[abilityKey].minCrit = amount
        end
        if not self.sessionData[abilityKey].minCrit or amount < self.sessionData[abilityKey].minCrit then
            self.sessionData[abilityKey].minCrit = amount
        end
    else
        -- Update normal statistics
        charAbilities[abilityKey].normalCount = charAbilities[abilityKey].normalCount + 1
        charAbilities[abilityKey].normalTotal = charAbilities[abilityKey].normalTotal + amount
        self.sessionData[abilityKey].normalCount = self.sessionData[abilityKey].normalCount + 1
        self.sessionData[abilityKey].normalTotal = self.sessionData[abilityKey].normalTotal + amount

        -- Update max normal
        if amount > charAbilities[abilityKey].maxNormal then
            charAbilities[abilityKey].maxNormal = amount
            maximumBroken = true
        end
        if amount > self.sessionData[abilityKey].maxNormal then
            self.sessionData[abilityKey].maxNormal = amount
            maximumBroken = true
        end

        -- Update min normal
        if not charAbilities[abilityKey].minNormal or amount < charAbilities[abilityKey].minNormal then
            charAbilities[abilityKey].minNormal = amount
        end
        if not self.sessionData[abilityKey].minNormal or amount < self.sessionData[abilityKey].minNormal then
            self.sessionData[abilityKey].minNormal = amount
        end
    end

    return maximumBroken
end

-- Create main UI frame
function BattleScribe:CreateUI()
    -- Main frame
    local frame = CreateFrame("Frame", "BattleScribeFrame", UIParent)
    frame:SetWidth(BattleScribeDB.settings.frameWidth or 250)
    frame:SetHeight(BattleScribeDB.settings.frameHeight or 280)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    frame:SetBackdropColor(0, 0, 0, 0.8)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetMinResize(175, 150)
    frame:SetMaxResize(300, 600)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)

    -- Restore saved position and height
    if BattleScribeDB.settings.frameX and BattleScribeDB.settings.frameY then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT",
            BattleScribeDB.settings.frameX, BattleScribeDB.settings.frameY)
    else
        -- Default position if no saved position
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    -- Title bar background
    local titleBg = frame:CreateTexture(nil, "BACKGROUND")
    titleBg:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -4)
    titleBg:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    titleBg:SetHeight(20)
    titleBg:SetTexture(0, 0, 0, 0.6)

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", titleBg, "LEFT", 5, 0)
    title:SetText("BattleScribe")
    title:SetTextColor(1, 0.82, 0)

    -- Make frame draggable via title bar
    frame:SetScript("OnMouseDown", function()
        if arg1 == "LeftButton" then
            this:StartMoving()
        end
    end)
    frame:SetScript("OnMouseUp", function()
        this:StopMovingOrSizing()
        -- Save position immediately after moving
        -- Get the actual screen position of the frame's top-left corner
        local frameLeft = this:GetLeft()
        local frameTop = this:GetTop()
        local uiParentBottom = UIParent:GetBottom()

        -- Convert to TOPLEFT -> BOTTOMLEFT coordinates
        local x = frameLeft
        local y = frameTop - uiParentBottom

        BattleScribeDB.settings.frameX = x
        BattleScribeDB.settings.frameY = y

        -- Re-anchor to ensure consistent positioning
        this:ClearAllPoints()
        this:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    end)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame)
    closeBtn:SetWidth(16)
    closeBtn:SetHeight(16)
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -6)

    -- Custom yellow X icon
    local closeTexture = closeBtn:CreateTexture(nil, "ARTWORK")
    closeTexture:SetWidth(16)
    closeTexture:SetHeight(16)
    closeTexture:SetAllPoints(closeBtn)
    closeTexture:SetTexture("Interface\\AddOns\\BattleScribe\\images\\yellow_close_x_icon.tga")
    closeTexture:SetTexCoord(0, 1, 0, 1)
    closeBtn.closeTexture = closeTexture

    closeBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    closeBtn:SetScript("OnEnter", function()
        this.closeTexture:SetVertexColor(1.2, 1.2, 1.2)
    end)
    closeBtn:SetScript("OnLeave", function()
        this.closeTexture:SetVertexColor(1, 1, 1)
    end)
    closeBtn:SetScript("OnClick", function()
        BattleScribe:ToggleFrame()
    end)

    -- Menu button (cogwheel icon for settings)
    local menuBtn = CreateFrame("Button", nil, frame)
    menuBtn:SetWidth(14)
    menuBtn:SetHeight(14)
    menuBtn:SetPoint("RIGHT", closeBtn, "LEFT", -3, 0)

    -- Create cogwheel texture using custom yellow icon
    local cogTexture = menuBtn:CreateTexture(nil, "ARTWORK")
    cogTexture:SetWidth(14)
    cogTexture:SetHeight(14)
    cogTexture:SetAllPoints(menuBtn)
    cogTexture:SetTexture("Interface\\AddOns\\BattleScribe\\images\\yellow_cogwheel_icon.tga")
    cogTexture:SetTexCoord(0, 1, 0, 1)
    menuBtn.cogTexture = cogTexture

    menuBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    menuBtn:SetScript("OnEnter", function()
        this.cogTexture:SetVertexColor(1.2, 1.2, 1.2)
    end)
    menuBtn:SetScript("OnLeave", function()
        this.cogTexture:SetVertexColor(1, 1, 1)
    end)
    menuBtn:SetScript("OnClick", function()
        BattleScribe:ToggleMenu()
    end)
    frame.menuBtn = menuBtn

    -- Resize grip (bottom-left corner, away from scrollbar)
    local resizeGrip = CreateFrame("Frame", nil, frame)
    resizeGrip:SetWidth(16)
    resizeGrip:SetHeight(16)
    resizeGrip:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 6, 6)
    resizeGrip:EnableMouse(true)
    resizeGrip:SetFrameLevel(frame:GetFrameLevel() + 10)

    -- Use custom resize grip texture
    local gripTexture = resizeGrip:CreateTexture(nil, "OVERLAY")
    gripTexture:SetWidth(16)
    gripTexture:SetHeight(16)
    gripTexture:SetPoint("CENTER", resizeGrip, "CENTER")
    gripTexture:SetTexture("Interface\\AddOns\\BattleScribe\\images\\ResizeGrip.tga")
    gripTexture:SetTexCoord(1, 0, 0, 1)  -- Flip horizontally for bottom-left
    gripTexture:SetVertexColor(1, 1, 1, 0.5)
    resizeGrip.texture = gripTexture

    resizeGrip:SetScript("OnEnter", function()
        gripTexture:SetVertexColor(1, 1, 1, 1)
    end)
    resizeGrip:SetScript("OnLeave", function()
        gripTexture:SetVertexColor(1, 1, 1, 0.5)
    end)
    resizeGrip:SetScript("OnMouseDown", function()
        frame:StartSizing("BOTTOMLEFT")
    end)
    resizeGrip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        -- Save both width and height
        local width, height = frame:GetWidth(), frame:GetHeight()
        BattleScribeDB.settings.frameWidth = width
        BattleScribeDB.settings.frameHeight = height
        BattleScribe:UpdateDisplay() -- Update display to handle responsive layout
    end)

    -- Responsive layout on resize
    frame:SetScript("OnSizeChanged", function()
        BattleScribe:UpdateDisplay()
    end)

    -- Create settings window (separate frame)
    self:CreateSettingsWindow()

    -- Column headers background
    local headerBg = frame:CreateTexture(nil, "BACKGROUND")
    headerBg:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -28)
    headerBg:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -28)
    headerBg:SetHeight(16)
    headerBg:SetTexture(0, 0, 0, 0.4)

    -- Column header: Ability (clickable)
    local headerAbilityBtn = CreateFrame("Button", nil, frame)
    headerAbilityBtn:SetPoint("LEFT", headerBg, "LEFT", 4, 0)
    headerAbilityBtn:SetWidth(120)
    headerAbilityBtn:SetHeight(16)
    local headerAbility = headerAbilityBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerAbility:SetPoint("LEFT", headerAbilityBtn, "LEFT", 0, 0)
    headerAbility:SetText("Ability")
    headerAbility:SetTextColor(0.7, 0.7, 0.7)
    frame.headerAbility = headerAbility
    frame.headerAbilityBtn = headerAbilityBtn  -- Store button reference
    headerAbilityBtn:SetScript("OnClick", function()
        BattleScribe:SetSort("name")
    end)
    headerAbilityBtn:SetScript("OnEnter", function()
        headerAbility:SetTextColor(1, 1, 1)
    end)
    headerAbilityBtn:SetScript("OnLeave", function()
        headerAbility:SetTextColor(0.7, 0.7, 0.7)
    end)

    -- Column header: Normal (clickable)
    local headerNormalBtn = CreateFrame("Button", nil, frame)
    headerNormalBtn:SetPoint("RIGHT", headerBg, "RIGHT", -78, 0)
    headerNormalBtn:SetWidth(50)
    headerNormalBtn:SetHeight(16)
    local headerNormal = headerNormalBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerNormal:SetPoint("CENTER", headerNormalBtn, "CENTER", 0, 0)
    headerNormal:SetJustifyH("RIGHT")
    headerNormal:SetText("Normal")
    headerNormal:SetTextColor(0.7, 0.7, 0.7)
    frame.headerNormal = headerNormal
    frame.headerNormalBtn = headerNormalBtn  -- Store button reference
    frame.headerBg = headerBg  -- Store header background reference
    headerNormalBtn:SetScript("OnClick", function()
        BattleScribe:SetSort("normal")
    end)
    headerNormalBtn:SetScript("OnEnter", function()
        headerNormal:SetTextColor(1, 1, 1)
    end)
    headerNormalBtn:SetScript("OnLeave", function()
        headerNormal:SetTextColor(0.7, 0.7, 0.7)
    end)

    -- Column header: Crit (clickable)
    local headerCritBtn = CreateFrame("Button", nil, frame)
    headerCritBtn:SetPoint("RIGHT", headerBg, "RIGHT", -28, 0)
    headerCritBtn:SetWidth(50)
    headerCritBtn:SetHeight(16)
    local headerCrit = headerCritBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerCrit:SetPoint("CENTER", headerCritBtn, "CENTER", 0, 0)
    headerCrit:SetJustifyH("RIGHT")
    headerCrit:SetWidth(45)
    headerCrit:SetText("Crit")
    headerCrit:SetTextColor(0.7, 0.7, 0.7)
    frame.headerCrit = headerCrit
    frame.headerCritBtn = headerCritBtn  -- Store button reference
    headerCritBtn:SetScript("OnClick", function()
        BattleScribe:SetSort("crit")
    end)
    headerCritBtn:SetScript("OnEnter", function()
        headerCrit:SetTextColor(1, 1, 1)
    end)
    headerCritBtn:SetScript("OnLeave", function()
        headerCrit:SetTextColor(0.7, 0.7, 0.7)
    end)

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", "BattleScribeScrollFrame", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -48)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 8)

    -- Content frame (holds the ability list)
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(210)
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)
    frame.content = content
    frame.scrollFrame = scrollFrame

    -- Create ability stats tooltip (reused for all abilities)
    self:CreateStatsTooltip()

    -- Event handler
    frame:SetScript("OnEvent", function()
        BattleScribe:OnEvent(event, arg1)
    end)

    self.frame = frame
end

-- Create reusable stats tooltip
function BattleScribe:CreateStatsTooltip()
    local tooltip = CreateFrame("Frame", "BattleScribeStatsTooltip", UIParent)
    tooltip:SetWidth(260)
    tooltip:SetHeight(135)
    tooltip:SetFrameStrata("TOOLTIP")
    tooltip:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    tooltip:SetBackdropColor(0, 0, 0, 0.95)
    tooltip:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    tooltip:Hide()

    -- Title
    tooltip.title = tooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    tooltip.title:SetPoint("TOPLEFT", tooltip, "TOPLEFT", 10, -10)
    tooltip.title:SetTextColor(1, 0.82, 0)

    -- Statistics header
    tooltip.statsHeader = tooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tooltip.statsHeader:SetPoint("TOPLEFT", tooltip.title, "BOTTOMLEFT", 0, -5)
    tooltip.statsHeader:SetText("|cFFFFFFFFStatistics|r")
    tooltip.statsHeader:SetJustifyH("LEFT")

    -- Create table-like structure with label and value columns
    local yOffset = -8
    local labelX = 0
    local valueX = 90

    -- Total Hits row
    tooltip.label1 = tooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tooltip.label1:SetPoint("TOPLEFT", tooltip.statsHeader, "BOTTOMLEFT", labelX, yOffset)
    tooltip.label1:SetText("Total Hits:")
    tooltip.label1:SetJustifyH("LEFT")

    tooltip.value1 = tooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tooltip.value1:SetPoint("TOPLEFT", tooltip.statsHeader, "BOTTOMLEFT", valueX, yOffset)
    tooltip.value1:SetJustifyH("LEFT")

    -- Normal row
    yOffset = yOffset - 14
    tooltip.label2 = tooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tooltip.label2:SetPoint("TOPLEFT", tooltip.statsHeader, "BOTTOMLEFT", labelX, yOffset)
    tooltip.label2:SetText("Normal:")
    tooltip.label2:SetJustifyH("LEFT")

    tooltip.value2 = tooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tooltip.value2:SetPoint("TOPLEFT", tooltip.statsHeader, "BOTTOMLEFT", valueX, yOffset)
    tooltip.value2:SetJustifyH("LEFT")

    -- Crit row
    yOffset = yOffset - 14
    tooltip.label3 = tooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tooltip.label3:SetPoint("TOPLEFT", tooltip.statsHeader, "BOTTOMLEFT", labelX, yOffset)
    tooltip.label3:SetText("Crit:")
    tooltip.label3:SetJustifyH("LEFT")

    tooltip.value3 = tooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tooltip.value3:SetPoint("TOPLEFT", tooltip.statsHeader, "BOTTOMLEFT", valueX, yOffset)
    tooltip.value3:SetJustifyH("LEFT")

    -- Total Damage row
    yOffset = yOffset - 20
    tooltip.label4 = tooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tooltip.label4:SetPoint("TOPLEFT", tooltip.statsHeader, "BOTTOMLEFT", labelX, yOffset)
    tooltip.label4:SetJustifyH("LEFT")

    tooltip.value4 = tooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tooltip.value4:SetPoint("TOPLEFT", tooltip.statsHeader, "BOTTOMLEFT", valueX, yOffset)
    tooltip.value4:SetJustifyH("LEFT")

    -- Range row
    yOffset = yOffset - 14
    tooltip.label5 = tooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tooltip.label5:SetPoint("TOPLEFT", tooltip.statsHeader, "BOTTOMLEFT", labelX, yOffset)
    tooltip.label5:SetText("Range:")
    tooltip.label5:SetJustifyH("LEFT")

    tooltip.value5 = tooltip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tooltip.value5:SetPoint("TOPLEFT", tooltip.statsHeader, "BOTTOMLEFT", valueX, yOffset)
    tooltip.value5:SetJustifyH("LEFT")

    self.statsTooltip = tooltip
end

-- Show ability stats tooltip
function BattleScribe:ShowStatsTooltip(abilityData, anchorFrame)
    local tooltip = self.statsTooltip
    if not tooltip or not abilityData then return end

    -- Calculate statistics
    local totalHits = abilityData.normalCount + abilityData.critCount
    if totalHits == 0 then return end  -- Don't show tooltip if no hits

    local critRate = (abilityData.critCount / totalHits) * 100
    local avgNormal = abilityData.normalCount > 0 and (abilityData.normalTotal / abilityData.normalCount) or 0
    local avgCrit = abilityData.critCount > 0 and (abilityData.critTotal / abilityData.critCount) or 0
    local totalDamage = abilityData.normalTotal + abilityData.critTotal

    -- Format min-max ranges
    local normalRange = "-"
    if abilityData.minNormal and abilityData.maxNormal > 0 then
        normalRange = abilityData.minNormal .. "-" .. abilityData.maxNormal
    end
    local critRange = "-"
    if abilityData.minCrit and abilityData.maxCrit > 0 then
        critRange = abilityData.minCrit .. "-" .. abilityData.maxCrit
    end

    -- Set title
    local typeName = abilityData.type == "healing" and "Healing" or "Damage"
    tooltip.title:SetText(abilityData.displayName .. " (" .. typeName .. ")")

    -- Set table values
    tooltip.value1:SetText(totalHits .. " (" .. string.format("%.1f", critRate) .. "% crit)")
    tooltip.value2:SetText(abilityData.normalCount .. " hits, avg " .. string.format("%.0f", avgNormal))
    tooltip.value3:SetText(abilityData.critCount .. " hits, avg " .. string.format("%.0f", avgCrit))

    tooltip.label4:SetText("Total " .. typeName .. ":")
    tooltip.value4:SetText(totalDamage)

    tooltip.value5:SetText(normalRange .. " / " .. critRange)

    -- Position tooltip near the ability row
    tooltip:ClearAllPoints()

    -- Check if tooltip would go off-screen to the right
    local tooltipWidth = tooltip:GetWidth()
    local anchorRight = anchorFrame:GetRight()
    local screenWidth = UIParent:GetRight()

    if anchorRight and screenWidth and (anchorRight + tooltipWidth + 5) > screenWidth then
        -- Position tooltip to the left of the frame
        tooltip:SetPoint("TOPRIGHT", anchorFrame, "TOPLEFT", -5, 0)
    else
        -- Position tooltip to the right of the frame (default)
        tooltip:SetPoint("TOPLEFT", anchorFrame, "TOPRIGHT", 5, 0)
    end

    tooltip:Show()
end

-- Create settings window
function BattleScribe:CreateSettingsWindow()
    local settingsFrame = CreateFrame("Frame", "BattleScribeSettingsFrame", UIParent)
    settingsFrame:SetWidth(180)
    settingsFrame:SetHeight(230)
    settingsFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    settingsFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    settingsFrame:SetBackdropColor(0, 0, 0, 0.9)
    settingsFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    settingsFrame:SetMovable(true)
    settingsFrame:EnableMouse(true)
    settingsFrame:SetClampedToScreen(true)
    settingsFrame:SetFrameStrata("DIALOG")
    settingsFrame:Hide()

    -- Title bar background
    local titleBg = settingsFrame:CreateTexture(nil, "BACKGROUND")
    titleBg:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 4, -4)
    titleBg:SetPoint("TOPRIGHT", settingsFrame, "TOPRIGHT", -4, -4)
    titleBg:SetHeight(18)
    titleBg:SetTexture(0, 0, 0, 0.6)

    -- Title
    local title = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("LEFT", titleBg, "LEFT", 5, 0)
    title:SetText("BattleScribe")
    title:SetTextColor(1, 0.82, 0)

    -- Make draggable
    settingsFrame:SetScript("OnMouseDown", function()
        if arg1 == "LeftButton" then
            this:StartMoving()
        end
    end)
    settingsFrame:SetScript("OnMouseUp", function()
        this:StopMovingOrSizing()
    end)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, settingsFrame)
    closeBtn:SetWidth(14)
    closeBtn:SetHeight(14)
    closeBtn:SetPoint("TOPRIGHT", settingsFrame, "TOPRIGHT", -7, -7)
    closeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    closeBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    closeBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    closeBtn:SetScript("OnClick", function()
        settingsFrame:Hide()
    end)

    -- Time Period Label
    local timeLabel = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    timeLabel:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 10, -30)
    timeLabel:SetText("Time Period:")
    timeLabel:SetTextColor(0.7, 0.7, 0.7)

    -- Time filter button
    local timeBtn = CreateFrame("Button", nil, settingsFrame)
    timeBtn:SetWidth(160)
    timeBtn:SetHeight(22)
    timeBtn:SetPoint("TOPLEFT", timeLabel, "BOTTOMLEFT", 0, -4)
    timeBtn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    timeBtn:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    timeBtn:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    local timeBtnText = timeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    timeBtnText:SetPoint("CENTER", 0, 0)
    timeBtnText:SetText("All Time")
    timeBtn:SetScript("OnEnter", function()
        this:SetBackdropColor(0.2, 0.2, 0.2, 1)
    end)
    timeBtn:SetScript("OnLeave", function()
        this:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    end)
    timeBtn:SetScript("OnClick", function()
        BattleScribe:ToggleTimeFilter()
    end)
    timeBtn.text = timeBtnText
    self.timeFilterBtn = timeBtn

    -- Show Type Label
    local typeLabel = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    typeLabel:SetPoint("TOPLEFT", timeBtn, "BOTTOMLEFT", 0, -8)
    typeLabel:SetText("Show Type:")
    typeLabel:SetTextColor(0.7, 0.7, 0.7)

    -- Type filter button
    local typeBtn = CreateFrame("Button", nil, settingsFrame)
    typeBtn:SetWidth(160)
    typeBtn:SetHeight(22)
    typeBtn:SetPoint("TOPLEFT", typeLabel, "BOTTOMLEFT", 0, -4)
    typeBtn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    typeBtn:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    typeBtn:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    local typeBtnText = typeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    typeBtnText:SetPoint("CENTER", 0, 0)
    typeBtnText:SetText("All")
    typeBtn:SetScript("OnEnter", function()
        this:SetBackdropColor(0.2, 0.2, 0.2, 1)
    end)
    typeBtn:SetScript("OnLeave", function()
        this:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    end)
    typeBtn:SetScript("OnClick", function()
        BattleScribe:ToggleTypeFilter()
    end)
    typeBtn.text = typeBtnText
    self.typeFilterBtn = typeBtn

    -- Hide in Combat Label
    local hideCombatLabel = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hideCombatLabel:SetPoint("TOPLEFT", typeBtn, "BOTTOMLEFT", 0, -8)
    hideCombatLabel:SetText("Hide in Combat:")
    hideCombatLabel:SetTextColor(0.7, 0.7, 0.7)

    -- Hide in Combat button
    local hideCombatBtn = CreateFrame("Button", nil, settingsFrame)
    hideCombatBtn:SetWidth(160)
    hideCombatBtn:SetHeight(22)
    hideCombatBtn:SetPoint("TOPLEFT", hideCombatLabel, "BOTTOMLEFT", 0, -4)
    hideCombatBtn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    hideCombatBtn:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    hideCombatBtn:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    local hideCombatBtnText = hideCombatBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hideCombatBtnText:SetPoint("CENTER", 0, 0)
    hideCombatBtnText:SetText(BattleScribeDB.settings.hideInCombat and "On" or "Off")
    hideCombatBtn:SetScript("OnEnter", function()
        this:SetBackdropColor(0.2, 0.2, 0.2, 1)
    end)
    hideCombatBtn:SetScript("OnLeave", function()
        this:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    end)
    hideCombatBtn:SetScript("OnClick", function()
        BattleScribe:ToggleHideInCombat()
    end)
    hideCombatBtn.text = hideCombatBtnText
    self.hideCombatBtn = hideCombatBtn

    -- Data Management Label
    local dataLabel = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dataLabel:SetPoint("TOPLEFT", hideCombatBtn, "BOTTOMLEFT", 0, -8)
    dataLabel:SetText("Data Management:")
    dataLabel:SetTextColor(0.7, 0.7, 0.7)

    -- Reset button
    local resetBtn = CreateFrame("Button", nil, settingsFrame)
    resetBtn:SetWidth(160)
    resetBtn:SetHeight(22)
    resetBtn:SetPoint("TOPLEFT", dataLabel, "BOTTOMLEFT", 0, -4)
    resetBtn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    resetBtn:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    resetBtn:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    local resetBtnText = resetBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    resetBtnText:SetPoint("CENTER", 0, 0)
    resetBtnText:SetText("Reset All Data")
    resetBtn:SetScript("OnEnter", function()
        this:SetBackdropColor(0.2, 0.2, 0.2, 1)
    end)
    resetBtn:SetScript("OnLeave", function()
        this:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    end)
    resetBtn:SetScript("OnClick", function()
        BattleScribe:ResetData()
    end)

    self.settingsFrame = settingsFrame
end

-- Toggle time filter (all time vs current session)
function BattleScribe:ToggleTimeFilter()
    self.showCurrentSessionOnly = not self.showCurrentSessionOnly

    if self.showCurrentSessionOnly then
        self.timeFilterBtn.text:SetText("Session")
    else
        self.timeFilterBtn.text:SetText("All Time")
    end

    self:UpdateDisplay()
end

-- Toggle type filter (all/damage/healing)
function BattleScribe:ToggleTypeFilter()
    if self.filterType == "all" then
        self.filterType = "damage"
        self.typeFilterBtn.text:SetText("Damage")
    elseif self.filterType == "damage" then
        self.filterType = "healing"
        self.typeFilterBtn.text:SetText("Heals")
    else
        self.filterType = "all"
        self.typeFilterBtn.text:SetText("All")
    end

    self:UpdateDisplay()
end

-- Toggle hide in combat setting
function BattleScribe:ToggleHideInCombat()
    BattleScribeDB.settings.hideInCombat = not BattleScribeDB.settings.hideInCombat

    if BattleScribeDB.settings.hideInCombat then
        self.hideCombatBtn.text:SetText("On")
    else
        self.hideCombatBtn.text:SetText("Off")
    end
end

-- Toggle menu visibility
function BattleScribe:ToggleMenu()
    if self.settingsFrame:IsShown() then
        self.settingsFrame:Hide()
    else
        self.settingsFrame:Show()
    end
end

-- Build sort comparator function (cached to avoid creating new closures on every sort)
function BattleScribe:BuildSortComparator()
    local sortColumn = self.sortColumn
    local sortAscending = self.sortAscending

    self.sortComparator = function(a, b)
        local aVal, bVal

        if sortColumn == "name" then
            aVal = a.name
            bVal = b.name
        elseif sortColumn == "normal" then
            aVal = a.maxNormal
            bVal = b.maxNormal
        elseif sortColumn == "crit" then
            aVal = a.maxCrit
            bVal = b.maxCrit
        end

        if sortAscending then
            return aVal < bVal
        else
            return aVal > bVal
        end
    end
end

-- Set sort column and direction
function BattleScribe:SetSort(column)
    if self.sortColumn == column then
        -- Toggle direction if clicking same column
        self.sortAscending = not self.sortAscending
    else
        -- New column, default to ascending
        self.sortColumn = column
        self.sortAscending = true
    end

    -- Rebuild sort comparator with new settings
    self:BuildSortComparator()

    -- Update header indicators
    self:UpdateSortIndicators()
    self:UpdateDisplay()
end

-- Update sort indicators on headers
function BattleScribe:UpdateSortIndicators()
    local arrow = self.sortAscending and " ▲" or " ▼"

    if self.sortColumn == "name" then
        self.frame.headerAbility:SetText("Ability" .. arrow)
        self.frame.headerNormal:SetText("Normal")
        self.frame.headerCrit:SetText("Crit")
    elseif self.sortColumn == "normal" then
        self.frame.headerAbility:SetText("Ability")
        self.frame.headerNormal:SetText("Normal" .. arrow)
        self.frame.headerCrit:SetText("Crit")
    elseif self.sortColumn == "crit" then
        self.frame.headerAbility:SetText("Ability")
        self.frame.headerNormal:SetText("Normal")
        self.frame.headerCrit:SetText("Crit" .. arrow)
    end
end

-- Get spell icon texture by name with fuzzy matching
function BattleScribe:GetSpellIcon(spellName)
    -- Check cache first
    if self.iconCache[spellName] then
        return self.iconCache[spellName]
    end

    -- Special case for Auto Attack
    if spellName == "Auto Attack" then
        self.iconCache[spellName] = "Interface\\Icons\\INV_Sword_04"
        return self.iconCache[spellName]
    end

    -- First pass: Try exact match in player's spellbook
    local i = 1
    while true do
        local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then
            break
        end
        if name == spellName then
            local texture = GetSpellTexture(i, BOOKTYPE_SPELL)
            self.iconCache[spellName] = texture
            return texture
        end
        i = i + 1
    end

    -- Second pass: Try exact match in pet spellbook
    i = 1
    while true do
        local name, rank = GetSpellName(i, BOOKTYPE_PET)
        if not name then
            break
        end
        if name == spellName then
            local texture = GetSpellTexture(i, BOOKTYPE_PET)
            self.iconCache[spellName] = texture
            return texture
        end
        i = i + 1
    end

    -- Third pass: Try exact match in talents
    local numTabs = GetNumTalentTabs()
    for tabIndex = 1, numTabs do
        local numTalents = GetNumTalents(tabIndex)
        for talentIndex = 1, numTalents do
            local name, iconTexture, tier, column, currentRank, maxRank = GetTalentInfo(tabIndex, talentIndex)
            if name == spellName then
                self.iconCache[spellName] = iconTexture
                return iconTexture
            end
        end
    end

    -- Fourth pass: Try fuzzy match using "contains" - search spellbook
    local lowerSpellName = string.lower(spellName)
    i = 1
    while true do
        local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then
            break
        end
        local lowerName = string.lower(name)
        -- Check if either name contains the other (handles "Deep Wound" vs "Deep Wounds")
        if string.find(lowerName, lowerSpellName) or string.find(lowerSpellName, lowerName) then
            local texture = GetSpellTexture(i, BOOKTYPE_SPELL)
            self.iconCache[spellName] = texture
            return texture
        end
        i = i + 1
    end

    -- Fifth pass: Try fuzzy match in pet spellbook
    i = 1
    while true do
        local name, rank = GetSpellName(i, BOOKTYPE_PET)
        if not name then
            break
        end
        local lowerName = string.lower(name)
        if string.find(lowerName, lowerSpellName) or string.find(lowerSpellName, lowerName) then
            local texture = GetSpellTexture(i, BOOKTYPE_PET)
            self.iconCache[spellName] = texture
            return texture
        end
        i = i + 1
    end

    -- Sixth pass: Try fuzzy match in talents
    for tabIndex = 1, numTabs do
        local numTalents = GetNumTalents(tabIndex)
        for talentIndex = 1, numTalents do
            local name, iconTexture, tier, column, currentRank, maxRank = GetTalentInfo(tabIndex, talentIndex)
            if name then
                local lowerName = string.lower(name)
                if string.find(lowerName, lowerSpellName) or string.find(lowerSpellName, lowerName) then
                    self.iconCache[spellName] = iconTexture
                    return iconTexture
                end
            end
        end
    end

    -- Cache nil result to avoid repeated lookups for unknown spells
    self.iconCache[spellName] = nil
    return nil
end

-- Update the ability list display
function BattleScribe:UpdateDisplay()
    -- Clear existing content by reusing or creating a frame pool
    local content = self.frame.content

    -- Initialize frame pool if it doesn't exist
    if not self.entryFrames then
        self.entryFrames = {}
    end

    -- Hide all existing frames (reuse cached frame list)
    local frameCount = table.getn(self.entryFrames)
    for i = 1, frameCount do
        self.entryFrames[i]:Hide()
        self.entryFrames[i]:ClearAllPoints()
    end

    -- Check if we're in narrow mode (below 250px threshold)
    local frameWidth = self.frame:GetWidth()
    local isNarrowMode = frameWidth < 250

    -- Update content width dynamically based on frame width
    local contentWidth = frameWidth - 40  -- Account for padding and scrollbar
    content:SetWidth(contentWidth)

    -- Update column header positions based on mode
    if isNarrowMode then
        -- In narrow mode, hide ability header and position number headers from left
        self.frame.headerAbilityBtn:Hide()

        -- Position Normal header (icon is 2px + 14px + 10px gap = 26px from left)
        self.frame.headerNormalBtn:ClearAllPoints()
        self.frame.headerNormalBtn:SetPoint("LEFT", self.frame.headerBg, "LEFT", 26, 0)
        self.frame.headerNormalBtn:SetWidth(45)

        -- Position Crit header (after normal column + gap)
        self.frame.headerCritBtn:ClearAllPoints()
        self.frame.headerCritBtn:SetPoint("LEFT", self.frame.headerNormalBtn, "RIGHT", 8, 0)
        self.frame.headerCritBtn:SetWidth(45)
    else
        -- In wide mode, show ability header and use standard positions
        self.frame.headerAbilityBtn:Show()

        self.frame.headerNormalBtn:ClearAllPoints()
        self.frame.headerNormalBtn:SetPoint("RIGHT", self.frame.headerBg, "RIGHT", -78, 0)
        self.frame.headerNormalBtn:SetWidth(50)

        self.frame.headerCritBtn:ClearAllPoints()
        self.frame.headerCritBtn:SetPoint("RIGHT", self.frame.headerBg, "RIGHT", -28, 0)
        self.frame.headerCritBtn:SetWidth(50)
    end

    -- Get data source based on filter (use current character's data)
    local charAbilities = BattleScribeDB.characters[self.characterKey].abilities
    local dataSource = self.showCurrentSessionOnly and self.sessionData or charAbilities

    -- Create sorted list of abilities
    local sortedAbilities = {}
    for abilityKey, data in pairs(dataSource) do
        -- Filter by type
        if (self.filterType == "all" or data.type == self.filterType) and
           (data.maxNormal > 0 or data.maxCrit > 0) then

            -- Get display name (for new format with displayName, or fallback to key for old data)
            local displayName = data.displayName or abilityKey

            table.insert(sortedAbilities, {
                key = abilityKey,
                name = displayName,  -- Use displayName for display and icon lookup
                maxNormal = data.maxNormal,
                maxCrit = data.maxCrit,
                type = data.type
            })
        end
    end

    -- Sort based on selected column and direction (using cached comparator)
    table.sort(sortedAbilities, self.sortComparator)

    -- Create display entries (table rows), reusing frames when possible
    local yOffset = 0

    for i, ability in ipairs(sortedAbilities) do
        -- Reuse existing frame from pool or create new one
        local entry = self.entryFrames[i]
        if not entry then
            entry = CreateFrame("Frame", nil, content)
            entry:SetHeight(16)

            -- Create permanent child elements that will be reused
            entry.rowBg = entry:CreateTexture(nil, "BACKGROUND")
            entry.rowBg:SetAllPoints(entry)

            entry.icon = entry:CreateTexture(nil, "ARTWORK")
            entry.icon:SetWidth(14)
            entry.icon:SetHeight(14)
            entry.icon:SetPoint("LEFT", entry, "LEFT", 2, 0)

            entry.nameText = entry:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            entry.nameText:SetPoint("LEFT", entry.icon, "RIGHT", 3, 0)
            entry.nameText:SetJustifyH("LEFT")
            entry.nameText:SetWidth(113)

            entry.normalText = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            entry.normalText:SetJustifyH("RIGHT")
            entry.normalText:SetWidth(45)

            entry.critText = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            entry.critText:SetJustifyH("RIGHT")
            entry.critText:SetWidth(45)

            -- Enable mouse events for tooltip
            entry:EnableMouse(true)
            entry:SetScript("OnEnter", function()
                if this.abilityKey and BattleScribe then
                    local dataSource = BattleScribe.showCurrentSessionOnly and BattleScribe.sessionData or BattleScribeDB.characters[BattleScribe.characterKey].abilities
                    local abilityData = dataSource[this.abilityKey]
                    if abilityData then
                        BattleScribe:ShowStatsTooltip(abilityData, this)
                    end
                end
            end)
            entry:SetScript("OnLeave", function()
                if BattleScribe and BattleScribe.statsTooltip then
                    BattleScribe.statsTooltip:Hide()
                end
            end)

            -- Add to frame pool
            self.entryFrames[i] = entry
        end

        -- Store ability key for tooltip lookup
        entry.abilityKey = ability.key

        -- Update entry width dynamically
        entry:SetWidth(contentWidth)
        entry:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
        entry:Show()

        -- Alternating row background
        if math.mod(i, 2) == 0 then
            entry.rowBg:SetTexture(0, 0, 0, 0.2)
            entry.rowBg:Show()
        else
            entry.rowBg:Hide()
        end

        -- Get and set spell icon texture
        local iconTexture = self:GetSpellIcon(ability.name)
        if iconTexture then
            entry.icon:SetTexture(iconTexture)
        else
            entry.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        end

        -- Handle responsive layout based on frame width
        if isNarrowMode then
            -- Hide ability name in narrow mode
            entry.nameText:Hide()

            -- Adjust column positions for narrow mode (closer to icon)
            entry.normalText:ClearAllPoints()
            entry.normalText:SetPoint("LEFT", entry.icon, "RIGHT", 10, 0)

            entry.critText:ClearAllPoints()
            entry.critText:SetPoint("LEFT", entry.normalText, "RIGHT", 8, 0)
        else
            -- Show ability name with color coding in wide mode
            entry.nameText:Show()
            entry.nameText:SetText(ability.name)
            if ability.type == "healing" then
                entry.nameText:SetTextColor(0.4, 1, 0.4) -- Green
            else
                entry.nameText:SetTextColor(1, 1, 0.5) -- Yellow
            end

            -- Use standard column positions for wide mode
            entry.normalText:ClearAllPoints()
            entry.normalText:SetPoint("RIGHT", entry, "RIGHT", -55, 0)

            entry.critText:ClearAllPoints()
            entry.critText:SetPoint("RIGHT", entry, "RIGHT", -4, 0)
        end

        -- Update normal value
        local normalStr = ability.maxNormal > 0 and ability.maxNormal or "-"
        entry.normalText:SetText(normalStr)
        entry.normalText:SetTextColor(1, 1, 1)

        -- Update crit value
        local critStr = ability.maxCrit > 0 and ability.maxCrit or "-"
        entry.critText:SetText(critStr)
        entry.critText:SetTextColor(1, 0.5, 0.5)

        yOffset = yOffset - 16
    end

    -- Update content height for scrolling
    content:SetHeight(math.abs(yOffset))
end

-- Reset all tracked data for current character
function BattleScribe:ResetData()
    -- Confirmation prompt
    local playerName = UnitName("player")
    StaticPopupDialogs["BATTLESCRIBE_RESET_CONFIRM"] = {
        text = "Reset all tracked hits for " .. playerName .. "?",
        button1 = "Yes",
        button2 = "No",
        OnAccept = function()
            BattleScribeDB.characters[BattleScribe.characterKey].abilities = {}
            BattleScribe.sessionData = {}
            BattleScribe:UpdateDisplay()
            DEFAULT_CHAT_FRAME:AddMessage("BattleScribe: All data reset for " .. playerName .. ".")
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true
    }
    StaticPopup_Show("BATTLESCRIBE_RESET_CONFIRM")
end

-- Toggle frame visibility
function BattleScribe:ToggleFrame()
    if self.frame:IsShown() then
        self.frame:Hide()
        BattleScribeDB.settings.isShown = false
    else
        self.frame:Show()
        BattleScribeDB.settings.isShown = true
        self:UpdateDisplay()
    end
end

-- Slash command handler
SLASH_BATTLESCRIBE1 = "/battlescribe"
SLASH_BATTLESCRIBE2 = "/bs"
SlashCmdList["BATTLESCRIBE"] = function(msg)
    msg = string.lower(msg or "")

    if msg == "reset" then
        BattleScribe:ResetData()
    elseif msg == "toggle" or msg == "" then
        BattleScribe:ToggleFrame()
    elseif msg == "debug" then
        BattleScribeDB.settings.debug = not BattleScribeDB.settings.debug
        if BattleScribeDB.settings.debug then
            DEFAULT_CHAT_FRAME:AddMessage("BattleScribe: Debug mode enabled. Combat event messages will be shown.", 1, 1, 0)
            -- Check if string.match exists
            if string and string.match then
                DEFAULT_CHAT_FRAME:AddMessage("string.match is available", 0, 1, 0)
            else
                DEFAULT_CHAT_FRAME:AddMessage("ERROR: string.match is NOT available!", 1, 0, 0)
                DEFAULT_CHAT_FRAME:AddMessage("string table type: " .. type(string), 1, 0, 0)
                if string then
                    DEFAULT_CHAT_FRAME:AddMessage("string.match type: " .. type(string.match), 1, 0, 0)
                end
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("BattleScribe: Debug mode disabled.", 1, 1, 0)
        end
    elseif msg == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("BattleScribe Commands:")
        DEFAULT_CHAT_FRAME:AddMessage("/bs or /bs toggle - Toggle tracker window")
        DEFAULT_CHAT_FRAME:AddMessage("/bs reset - Reset all tracked data for this character")
        DEFAULT_CHAT_FRAME:AddMessage("/bs debug - Toggle debug mode")
        DEFAULT_CHAT_FRAME:AddMessage("/bs help - Show this help")
    else
        DEFAULT_CHAT_FRAME:AddMessage("Unknown command. Type /bs help for help.")
    end
end

-- Initialize on load
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    BattleScribe:Initialize()
end)
