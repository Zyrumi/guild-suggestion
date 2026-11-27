-- GuildSuggestion: the tab in the guild window and the right-click menu entry.
--
-- Page "Suggest": name + reason, and your own suggestions with their status.
-- Page "To decide": only for members who may invite. Waiting suggestions
-- with Invite / Decline, then the ones already decided.

local ADDON_NAME, ns = ...

local GOLD = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }
local DIM = { 0.65, 0.65, 0.65 }
local GOOD = { 0.35, 0.9, 0.35 }
local ICON = "Interface\\Icons\\INV_Letter_15"

local pages = {}
local currentPage = 1

-------------------------------------------------------------------------------
-- Building blocks
-------------------------------------------------------------------------------

local function Text(parent, template, text, color)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    local c = color or WHITE
    fs:SetTextColor(c[1], c[2], c[3])
    return fs
end

local function Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 100, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function Backdrop(f)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f:SetBackdropColor(0, 0, 0, 0.6)
        f:SetBackdropBorderColor(0.5, 0.45, 0.35, 1)
    end
end

-- One-line text box with a grey hint while empty.
local function Input(parent, width, hintText)
    local ok, e = pcall(CreateFrame, "EditBox", nil, parent, "InputBoxTemplate")
    if not ok or not e then
        e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
        Backdrop(e)
        e:SetTextInsets(6, 6, 0, 0)
    end
    e:SetSize(width, 22)
    e:SetAutoFocus(false)
    e:SetFontObject(ChatFontNormal)
    e:SetTextColor(1, 1, 1)
    local hint = Text(e, "GameFontHighlightSmall", hintText, DIM)
    hint:SetPoint("LEFT", 4, 0)
    local function UpdateHint()
        hint:SetShown(e:GetText() == "" and not e:HasFocus())
    end
    e:SetScript("OnEditFocusGained", UpdateHint)
    e:SetScript("OnEditFocusLost", UpdateHint)
    e:SetScript("OnTextChanged", UpdateHint)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    e.UpdateHint = UpdateHint
    return e
end

-- Tooltip with a title and wrapped lines.
local function ShowTip(owner, title, ...)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, GOLD[1], GOLD[2], GOLD[3])
    for i = 1, select("#", ...) do
        local line = select(i, ...)
        if line and line ~= "" then
            GameTooltip:AddLine(line, 1, 1, 1, true)
        end
    end
    GameTooltip:Show()
end

local function HideTip()
    GameTooltip:Hide()
end

-------------------------------------------------------------------------------
-- A list of rows (each entry has its own height). It scrolls by whole rows,
-- only when they don't all fit, with the game's own slim scroll bar (arrows,
-- track, thumb), the one the guild window's lists use. Same approach as
-- FriendsCraft's NativeScrollBar: the bar is driven by row offsets.
-------------------------------------------------------------------------------

local BAR_W = 14

local function NativeScrollBar(list)
    if not (ScrollBarMixin and ScrollBarMixin.Event and ScrollBarMixin.Event.OnScroll) then
        return nil
    end
    local ok, bar = pcall(CreateFrame, "EventFrame", nil, list, "MinimalScrollBar")
    if not ok or not bar or type(bar.SetScrollPercentage) ~= "function" or type(bar.RegisterCallback) ~= "function" then
        if ok and bar then
            bar:Hide()
        end
        return nil
    end
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", 0, 0)
    bar.useProportionalThumb = true
    bar:RegisterCallback(ScrollBarMixin.Event.OnScroll, function(_, pct)
        if list.syncing or type(pct) ~= "number" then
            return
        end
        list:SetOffset(math.floor(pct * list:MaxOffset() + 0.5))
    end, list)
    return bar
end

local function List(parent)
    local list = CreateFrame("Frame", nil, parent)
    list.rows = {}     -- built rows, reused
    list.entries = {}
    list.offset = 0
    list.bar = NativeScrollBar(list)
    if not rawget(list, "bar") then
        -- Where the game has no such bar: a plain hint instead.
        list.more = Text(list, "GameFontDisableSmall", "Scroll for more", DIM)
        list.more:SetPoint("BOTTOMRIGHT", 0, -14)
    end
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, delta)
        self:SetOffset(self.offset - delta)
    end)

    -- The first row that can be at the top with the rest still filling the
    -- box: 0 when everything fits (then nothing scrolls).
    function list:MaxOffset()
        local height, sum = self:GetHeight() or 0, 0
        for i = #self.entries, 1, -1 do
            sum = sum + self.entries[i].height
            if sum > height then
                return i
            end
        end
        return 0
    end

    function list:SetOffset(value)
        value = math.max(0, math.min(self:MaxOffset(), value or 0))
        if value ~= self.offset then
            self.offset = value
            self:Layout()
        end
    end

    function list:Layout()
        local y, height = 0, self:GetHeight()
        local max = self:MaxOffset()
        self.offset = math.min(self.offset, max)
        local scrolls = max > 0
        local bar, more = rawget(self, "bar"), rawget(self, "more")
        local right = (scrolls and bar) and -(BAR_W + 4) or 0
        for _, row in ipairs(self.rows) do
            row:Hide()
        end
        local used = 0
        for i = self.offset + 1, #self.entries do
            local e = self.entries[i]
            local h = e.height
            if y + h > height and used > 0 then
                break
            end
            used = used + 1
            local row = self.rows[used]
            if not row then
                row = self.MakeRow(self)
                self.rows[used] = row
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
            row:SetPoint("RIGHT", right, 0)
            row:SetHeight(h)
            -- One broken row must not blank the whole list; say what broke.
            local ok, err = pcall(self.FillRow, row, e)
            if not ok and not self.reported then
                self.reported = true
                ns.Print("error showing the list: " .. tostring(err))
            end
            row:Show()
            y = y + h
        end
        if bar then
            bar:SetShown(scrolls)
            if scrolls then
                local total = 0
                for _, e in ipairs(self.entries) do
                    total = total + e.height
                end
                self.syncing = true
                pcall(bar.SetPanExtentPercentage, bar, 1 / max)
                pcall(bar.SetVisibleExtentPercentage, bar, math.min(1, (height or 0) / math.max(1, total)))
                pcall(bar.SetScrollPercentage, bar, self.offset / max, true)
                self.syncing = false
            end
        elseif more then
            more:SetShown(self.offset < max)
        end
    end
    function list:SetEntries(entries)
        self.entries = entries
        self:Layout()
    end
    list:SetScript("OnSizeChanged", function(self) self:Layout() end)
    return list
end

-------------------------------------------------------------------------------
-- Page 1: Suggest
-------------------------------------------------------------------------------

local MINE_STATUS = {
    new = "Sent, waiting for a decision",
    invited = "Invited",
    declined = "Not invited",
}

local function MineRow(list)
    local row = CreateFrame("Frame", nil, list)
    row.remove = Button(row, "X", 24, function(self)
        for _, m in ipairs(rawget(self:GetParent(), "group") or {}) do
            ns.ForgetMine(m.id)
        end
    end)
    row.remove:SetPoint("RIGHT", -2, 0)
    row.status = Text(row, "GameFontNormalSmall")
    row.status:SetPoint("RIGHT", row.remove, "LEFT", -8, 0)
    row.status:SetJustifyH("RIGHT")
    row.name = Text(row, "GameFontHighlight")
    row.name:SetPoint("LEFT", 2, 0)
    row.name:SetPoint("RIGHT", row.status, "LEFT", -8, 0)
    row.name:SetWordWrap(false)
    row.remove:SetScript("OnEnter", function(self)
        ShowTip(self, "Remove from your list")
    end)
    row.remove:SetScript("OnLeave", HideTip)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        ShowTip(self, ns.Show(self.target), (self.fullReason and self.fullReason ~= "") and self.fullReason or "(no reason given)")
    end)
    row:SetScript("OnLeave", HideTip)
    local line = row:CreateTexture(nil, "BACKGROUND")
    line:SetColorTexture(1, 1, 1, 0.08)
    line:SetPoint("BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", 0, 0)
    line:SetHeight(1)
    return row
end

local function FillMine(row, e)
    local m = e.mine
    row.id, row.target, row.group = m.id, m.target, e.group or { m }
    local reasons = {}
    for _, s in ipairs(row.group) do
        if s.reason and s.reason ~= "" then
            reasons[#reasons + 1] = s.reason
        end
    end
    row.fullReason = table.concat(reasons, string.char(10))
    row.name:SetText(ns.Colored(m.target, m.class) .. "  |cffa6a6a6" .. ns.InfoText(m.level, m.class) .. "|r")
    local status
    if m.joinedAt then
        status = "Joined the guild"
    elseif not m.delivered then
        status = "Waiting to send"
    else
        status = MINE_STATUS[m.status] or MINE_STATUS.new
    end
    row.status:SetText(status .. "  " .. ns.Ago(m.joinedAt or m.at))
    local c = ((m.joinedAt or m.status == "invited") and GOOD) or GOLD
    row.status:SetTextColor(c[1], c[2], c[3])
end

local function ConfirmClearMine()
    if not StaticPopup_Show or not StaticPopupDialogs then
        ns.ClearMine()
        return
    end
    StaticPopupDialogs.GUILDSUGGESTION_CLEAR = StaticPopupDialogs.GUILDSUGGESTION_CLEAR or {
        text = "Clear your list of suggestions?\n\nOnes already sent stay with the members who can invite. Ones still waiting to send are cancelled.",
        button1 = "Clear",
        button2 = "Cancel",
        OnAccept = function() ns.ClearMine() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopup_Show("GUILDSUGGESTION_CLEAR")
end

local function BuildSuggestPage(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints()

    local nameLabel = Text(p, "GameFontNormal", "Player to suggest", GOLD)
    nameLabel:SetPoint("TOPLEFT", 4, -4)
    p.name = Input(p, 250, ns.forever and "First name and surname" or "Character name")
    p.name:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 6, -4)
    p.name:SetMaxLetters(60)
    local useTarget = Button(p, "Use target", 100, function()
        local name = ns.TargetName()
        if name then
            p.name:SetText(name)
            p.name:UpdateHint()
        else
            p.msg:SetText("Target a player first.")
        end
    end)
    useTarget:SetPoint("LEFT", p.name, "RIGHT", 8, 0)

    local reasonLabel = Text(p, "GameFontNormal", "Why? (short, optional)", GOLD)
    reasonLabel:SetPoint("TOPLEFT", p.name, "BOTTOMLEFT", -6, -10)
    local box = CreateFrame("Frame", nil, p, "BackdropTemplate")
    Backdrop(box)
    box:SetPoint("TOPLEFT", reasonLabel, "BOTTOMLEFT", 0, -4)
    box:SetPoint("RIGHT", p, "RIGHT", -4, 0)
    box:SetHeight(64)
    local reason = CreateFrame("EditBox", nil, box)
    reason:SetMultiLine(true)
    reason:SetAutoFocus(false)
    reason:SetFontObject(ChatFontNormal)
    reason:SetTextColor(1, 1, 1)
    reason:SetMaxLetters(ns.MAX_REASON)
    reason:SetPoint("TOPLEFT", 8, -6)
    reason:SetPoint("BOTTOMRIGHT", -8, 6)
    reason:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function() reason:SetFocus() end)
    p.reason = reason
    local count = Text(p, "GameFontDisableSmall", "0/" .. ns.MAX_REASON, DIM)
    count:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, -3)
    reason:SetScript("OnTextChanged", function(self)
        count:SetText(#self:GetText() .. "/" .. ns.MAX_REASON)
    end)

    local send = Button(p, "Send suggestion", 140, function()
        local ok, msg = ns.Suggest(p.name:GetText(), p.reason:GetText())
        p.msg:SetText(msg or "")
        if ok then
            p.name:SetText("")
            p.name:UpdateHint()
            p.reason:SetText("")
            p.name:ClearFocus()
            p.reason:ClearFocus()
        end
    end)
    send:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -8)
    p.name:SetScript("OnEnterPressed", function() p.reason:SetFocus() end)
    p.msg = Text(p, "GameFontHighlightSmall", "", WHITE)
    p.msg:SetPoint("LEFT", send, "RIGHT", 10, 0)
    p.msg:SetPoint("RIGHT", p, "RIGHT", -4, 0)
    p.msg:SetWordWrap(true)
    p.msg:SetMaxLines(2)

    p.who = Text(p, "GameFontDisableSmall", "", DIM)
    p.who:SetPoint("TOPLEFT", send, "BOTTOMLEFT", 0, -8)
    p.who:SetPoint("RIGHT", p, "RIGHT", -4, 0)

    local mineLabel = Text(p, "GameFontNormal", "Your suggestions", GOLD)
    mineLabel:SetPoint("TOPLEFT", p.who, "BOTTOMLEFT", 0, -12)
    p.clear = Button(p, "Clear list", 90, ConfirmClearMine)
    p.clear:SetPoint("RIGHT", p, "RIGHT", -4, 0)
    p.clear:SetPoint("BOTTOM", mineLabel, "BOTTOM", 0, -3)
    p.empty = Text(p, "GameFontDisableSmall", "Nothing yet.", DIM)
    p.empty:SetPoint("TOPLEFT", mineLabel, "BOTTOMLEFT", 0, -6)

    p.list = List(p)
    p.list:SetPoint("TOPLEFT", mineLabel, "BOTTOMLEFT", 0, -8)
    p.list:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -4, 4)
    p.list.MakeRow = MineRow
    p.list.FillRow = FillMine

    function p:Refresh()
        ns.SyncMine()
        local g = ns.Guild()
        local entries = {}
        if g then
            -- One row per player: the latest suggestion shows, X removes all.
            local byTarget = {}
            for _, m in pairs(g.mine) do
                local e = byTarget[m.target]
                if not e then
                    e = { height = 26, mine = m, group = {} }
                    byTarget[m.target] = e
                    entries[#entries + 1] = e
                end
                table.insert(e.group, m)
                if (m.at or 0) > (e.mine.at or 0) then
                    e.mine = m
                end
            end
            table.sort(entries, function(a, b) return (a.mine.at or 0) > (b.mine.at or 0) end)
        end
        p.empty:SetShown(#entries == 0)
        p.clear:SetShown(#entries > 0)
        p.list:SetEntries(entries)
        if not g then
            p.who:SetText("You are not in a guild.")
        elseif ns.IMayInvite() then
            p.who:SetText("Anyone you suggest shows up on the To decide list.")
        else
            local n = #ns.OnlineInviters()
            p.who:SetText(n == 0 and "Members who can invite decide. None of them is online right now."
                or (n == 1 and "Members who can invite decide. 1 of them is online now."
                or ("Members who can invite decide. " .. n .. " of them are online now.")))
        end
    end
    return p
end

-------------------------------------------------------------------------------
-- Page 2: To decide
-------------------------------------------------------------------------------

-- group: every waiting suggestion for one player (they're decided together).
local function ConfirmDecline(group)
    local ids, names, seen = {}, {}, {}
    for _, it in ipairs(group) do
        ids[#ids + 1] = it.id
        if not seen[it.by] then
            seen[it.by] = true
            names[#names + 1] = ns.Show(it.by)
        end
    end
    local it = group[1]
    if not StaticPopup_Show or not StaticPopupDialogs then
        for _, id in ipairs(ids) do ns.Decide(id, "declined") end
        return
    end
    StaticPopupDialogs.GUILDSUGGESTION_DECLINE = StaticPopupDialogs.GUILDSUGGESTION_DECLINE or {
        text = "%s",
        button1 = "Decline",
        button2 = "Cancel",
        OnAccept = function(_, list)
            for _, id in ipairs(type(list) == "table" and list or {}) do
                ns.Decide(id, "declined")
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    local text = "Decline " .. ns.Show(it.target) .. "?\n\n" .. table.concat(names, ", ")
        .. (#names == 1 and " will see" or " will each see") .. " that the suggestion was not accepted (not who declined it)."
    StaticPopup_Show("GUILDSUGGESTION_DECLINE", text, nil, ids)
end

-- Invite: Forever only lets Blizzard's own UI send guild invites, and only
-- with a name the player gave it: an addon can't invite, not even through a
-- secure macro button, and a name the addon writes into a box or the chat
-- line is marked as the addon's and blocked too (all tried in game).
-- What works (confirmed in game): Blizzard's own "Invite Member" button
-- (bottom of the guild Chat page) opens the Add Guild Member box, and the
-- player pastes the name there themselves. So Invite shows the name selected
-- in a box to copy and highlights Invite Member; paste, Accept. Your own
-- copy and paste count as typing. Comm.lua marks the suggestion once the
-- game confirms.
local glow

local function PointAtInviteMember(button)
    if not glow then
        -- Part of the guild window, so it closes with it.
        glow = CreateFrame("Frame", nil, CommunitiesFrame)
        glow:SetFrameLevel(math.min((CommunitiesFrame:GetFrameLevel() or 0) + 3100, 9500))
        local edges = {}
        for i = 1, 4 do
            edges[i] = glow:CreateTexture(nil, "OVERLAY")
            edges[i]:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
        end
        edges[1]:SetPoint("TOPLEFT"); edges[1]:SetPoint("TOPRIGHT"); edges[1]:SetHeight(2)
        edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(2)
        edges[3]:SetPoint("TOPLEFT"); edges[3]:SetPoint("BOTTOMLEFT"); edges[3]:SetWidth(2)
        edges[4]:SetPoint("TOPRIGHT"); edges[4]:SetPoint("BOTTOMRIGHT"); edges[4]:SetWidth(2)
        local anim = glow:CreateAnimationGroup()
        anim:SetLooping("BOUNCE")
        local fade = anim:CreateAnimation("Alpha")
        fade:SetFromAlpha(1)
        fade:SetToAlpha(0.2)
        fade:SetDuration(0.5)
        glow.anim = anim
    end
    glow:ClearAllPoints()
    glow:SetPoint("TOPLEFT", button, "TOPLEFT", -3, 3)
    glow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 3, -3)
    glow:Show()
    glow.anim:Play()
    local shownAt = GetTime()
    glow.shownAt = shownAt
    C_Timer.After(4, function()
        if glow.shownAt == shownAt then
            glow.anim:Stop()
            glow:Hide()
        end
    end)
end

function ns.StopGlow()
    if glow then
        glow.shownAt = nil
        glow.anim:Stop()
        glow:Hide()
    end
end

local function InviteHelp(it)
    local cf = CommunitiesFrame
    local button = cf and rawget(cf, "InviteButton")
    local ready = button and button:IsShown() and button:IsEnabled()
    if pages[2] and pages[2].ShowCopy then
        pages[2].ShowCopy(it.target, not ready)
    end
    if ready then
        PointAtInviteMember(button)
    end
end

local function DecideRow(list)
    local row = CreateFrame("Frame", nil, list)
    row.name = Text(row, "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 2, -4)
    row.from = Text(row, "GameFontDisableSmall", "", DIM)
    row.from:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
    row.from:SetPoint("RIGHT", row, "RIGHT", -170, 0)
    row.from:SetWordWrap(false)
    row.reason = Text(row, "GameFontHighlightSmall", "", WHITE)
    row.reason:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -4)
    row.reason:SetPoint("RIGHT", -4, 0)
    row.reason:SetWordWrap(true)
    row.reason:SetMaxLines(2)
    -- See InviteHelp: the game's own UI has to send the invite.
    row.invite = Button(row, "Invite", 76, function(self)
        local g = ns.Guild()
        local it = g and g.items[self:GetParent().id]
        if it then
            InviteHelp(it)
        end
    end)
    row.invite:SetScript("OnEnter", function(self)
        local g = ns.Guild()
        local it = g and g.items[self:GetParent().id]
        ShowTip(self, "Invite " .. (it and ns.Show(it.target) or ""), "Copy the name, click Invite Member, paste, Accept.")
    end)
    row.invite:SetScript("OnLeave", HideTip)
    row.invite:SetPoint("TOPRIGHT", -84, -1)
    row.decline = Button(row, "Decline", 76, function(self)
        local group = rawget(self:GetParent(), "group")
        if group and #group > 0 then
            ConfirmDecline(group)
        end
    end)
    row.decline:SetPoint("TOPRIGHT", -4, -1)
    row.remove = Button(row, "Remove", 76, function(self)
        for _, it in ipairs(rawget(self:GetParent(), "group") or {}) do
            ns.Decide(it.id, "removed")
        end
    end)
    row.remove:SetPoint("TOPRIGHT", -4, -1)
    row.remove:SetScript("OnEnter", function(self)
        ShowTip(self, "Remove", "Takes it off this list for everyone who can invite.")
    end)
    row.remove:SetScript("OnLeave", HideTip)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        ShowTip(self, ns.Show(self.target), unpack(rawget(self, "reasons") or { "(no reason given)" }))
    end)
    row:SetScript("OnLeave", HideTip)
    local line = row:CreateTexture(nil, "BACKGROUND")
    line:SetColorTexture(1, 1, 1, 0.08)
    line:SetPoint("BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", 0, 0)
    line:SetHeight(1)
    row.header = Text(row, "GameFontNormal", "", GOLD)
    row.header:SetPoint("BOTTOMLEFT", 0, 4)
    return row
end

local function FillDecide(row, e)
    local it = e.item
    local isHeader = e.header ~= nil
    row.header:SetShown(isHeader)
    for _, k in ipairs({ "name", "from", "reason", "invite", "decline", "remove" }) do
        row[k]:SetShown(not isHeader)
    end
    if isHeader then
        row.header:SetText(e.header)
        row.id = nil
        row:EnableMouse(false)
        return
    end
    row:EnableMouse(true)
    local group = e.group or { it }
    row.group = group
    row.id, row.target = it.id, it.target
    row.name:SetText(ns.Colored(it.target, it.class))
    local waiting = it.status == "new" and not it.joinedAt
    -- Everyone who suggested this player, and all their reasons.
    local byNames, reasons, seen, latest, first = {}, {}, {}, 0, nil
    for _, s in ipairs(group) do
        if not seen[s.by] then
            seen[s.by] = true
            byNames[#byNames + 1] = ns.Colored(s.by, ns.MemberClass(s.by))
        end
        if s.reason and s.reason ~= "" then
            reasons[#reasons + 1] = ns.Show(s.by) .. ": " .. s.reason
            first = first or s.reason
        end
        latest = math.max(latest, s.at or 0)
    end
    row.reasons = #reasons > 0 and reasons or { "(no reason given)" }
    for _, s in ipairs(group) do
        if s.level and not it.level then it = setmetatable({ level = s.level }, { __index = it }) end
        if s.class and not it.class then it = setmetatable({ class = s.class }, { __index = it }) end
    end
    row.name:SetText(ns.Colored(it.target, it.class))
    local by = byNames[1] .. (#byNames > 1 and (" +" .. (#byNames - 1) .. " more") or "")
    if #byNames > 1 then
        table.insert(row.reasons, 1, "Suggested by " .. table.concat(byNames, ", "))
    end
    if waiting then
        local state = ns.OnlineState(it.target)
        local online = (state == "online" and "|cff4ee44eonline|r") or (state == "offline" and "|cff9d9d9doffline|r") or "checking"
        row.from:SetText(ns.InfoText(it.level, it.class) .. ", " .. online .. ", from " .. by .. ", " .. ns.Ago(latest))
        local text = first or "(no reason given)"
        if #reasons > 1 then
            text = text .. "  (+" .. (#reasons - 1) .. " more, hover)"
        end
        local prev = e.declinedBefore
        if prev then
            text = "|cffff9999Declined before, " .. ns.Ago(prev.decidedAt) .. " by "
                .. ns.Show(prev.decidedBy) .. ".|r " .. text
        end
        row.reason:SetText(text)
        row.reason:SetTextColor(WHITE[1], WHITE[2], WHITE[3])
    else
        row.from:SetText(ns.InfoText(it.level, it.class) .. ", from " .. by)
        if it.joinedAt then
            row.reason:SetText("Joined the guild, " .. ns.Ago(it.joinedAt))
            row.reason:SetTextColor(GOOD[1], GOOD[2], GOOD[3])
        else
            local what = it.status == "invited" and "Invited" or "Declined"
            row.reason:SetText(what .. " by " .. ns.Colored(it.decidedBy, ns.MemberClass(it.decidedBy)) .. ", " .. ns.Ago(it.decidedAt))
            local c = it.status == "invited" and GOOD or GOLD
            row.reason:SetTextColor(c[1], c[2], c[3])
        end
    end
    row.invite:SetShown(waiting)
    row.decline:SetShown(waiting)
    row.remove:SetShown(not waiting)
end

local function BuildDecidePage(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints()
    p.note = Text(p, "GameFontDisableSmall", "", DIM)
    p.note:SetPoint("TOPLEFT", 4, -4)
    p.note:SetPoint("RIGHT", p, "RIGHT", -4, 0)
    p.note:SetWordWrap(true)
    p.list = List(p)
    p.list:SetPoint("TOPLEFT", p.note, "BOTTOMLEFT", 0, -8)
    p.list:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -4, 34)
    p.list.MakeRow = DecideRow
    p.list.FillRow = FillDecide
    -- While the page is open, check again now and then (once a minute per name).
    local since = 0
    p:SetScript("OnUpdate", function(self, elapsed)
        since = since + elapsed
        if since > 30 then
            since = 0
            self:Refresh()
        end
    end)

    -- After Invite: the name, selected, for you to copy and paste into
    -- Blizzard's Add Guild Member box (wording without key names, so it fits
    -- any keyboard layout). The addon may not copy
    -- for you (the game blocks it), but your own copy and paste are fine.
    local strip = CreateFrame("Frame", nil, p)
    strip:SetPoint("BOTTOMLEFT", 4, 4)
    strip:SetPoint("BOTTOMRIGHT", -4, 4)
    strip:SetHeight(26)
    strip:Hide()
    local label = Text(strip, "GameFontNormalSmall", "Copy:", GOLD)
    label:SetPoint("LEFT", 0, 0)
    local box = Input(strip, 200, "")
    box:SetPoint("LEFT", label, "RIGHT", 10, 0)
    local close = Button(strip, "X", 24, function() p.HideCopy() end)
    close:SetPoint("RIGHT", 0, 0)
    local hint = Text(strip, "GameFontHighlightSmall", "Click Invite Member, paste, Accept.", WHITE)
    hint:SetPoint("LEFT", box, "RIGHT", 10, 0)
    hint:SetPoint("RIGHT", close, "LEFT", -4, 0)
    hint:SetWordWrap(false)
    -- Read-only: any edit snaps back to the name, kept selected.
    box:SetScript("OnTextChanged", function(self, userInput)
        if userInput and self:GetText() ~= strip.name then
            self:SetText(strip.name or "")
            self:HighlightText()
        end
        self:UpdateHint()
    end)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    -- otherPage: Invite Member isn't on screen (the window shows another page).
    function p.ShowCopy(name, otherPage)
        strip.name = name
        hint:SetText(otherPage and "Open guild Chat, click Invite Member, paste, Accept."
            or "Click Invite Member, paste, Accept.")
        box:SetText(name)
        strip:Show()
        box:SetFocus()
        box:HighlightText()
    end
    function p.HideCopy()
        strip:Hide()
        strip.name = nil
        box:ClearFocus()
    end

    function p:Refresh()
        local g = ns.Guild()
        local waiting, decided = {}, {}
        -- The copy box goes away once its suggestion is no longer waiting.
        local stillWaiting = false
        for _, it in pairs(g and g.items or {}) do
            if it.status == "new" and not it.joinedAt and it.target == strip.name then
                stillWaiting = true
            end
        end
        if not stillWaiting then
            p.HideCopy()
        end
        -- One entry per player: their suggestions together.
        local waitBy, decBy, declinedBy = {}, {}, {}
        if g and ns.IMayInvite() then
            for _, it in pairs(g.items) do
                if it.status == "new" and not it.joinedAt then
                    if not waitBy[it.target] then
                        waitBy[it.target] = {}
                        waiting[#waiting + 1] = waitBy[it.target]
                        ns.CheckOnline(it.target)
                    end
                    table.insert(waitBy[it.target], it)
                elseif (it.joinedAt or it.status == "invited" or it.status == "declined") and not it.removedAt then
                    if not decBy[it.target] then
                        decBy[it.target] = {}
                        decided[#decided + 1] = decBy[it.target]
                    end
                    table.insert(decBy[it.target], it)
                end
                -- The latest decline of this player (for "declined before").
                if it.status == "declined" and it.decidedAt then
                    local prev = declinedBy[it.target]
                    if not prev or it.decidedAt > prev.decidedAt then
                        declinedBy[it.target] = it
                    end
                end
            end
        end
        local function Oldest(list)
            table.sort(list, function(a, b) return (a.at or 0) < (b.at or 0) end)
            return list[1]
        end
        local function Last(list)
            local best = list[1]
            for _, it in ipairs(list) do
                if (it.joinedAt or it.decidedAt or 0) > (best.joinedAt or best.decidedAt or 0) then best = it end
            end
            return best
        end
        for _, list in ipairs(waiting) do Oldest(list) end
        table.sort(waiting, function(a, b) return (a[1].at or 0) < (b[1].at or 0) end)
        table.sort(decided, function(a, b)
            local x, y = Last(a), Last(b)
            return (x.joinedAt or x.decidedAt or 0) > (y.joinedAt or y.decidedAt or 0)
        end)
        local entries = {}
        for _, list in ipairs(waiting) do
            entries[#entries + 1] = { height = 60, item = list[1], group = list, declinedBefore = declinedBy[list[1].target] }
        end
        if #decided > 0 then
            entries[#entries + 1] = { height = 30, header = "Decided" }
            for _, list in ipairs(decided) do
                entries[#entries + 1] = { height = 44, item = Last(list), group = list }
            end
        end
        if not g then
            p.note:SetText("You are not in a guild.")
        elseif not ns.IMayInvite() then
            p.note:SetText("Only members who can invite see suggestions.")
        elseif #waiting == 0 then
            p.note:SetText("No suggestions waiting. Hover a name to read the whole reason.")
        else
            p.note:SetText((#waiting == 1 and "1 suggestion waiting." or (#waiting .. " suggestions waiting."))
                .. " Hover a name to read the whole reason.")
        end
        p.list:SetEntries(entries)
    end
    return p
end

-------------------------------------------------------------------------------
-- Page 3: Log (only for members who may invite)
-- Every step of every suggestion, newest first: who suggested whom, who
-- invited or declined, who took it off the list, and when.
-------------------------------------------------------------------------------

local function When(t)
    local fmt = date or (os and os.date)
    return t and fmt and fmt("%Y-%m-%d %H:%M", t) or ""
end

-- One line per step, built from what each suggestion keeps.
function ns.LogEntries()
    local g = ns.GuildName() and ns.Guild()
    local list = {}
    if not g then
        return list
    end
    local joined = {} -- one "joined" line per player
    local function Add(at, it, actor, action, middle, tail)
        local who = ns.Show(it.target)
        list[#list + 1] = {
            at = at or 0, item = it, actor = actor, action = action,
            text = ns.Show(actor) .. " " .. middle .. " " .. who .. (tail or ""),
            display = ns.Colored(actor, ns.MemberClass(actor)) .. " " .. middle .. " " .. ns.Colored(it.target, it.class) .. (tail or ""),
        }
    end
    for _, it in pairs(g.items) do
        Add(it.at, it, it.by, "suggested", "suggested")
        if it.decidedAt and it.decidedBy then
            local did = (it.status == "invited" and "invited") or (it.status == "declined" and "declined") or "decided on"
            Add(it.decidedAt, it, it.decidedBy, did, did)
        end
        if it.removedAt and it.removedBy then
            Add(it.removedAt, it, it.removedBy, "removed", "removed", " from the list")
        end
        if it.joinedAt and not joined[it.target] then
            joined[it.target] = true
            list[#list + 1] = {
                at = it.joinedAt, item = it, actor = it.target, action = "joined",
                text = ns.Show(it.target) .. " joined the guild",
                display = ns.Colored(it.target, it.class) .. " joined the guild",
            }
        end
    end
    table.sort(list, function(a, b)
        if a.at ~= b.at then
            return a.at > b.at
        end
        return a.text < b.text
    end)
    return list
end

local function LogRow(list)
    local row = CreateFrame("Frame", nil, list)
    row.when = Text(row, "GameFontDisableSmall", "", DIM)
    row.when:SetPoint("LEFT", 2, 0)
    row.when:SetWidth(104)
    row.text = Text(row, "GameFontHighlightSmall", "", WHITE)
    row.text:SetPoint("LEFT", row.when, "RIGHT", 6, 0)
    row.text:SetPoint("RIGHT", -2, 0)
    row.text:SetWordWrap(false)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        local it = self.item
        if it then
            ShowTip(self, ns.Show(it.target), ns.InfoText(it.level, it.class), "Suggested by " .. ns.Show(it.by) .. ", " .. When(it.at),
                it.reason ~= "" and ("Reason: " .. it.reason) or "No reason given")
        end
    end)
    row:SetScript("OnLeave", HideTip)
    return row
end

local function FillLog(row, e)
    row.item = e.item
    row.when:SetText(When(e.at))
    row.text:SetText(e.display or e.text)
end

-- The game's own dropdown menu button (nil where the game has none).
-- generator(dropdown, root) fills the menu each time it opens. Same as
-- FriendsCraft's.
local function Dropdown(parent, width, generator)
    if not MenuUtil then
        return nil
    end
    local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    if not ok or not dd or type(rawget(dd, "SetupMenu")) ~= "function" then
        if ok and dd then
            dd:Hide()
        end
        return nil
    end
    dd:SetWidth(width)
    local okSetup = pcall(dd.SetupMenu, dd, generator)
    if not okSetup then
        dd:Hide()
        return nil
    end
    return dd
end

local ACTIONS = { "suggested", "invited", "declined", "removed", "joined" }

local function BuildLogPage(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints()
    p.who, p.action = nil, nil -- filters: nil = anyone / any action
    p.actors = {}
    local function Pick(field, value)
        p[field] = value
        p:Refresh()
    end
    p.whoDrop = Dropdown(p, 170, function(_, root)
        root:CreateRadio("Anyone", function() return rawget(p, "who") == nil end, function() Pick("who", nil) end)
        for _, name in ipairs(p.actors) do
            root:CreateRadio(ns.Colored(name, ns.MemberClass(name)), function() return rawget(p, "who") == name end, function() Pick("who", name) end)
        end
    end)
    p.actionDrop = Dropdown(p, 150, function(_, root)
        root:CreateRadio("Any action", function() return rawget(p, "action") == nil end, function() Pick("action", nil) end)
        for _, a in ipairs(ACTIONS) do
            root:CreateRadio(a:sub(1, 1):upper() .. a:sub(2), function() return rawget(p, "action") == a end, function() Pick("action", a) end)
        end
    end)
    local top = -4
    local whoDrop, actionDrop = rawget(p, "whoDrop"), rawget(p, "actionDrop")
    if whoDrop and actionDrop then
        local whoLabel = Text(p, "GameFontNormalSmall", "Who:", GOLD)
        whoLabel:SetPoint("TOPLEFT", 4, -9)
        p.whoDrop:SetPoint("LEFT", whoLabel, "RIGHT", 6, 0)
        local actionLabel = Text(p, "GameFontNormalSmall", "Action:", GOLD)
        actionLabel:SetPoint("LEFT", p.whoDrop, "RIGHT", 16, 0)
        p.actionDrop:SetPoint("LEFT", actionLabel, "RIGHT", 6, 0)
        top = -36
    end
    p.note = Text(p, "GameFontDisableSmall", "", DIM)
    p.note:SetPoint("TOPLEFT", 4, top)
    p.note:SetPoint("RIGHT", p, "RIGHT", -4, 0)
    p.list = List(p)
    p.list:SetPoint("TOPLEFT", p.note, "BOTTOMLEFT", 0, -8)
    p.list:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -4, 4)
    p.list.MakeRow = LogRow
    p.list.FillRow = FillLog

    function p:Refresh()
        local entries, seen, actors, total = {}, {}, {}, 0
        local who, action = rawget(p, "who"), rawget(p, "action")
        if ns.IMayInvite() then
            for _, e in ipairs(ns.LogEntries()) do
                total = total + 1
                if e.actor and not seen[e.actor] then
                    seen[e.actor] = true
                    actors[#actors + 1] = e.actor
                end
                if (not who or e.actor == who) and (not action or e.action == action) then
                    e.height = 20
                    entries[#entries + 1] = e
                end
            end
        end
        table.sort(actors)
        p.actors = actors
        for _, dd in ipairs({ rawget(p, "whoDrop"), rawget(p, "actionDrop") }) do
            if dd and dd.GenerateMenu then
                pcall(dd.GenerateMenu, dd)
            end
        end
        if not ns.IMayInvite() then
            p.note:SetText("Only members who can invite see the log.")
        elseif total == 0 then
            p.note:SetText("Nothing logged yet.")
        elseif #entries == 0 then
            p.note:SetText("Nothing matches these filters.")
        else
            p.note:SetText("Newest first. Hover a line for the reason.")
        end
        p.list:SetEntries(entries)
    end
    return p
end

-------------------------------------------------------------------------------
-- Tab in the guild window
--
-- A side tab under the game's guild tabs (Roster, Info, ...) opens our panel
-- on top of the window's content. It never changes the window's display
-- mode, so the game's own tabs keep working.
--
-- Other addons can add side tabs the same way (FriendsCraft's Professions
-- tab does). Each such tab carries .sideTabAddon = its addon's name: tabs
-- line up in name order under the game's tabs, and clicking any other tab
-- closes our panel. Our panel opens one frame after the click, so another
-- addon closing its own panel on that click can't undo what ours sets up.
-------------------------------------------------------------------------------

local SIDE_TAB_ID = "GuildSuggestion"
local BLIZZ_TABS = { "ChatTab", "RosterTab", "GuildBenefitsTab", "GuildInfoTab", "GuildPreferredPlaySettingsTab" }
local panel, tab, switch
local hookedTabs = {}

local function ShowPage(i)
    if i ~= 1 and not ns.IMayInvite() then
        i = 1
    end
    if i ~= currentPage and pages[2] and pages[2].HideCopy then
        pages[2].HideCopy()
    end
    currentPage = i
    for n, page in ipairs(pages) do
        page:SetShown(n == i)
    end
    if switch then
        for n, t in ipairs(switch) do
            if t.isTab == true then
                if n == i then PanelTemplates_SelectTab(t) else PanelTemplates_DeselectTab(t) end
            else
                t:SetEnabled(n ~= i)
            end
        end
    end
    if pages[i] and pages[i].Refresh then
        pages[i]:Refresh()
    end
end

local function UpdateSwitch()
    if not switch then
        return
    end
    local mayInvite = ns.IMayInvite()
    local waiting = ns.WaitingCount()
    switch[2]:SetText(waiting > 0 and ("To decide (" .. waiting .. ")") or "To decide")
    if switch[2].isTab == true then
        pcall(PanelTemplates_TabResize, switch[2], 0)
    end
    for _, t in ipairs(switch) do
        t:SetShown(mayInvite)
    end
    switch.line:SetShown(mayInvite)
    if not mayInvite and currentPage == 2 then
        ShowPage(1)
    end
end

-- The tab's badge and tooltip show how many wait for a decision.
function ns.RefreshBadge()
    if not tab then
        return
    end
    local waiting = ns.WaitingCount()
    tab.badge:SetText(waiting > 0 and tostring(waiting) or "")
    tab.badge:SetShown(waiting > 0)
    tab.tooltip = waiting > 0 and ("Guild suggestions (" .. waiting .. " waiting)") or "Guild suggestions"
end

-- The guild chat's scroll bar is drawn on the HIGH layer, above the whole
-- window. While our panel is open it moves down to the window's own layer.
local chatBarStrata
local function ChatBar()
    local chat = CommunitiesFrame and CommunitiesFrame.Chat
    return type(chat) == "table" and chat.ScrollBar or nil
end

local function LowerChatBar()
    local bar = ChatBar()
    if chatBarStrata or not bar or not bar.GetFrameStrata then
        return
    end
    local strata = bar:GetFrameStrata()
    if type(strata) == "string" then
        chatBarStrata = strata
        bar:SetFrameStrata(panel:GetFrameStrata() or "MEDIUM")
    end
end

local function RestoreChatBar()
    local bar = ChatBar()
    if chatBarStrata and bar then
        bar:SetFrameStrata(chatBarStrata)
    end
    chatBarStrata = nil
end

-- The guild window's buttons along the bottom edge (Guild Control, Guild
-- Log) sit outside the panel; they're faded out and made
-- unclickable while it's open, so the game stays in charge of showing them.
-- Blizzard's Invite Member button stays usable: inviting goes through it.
local BOTTOM_BUTTONS = { "CommunitiesControlFrame", "GuildLogButton" }
local muted

local function Mute(f)
    if f.IsMouseEnabled and f.EnableMouse then
        muted[f] = f:IsMouseEnabled()
        f:EnableMouse(false)
    else
        muted[f] = false
    end
    if f.GetChildren then
        for _, child in ipairs({ f:GetChildren() }) do
            Mute(child)
        end
    end
end

local function MuteBottomButtons()
    local cf = CommunitiesFrame
    if muted or not cf then
        return
    end
    muted = {}
    for _, key in ipairs(BOTTOM_BUTTONS) do
        local f = rawget(cf, key)
        if type(f) == "table" and f.SetAlpha then
            f:SetAlpha(0)
            Mute(f)
        end
    end
    local detail = rawget(cf, "GuildMemberDetailFrame")
    if type(detail) == "table" and detail.Hide then
        detail:Hide()
    end
end

local function RestoreBottomButtons()
    local cf = CommunitiesFrame
    if not muted or not cf then
        return
    end
    for f, mouse in pairs(muted) do
        if mouse then
            f:EnableMouse(true)
        end
    end
    for _, key in ipairs(BOTTOM_BUTTONS) do
        local f = rawget(cf, key)
        if type(f) == "table" and f.SetAlpha then
            f:SetAlpha(1)
        end
    end
    muted = nil
end

local function SetBlizzardTabsChecked(cf, checked)
    for _, n in ipairs(BLIZZ_TABS) do
        local t = cf[n]
        if t and t.SetChecked then
            t:SetChecked(checked)
        end
    end
end

local function HidePanel()
    if ns.StopGlow then
        ns.StopGlow()
    end
    if pages[2] and pages[2].HideCopy then
        pages[2].HideCopy()
    end
    if panel and panel:IsShown() then
        panel:Hide()
    end
    RestoreChatBar()
    RestoreBottomButtons()
    if tab then
        tab:SetChecked(false)
    end
end

local function ShowPanel()
    if not panel or not tab or not tab:IsShown() then
        return
    end
    panel:Show()
    LowerChatBar()
    MuteBottomButtons()
    SetBlizzardTabsChecked(CommunitiesFrame, false)
    for t in pairs(hookedTabs) do
        if t.SetChecked then t:SetChecked(false) end
    end
    tab:SetChecked(true)
    UpdateSwitch()
    ShowPage(currentPage)
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        pcall(C_GuildInfo.GuildRoster)
    end
end

local function BuildPanel(cf)
    panel = CreateFrame("Frame", nil, cf)
    panel:Hide()
    panel:SetPoint("TOPLEFT", cf.CommunitiesList or cf, cf.CommunitiesList and "TOPRIGHT" or "TOPLEFT", 24, 0)
    panel:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", -8, 26)
    -- Well above every page of the window (its chat input sits high).
    panel:SetFrameLevel(math.min((cf:GetFrameLevel() or 0) + 3000, 9000))
    panel:EnableMouse(true)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.04, 0.05, 1)

    local title = Text(panel, "GameFontNormalLarge", "Guild suggestions", GOLD)
    title:SetPoint("TOPLEFT", 12, -12)
    -- Tabs standing on a line across the panel, like the Macros window.
    local line = panel:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.35)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 8, -38)
    line:SetPoint("TOPRIGHT", -8, -38)
    local function Tab(label, i)
        local hasApi = PanelTemplates_SelectTab and PanelTemplates_DeselectTab and PanelTemplates_TabResize
        local ok, t = false, nil
        if hasApi then
            ok, t = pcall(CreateFrame, "Button", "GuildSuggestionPageTab" .. i, panel, "PanelTopTabButtonTemplate")
        end
        if ok and t then
            t.isTab = true
            t:SetText(label)
            pcall(PanelTemplates_TabResize, t, 0)
            t:SetScript("OnClick", function()
                if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then
                    pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_TAB)
                end
                ShowPage(i)
            end)
        else
            t = Button(panel, label, 110, function() ShowPage(i) end)
        end
        return t
    end
    switch = { Tab("Suggest", 1), Tab("To decide", 2), Tab("Log", 3), line = line }
    switch[3]:SetPoint("BOTTOMRIGHT", line, "TOPRIGHT", -8, 0)
    for i = 2, 1, -1 do
        switch[i]:SetPoint("BOTTOMRIGHT", switch[i + 1], "BOTTOMLEFT", switch[i].isTab == true and 0 or -4, 0)
    end

    local content = CreateFrame("Frame", nil, panel)
    content:SetPoint("TOPLEFT", 12, -48)
    content:SetPoint("BOTTOMRIGHT", -12, 8)
    pages[1] = BuildSuggestPage(content)
    pages[2] = BuildDecidePage(content)
    pages[3] = BuildLogPage(content)
    panel:SetScript("OnShow", ns.Safe(function() ShowPage(currentPage) end, "guild tab"))
end

local function MakeTab(cf)
    local ok, b = pcall(CreateFrame, "CheckButton", "GuildSuggestionGuildTab", cf, "CommunitiesFrameTabTemplate")
    if not ok or not b then
        b = CreateFrame("CheckButton", "GuildSuggestionGuildTab", cf)
        b:SetSize(32, 32)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.7)
        b:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight")
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.tooltip, 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    b.sideTabAddon = SIDE_TAB_ID
    b.tooltip = "Guild suggestions"
    local icon = rawget(b, "Icon") or rawget(b, "icon")
    if type(icon) ~= "table" then
        icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 2, -2)
        icon:SetPoint("BOTTOMRIGHT", -2, 2)
    end
    icon:SetTexture(ICON)
    icon:Show()
    -- Number of suggestions waiting (the tooltip says it in words too).
    b.badge = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.badge:SetPoint("BOTTOMRIGHT", -1, 2)
    b.badge:SetTextColor(GOOD[1], GOOD[2], GOOD[3])
    b.badge:Hide()
    b:SetScript("OnClick", function()
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then
            pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_TAB)
        end
        b:SetChecked(true)
        C_Timer.After(0, ns.Safe(ShowPanel, "guild tab"))
    end)
    b:Hide()
    return b
end

-- Other addons' side tabs on this window (see the note above).
local function OtherSideTabs(cf)
    local list = {}
    for _, child in ipairs({ cf:GetChildren() }) do
        local id = rawget(child, "sideTabAddon")
        if type(id) == "string" and id ~= SIDE_TAB_ID then
            list[#list + 1] = child
            if not hookedTabs[child] and child.HookScript then
                hookedTabs[child] = true
                child:HookScript("OnClick", HidePanel)
            end
        end
    end
    return list
end

local function PlaceTab(cf)
    if not tab then
        return
    end
    local guild = cf.GuildInfoTab and cf.GuildInfoTab:IsShown()
    if not guild or not ns.GuildName() then
        tab:Hide()
        HidePanel()
        return
    end
    local last
    for i = #BLIZZ_TABS, 2, -1 do
        local t = cf[BLIZZ_TABS[i]]
        if t and t:IsShown() then
            last = t
            break
        end
    end
    local gap = -20
    -- Under any other addon's tab whose name comes before ours.
    local before = {}
    for _, t in ipairs(OtherSideTabs(cf)) do
        if t:IsShown() and t.sideTabAddon < SIDE_TAB_ID then
            before[#before + 1] = t
        end
    end
    table.sort(before, function(a, b) return a.sideTabAddon < b.sideTabAddon end)
    if #before > 0 then
        last = before[#before]
    end
    tab:ClearAllPoints()
    if last then
        tab:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, gap)
    else
        tab:SetPoint("TOPLEFT", cf, "TOPRIGHT", 0, -60)
    end
    tab:Show()
    ns.RefreshBadge()
    if panel:IsShown() then
        SetBlizzardTabsChecked(cf, false)
        tab:SetChecked(true)
    else
        tab:SetChecked(false)
    end
end

local function PlaceSoon(cf)
    -- After every addon has placed its own tab.
    C_Timer.After(0, ns.Safe(function() PlaceTab(cf) end, "guild tab"))
end

local function Setup()
    local cf = CommunitiesFrame
    if tab or not cf then
        return
    end
    BuildPanel(cf)
    tab = MakeTab(cf)
    for _, n in ipairs(BLIZZ_TABS) do
        local t = cf[n]
        if t and t.HookScript then
            t:HookScript("OnClick", HidePanel)
        end
    end
    if type(cf.UpdateCommunitiesTabs) == "function" then
        hooksecurefunc(cf, "UpdateCommunitiesTabs", function() PlaceSoon(cf) end)
    end
    cf:HookScript("OnShow", function() PlaceSoon(cf) end)
    cf:HookScript("OnHide", HidePanel)
    PlaceSoon(cf)
end

local function CommunitiesLoaded()
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        return C_AddOns.IsAddOnLoaded("Blizzard_Communities")
    end
    return IsAddOnLoaded and IsAddOnLoaded("Blizzard_Communities")
end

ns.On("ADDON_LOADED", function(name)
    if name == "Blizzard_Communities" then
        Setup()
    end
end)
ns.On("IS_READY", function()
    if CommunitiesLoaded() then
        Setup()
    end
end)
ns.On("IS_ROSTER", function() ns.RefreshBadge() end)

function ns.RefreshUI()
    ns.RefreshBadge()
    if panel and panel:IsShown() then
        UpdateSwitch()
        if pages[currentPage] then
            pages[currentPage]:Refresh()
        end
    end
end

-- Opens the guild window on our tab (a name goes in the Suggest page).
local function Open(fill)
    if not ns.GuildName() then
        ns.Print("you are not in a guild.")
        return
    end
    if not (CommunitiesFrame and CommunitiesFrame:IsShown()) then
        if ToggleGuildFrame then
            pcall(ToggleGuildFrame)
        end
    end
    -- The window (and our tab) may need a moment to load and lay out.
    local tries = 0
    local function Try()
        tries = tries + 1
        if not tab then Setup() end
        if tab and tab:IsShown() and panel then
            if fill then
                currentPage = 1
            elseif ns.WaitingCount() > 0 then
                currentPage = 2
            end
            ShowPanel()
            if fill then
                local p = pages[1]
                p.name:SetText(ns.FullName(fill) or fill)
                p.name:UpdateHint()
                p.msg:SetText("")
                p.reason:SetFocus()
            end
        elseif tries < 10 then
            C_Timer.After(0.1, ns.Safe(Try, "open"))
        else
            ns.Print("could not open the guild window. Open it and pick the Guild suggestions tab.")
        end
    end
    C_Timer.After(0.05, ns.Safe(Try, "open"))
end

function ns.ToggleWindow()
    if panel and panel:IsShown() and CommunitiesFrame and CommunitiesFrame:IsShown() then
        HidePanel()
        return
    end
    Open(nil)
end

function ns.OpenSuggest(name)
    Open(name or "")
end

-------------------------------------------------------------------------------
-- Right-click a player: "Suggest for guild invite"
-------------------------------------------------------------------------------

local function NameFromContext(contextData)
    if type(contextData) ~= "table" then
        return nil
    end
    local unit = contextData.unit
    if type(unit) == "string" and UnitIsPlayer and UnitIsPlayer(unit) then
        local first, second = UnitName(unit)
        if type(first) == "string" and not ns.IsSecret(first) then
            if type(second) == "string" and not ns.IsSecret(second) and second ~= "" then
                return first .. " " .. second
            end
            return first
        end
    end
    local name = contextData.name
    if type(name) ~= "string" or ns.IsSecret(name) then
        return nil
    end
    local server = contextData.server
    if ns.forever and type(server) == "string" and not ns.IsSecret(server) and server ~= "" and not name:find("[%s%-]") then
        return name .. " " .. server
    end
    return name
end

local function AddMenuEntry(owner, root, contextData)
    if not ns.me or not ns.GuildName() then
        return
    end
    local raw = NameFromContext(contextData)
    local full = raw and ns.FullName(raw)
    if not raw or full == ns.me or (full and ns.Member(full) == full) then
        return -- you, or already in the guild
    end
    root:CreateDivider()
    root:CreateButton("Suggest for guild invite", function()
        ns.OpenSuggest(full or raw)
    end)
end

if Menu and Menu.ModifyMenu then
    for _, tag in ipairs({ "MENU_UNIT_PLAYER", "MENU_UNIT_TARGET", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER",
        "MENU_UNIT_FRIEND" }) do
        pcall(Menu.ModifyMenu, tag, function(owner, root, contextData)
            local ok, err = pcall(AddMenuEntry, owner, root, contextData)
            if not ok then
                ns.Print("menu error: " .. tostring(err))
            end
        end)
    end
end
