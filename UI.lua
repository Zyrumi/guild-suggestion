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
        if self.BeforeLayout then
            self.BeforeLayout()
        end
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
            -- One broken row must not blank the whole list; say what broke.
            local ok, err = pcall(self.FillRow, row, e)
            if not ok and not self.reported then
                self.reported = true
                ns.Print("error showing the list: " .. tostring(err))
            end
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
            p.who:SetText("Anyone you suggest shows up on the To decide list.")
        else
            local n = #ns.OnlineInviters()
            local start = "Your suggestion shows up on the To decide list of the members who can invite. You see their answer below. "
            p.who:SetText(start .. (n == 0 and "None of them is online right now, so it waits until one is online at the same time as you."
                or (n == 1 and "1 of them is online now." or (n .. " of them are online now."))))
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
    StaticPopupDialogs.GUILDSUGGESTION_DECLINE = StaticPopupDialogs.GUILDSUGGESTION_DECLINE or {
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
    StaticPopup_Show("GUILDSUGGESTION_DECLINE", text, nil, it.id)
end

-- Invite: Forever only lets its own UI send guild invites, so an addon can't
-- call the invite itself. Instead the Invite button is a secure button that
-- runs "/ginvite First Surname" as a macro when you click it, exactly as if
-- you had typed it. Secure buttons can't be moved, shown or hidden during a
-- fight, so they sit on UIParent (outside the guild window) and are hidden
-- and set loose as a fight starts; until it ends, the row's plain Invite
-- button stands in and says to wait.
local secureButtons = {}
local fighting = false -- from the moment a fight starts until it ends
local secureProblem      -- why the last Invite button couldn't be set up (shown on the stand-in)

local function HideSecure()
    if InCombatLockdown() then
        return
    end
    for _, b in ipairs(secureButtons) do
        b:Hide()
        b:ClearAllPoints()
        b.id, b.row, b.placed = nil, nil, nil
    end
end

-- Secure frames may only be anchored to the screen (UIParent), not to our
-- rows, so each button is put at its row's place on screen, at the row's
-- scale, and follows it while the page is open (see the panel's OnUpdate).
local function PlaceSecure(b)
    local row = rawget(b, "row")
    if not row or fighting or InCombatLockdown() then
        return
    end
    -- Stay above the row: the guild window rises above other frames when
    -- clicked, which would otherwise cover a button placed above it once.
    local strata, level = row:GetFrameStrata() or "MEDIUM", math.min((row:GetFrameLevel() or 0) + 10, 10000)
    if b:GetFrameStrata() ~= strata then
        b:SetFrameStrata(strata)
    end
    if b:GetFrameLevel() ~= level then
        b:SetFrameLevel(level)
    end
    local face = row.invite
    local right, top = face:GetRight(), face:GetTop()
    if not right or not top then
        return -- not laid out yet; the next update places it
    end
    local scale = (face:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    local x, y = right, top
    local placed = rawget(b, "placed")
    if placed and placed[1] == x and placed[2] == y and placed[3] == scale then
        return
    end
    b:SetScale(scale)
    b:ClearAllPoints()
    b:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", x, y)
    b.placed = { x, y, scale }
end

-- /gsuggest debug: where each Invite button is and what covers it.
function ns.DebugInvite()
    if #secureButtons == 0 then
        ns.Print("debug: no Invite buttons made yet. " .. (secureProblem and ("Last problem: " .. secureProblem) or ""))
    end
    local function R(v) return v and string.format("%.0f", v) or "-" end
    for i, b in ipairs(secureButtons) do
        local row = rawget(b, "row")
        ns.Print(string.format("debug %d: shown %s visible %s, %s %d, at %s,%s scale %.2f, alpha %.2f | row %s %s %d, right %s top %s",
            i, tostring(b:IsShown()), tostring(b:IsVisible()), b:GetFrameStrata(), b:GetFrameLevel(),
            R(b:GetLeft()), R(b:GetTop()), b:GetScale() or 0, b:GetEffectiveAlpha() or 0,
            row and "yes" or "none", row and row:GetFrameStrata() or "-", row and row:GetFrameLevel() or 0,
            R(row and row:GetRight()), R(row and row:GetTop())))
    end
    if secureProblem then
        ns.Print("debug: last problem: " .. secureProblem)
    end
    -- Paint the click catchers red (until /reload) so you can see where they are.
    for i, b in ipairs(secureButtons) do
        if not rawget(b, "debugPaint") then
            local t = b:CreateTexture(nil, "OVERLAY")
            t:SetAllPoints()
            t:SetColorTexture(1, 0, 0, 0.6)
            b.debugPaint = t
        end
        ns.Print(string.format("debug %d: mouse %s, size %.0fx%.0f | screen left %s bottom %s scale %.3f, button scale %.3f, row scale %.3f",
            i, tostring(b:IsMouseEnabled()), b:GetWidth() or 0, b:GetHeight() or 0,
            R(UIParent:GetLeft()), R(UIParent:GetBottom()), UIParent:GetEffectiveScale() or 0,
            b:GetEffectiveScale() or 0, rawget(b, "row") and rawget(b, "row"):GetEffectiveScale() or 0))
    end
end

function ns.FollowSecure()
    for _, b in ipairs(secureButtons) do
        if b:IsShown() then
            PlaceSecure(b)
        end
    end
end

local function SecureFor(row)
    if fighting or InCombatLockdown() then
        return nil
    end
    local have = rawget(row, "secure")
    if have then
        return have
    end
    -- An invisible click catcher laid over the row's own Invite button,
    -- which stays the visible face (lit up while the mouse is over it).
    local ok, b = pcall(CreateFrame, "Button", "GuildSuggestionInvite" .. (#secureButtons + 1), UIParent,
        "SecureActionButtonTemplate")
    if not ok or not b then
        secureProblem = "could not create it: " .. tostring(b)
        return nil
    end
    b:SetSize(76, 22)
    local face = row.invite
    b:HookScript("OnMouseDown", function() face:SetButtonState("PUSHED") end)
    b:HookScript("OnMouseUp", function() face:SetButtonState("NORMAL") end)
    -- Both halves of a click: the game acts on the press or the release
    -- depending on the "cast on key down" setting.
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("type", "macro")
    b:HookScript("PostClick", function(self)
        if self.id then
            ns.WatchInvite(self.id)
        end
    end)
    b:SetScript("OnEnter", function(self)
        face:LockHighlight()
        ShowTip(self, "Invite", "Sends " .. ns.Show(self.target) .. " a guild invite, like typing /ginvite. They need to be online.")
    end)
    b:SetScript("OnLeave", function()
        face:UnlockHighlight()
        face:SetButtonState("NORMAL")
        HideTip()
    end)
    b:Hide()
    secureButtons[#secureButtons + 1] = b
    row.secure = b
    return b
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
    -- The visible Invite button. Its clicks normally land on the secure
    -- catcher on top (see SecureFor); a click that reaches it means the
    -- catcher isn't there: during a fight, or it couldn't be set up (then it
    -- says why and tries again).
    row.invite = Button(row, "Invite", 76, function(self)
        if InCombatLockdown() then
            ns.Print("guild invites can be sent again when the fight is over.")
            return
        end
        local target = self:GetParent().target
        ns.Print("the Invite button wasn't ready (" .. (secureProblem or (fighting and "a fight seemed to be on" or "unknown"))
            .. "). Trying again; meanwhile you can type /ginvite " .. tostring(target))
        fighting = false
        ns.RefreshUI()
    end)
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
    row.decline:SetShown(waiting)
    row.remove:SetShown(not waiting)
    local secure = waiting and SecureFor(row)
    local ready = false
    if secure then
        local ok, err = pcall(function()
            secure.id, secure.target = it.id, it.target
            secure:SetAttribute("macrotext", "/ginvite " .. it.target)
            secure.row, secure.placed = row, nil
            secure:Show()
            PlaceSecure(secure)
        end)
        if ok then
            ready = true
            secureProblem = nil
        else
            secureProblem = tostring(err)
        end
    end
    -- The row's Invite button is always the visible one; when the secure
    -- catcher is ready it lies on top and takes the click.
    row.invite:SetShown(waiting)
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
    p.list.BeforeLayout = HideSecure

    function p:Refresh()
        local g = ns.Guild()
        local waiting, decided = {}, {}
        if g and ns.IMayInvite() then
            for _, it in pairs(g.items) do
                if it.status == "new" then
                    waiting[#waiting + 1] = it
                elseif (it.status == "invited" or it.status == "declined") and not it.removedAt then
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
    for _, it in pairs(g.items) do
        local who = ns.Show(it.target)
        list[#list + 1] = { at = it.at or 0, item = it, text = ns.Show(it.by) .. " suggested " .. who }
        if it.decidedAt and it.decidedBy then
            local did = (it.status == "invited" and "invited") or (it.status == "declined" and "declined") or "decided on"
            list[#list + 1] = { at = it.decidedAt, item = it, text = ns.Show(it.decidedBy) .. " " .. did .. " " .. who }
        end
        if it.removedAt and it.removedBy then
            list[#list + 1] = { at = it.removedAt, item = it, text = ns.Show(it.removedBy) .. " removed " .. who .. " from the list" }
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
            ShowTip(self, ns.Show(it.target), "Suggested by " .. ns.Show(it.by) .. ", " .. When(it.at),
                it.reason ~= "" and ("Reason: " .. it.reason) or "No reason given")
        end
    end)
    row:SetScript("OnLeave", HideTip)
    return row
end

local function FillLog(row, e)
    row.item = e.item
    row.when:SetText(When(e.at))
    row.text:SetText(e.text)
end

local function BuildLogPage(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints()
    p.note = Text(p, "GameFontDisableSmall", "", DIM)
    p.note:SetPoint("TOPLEFT", 4, -4)
    p.note:SetPoint("RIGHT", p, "RIGHT", -4, 0)
    p.list = List(p)
    p.list:SetPoint("TOPLEFT", p.note, "BOTTOMLEFT", 0, -8)
    p.list:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -4, 18)
    p.list.MakeRow = LogRow
    p.list.FillRow = FillLog

    function p:Refresh()
        local entries = {}
        if ns.IMayInvite() then
            for _, e in ipairs(ns.LogEntries()) do
                e.height = 20
                entries[#entries + 1] = e
            end
        end
        if not ns.IMayInvite() then
            p.note:SetText("Only members who can invite see the log.")
        elseif #entries == 0 then
            p.note:SetText("Nothing logged yet.")
        else
            p.note:SetText("Every suggestion and decision, newest first. Hover a line for the reason.")
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
    currentPage = i
    if i ~= 2 then
        HideSecure()
    end
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

-- The roster page's buttons along the bottom edge (Invite Member, Guild
-- Control, Guild Log) sit outside the panel; they're faded out and made
-- unclickable while it's open, so the game stays in charge of showing them.
local BOTTOM_BUTTONS = { "InviteButton", "CommunitiesControlFrame", "GuildLogButton" }
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
    HideSecure()
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
    -- Keep the Invite buttons on their rows if the window moves.
    local since = 0
    panel:SetScript("OnUpdate", function(_, elapsed)
        since = since + elapsed
        if since > 0.1 then
            since = 0
            ns.FollowSecure()
        end
    end)
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
ns.On("PLAYER_REGEN_DISABLED", function()
    fighting = true
    HideSecure()
    ns.RefreshUI()
end)
ns.On("PLAYER_REGEN_ENABLED", function()
    fighting = false
    ns.RefreshUI()
end)

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
