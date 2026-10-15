--!strict
-- The window half: the profile switcher, a palette command per profile, the
-- link-routing picker, cookie import, and link routing.

local profiles = require("./profiles")

-- Read once when the window starts, for the per-profile commands and for how
-- commands name the browsers: someone whose profiles all live in Chrome sees
-- "Chrome: Open profile…", never a word about other browsers.
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

-- Opens `p`, reporting failures through toasts.
local function launch(cx: WindowCx, p: profiles.Profile)
	local what = p.browser.name .. " did not open " .. p.name
	local spawn_error = profiles.launch(p, nil, function(r: ProcessResult, cb_cx: WindowCx?)
		if r.status ~= 0 and cb_cx then
			cb_cx:toast("error", what, "open exited with status " .. r.status)
		end
	end)
	if spawn_error then
		cx:toast("error", what, spawn_error)
	end
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
-- dismissed picker does nothing.
local function pick_profile(
	cx: WindowCx,
	list: { profiles.Profile },
	placeholder: string,
	chosen: (WindowCx, profiles.Profile) -> ()
)
	cx:pick({ items = profile_items(list, nil), placeholder = placeholder, icon = "compass" })
		:next(function(item: PickItem?, _e: string?, pick_cx: WindowCx?)
			local p = if item ~= nil then profiles.find(list, item.id) else nil
			if p ~= nil then
				chosen(pick_cx or cx, p)
			end
		end)
end

-- Sets `cookies` one at a time through browser block `block`'s cookie store,
-- then calls `finish(imported, rejected, cx)`. One at a time keeps the window
-- from being flooded with thousands of pending native calls.
local function set_cookies(cx: WindowCx, block: number, cookies: { any }, finish: (number, number, WindowCx) -> ())
	local imported, rejected = 0, 0
	local function step(i: number, step_cx: WindowCx)
		local cookie = cookies[i]
		if cookie == nil then
			finish(imported, rejected, step_cx)
			return
		end
		step_cx.browser:call({ op = "setCookie", block = block, cookie = cookie }):next(function(res, e, next_cx)
			if res ~= nil and res.ok ~= nil and e == nil then
				imported += 1
			else
				rejected += 1
			end
			step(i + 1, next_cx or step_cx)
		end)
	end
	step(1, cx)
end

-- Copies the cookies of the site `target` (a Tern browser block) shows from
-- profile `p` into Tern's browser, then reloads that block signed in.
-- Cookie values never reach a toast or the log.
local function import_cookies(cx: WindowCx, p: profiles.Profile, target: any, url: string, host: string)
	local who = p.browser.name .. " " .. p.name
	cx:toast("info", "Reading " .. who .. " cookies for " .. host, "macOS may ask to allow the " .. p.browser.keychain .. " Keychain item")
	local spawn_error = profiles.export_cookies(p, host, function(cookies, err, cb_cx)
		if cb_cx == nil then
			return
		end
		if cookies == nil then
			cb_cx:toast("error", "Could not read " .. who .. " cookies", err)
			return
		end
		if #cookies == 0 then
			cb_cx:toast("info", who .. " has no cookies for " .. host)
			return
		end
		set_cookies(cb_cx, target.block, cookies, function(imported, rejected, done_cx)
			if imported == 0 then
				done_cx:toast("error", "Tern's browser took none of the " .. #cookies .. " cookies")
				return
			end
			local sub = if rejected > 0 then rejected .. " were rejected" else nil
			done_cx:toast("success", "Imported " .. imported .. " cookies for " .. host, sub)
			done_cx.browser:call({ op = "goto", block = target.block, url = url })
		end)
	end)
	if spawn_error then
		cx:toast("error", "Could not read " .. who .. " cookies", spawn_error)
	end
end

tern.command({
	id = "switch",
	title = PREFIX .. ": Open profile…",
	icon = "compass",
	group = GROUP,
	run = function(cx: WindowCx)
		-- Read each time: profiles made since the window started show up.
		local list = load_or_explain(cx)
		if list ~= nil then
			pick_profile(cx, list, "Open a " .. noun(list), launch)
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
			{ label = "Tern", detail = "links open in Tern (default)", current = current == nil },
		}
		table.move(profile_items(list, current), 1, #list, 2, items)
		cx:pick({ items = items, placeholder = "Open plain link clicks in", icon = "share" })
			:next(function(item: PickItem?, _e: string?, pick_cx: WindowCx?)
				if item == nil then
					return
				end
				local wcx = pick_cx or cx
				local p = profiles.find(list, item.id)
				if p ~= nil then
					profiles.set_link_id(p.id)
					wcx:toast(
						"success",
						"Links open in " .. p.browser.name .. ": " .. p.name,
						"Click a link with ⌘, ⌥, ⇧ or ⌃ to open it in Tern"
					)
				else
					profiles.set_link_id(nil)
					wcx:toast("info", "Links open in Tern again")
				end
			end)
	end,
})

tern.command({
	id = "import",
	title = PREFIX .. ": Sign this Tern page in with a profile…",
	icon = "download",
	group = GROUP,
	run = function(cx: WindowCx)
		-- The import is for the site the focused Tern browser block shows;
		-- find that block before asking for a profile.
		local focused = cx.session:focused()
		cx.browser:call({ op = "blocks" }):next(function(res, e, blocks_cx)
			local wcx = blocks_cx or cx
			local blocks = if res ~= nil and res.ok ~= nil and e == nil then (res.ok :: any).blocks else nil
			local target: any = nil
			if type(blocks) == "table" then
				for _, b in blocks :: any do
					if b.block == focused then
						target = b
					end
				end
			end
			if target == nil then
				wcx:toast("error", "Focus a Tern browser block first", "The import is for the site that block shows")
				return
			end
			local url: string = target.url
			local host = if type(url) == "string" then string.match(url, "^https?://([^/:?#]+)") else nil
			if host == nil then
				wcx:toast("error", "That page has no site to import cookies for", url)
				return
			end
			local list = load_or_explain(wcx)
			if list ~= nil then
				pick_profile(wcx, list, "Sign " .. host .. " in with a " .. noun(list), function(pick_cx, p)
					import_cookies(pick_cx, p, target, url, host)
				end)
			end
		end)
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
			launch(cx, p)
		end,
	})
end

-- With a routing profile chosen, plain http(s) link clicks open in it.
-- Any modifier held (⌘, ⌥, ⇧, ⌃ — the "open differently" idioms) falls
-- through to Tern's own handling.
tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if link.mods.shift or link.mods.cmd or link.mods.alt or link.mods.ctrl then
		return nil
	end
	if string.match(link.url, "^https?://") == nil then
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
	local what = "Link did not open in " .. p.browser.name
	local spawn_error = profiles.launch(p, link.url, function(r: ProcessResult, cb_cx: WindowCx?)
		if r.status ~= 0 and cb_cx then
			cb_cx:toast("error", what, "open exited with status " .. r.status)
		end
	end)
	if spawn_error then
		cx:toast("error", what, spawn_error)
		return nil -- let Tern handle the link after all
	end
	return { handled = true }
end)
