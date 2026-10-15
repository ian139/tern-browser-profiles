--!strict
-- The window half: palette commands that open Brave in one profile, the
-- "links open in" switch, the block opener, and link routing.

local profiles = require("./profiles")

local KIND = "brave-profiles.profiles"

-- Command ids are letters, digits, `_` and `-`, unique per command:
-- distinct profile directories can slugify alike ("Profile 1" and
-- "Profile-1"), so collisions get a numeric suffix.
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

local function slug(dir: string): string
	local out = string.lower(string.gsub(dir, "[^%w]+", "-"))
	out = string.gsub(out, "^-+", "")
	if out == "" or string.match(out, "^[0-9]") ~= nil then
		out = "p" .. out
	end
	return out
end

local function account_suffix(p: profiles.Profile): string
	return if p.account ~= "" then " · " .. p.account else ""
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

-- Copies the cookies of the focused Tern browser block's site from profile
-- `p` into Tern's browser, then reloads that block signed in. Explicit and
-- per site: a browser block you did not ask for stays signed out.
local function import_cookies(cx: WindowCx, p: profiles.Profile)
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
		local host = string.match(url, "^https?://([^/:?#]+)")
		if host == nil then
			wcx:toast("error", "That page has no site to import cookies for", url)
			return
		end
		wcx:toast("info", "Reading " .. p.name .. " cookies for " .. host, "macOS may ask to allow the Brave Safe Storage Keychain item")
		local spawn_error = profiles.export_cookies(p.dir, host, function(cookies, err, cb_cx)
			if cb_cx == nil then
				return
			end
			if cookies == nil then
				cb_cx:toast("error", "Could not read " .. p.name .. " cookies", err)
				return
			end
			if #cookies == 0 then
				cb_cx:toast("info", p.name .. " has no cookies for " .. host)
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
			wcx:toast("error", "Could not read " .. p.name .. " cookies", spawn_error)
		end
	end)
end

-- Opens the profiles block beside the focused pane, or focuses the one
-- already open in this window.
local function open_block(cx: WindowCx)
	for _, pane in cx.session:panes() do
		if pane.block == KIND then
			cx.layout:focus(pane.pane)
			return
		end
	end
	if cx:new_block(KIND, nil, "beside") == nil then
		cx:toast("error", "Brave Profiles is not loaded on this host", "Install the plugin where your panes run.")
	end
end

tern.command({
	id = "profiles",
	title = "Open Brave profiles",
	icon = "compass",
	group = "Brave",
	run = open_block,
})

tern.bind("alt+shift+b", "plugin.brave-profiles.profiles")

-- One "Open in <profile>" and one "Links: <profile>" command per profile,
-- registered when the window starts. The list is read once per window
-- start; after making a new Brave profile, reload plugins (or open a new
-- window) to get its commands.
local list, err = profiles.load()
if err ~= nil then
	tern.log.warn("brave-profiles", err)
else
	for _, p in list do
		local dir = p.dir
		tern.command({
			id = unique_id("open-" .. slug(dir)),
			title = "Brave: Open " .. p.name .. account_suffix(p),
			icon = "compass",
			group = "Brave",
			run = function(cx: WindowCx)
				local spawn_error = profiles.launch(dir, nil, function(r: ProcessResult, cb_cx: WindowCx?)
					if r.status ~= 0 and cb_cx then
						cb_cx:toast("error", "Brave did not open " .. p.name, "open exited with status " .. r.status)
					end
				end)
				if spawn_error then
					cx:toast("error", "Brave did not open " .. p.name, spawn_error)
				end
			end,
		})
		tern.command({
			id = unique_id("link-" .. slug(dir)),
			title = "Brave: Links open in " .. p.name .. account_suffix(p),
			icon = "share",
			group = "Brave",
			available = function(_cx: WindowCx)
				return profiles.link_dir() ~= dir
			end,
			run = function(cx: WindowCx)
				profiles.set_link_dir(dir)
				cx:toast("success", "Links open in " .. p.name, "Click a link with ⌘, ⌥, ⇧ or ⌃ to open it in Tern")
			end,
		})
		tern.command({
			id = unique_id("import-" .. slug(dir)),
			title = "Brave: Sign this Tern page in with " .. p.name .. account_suffix(p) .. " cookies",
			icon = "download",
			group = "Brave",
			run = function(cx: WindowCx)
				import_cookies(cx, p)
			end,
		})
	end
end

tern.command({
	id = "link-off",
	title = "Brave: Links open in Tern",
	icon = "share",
	group = "Brave",
	available = function(_cx: WindowCx)
		return profiles.link_dir() ~= nil
	end,
	run = function(cx: WindowCx)
		profiles.set_link_dir(nil)
		cx:toast("info", "Links open in Tern again")
	end,
})

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
	local dir = profiles.link_dir()
	if dir == nil then
		return nil
	end
	-- A routing choice whose profile directory no longer exists is stale;
	-- drop it and let this click open the ordinary way.
	local base = profiles.base_dir()
	if base == nil or not profiles.valid_dir(dir) or not tern.fs.exists(base .. "/" .. dir) then
		profiles.set_link_dir(nil)
		return nil
	end
	local spawn_error = profiles.launch(dir, link.url, function(r: ProcessResult, cb_cx: WindowCx?)
		if r.status ~= 0 and cb_cx then
			cb_cx:toast("error", "Link did not open in Brave", "open exited with status " .. r.status)
		end
	end)
	if spawn_error then
		cx:toast("error", "Link did not open in Brave", spawn_error)
		return nil -- let Tern handle the link after all
	end
	return { handled = true }
end)
