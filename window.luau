--!strict
-- The window half: the profile switcher, a palette command per profile, the
-- link-routing picker, copying sign-ins again, and link routing. Every one
-- opens the profile in its own Tern browser (see browser.luau).

local profiles = require("./profiles")
local browser = require("./browser")

-- Read once when the window starts, for the per-profile commands and for how
-- commands name the browsers: someone whose profiles all live in Chrome sees
-- "Chrome: Open profile in Tern…", never a word about other browsers.
local startup, startup_err = profiles.load()
if startup_err ~= nil then
	tern.log.warn("brave-profiles", startup_err)
end
local SOLE = profiles.sole_browser(startup)
local PREFIX = SOLE or "Browser"
local GROUP = SOLE or "Browser Profiles"

-- Command ids are letters, digits, `_` and `-`, unique per command:
-- distinct profile ids can slugify alike ("Profile 1" and "Profile-1"), so
-- collisions get a numeric suffix.
local used_ids: { [string]: boolean } = {}

local function unique_id(prefix: string): string
	local id = prefix
	local n = 2
	while used_ids[id] do
		id = prefix .. "-" .. n
		n += 1
	end
	used_ids[id] = true
	return id
end

local function slug(text: string): string
	local out = string.lower((string.gsub(text, "[^%w]+", "-")))
	out = (string.gsub(out, "^-+", ""))
	if out == "" or string.match(out, "^[0-9]") ~= nil then
		out = "p" .. out
	end
	return out
end

local function account_suffix(p: profiles.Profile): string
	return if p.account ~= "" then " · " .. p.account else ""
end

-- The profiles, read now, or nil after telling the user why there are none.
local function load_or_explain(cx: WindowCx): { profiles.Profile }?
	local list, err = profiles.load()
	if #list > 0 then
		return list
	end
	cx:toast(if err == "HOME is not set" then "error" else "info", "No browser profiles", err)
	return nil
end

-- "Chrome profile" when every profile of `list` is Chrome's, else
-- "browser profile".
local function noun(list: { profiles.Profile }): string
	return (profiles.sole_browser(list) or "browser") .. " profile"
end

-- Picker rows for `list`: one per profile, showing its signed-in account.
-- Rows are grouped by browser only when there is more than one (the list is
-- already in browser order, so groups are contiguous).
local function profile_items(list: { profiles.Profile }, current: string?): { PickItem }
	local grouped = profiles.sole_browser(list) == nil
	local items: { PickItem } = {}
	for _, p in list do
		table.insert(items, {
			label = p.name,
			detail = if p.account ~= "" then p.account else nil,
			group = if grouped then p.browser.name else nil,
			current = current ~= nil and p.id == current,
			id = p.id,
		})
	end
	return items
end

-- Asks for one of `list` and calls `chosen` with a fresh cx and it; a
-- dismissed picker (or a closed window) does nothing.
local function pick_profile(
	cx: WindowCx,
	list: { profiles.Profile },
	placeholder: string,
	chosen: (WindowCx, profiles.Profile) -> ()
)
	cx:pick({ items = profile_items(list, nil), placeholder = placeholder, icon = "compass" })
		:next(function(item: PickItem?, _e: string?, pick_cx: WindowCx?)
			local p = if item ~= nil then profiles.find(list, item.id) else nil
			if p ~= nil and pick_cx ~= nil then
				chosen(pick_cx, p)
			end
		end)
end

local function open_in_tern(cx: WindowCx, p: profiles.Profile)
	browser.open(cx, p, nil, false)
end

tern.command({
	id = "switch",
	title = PREFIX .. ": Open profile in Tern…",
	icon = "compass",
	group = GROUP,
	run = function(cx: WindowCx)
		-- Read each time: profiles made since the window started show up.
		local list = load_or_explain(cx)
		if list ~= nil then
			pick_profile(cx, list, "Open a " .. noun(list) .. " in Tern", open_in_tern)
		end
	end,
})

tern.bind("alt+shift+b", "plugin.brave-profiles.switch")

tern.command({
	id = "links",
	title = PREFIX .. ": Open Tern's links in a profile…",
	icon = "share",
	group = GROUP,
	run = function(cx: WindowCx)
		local current = profiles.link_id()
		local list = profiles.load()
		local items: { PickItem } = {
			{ label = "Tern", detail = "links open in Tern's default browser (default)", current = current == nil },
		}
		table.move(profile_items(list, current), 1, #list, 2, items)
		cx:pick({ items = items, placeholder = "Open plain link clicks in", icon = "share" })
			:next(function(item: PickItem?, _e: string?, pick_cx: WindowCx?)
				if item == nil or pick_cx == nil then
					return
				end
				local p = profiles.find(list, item.id)
				if p ~= nil then
					profiles.set_link_id(p.id)
					pick_cx:toast(
						"success",
						"Links open in Tern as " .. p.browser.name .. ": " .. p.name,
						"Click a link with ⌘, ⌥, ⇧ or ⌃ to open it in Tern's default browser"
					)
				else
					profiles.set_link_id(nil)
					pick_cx:toast("info", "Links open in Tern's default browser again")
				end
			end)
	end,
})

-- Copies a profile's sign-ins into its own Tern browser again (they are a
-- one-off copy, not kept in step), then shows it. Only that profile's store
-- changes; whatever browser is focused is left alone.
tern.command({
	id = "import",
	title = PREFIX .. ": Copy sign-ins again…",
	icon = "download",
	group = GROUP,
	run = function(cx: WindowCx)
		local list = load_or_explain(cx)
		if list ~= nil then
			pick_profile(cx, list, "Copy sign-ins again from a " .. noun(list) .. " into its Tern browser", function(pick_cx, p)
				browser.open(pick_cx, p, nil, true)
			end)
		end
	end,
})

-- One command per profile that opens it without a picker ("Chrome: Work").
-- A profile made after the window started is in the switcher at once; its
-- own command arrives with the next window (or plugin reload).
for _, p in startup do
	tern.command({
		id = unique_id("open-" .. slug(p.id)),
		title = p.browser.name .. ": " .. p.name .. account_suffix(p),
		icon = "compass",
		group = GROUP,
		run = function(cx: WindowCx)
			open_in_tern(cx, p)
		end,
	})
end

-- The profiles block's ⏎ (the host has no browser): only an open URI its own
-- pane requested opens anything (see profiles.take_open); every other one is
-- swallowed, never handed to the system. Several windows may see the same
-- request; the first takes it.
local function host_request(link: LinkRequest, cx: WindowCx)
	local id = profiles.take_open(link.pane, link.url)
	if id == nil then
		return
	end
	local p = profiles.find(profiles.load(), id) or profiles.resolve(id)
	if p == nil then
		cx:toast("error", "That browser profile is not on this Mac", "Open it from a Tern window on the Mac that has it")
		return
	end
	browser.open(cx, p, nil, false)
end

-- With a routing profile chosen, plain http(s) link clicks open in its Tern
-- browser. Any modifier held (⌘, ⌥, ⇧, ⌃ — the "open differently" idioms)
-- falls through to Tern's own handling, as do links inside a profile's own
-- browser, which stay there.
tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if profiles.is_open_uri(link.url) then
		host_request(link, cx)
		return { handled = true }
	end
	if link.mods.shift or link.mods.cmd or link.mods.alt or link.mods.ctrl then
		return nil
	end
	if string.match(link.url, "^https?://") == nil or browser.owns(link.pane) then
		return nil
	end
	local id = profiles.link_id()
	if id == nil then
		return nil
	end
	-- A routing choice whose browser or profile directory is gone is stale;
	-- drop it and let this click open the ordinary way.
	local p = profiles.resolve(id)
	if p == nil or not tern.fs.exists(p.browser.root .. "/" .. p.dir) then
		profiles.set_link_id(nil)
		return nil
	end
	browser.open(cx, p, link.url, false)
	return { handled = true }
end)
