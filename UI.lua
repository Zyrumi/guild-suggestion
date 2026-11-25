-- Invite Suggestions: the window, minimap button and right-click menu entry.
--
-- Page "Suggest": name + reason, and your own suggestions with their status.
-- Page "To decide": only for members who may invite. Waiting suggestions
-- with Invite / Decline, then the ones already decided.

local ADDON_NAME, ns = ...

local W, H = 440, 520
local GOLD = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }
local DIM = { 0.65, 0.65, 0.65 }
local GOOD = { 0.35, 0.9, 0.35 }
local ICON = "Interface\\Icons\\INV_Letter_15"

local window, pages, tabs = nil, {}, {}
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
-- A simple list: rows of fixed heights, mouse wheel scrolls by one entry
-------------------------------------------------------------------------------

local function List(parent)
    local list = CreateFrame("Frame", nil, parent)
    list.rows = {}     -- built rows, reused
    list.entries = {}
    list.offset = 0
    list.more = Text(list, "GameFontDisableSmall", "Scroll for more", DIM)
    list.more:SetPoint("BOTTOMRIGHT", 0, -14)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, #self.entries - 1)
        self.offset = math.min(max, math.max(0, self.offset - delta))
        self:Layout()
    end)
    function list:Layout()
        local y, height = 0, self:GetHeight()
        for _, row in ipairs(self.rows) do
            row:Hide()
        end
        local used = 0
        local shownAll = true
        for i = self.offset + 1, #self.entries do
            local e = self.entries[i]
            local h = e.height
            if y + h > height and used > 0 then
                shownAll = false
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
            row:SetPoint("RIGHT", 0, 0)
            row:SetHeight(h)
            self.FillRow(row, e)
            row:Show()
            y = y + h
        end
        self.more:SetShown(not shownAll)
    end
    function list:SetEntries(entries)
        self.entries = entries
        self.offset = math.min(self.offset, math.max(0, #entries - 1))
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
    row.name = Text(row, "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 2, -4)
    row.status = Text(row, "GameFontNormalSmall")
    row.status:SetPoint("TOPRIGHT", -26, -5)
    row.status:SetJustifyH("RIGHT")
    row.reason = Text(row, "GameFontHighlightSmall", "", DIM)
    row.reason:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
    row.reason:SetPoint("RIGHT", -26, 0)
    row.reason:SetWordWrap(false)
    row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
    row.remove:SetSize(20, 20)
    row.remove:SetPoint("TOPRIGHT", 0, -1)
    row.remove:SetScript("OnClick", function(self) ns.ForgetMine(self:GetParent().id) end)
    row.remove:SetScript("OnEnter", function(self)
        ShowTip(self, "Remove from your list", "Only removes it here. It stays with the members who can invite.")
    end)
    row.remove:SetScript("OnLeave", HideTip)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if self.fullReason and self.fullReason ~= "" then
            ShowTip(self, ns.Show(self.target), self.fullReason)
        end
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
    row.id, row.target, row.fullReason = m.id, m.target, m.reason
    row.name:SetText(ns.Show(m.target))
    local status
    if not m.delivered then
        status = "Waiting to send"
    else
        status = MINE_STATUS[m.status] or MINE_STATUS.new
    end
    row.status:SetText(status .. "  " .. ns.Ago(m.at))
    local c = (m.status == "invited" and GOOD) or GOLD
    row.status:SetTextColor(c[1], c[2], c[3])
    row.reason:SetText(m.reason ~= "" and m.reason or "(no reason given)")
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
        local first, second = UnitName("target")
        if UnitIsPlayer and UnitIsPlayer("target") and type(first) == "string" and not ns.IsSecret(first) then
            local raw = (type(second) == "string" and not ns.IsSecret(second) and second ~= "") and (first .. " " .. second) or first
            p.name:SetText(ns.FullName(raw) or raw)
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
    p.empty = Text(p, "GameFontDisableSmall", "Nothing yet.", DIM)
    p.empty:SetPoint("TOPLEFT", mineLabel, "BOTTOMLEFT", 0, -6)

    p.list = List(p)
    p.list:SetPoint("TOPLEFT", mineLabel, "BOTTOMLEFT", 0, -4)
    p.list:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -4, 18)
    p.list.MakeRow = MineRow
    p.list.FillRow = FillMine

    function p:Refresh()
        local g = ns.Guild()
        local entries = {}
        if g then
            for _, m in pairs(g.mine) do
                entries[#entries + 1] = { height = 38, mine = m }
            end
            table.sort(entries, function(a, b) return (a.mine.at or 0) > (b.mine.at or 0) end)
        end
        p.empty:SetShown(#entries == 0)
        p.list:SetEntries(entries)
        if not g then
            p.who:SetText("You are not in a guild.")
        elseif ns.IMayInvite() then
            p.who:SetText("You can invite, so your suggestions go straight on the To decide list.")
        else
            local n = #ns.OnlineInviters()
            p.who:SetText(n == 0 and "Nobody who can invite is online with this addon right now."
                or (n == 1 and "1 member who can invite is online with this addon."
                or (n .. " members who can invite are online with this addon.")))
        end
    end
    return p
end

-------------------------------------------------------------------------------
-- Page 2: To decide
-------------------------------------------------------------------------------

local function ConfirmDecline(it)
    if not StaticPopup_Show or not StaticPopupDialogs then
        ns.Decide(it.id, "declined")
        return
    end
    StaticPopupDialogs.INVITESUGGESTIONS_DECLINE = StaticPopupDialogs.INVITESUGGESTIONS_DECLINE or {
        text = "%s",
        button1 = "Decline",
        button2 = "Cancel",
        OnAccept = function(_, id)
            if id then
                ns.Decide(id, "declined")
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    local text = "Decline " .. ns.Show(it.target) .. "?\n\n" .. ns.Show(it.by)
        .. " will see that the suggestion was not accepted (not who declined it)."
    StaticPopup_Show("INVITESUGGESTIONS_DECLINE", text, nil, it.id)
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
    row.invite = Button(row, "Invite", 76, function(self) ns.InvitePlayer(self:GetParent().id) end)
    row.invite:SetPoint("TOPRIGHT", -84, -1)
    row.decline = Button(row, "Decline", 76, function(self)
        local g = ns.Guild()
        local it = g and g.items[self:GetParent().id]
        if it then
            ConfirmDecline(it)
        end
    end)
    row.decline:SetPoint("TOPRIGHT", -4, -1)
    row.remove = Button(row, "Remove", 76, function(self) ns.Decide(self:GetParent().id, "removed") end)
    row.remove:SetPoint("TOPRIGHT", -4, -1)
    row.remove:SetScript("OnEnter", function(self)
        ShowTip(self, "Remove", "Takes it off this list for everyone who can invite.")
    end)
    row.remove:SetScript("OnLeave", HideTip)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        ShowTip(self, ns.Show(self.target), self.fullReason ~= "" and self.fullReason or "(no reason given)")
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
    row.id, row.target, row.fullReason = it.id, it.target, it.reason or ""
    row.name:SetText(ns.Show(it.target))
    local waiting = it.status == "new"
    if waiting then
        row.from:SetText("from " .. ns.Show(it.by) .. ", " .. ns.Ago(it.at))
        row.reason:SetText(it.reason ~= "" and it.reason or "(no reason given)")
        row.reason:SetTextColor(WHITE[1], WHITE[2], WHITE[3])
    else
        local what = it.status == "invited" and "Invited" or "Declined"
        row.from:SetText("from " .. ns.Show(it.by))
        row.reason:SetText(what .. " by " .. ns.Show(it.decidedBy) .. ", " .. ns.Ago(it.decidedAt))
        local c = it.status == "invited" and GOOD or GOLD
        row.reason:SetTextColor(c[1], c[2], c[3])
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
    p.list:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -4, 18)
    p.list.MakeRow = DecideRow
    p.list.FillRow = FillDecide

    function p:Refresh()
        local g = ns.Guild()
        local waiting, decided = {}, {}
        if g and ns.IMayInvite() then
            for _, it in pairs(g.items) do
                if it.status == "new" then
                    waiting[#waiting + 1] = it
                elseif it.status == "invited" or it.status == "declined" then
                    decided[#decided + 1] = it
                end
            end
        end
        table.sort(waiting, function(a, b) return (a.at or 0) < (b.at or 0) end)
        table.sort(decided, function(a, b) return (a.decidedAt or 0) > (b.decidedAt or 0) end)
        local entries = {}
        for _, it in ipairs(waiting) do
            entries[#entries + 1] = { height = 60, item = it }
        end
        if #decided > 0 then
            entries[#entries + 1] = { height = 30, header = "Decided" }
            for _, it in ipairs(decided) do
                entries[#entries + 1] = { height = 44, item = it }
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
-- Window
-------------------------------------------------------------------------------

local function ShowPage(i)
    currentPage = i
    for n, page in ipairs(pages) do
        page:SetShown(n == i)
    end
    if PanelTemplates_SetTab and window.numTabs then
        PanelTemplates_SetTab(window, i)
    end
    for n, t in ipairs(tabs) do
        if t.plain then
            t:SetEnabled(n ~= i)
        end
    end
    if pages[i] and pages[i].Refresh then
        pages[i]:Refresh()
    end
end

local function UpdateTabs()
    local mayInvite = ns.IMayInvite()
    local waiting = ns.WaitingCount()
    if tabs[2] then
        tabs[2]:SetText(waiting > 0 and ("To decide (" .. waiting .. ")") or "To decide")
        if PanelTemplates_TabResize then
            pcall(PanelTemplates_TabResize, tabs[2], 0)
        end
        tabs[2]:SetShown(mayInvite)
    end
    if not mayInvite and currentPage == 2 then
        ShowPage(1)
    end
end

local function SavePlace()
    local point, _, relPoint, x, y = window:GetPoint(1)
    ns.db.window = { point = point, relPoint = relPoint, x = x, y = y }
end

local function BuildWindow()
    local ok, f = pcall(CreateFrame, "Frame", "InviteSuggestionsFrame", UIParent, "ButtonFrameTemplate")
    local framed = ok and f
    if not framed then
        f = CreateFrame("Frame", "InviteSuggestionsFrame", UIParent, "BackdropTemplate")
        if f.SetBackdrop then
            f:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 11, right = 12, top = 12, bottom = 11 },
            })
        end
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)
        local title = Text(f, "GameFontNormal", "Invite Suggestions", GOLD)
        title:SetPoint("TOP", 0, -16)
    end
    window = f
    f:SetSize(W, H)
    local place = ns.db.window or {}
    if place.point then
        f:SetPoint(place.point, UIParent, place.relPoint or place.point, tonumber(place.x) or 0, tonumber(place.y) or 0)
    else
        f:SetPoint("CENTER")
    end
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePlace()
    end)
    f:Hide()
    tinsert(UISpecialFrames, "InviteSuggestionsFrame")

    if framed then
        if ButtonFrameTemplate_HideButtonBar then
            pcall(ButtonFrameTemplate_HideButtonBar, f)
        end
        if f.SetTitle then
            pcall(f.SetTitle, f, "Invite Suggestions")
        end
        if f.SetPortraitToAsset then
            pcall(f.SetPortraitToAsset, f, ICON)
        elseif type(f.portrait) == "table" and SetPortraitToTexture then
            pcall(SetPortraitToTexture, f.portrait, ICON)
        end
    end

    local content = CreateFrame("Frame", nil, f)
    if framed and type(f.Inset) == "table" then
        content:SetPoint("TOPLEFT", f.Inset, "TOPLEFT", 8, -8)
        content:SetPoint("BOTTOMRIGHT", f.Inset, "BOTTOMRIGHT", -8, 4)
    else
        content:SetPoint("TOPLEFT", 20, -40)
        content:SetPoint("BOTTOMRIGHT", -20, 20)
    end
    pages[1] = BuildSuggestPage(content)
    pages[2] = BuildDecidePage(content)

    -- Tabs under the window, like the game's own panels.
    local labels = { "Suggest", "To decide" }
    for i, label in ipairs(labels) do
        local okTab, t = pcall(CreateFrame, "Button", "InviteSuggestionsFrameTab" .. i, f, "PanelTabButtonTemplate")
        if not okTab or not t then
            t = Button(f, label, 110)
            t.plain = true
        end
        t:SetID(i)
        t:SetText(label)
        t:SetScript("OnClick", function(self) ShowPage(self:GetID()) end)
        if i == 1 then
            t:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, 2)
        else
            t:SetPoint("LEFT", tabs[i - 1], "RIGHT", t.plain and 4 or -15, 0)
        end
        if PanelTemplates_TabResize and not t.plain then
            pcall(PanelTemplates_TabResize, t, 0)
        end
        tabs[i] = t
    end
    if PanelTemplates_SetNumTabs and not tabs[1].plain then
        PanelTemplates_SetNumTabs(f, #tabs)
    end
    f:SetScript("OnShow", function()
        UpdateTabs()
        ShowPage(currentPage)
    end)
    return f
end

function ns.RefreshUI()
    if window and window:IsShown() then
        UpdateTabs()
        if pages[currentPage] then
            pages[currentPage]:Refresh()
        end
    end
end

function ns.ToggleWindow()
    if not ns.db or not ns.me then
        return
    end
    if not window then
        BuildWindow()
    end
    if window:IsShown() then
        window:Hide()
    else
        -- Waiting suggestions open on the To decide page.
        if ns.WaitingCount() > 0 then
            currentPage = 2
        end
        window:Show()
    end
end

-- Opens the Suggest page with a name filled in.
function ns.OpenSuggest(name)
    if not ns.db or not ns.me then
        return
    end
    if not window then
        BuildWindow()
    end
    currentPage = 1
    window:Show()
    ShowPage(1)
    local p = pages[1]
    p.name:SetText(ns.FullName(name) or name or "")
    p.name:UpdateHint()
    p.msg:SetText("")
    p.reason:SetFocus()
end

-------------------------------------------------------------------------------
-- Minimap button (drag it around the edge)
-------------------------------------------------------------------------------

local function PlaceMinimapButton(b)
    local angle = math.rad(ns.db.minimap.angle or 200)
    local radius = (Minimap:GetWidth() / 2) + 10
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function BuildMinimapButton()
    local b = CreateFrame("Button", "InviteSuggestionsMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetPoint("CENTER")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    b:RegisterForClicks("LeftButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnClick", function() ns.ToggleWindow() end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            ns.db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            PlaceMinimapButton(self)
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    -- "!" while suggestions wait for you (the tooltip says it in words too).
    b.mark = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    b.mark:SetPoint("TOPRIGHT", 2, 0)
    b.mark:SetText("!")
    b.mark:SetTextColor(GOOD[1], GOOD[2], GOOD[3])
    b.mark:Hide()
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Invite Suggestions", 1, 0.82, 0)
        local waiting = ns.WaitingCount()
        if waiting > 0 then
            GameTooltip:AddLine(waiting == 1 and "1 suggestion waiting for a decision."
                or (waiting .. " suggestions waiting for a decision."), GOOD[1], GOOD[2], GOOD[3], true)
        end
        GameTooltip:AddLine("Left-click: Open or close", 1, 1, 1, true)
        GameTooltip:AddLine("Drag: Move", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    PlaceMinimapButton(b)
    return b
end

function ns.RefreshMinimapMark()
    local b = InviteSuggestionsMinimapButton
    if b and b.mark then
        b.mark:SetShown(ns.WaitingCount() > 0)
    end
end

ns.On("IS_READY", function()
    if Minimap and not ns.db.minimap.hide then
        BuildMinimapButton()
        ns.RefreshMinimapMark()
    end
end)
ns.On("IS_ROSTER", function() ns.RefreshMinimapMark() end)

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
