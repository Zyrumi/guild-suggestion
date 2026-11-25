-- Invite Suggestions: core
-- Saved data, names, the guild roster, who may invite, events, slash command.
--
-- Files:
--   Core.lua  this file
--   Comm.lua  hidden addon messages between guild members
--   UI.lua    the window, minimap button and right-click menu entry

local ADDON_NAME, ns = ...

ns.PROTOCOL = 1
ns.MAX_REASON = 200

local DEFAULTS = {
    guilds = {},  -- [guild name] = { items = {}, mine = {} }, see ns.Guild
    minimap = { angle = 200, hide = false },
    window = {},  -- where the window was left
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

function ns.Print(msg)
    print("|cffffd100Invite Suggestions:|r " .. msg)
end

-- Midnight-era clients can hand addons "secret" values; treat as unknown.
function ns.IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

-- WoW Forever has no realms: every character has a first name and a
-- surname ("Tom Stonebrook"), and that pair is unique. The game shows this
-- by giving the surname as UnitName's second value. Set at login.
ns.forever = false

local function Capitalize(n)
    if n:byte(1) and n:byte(1) < 128 then
        n = n:sub(1, 1):upper() .. n:sub(2):lower()
    end
    return n
end

local function MyRealm()
    local r = GetNormalizedRealmName and GetNormalizedRealmName()
    if r and r ~= "" then
        return r
    end
    return ((GetRealmName and GetRealmName()) or ""):gsub("[%s%-]", "")
end

-- Forever: "tom stonebrook" or "Tom-Stonebrook" -> "Tom Stonebrook".
--   A first name alone gives nil (see ns.Member for guild members).
-- Other clients: "tom" -> "Tom-MyRealm".
function ns.FullName(name)
    if type(name) ~= "string" or ns.IsSecret(name) then
        return nil
    end
    if name:find("[|%^,;:#=/~%d%c]") or #name > 60 then
        return nil
    end
    if ns.forever then
        local first, surname = strtrim(name):match("^([^%s%-]+)[%s%-]+([^%s%-]+)$")
        if not first then
            return nil
        end
        return Capitalize(first) .. " " .. Capitalize(surname)
    end
    name = name:gsub("%s+", "")
    if name == "" then
        return nil
    end
    local n, r = name:match("^([^%-]+)%-(.+)$")
    if not n then
        n, r = name, MyRealm()
    end
    return Capitalize(n) .. "-" .. r
end

function ns.FirstName(name)
    return type(name) == "string" and (name:match("^[^%s%-]+") or ""):lower() or ""
end

-- Name to show. Forever keeps the full name (two people can share a first name).
function ns.Show(full)
    if not full then
        return "?"
    end
    if ns.forever then
        return full
    end
    local n, r = full:match("^([^%-]+)%-(.+)$")
    if n and r == MyRealm() then
        return n
    end
    return full
end

-- Text someone typed, made safe to send: one line, none of our separators.
function ns.Clean(text, max)
    text = tostring(text or ""):gsub("[\r\n\t]+", " "):gsub("[%^|~]", ""):gsub("%s+", " ")
    text = strtrim(text)
    if max and #text > max then
        text = text:sub(1, max)
        -- Don't leave half a letter (UTF-8) at the end.
        while #text > 0 and text:byte(#text) >= 128 and text:byte(#text) < 192 do
            text = text:sub(1, -2)
        end
        if #text > 0 and text:byte(#text) >= 192 then
            text = text:sub(1, -2)
        end
    end
    return text
end

function ns.Ago(t)
    if not t then
        return ""
    end
    local s = time() - t
    if s < 120 then
        return "just now"
    elseif s < 3600 then
        return math.floor(s / 60) .. " min ago"
    elseif s < 86400 then
        return math.floor(s / 3600) .. " h ago"
    end
    local d = math.floor(s / 86400)
    return d == 1 and "1 day ago" or (d .. " days ago")
end

function ns.NewId()
    return string.format("%x%04x", time(), math.random(0, 65535))
end

local function MergeDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then
                dst[k] = {}
            end
            MergeDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

-------------------------------------------------------------------------------
-- Events: other files register with ns.On("EVENT", function(...) end)
-------------------------------------------------------------------------------

local handlers = {}
local eventFrame = CreateFrame("Frame")

function ns.On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        if not event:find("^IS_") then
            pcall(eventFrame.RegisterEvent, eventFrame, event)
        end
    end
    table.insert(handlers[event], fn)
end

function ns.Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then
            ns.Print("error in " .. event .. ": " .. tostring(err))
        end
    end
end

function ns.Safe(fn, what)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            ns.Print("error in " .. (what or "timer") .. ": " .. tostring(err))
        end
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if not ns.me and event ~= "ADDON_LOADED" and event ~= "PLAYER_LOGIN" then
        return
    end
    ns.Fire(event, ...)
end)

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
handlers.ADDON_LOADED = { function(name)
    if name ~= ADDON_NAME then
        return
    end
    InviteSuggestionsDB = MergeDefaults(DEFAULTS, InviteSuggestionsDB or {})
    ns.db = InviteSuggestionsDB
end }
handlers.PLAYER_LOGIN = { function()
    local first, second = UnitName("player")
    ns.forever = type(second) == "string" and not ns.IsSecret(second) and second ~= ""
    ns.me = ns.FullName(ns.forever and (tostring(first) .. " " .. tostring(second)) or first)
    if not ns.me then
        ns.Print("could not read your character name, so the addon is off for now. Try /reload.")
        return
    end
    ns.Fire("IS_READY")
end }

-------------------------------------------------------------------------------
-- The guild: its saved suggestions, its roster and who may invite
-------------------------------------------------------------------------------

function ns.GuildName()
    if not IsInGuild or not IsInGuild() then
        return nil
    end
    local name = GetGuildInfo and GetGuildInfo("player")
    if type(name) ~= "string" or ns.IsSecret(name) or name == "" then
        return nil
    end
    return name
end

-- items: suggestions you can decide on (only kept if you may invite)
--   [id] = { id, target, reason, by, at, status, decidedBy, decidedAt, rev }
--   status: "new", "invited", "declined" or "removed"
-- mine: suggestions made by your characters
--   [id] = { id, target, reason, by, at, delivered, status }
function ns.Guild()
    local name = ns.GuildName()
    if not name then
        return nil
    end
    local g = ns.db.guilds[name]
    if type(g) ~= "table" then
        g = {}
        ns.db.guilds[name] = g
    end
    g.items = type(g.items) == "table" and g.items or {}
    g.mine = type(g.mine) == "table" and g.mine or {}
    return g
end

-- Roster, rebuilt whenever the game sends it.
local roster = { full = {}, first = {}, count = 0 }

local function ReadRoster()
    if not GetNumGuildMembers or not GetGuildRosterInfo then
        return
    end
    local n = GetNumGuildMembers() or 0
    if n == 0 then
        return
    end
    local full, first = {}, {}
    for i = 1, n do
        local ok, raw, _, rankIndex, _, _, _, _, _, online = pcall(GetGuildRosterInfo, i)
        if ok and type(raw) == "string" and not ns.IsSecret(raw) then
            local name = ns.FullName(raw)
            if not name and ns.forever then
                -- Only a first name: keep it, matched by first name below.
                name = Capitalize(strtrim(raw))
            end
            if name then
                local rank = (not ns.IsSecret(rankIndex)) and tonumber(rankIndex) or nil
                full[name] = { rank = rank, online = (not ns.IsSecret(online)) and online and true or false }
                local f = ns.FirstName(name)
                if first[f] == nil then
                    first[f] = name
                else
                    first[f] = false -- two members share this first name
                end
            end
        end
    end
    roster = { full = full, first = first, count = n }
end

-- A guild member's full name (as the roster has it) from whatever the game
-- gave us: "First Surname", "First-Surname" or a first name alone.
function ns.Member(raw)
    if type(raw) ~= "string" or ns.IsSecret(raw) then
        return nil
    end
    local name = ns.FullName(raw)
    if name and roster.full[name] then
        return name
    end
    local only = roster.first[ns.FirstName(raw)]
    if only then
        if not name then
            return only -- a first name alone, and only one member has it
        end
        if ns.FullName(only) == nil then
            return only -- the roster itself only gives first names
        end
    end
    return nil
end

-- Whether a name (as the roster or a message gave it) is you.
function ns.IsMe(name)
    return name ~= nil and (name == ns.me or ns.Member(ns.me) == name)
end

function ns.IsOnline(name)
    local m = name and roster.full[name]
    return m and m.online or false
end

function ns.RosterReady()
    return roster.count > 0
end

-- Whether this guild member may invite. You: the game says. Others: their
-- rank. The guild master always may; other ranks only if the rank's
-- "Invite member" permission is on and the game lets us read it. When it
-- can't be read, the answer is no, so a reason is never sent to someone
-- who may not see it.
function ns.CanInvite(name)
    if not name then
        return false
    end
    if ns.IsMe(name) then
        return CanGuildInvite and CanGuildInvite() and true or false
    end
    local m = roster.full[name]
    if not m or not m.rank then
        return false
    end
    if m.rank == 0 then
        return true
    end
    if C_GuildInfo and C_GuildInfo.GuildControlGetRankFlags then
        local ok, flags = pcall(C_GuildInfo.GuildControlGetRankFlags, m.rank + 1)
        if ok and type(flags) == "table" and flags[5] == true then
            return true
        end
    end
    return false
end

ns.On("GUILD_ROSTER_UPDATE", function()
    ReadRoster()
    ns.Fire("IS_ROSTER")
end)

-- Old decided and removed suggestions are dropped after a while.
local KEEP_DECIDED = 60 * 86400
local KEEP_REMOVED = 30 * 86400

local function Purge()
    local now = time()
    for _, g in pairs(ns.db.guilds) do
        if type(g) == "table" then
            for id, it in pairs(g.items or {}) do
                local t = it.decidedAt or it.at or 0
                if (it.status == "removed" and now - t > KEEP_REMOVED)
                    or ((it.status == "invited" or it.status == "declined") and now - t > KEEP_DECIDED) then
                    g.items[id] = nil
                end
            end
        end
    end
end

ns.On("IS_READY", function()
    Purge()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        pcall(C_GuildInfo.GuildRoster)
    end
end)

-------------------------------------------------------------------------------
-- Slash command
-------------------------------------------------------------------------------

SLASH_INVITESUGGESTIONS1 = "/suggest"
SLASH_INVITESUGGESTIONS2 = "/invitesuggestions"
SlashCmdList.INVITESUGGESTIONS = function(input)
    local text = strtrim(input or "")
    if text:lower() == "help" then
        ns.Print("/suggest opens the window. /suggest First Surname fills in a name.")
    elseif text ~= "" then
        ns.OpenSuggest(text)
    else
        ns.ToggleWindow()
    end
end
