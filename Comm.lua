-- GuildSuggestion: hidden addon messages between guild members
--
-- Who sees what:
--   Everyone with the addon says a short hello on the guild channel: name and
--   whether they may invite. Hellos never carry suggestions.
--   A suggestion (name + reason) is only ever WHISPERED to members who may
--   invite, after checking their guild rank (see ns.CanInvite).
--   Members who may invite keep each other's lists in step, also by whisper.
--   The member who made a suggestion only hears back its status.
--
-- If nobody who may invite is online, the suggestion waits on your side and
-- goes out when one of them logs in while you are online.
--
-- Guild channel:
--   HI  hello: ver^reply^full name^may invite (1/0)
-- Whispers:
--   SG  suggestion: id^target^at^reason^level^class       member -> inviter
--   OK  got it: id                                        inviter -> member
--   ST  status: id^status                                 inviter -> member
--   DL  my list: id:rev,id:rev,...                        inviter -> inviter
--   DQ  please send: id,id,...                            inviter -> inviter
--   PI  online check: empty, to a suggested player (see ns.CheckOnline)
--   DI  one suggestion: id^rev^target^by^at^status^decidedBy^decidedAt^reason^removedBy^removedAt^level^class
--
-- Long messages are split in parts; sending is paced and pauses in combat.

local ADDON_NAME, ns = ...

local PREFIX = "GuildSuggest"
local MAX_LEN = 240
local GUILD = "@guild"

local heard = {}        -- [name] = { canInvite = bool } members with the addon this session
local recentWhisper = {} -- [target] = GetTime() of our last whisper
local ready = false

local STATUSES = { new = true, invited = true, declined = true, removed = true }

local function Split(s, sep)
    local out = {}
    local start = 1
    while true do
        local i = s:find(sep, start, true)
        if not i then
            out[#out + 1] = s:sub(start)
            return out
        end
        out[#out + 1] = s:sub(start, i - 1)
        start = i + 1
    end
end

local function ValidId(id)
    return type(id) == "string" and #id <= 16 and id:match("^%x+$") ~= nil
end

local function Refresh()
    if ns.RefreshUI then ns.RefreshUI() end
    if ns.RefreshBadge then ns.RefreshBadge() end
end

-------------------------------------------------------------------------------
-- Sending (paced queue)
-------------------------------------------------------------------------------

local queue = {}
local tokens, MAX_TOKENS, REFILL = 6, 6, 1.0
local chunkId = math.random(0, 998)

local function RawSend(item)
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then
        return "drop"
    end
    local ok, res
    if item.target == GUILD then
        ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, item.text, "GUILD")
    else
        ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, item.text, "WHISPER", item.target)
    end
    if not ok then
        return "drop"
    end
    if res == 3 or res == 8 then
        return "retry" -- the game says: slow down
    end
    -- Newer clients return a result code (0 = sent), older ones nothing or true.
    if res == nil or res == 0 or res == true then
        return "sent"
    end
    return "drop" -- refused by the game
end

local pump = CreateFrame("Frame")
pump:SetScript("OnUpdate", function(_, elapsed)
    tokens = math.min(MAX_TOKENS, tokens + elapsed * REFILL)
    if #queue == 0 or tokens < 1 or InCombatLockdown() then
        return
    end
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        return
    end
    local item = table.remove(queue, 1)
    local result = RawSend(item)
    if result == "retry" then
        table.insert(queue, 1, item)
        tokens = 0
    else
        tokens = tokens - 1
        if result == "sent" and item.target ~= GUILD then
            recentWhisper[item.target] = GetTime()
        end
        local cb = item.cb
        if cb then
            local fn = result == "sent" and cb.sent or cb.failed
            if fn then
                pcall(fn, GetTime())
            end
        end
    end
end)

-- cb (optional, single-part messages): { sent = fn(time), failed = fn() }
local function Queue(target, kind, payload, tag, cb)
    if tag then
        for i = #queue, 1, -1 do
            if queue[i].tag == tag and queue[i].target == target then
                table.remove(queue, i)
            end
        end
    end
    local msg = kind .. "^" .. (payload or "")
    if #msg <= MAX_LEN then
        queue[#queue + 1] = { target = target, text = "S" .. msg, tag = tag, cb = cb }
        return
    end
    chunkId = (chunkId % 999) + 1
    local n = math.ceil(#msg / MAX_LEN)
    for i = 1, n do
        local part = msg:sub((i - 1) * MAX_LEN + 1, i * MAX_LEN)
        queue[#queue + 1] = { target = target, text = "C" .. chunkId .. ":" .. i .. ":" .. n .. ":" .. part, tag = tag }
    end
end

local function ForgetQueued(target)
    for i = #queue, 1, -1 do
        if queue[i].target == target then
            table.remove(queue, i)
        end
    end
end

-------------------------------------------------------------------------------
-- Who is around
-------------------------------------------------------------------------------

local function IMayInvite()
    return ns.CanInvite(ns.me)
end
ns.IMayInvite = IMayInvite

-- Online members with the addon who may invite (checked by rank, not by
-- what they say), not counting you.
local function OnlineInviters()
    local list = {}
    for name, h in pairs(heard) do
        if h.canInvite and ns.IsOnline(name) and ns.CanInvite(name) then
            list[#list + 1] = name
        end
    end
    return list
end
ns.OnlineInviters = OnlineInviters

local lastHello = 0

local function Hello(reply)
    if not ready or not ns.GuildName() then
        return
    end
    if reply and GetTime() - lastHello < 10 then
        return -- answered a moment ago; everyone heard it
    end
    lastHello = GetTime()
    Queue(GUILD, "HI", table.concat({ ns.PROTOCOL, reply and 1 or 0, ns.me, IMayInvite() and 1 or 0 }, "^"), "HI")
end

-------------------------------------------------------------------------------
-- Suggestions
-------------------------------------------------------------------------------

local function ItemPayload(it)
    return table.concat({ it.id, it.rev or 1, it.target, it.by, it.at or 0, it.status or "new",
        it.decidedBy or "", it.decidedAt or 0, it.reason or "", it.removedBy or "", it.removedAt or 0,
        it.level or 0, it.class or "" }, "^")
end

local function SendSuggestion(to, m)
    Queue(to, "SG", table.concat({ m.id, m.target, m.at or 0, m.reason or "", m.level or 0, m.class or "" }, "^"), "SG" .. m.id)
end

-- Your waiting suggestions go to everyone online who may invite.
local function FlushOutbox(only)
    local g = ns.Guild()
    if not g then
        return
    end
    local to = only and { only } or OnlineInviters()
    for _, m in pairs(g.mine) do
        if not m.delivered then
            for _, name in ipairs(to) do
                SendSuggestion(name, m)
            end
        end
    end
end

-- Tells the other inviters online about one suggestion.
local function PushItem(it, except)
    for _, name in ipairs(OnlineInviters()) do
        if name ~= except then
            Queue(name, "DI", ItemPayload(it), "DI" .. it.id)
        end
    end
end

-- Tells the member who suggested it what became of it, if they are online.
local function TellSuggester(it)
    if ns.IsMe(it.by) then
        return
    end
    if (it.status == "invited" or it.status == "declined") and ns.IsOnline(it.by) and heard[it.by] then
        Queue(it.by, "ST", it.id .. "^" .. it.status, "ST" .. it.id)
        it.told = true
    end
end

-- Several new suggestions at once (e.g. after logging in) give one line.
local newCount, newTimer = 0, false
local function NoteNew(it)
    newCount = newCount + 1
    ns.lastNew = it
    if newTimer then
        return
    end
    newTimer = true
    C_Timer.After(3, ns.Safe(function()
        newTimer = false
        if newCount == 1 and ns.lastNew then
            ns.Print("new invite suggestion: " .. ns.Show(ns.lastNew.target) .. " (from " .. ns.Show(ns.lastNew.by)
                .. "). Open the guild window or type /gsuggest to see it.")
        elseif newCount > 1 then
            ns.Print(newCount .. " new invite suggestions. Open the guild window or type /gsuggest to see them.")
        end
        newCount = 0
        ns.lastNew = nil
    end, "notice"))
end

-- Suggestions you can decide on that nobody has decided yet.
function ns.WaitingCount()
    local g = ns.GuildName() and ns.Guild()
    if not g or not IMayInvite() then
        return 0
    end
    local n, seen = 0, {}
    for _, it in pairs(g.items) do
        if it.status == "new" and not it.joinedAt and not seen[it.target] then
            seen[it.target] = true
            n = n + 1
        end
    end
    return n
end

-- A new suggestion typed in the window. Returns true, or false + why not.
function ns.Suggest(rawTarget, rawReason)
    local g = ns.Guild()
    if not g then
        return false, "You are not in a guild."
    end
    local target = ns.FullName(ns.Clean(rawTarget, 60))
    if not target then
        if ns.forever then
            return false, "Type the full name: first name and surname."
        end
        return false, "Type a character name."
    end
    if ns.IsMe(target) then
        return false, "That is you."
    end
    if ns.Member(target) == target then
        return false, ns.Show(target) .. " is already in the guild."
    end
    local reason = ns.Clean(rawReason, ns.MAX_REASON)
    local level, class = ns.LookupPlayer(target)
    if not level or not class then
        local kl, kc = ns.KnownInfo(g, target)
        level, class = level or kl, class or kc
    end
    local m = { id = ns.NewId(), target = target, reason = reason, by = ns.MyKey(), at = time(), status = "new",
        level = level, class = class }
    g.mine[m.id] = m
    if IMayInvite() then
        -- You may invite yourself: it goes straight on your list and to the others.
        m.delivered = true
        local it = { id = m.id, rev = 1, target = target, reason = reason, by = ns.MyKey(), at = m.at, status = "new",
            level = level, class = class }
        g.items[it.id] = it
        PushItem(it)
        Refresh()
        return true, "Added to the To decide list."
    end
    local to = OnlineInviters()
    for _, name in ipairs(to) do
        SendSuggestion(name, m)
    end
    Refresh()
    if #to > 0 then
        return true, "Sent."
    end
    return true, "Saved. It's sent when a member who can invite is online."
end

-- An inviter's choice: "invited", "declined" or "removed". Removing only
-- takes a decided suggestion off the Decided list: its status (invited or
-- declined) and who decided stay on record for the log, next to who removed it.
function ns.Decide(id, status)
    local g = ns.Guild()
    local it = g and g.items[id]
    if not it or not STATUSES[status] or not IMayInvite() then
        return
    end
    it.rev = (it.rev or 1) + 1
    if status == "removed" then
        it.removedBy = ns.MyKey()
        it.removedAt = time()
    else
        it.status = status
        it.decidedBy = ns.MyKey()
        it.decidedAt = time()
        it.told = nil
    end
    if ns.IsMe(it.by) and g.mine[id] and status ~= "removed" then
        g.mine[id].status = status
    end
    PushItem(it)
    TellSuggester(it)
    Refresh()
end

-- Seeing a suggested player (target or mouseover) fills in or updates their
-- level and class on your side.
local function Seen(unit)
    local name, level, class = ns.UnitInfo(unit)
    local g = name and ns.GuildName() and ns.Guild()
    if not g or (not level and not class) then
        return
    end
    local changed = false
    for _, list in ipairs({ g.items, g.mine }) do
        for _, it in pairs(list) do
            if it.target == name and (it.level ~= (level or it.level) or it.class ~= (class or it.class)) then
                it.level = level or it.level
                it.class = class or it.class
                changed = true
            end
        end
    end
    if changed then
        Refresh()
    end
end
ns.On("PLAYER_TARGET_CHANGED", function() Seen("target") end)
ns.On("UPDATE_MOUSEOVER_UNIT", function() Seen("mouseover") end)

-- Your characters share one saved list. A suggestion one of your characters
-- made and another (who can invite) decided is already in the shared list,
-- so your own list takes the decision from there: the two characters are
-- never online together to tell each other.
-- The latest known level and class of a player, from any suggestion of
-- them in your saved lists (suggestions of the same name are the same player).
function ns.KnownInfo(g, target)
    local level, class, levelAt = nil, nil, -1
    for _, list in ipairs({ g.items, g.mine }) do
        for _, it in pairs(list) do
            if it.target == target then
                if it.level and (it.at or 0) > levelAt then
                    level, levelAt = it.level, it.at or 0
                end
                class = class or it.class
            end
        end
    end
    return level, class
end

function ns.SyncMine()
    local g = ns.GuildName() and ns.Guild()
    if not g then
        return
    end
    -- Fill in level and class known from another suggestion of the same name.
    for _, list in ipairs({ g.items, g.mine }) do
        for _, it in pairs(list) do
            if it.target and (not it.level or not it.class) then
                local kl, kc = ns.KnownInfo(g, it.target)
                it.level, it.class = it.level or kl, it.class or kc
            end
        end
    end
    for id, m in pairs(g.mine) do
        local it = g.items[id]
        if it then
            m.delivered = true
            if (it.status == "invited" or it.status == "declined") and m.status ~= it.status then
                m.status = it.status
            end
            if it.joinedAt and not m.joinedAt then
                m.joinedAt = it.joinedAt
            end
        end
    end
end

-- Your whole list (only on your side; ones not sent yet are cancelled).
function ns.ClearMine()
    local g = ns.Guild()
    if g then
        g.mine = {}
        Refresh()
    end
end

-- Your own suggestion off your own list (only on your side).
function ns.ForgetMine(id)
    local g = ns.Guild()
    if g and g.mine[id] then
        g.mine[id] = nil
        Refresh()
    end
end

-------------------------------------------------------------------------------
-- Inviting: the game's own UI sends the invite (see InviteHelp in UI.lua);
-- its "You have invited X to join your guild." line marks the waiting
-- suggestion for X as invited, by you, however the invite was sent.
-------------------------------------------------------------------------------

local function FormatPattern(fmt)
    if type(fmt) ~= "string" then
        return nil
    end
    local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1")
    return "^" .. p:gsub("%%%%s", "(.+)") .. "$"
end

-- The waiting suggestion a name from a game message points at: the same
-- full name, or the only waiting one with that first name.
local function WaitingFor(raw)
    local g = ns.Guild()
    if not g or type(raw) ~= "string" then
        return nil
    end
    local full = ns.FullName((raw:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")))
    local first = ns.FirstName(raw)
    local byFirst, count = nil, 0
    for _, it in pairs(g.items) do
        if it.status == "new" and not it.joinedAt then
            if full and it.target == full then
                return it
            end
            if ns.FirstName(it.target) == first then
                byFirst, count = it, count + 1
            end
        end
    end
    return count == 1 and byFirst or nil
end

ns.On("CHAT_MSG_SYSTEM", function(msg)
    if type(msg) ~= "string" or ns.IsSecret(msg) or not IMayInvite() then
        return
    end
    local p = FormatPattern(ERR_GUILD_INVITE_S)
    local who = p and msg:match(p)
    local it = who and WaitingFor(who)
    if it then
        local g = ns.Guild()
        for id, other in pairs(g.items) do
            if other.status == "new" and not other.joinedAt and other.target == it.target then
                ns.Decide(id, "invited")
            end
        end
    end
end)

-- A suggested player showing up in the guild roster has joined (whoever
-- invited them). Every client sees the roster, so this isn't synced.
local function CheckJoined()
    local g = ns.GuildName() and ns.Guild()
    if not g or not ns.RosterReady() then
        return
    end
    local changed = false
    for _, list in ipairs({ g.items, g.mine }) do
        for _, it in pairs(list) do
            if not it.joinedAt and it.target and ns.IsGuildMember(it.target) then
                it.joinedAt = time()
                changed = true
            end
        end
    end
    if changed then
        Refresh()
    end
end
ns.On("IS_ROSTER", CheckJoined)

-------------------------------------------------------------------------------
-- Receiving
-------------------------------------------------------------------------------

local Whisper = {}

-- member -> inviter: a suggestion. The sender is who the game says sent it.
function Whisper.SG(from, payload)
    if not IMayInvite() then
        return
    end
    local f = Split(payload, "^")
    local id, target, at, reason = f[1], ns.FullName(f[2]), tonumber(f[3]), ns.Clean(f[4], ns.MAX_REASON)
    if not ValidId(id) or not target then
        return
    end
    local g = ns.Guild()
    if not g then
        return
    end
    if not g.items[id] then
        local now = time()
        local it = { id = id, rev = 1, target = target, reason = reason, by = from,
            at = (at and at <= now and at > now - 365 * 86400) and at or now, status = "new",
            level = ns.ValidLevel(f[5]), class = ns.ValidClass(f[6]) }
        g.items[id] = it
        NoteNew(it)
        PushItem(it, from)
        Refresh()
    end
    Queue(from, "OK", id, "OK" .. id)
    TellSuggester(g.items[id])
end

-- inviter -> member: your suggestion arrived.
function Whisper.OK(from, payload)
    local g = ns.Guild()
    local m = g and g.mine[payload]
    if m and ns.CanInvite(from) and not m.delivered then
        m.delivered = true
        Refresh()
    end
end

-- inviter -> member: what became of your suggestion.
function Whisper.ST(from, payload)
    local id, status = payload:match("^(%x+)%^(%a+)$")
    local g = ns.Guild()
    local m = g and id and g.mine[id]
    if not m or not ns.CanInvite(from) or (status ~= "invited" and status ~= "declined") then
        return
    end
    m.delivered = true
    if m.status ~= status then
        m.status = status
        ns.Print("your suggestion " .. ns.Show(m.target) .. ": "
            .. (status == "invited" and "invited to the guild." or "not invited."))
        Refresh()
    end
end

-- inviter <-> inviter: what each of us has, to fill the gaps.
function Whisper.DL(from, payload)
    local g = ns.Guild()
    if not g or not IMayInvite() or not ns.CanInvite(from) then
        return
    end
    local want, theirs = {}, {}
    for pair in payload:gmatch("[^,]+") do
        local id, rev = pair:match("^(%x+):(%d+)$")
        rev = tonumber(rev)
        if id and ValidId(id) and rev then
            theirs[id] = rev
            local it = g.items[id]
            if not it or rev > (it.rev or 1) then
                want[#want + 1] = id
            end
        end
    end
    if #want > 0 then
        Queue(from, "DQ", table.concat(want, ","), "DQ")
    end
    -- What they lack or have older: send it right away.
    for id, it in pairs(g.items) do
        if not theirs[id] or theirs[id] < (it.rev or 1) then
            Queue(from, "DI", ItemPayload(it), "DI" .. id)
        end
    end
end

function Whisper.DQ(from, payload)
    local g = ns.Guild()
    if not g or not IMayInvite() or not ns.CanInvite(from) then
        return
    end
    for id in payload:gmatch("[^,]+") do
        local it = ValidId(id) and g.items[id]
        if it then
            Queue(from, "DI", ItemPayload(it), "DI" .. id)
        end
    end
end

function Whisper.DI(from, payload)
    local g = ns.Guild()
    if not g or not IMayInvite() or not ns.CanInvite(from) then
        return
    end
    local f = Split(payload, "^")
    local id, rev, target, by = f[1], tonumber(f[2]), ns.FullName(f[3]), ns.Member(f[4]) or ns.FullName(f[4])
    local status = f[6]
    if not ValidId(id) or not rev or not target or not by or not STATUSES[status] then
        return
    end
    local old = g.items[id]
    if old and (old.rev or 1) >= rev then
        return
    end
    local it = {
        id = id, rev = rev, target = target, by = by, at = tonumber(f[5]) or time(), status = status,
        decidedBy = (f[7] ~= "" and (ns.Member(f[7]) or ns.FullName(f[7]))) or nil,
        decidedAt = tonumber(f[8]) ~= 0 and tonumber(f[8]) or nil,
        reason = ns.Clean(f[9], ns.MAX_REASON),
        removedBy = ((f[10] or "") ~= "" and (ns.Member(f[10]) or ns.FullName(f[10]))) or nil,
        removedAt = (tonumber(f[11]) or 0) ~= 0 and tonumber(f[11]) or nil,
        told = old and old.told or nil,
        level = ns.ValidLevel(f[12]) or (old and old.level) or nil,
        class = ns.ValidClass(f[13]) or (old and old.class) or nil,
    }
    g.items[id] = it
    if not old and status == "new" then
        NoteNew(it)
    end
    -- One of your own suggestions, decided by another inviter.
    if ns.IsMe(it.by) and g.mine[id] and status ~= "removed" then
        g.mine[id].status = status
        g.mine[id].delivered = true
    end
    -- Decided by another inviter: tell the suggester too, in case they can't
    -- check that inviter's rank (then they only trust a message from us).
    if not old or old.status ~= status then
        TellSuggester(it)
    end
    Refresh()
end

local function Handle(from, msg, guild)
    local kind, payload = msg:match("^(%u%u)%^(.*)$")
    if not kind then
        return
    end
    if guild then
        if kind ~= "HI" then
            return
        end
        local f = Split(payload, "^")
        if (tonumber(f[1]) or 0) < 1 then
            return
        end
        -- The name in the hello must belong to the sender.
        local claimed = ns.Member(f[3])
        if not claimed or claimed ~= from or ns.IsMe(claimed) then
            return
        end
        local was = heard[claimed]
        heard[claimed] = { canInvite = f[4] == "1" }
        if f[2] ~= "1" then
            Hello(true)
        end
        local g = ns.Guild()
        if g and f[4] == "1" and ns.CanInvite(claimed) then
            FlushOutbox(claimed)
            if IMayInvite() then
                local list = {}
                for id, it in pairs(g.items) do
                    list[#list + 1] = id .. ":" .. (it.rev or 1)
                end
                Queue(claimed, "DL", table.concat(list, ","), "DL")
            end
        end
        -- They logged in: tell them about their suggestions decided meanwhile.
        if g and IMayInvite() then
            for _, it in pairs(g.items) do
                if it.by == claimed and not it.told then
                    TellSuggester(it)
                end
            end
        end
        if not was then
            Refresh()
        end
        return
    end
    if Whisper[kind] then
        -- An inviter syncing with us is online with the addon, even if we
        -- missed their hello.
        if (kind == "DL" or kind == "DQ" or kind == "DI") and not heard[from] and ns.CanInvite(from) then
            heard[from] = { canInvite = true }
        end
        Whisper[kind](from, payload)
    end
end

local buffers = {}
local MAX_PARTS = 60

local function Receive(label, text, from, guild)
    local mark = text:sub(1, 1)
    if mark == "S" then
        Handle(from, text:sub(2), guild)
    elseif mark == "C" then
        local id, i, n, part = text:match("^C(%d+):(%d+):(%d+):(.*)$")
        i, n = tonumber(i), tonumber(n)
        if not id or not i or not n or n < 1 or n > MAX_PARTS or i < 1 or i > n then
            return
        end
        local key = label .. "#" .. id
        local b = buffers[key]
        if b and (b.n ~= n or b.parts[i]) then
            b = nil
        end
        if not b then
            b = { n = n, parts = {}, got = 0, t = GetTime() }
            buffers[key] = b
        end
        b.parts[i] = part
        b.got = b.got + 1
        if b.got == b.n then
            buffers[key] = nil
            Handle(from, table.concat(b.parts), guild)
        end
    end
    for key, b in pairs(buffers) do
        if GetTime() - b.t > 120 then
            buffers[key] = nil
        end
    end
end

ns.On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
    if prefix ~= PREFIX or ns.IsSecret(text) or ns.IsSecret(sender) then
        return
    end
    if type(text) ~= "string" or type(sender) ~= "string" then
        return
    end
    -- Only guild members count, for everything.
    local from = ns.Member(sender)
    if not from or ns.IsMe(from) then
        return
    end
    if channel == "GUILD" then
        Receive("G:" .. from, text, from, true)
    elseif channel == "WHISPER" or channel == nil then
        Receive(from, text, from, false)
    end
end)

-------------------------------------------------------------------------------
-- Whispering someone who just logged off makes the game print "No player
-- named X is currently playing". Hide that line for our own hidden whispers.
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Is a suggested player online? A hidden addon whisper to them: when they're
-- offline the game answers "No player named X is currently playing" (caught
-- and hidden below); no answer means they're online. At most once a minute
-- per name.
-------------------------------------------------------------------------------

local onlineState = {} -- [name] = { state = "online" | "offline", at = GetTime() }
local pinged = {}      -- [name] = GetTime() of the last check (queued)
local pingSent = {}    -- [name] = GetTime() the last ping actually went out
local manualWhisper = {} -- [first name, lower case] = GetTime() the player whispered someone

function ns.CheckOnline(name)
    if not name or (pinged[name] and GetTime() - pinged[name] < 60) then
        return
    end
    pinged[name] = GetTime()
    Queue(name, "PI", "", "PI" .. name, {
        sent = function(sentAt)
            pingSent[name] = sentAt
            C_Timer.After(6, ns.Safe(function()
                local s = onlineState[name]
                if not (s and s.state == "offline" and s.at >= sentAt) then
                    onlineState[name] = { state = "online", at = GetTime() }
                    Refresh()
                end
            end, "online check"))
        end,
        failed = function()
            onlineState[name] = nil -- the game refused the check: unknown
            Refresh()
        end,
    })
end

-- "online", "offline" or nil (not checked yet).
function ns.OnlineState(name)
    local s = name and onlineState[name]
    return s and s.state or nil
end

-- The recent hidden-whisper target a "No player named X" line is about:
-- the same full name, or the only recent target with that first name.
local function NotFoundTarget(msg)
    if type(msg) ~= "string" or ns.IsSecret(msg) or not ERR_CHAT_PLAYER_NOT_FOUND_S then
        return nil
    end
    local now = GetTime()
    local byFirst, count = nil, 0
    for target, t in pairs(recentWhisper) do
        if now - t < 10 then
            if msg == ERR_CHAT_PLAYER_NOT_FOUND_S:format(target) then
                return target
            end
            local first = target:match("^[^%s%-]+")
            if msg == ERR_CHAT_PLAYER_NOT_FOUND_S:format(first) then
                byFirst, count = target, count + 1
            end
        else
            recentWhisper[target] = nil
        end
    end
    return count == 1 and byFirst or nil
end

ns.On("CHAT_MSG_SYSTEM", function(msg)
    local target = NotFoundTarget(msg)
    if not target then
        return
    end
    if pingSent[target] and GetTime() - pingSent[target] < 10 then
        onlineState[target] = { state = "offline", at = GetTime() }
        Refresh()
    end
    heard[target] = nil
    ForgetQueued(target)
end)

local function SystemFilter(_, _, msg)
    local target = NotFoundTarget(msg)
    if not target then
        return false
    end
    local mine = manualWhisper[ns.FirstName(target)]
    if mine and GetTime() - mine < 10 then
        return false -- the player whispered them too: let them see it
    end
    return true
end

-- Whispers the player sends themselves (so their "No player named" line stays).
local function NoteManualWhisper(_, chatType, _, target)
    if chatType == "WHISPER" and type(target) == "string" and not ns.IsSecret(target) then
        manualWhisper[ns.FirstName(target)] = GetTime()
    end
end
if hooksecurefunc then
    if C_ChatInfo and type(C_ChatInfo.SendChatMessage) == "function" then
        hooksecurefunc(C_ChatInfo, "SendChatMessage", NoteManualWhisper)
    end
    if type(SendChatMessage) == "function" and SendChatMessage ~= (C_ChatInfo and C_ChatInfo.SendChatMessage) then
        hooksecurefunc("SendChatMessage", NoteManualWhisper)
    end
end

local AddFilter = ChatFrame_AddMessageEventFilter or (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)
if AddFilter then
    AddFilter("CHAT_MSG_SYSTEM", SystemFilter)
end

-------------------------------------------------------------------------------
-- Start-up
-------------------------------------------------------------------------------

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
end

local rosterSeen = false

ns.On("IS_READY", function()
    C_Timer.After(5, ns.Safe(function()
        ready = true
        if ns.RosterReady() then
            rosterSeen = true
            Hello(false)
        end
    end, "start"))
end)

-- The hello needs the roster (to check names), so wait for it once.
ns.On("IS_ROSTER", function()
    if ready and not rosterSeen then
        rosterSeen = true
        Hello(false)
    end
    Refresh()
end)

ns.On("PLAYER_GUILD_UPDATE", function()
    if ready then
        rosterSeen = false
        heard = {}
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            pcall(C_GuildInfo.GuildRoster)
        end
    end
end)
