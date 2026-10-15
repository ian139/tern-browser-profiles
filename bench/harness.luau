--!nocheck
-- Benchmark + behaviour harness for the brave-profiles Tern plugin.
--
--   lune run bench/harness.luau -- PLUGIN_DIR FIXTURE_ROOT
--
-- Loads the plugin's window and host halves into sandboxed VMs with a mocked
-- `tern` API backed by a fake macOS tree (bench/make_fixtures.py): system
-- apps under FIXTURE_ROOT/Applications (seen as /Applications), a real HOME
-- at FIXTURE_ROOT/home with Chromium-family browsers' "Local State" files and
-- cookie databases. The cookie exporter runs for real through
-- bench/py_shim.py with a fixture Keychain; every Keychain lookup it makes is
-- logged and checked. Any other process is an external launch and fails the
-- "never launches an external browser" check.
--
-- Tern's embedded browser is mocked as native cookie stores keyed by the
-- profile name `open` was given (nil = Tern's default store). Stores persist
-- for the whole scenario (across window reloads), like Tern's persistent
-- named profiles; blocks, docking, navigation and every native call are
-- recorded, and calls resolve asynchronously through `:next`. Checks judge
-- what the user ends up with: which store holds which cookies, which page a
-- live profile block shows and when, which Keychain item was read — not
-- which helper was called.
--
-- Contract (window half, action ids are `plugin.brave-profiles.<id>`):
--   switch   palette command: cx:pick over every profile of every installed
--            Chromium browser; the chosen one opens INSIDE Tern in its own
--            persistent store "brave-profiles:<browser key>/<dir>". The first
--            open copies every live cookie of that source profile (all sites)
--            into the store before showing https://www.google.com/; later
--            opens reuse the store without exporting again.
--   links    palette command: cx:pick of routing targets (profiles plus an
--            item whose text contains "Tern" that stops routing); plain
--            http(s) clicks then open inside Tern in that profile's store.
--   import   palette command: cx:pick of profiles; copies that profile's
--            sign-ins again into its own Tern store only.
--   a palette command per profile whose title names the profile and browser.
-- Host half: block `profiles` listing the same profiles; Enter/activate opens
-- the profile inside Tern through BlockCx:open, which reaches the window's
-- tern.route.link with LinkRequest.pane = the block's pane.
--
-- Prints `METRIC name=value` lines; score = 10 * spec_points - io_cost.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local luau = require("@lune/luau")

local PLUGIN = assert(process.args[1], "usage: harness.luau PLUGIN_DIR FIXTURE_ROOT")
local ROOT = assert(process.args[2], "usage: harness.luau PLUGIN_DIR FIXTURE_ROOT")
local VERBOSE = process.env.BP_VERBOSE == "1"
local SPEC = serde.decode("json", fs.readFile(PLUGIN .. "/bench/spec.json"))
local HOME = ROOT .. "/" .. SPEC.home
local SUPPORT = HOME .. "/Library/Application Support"
local PLUGIN_ID = "brave-profiles"
local BLOCK_KIND = PLUGIN_ID .. ".profiles"
local BLOCK_PANE = 900
local BROWSER_PANE = 7
local TERMINAL_PANE = 1
local FLOAT_PANE = 5
local STORE_PREFIX = "brave-profiles:"
local HOME_PAGE = "https://www.google.com/"
local KEYCHAIN = ROOT .. "/keychain.json"
local KEYCHAIN_DENIED = ROOT .. "/keychain-denied.json"
local SHIM_LOG = ROOT .. "/shim.log"
local NO_MODS = { cmd = false, alt = false, shift = false, ctrl = false }

-- The user refusing the Keychain prompt looks to the exporter like an
-- absent item: an empty fixture Keychain.
fs.writeFile(KEYCHAIN_DENIED, "{}")

local manifest = fs.readFile(PLUGIN .. "/plugin.toml")
local WINDOW_ENTRY = string.match(manifest, '\nwindow%s*=%s*"([^"]+)"')
local HOST_ENTRY = string.match(manifest, '\nhost%s*=%s*"([^"]+)"')

local function log(...)
	if VERBOSE then
		print(...)
	end
end

local function contains(hay: string?, needle: string): boolean
	return hay ~= nil and string.find(hay, needle, 1, true) ~= nil
end

------------------------------------------------------------------------------
-- Expected profiles and cookies (from the spec).

local BROWSERS = {}
for _, b in SPEC.browsers do
	BROWSERS[b.key] = b
end

local EXPECTED = {} -- listed profiles {b, dir, name, account}
for _, b in SPEC.browsers do
	if b.location ~= nil and b.state == "ok" then
		for _, p in b.profiles do
			if not p.hostile and not p.unlaunchable then
				table.insert(EXPECTED, { b = b, dir = p.dir, name = p.name, account = p.account })
			end
		end
	end
end
local FORBIDDEN_TEXT = { "Ghost", "Evil" }

-- Source cookie databases by profile id; profiles without one are fresh.
local COOKIE_SPECS = {}
for _, cs in SPEC.cookies do
	COOKIE_SPECS[cs.browser .. "/" .. cs.profile] = cs
end

local function source_id(e): string
	return e.b.key .. "/" .. e.dir
end

local function store_name(e): string
	return STORE_PREFIX .. source_id(e)
end

local function cookie_spec(e)
	return COOKIE_SPECS[source_id(e)]
end

-- name -> value of every live cookie the profile's source holds.
local function expected_cookies(e): { [string]: string }
	local cs = cookie_spec(e)
	return if cs then cs.expected else {}
end

local function copy_fails(e): boolean
	local cs = cookie_spec(e)
	return cs ~= nil and cs.fails == true
end

local EXPECTED_OK = {} -- profiles whose sign-ins copy cleanly
for _, e in EXPECTED do
	if not copy_fails(e) then
		table.insert(EXPECTED_OK, e)
	end
end

local ALL_SECRET_VALUES = {}
for _, cs in SPEC.cookies do
	for _, row in cs.rows do
		table.insert(ALL_SECRET_VALUES, row.value)
	end
end

-- Tern's own cookie in its default store; nothing may change it.
local DEFAULT_COOKIE = { name = "tern_own", value = "tern-default-session", domain = ".example.com", path = "/" }

------------------------------------------------------------------------------
-- Op accounting. Native browser calls are priced by what they cost Tern:
-- opening a WebKit view dwarfs a cookie write.

local C = {
	fs_read = 0,
	fs_exists = 0,
	fs_list = 0,
	fs_mut = 0,
	kv_get = 0,
	kv_set = 0,
	proc = 0,
	getenv = 0,
	timers = 0,
	read_bytes = 0,
	decode_bytes = 0,
	native_open = 0,
	native_dock = 0,
	native_cookie_write = 0,
	native_nav = 0,
	native_close = 0,
	native_read = 0,
}

local OP_WEIGHTS = {
	fs_read = 3,
	fs_exists = 1,
	fs_list = 2,
	fs_mut = 5,
	kv_get = 1,
	kv_set = 2,
	proc = 25,
	getenv = 0.1,
	timers = 1,
	read_bytes = 1 / 32768,
	decode_bytes = 1 / 32768,
	native_open = 8,
	native_dock = 2,
	native_cookie_write = 1,
	native_nav = 2,
	native_close = 2,
	native_read = 1,
}

local function snapshot()
	return table.clone(C)
end

local function cost_since(s): number
	local total = 0
	for k, v in C do
		total += (v - s[k]) * OP_WEIGHTS[k]
	end
	return total
end

------------------------------------------------------------------------------
-- The world one scenario runs in.

local W
local EXTERNAL_LAUNCHES = {} -- every non-exporter process, across all scenarios
local TERN_OPENS = 0 -- native opens into a named profile store, across all scenarios

local function new_world(opts)
	opts = opts or {}
	W = {
		home = opts.home ~= false,
		apps = opts.apps ~= false,
		only_apps = opts.only_apps,
		kv = {},
		procs = {},
		toasts = {},
		picks = {},
		pick_answer = nil,
		browser_ops = {},
		opens = {},
		host_opens = {},
		hold_host_open = false,
		fallthroughs = {},
		actions = {},
		queue = {},
		timers = {},
		clock = 0,
		seq = 0,
		errors = {},
		commands = {},
		command_order = {},
		dup_ids = {},
		binds = {},
		link_routes = {},
		status_fns = {},
		on = {},
		blocks = {},
		new_blocks = {},
		window_vm = nil,
		-- Tern's embedded browser.
		bblocks = {},
		stores = { [""] = {} },
		navs = {},
		next_block = 100,
		fail = {}, -- open = true; setCookie = "envelope" | "nil" | "raise"
		reject_cookie = nil, -- cookie name WebKit refuses
		gone_on_process = false, -- process callbacks get no window cx
		keychain = KEYCHAIN,
		focused = TERMINAL_PANE,
		floats = {},
		panes = {
			{ pane = TERMINAL_PANE, kind = "terminal", title = "zsh", cwd = HOME },
			{ pane = BLOCK_PANE, kind = "plugin", title = "Browser Profiles", cwd = HOME },
		},
		unmocked = {},
	}
	local key = DEFAULT_COOKIE.domain .. "|" .. DEFAULT_COOKIE.path .. "|" .. DEFAULT_COOKIE.name
	W.stores[""][key] = table.clone(DEFAULT_COOKIE)
	if opts.browser_block then
		-- An ordinary Tern browser block on the default store, focused.
		local b = { block = BROWSER_PANE, profile = nil, store = "", url = "https://app.example.com/dash", owner = TERMINAL_PANE, closed = false, docked = true }
		W.bblocks[BROWSER_PANE] = b
		table.insert(W.panes, { pane = BROWSER_PANE, kind = "browser", title = "Example", url = b.url, cwd = "" })
		W.focused = BROWSER_PANE
	end
	if opts.float then
		-- A floating block over the terminal has focus.
		table.insert(W.panes, { pane = FLOAT_PANE, kind = "terminal", title = "float", cwd = HOME, floating = true })
		W.floats = { { pane = FLOAT_PANE, over = TERMINAL_PANE, corner = "bottom_right" } }
		W.focused = FLOAT_PANE
	end
	if fs.isFile(SHIM_LOG) then
		fs.removeFile(SHIM_LOG)
	end
end

local function record_error(where: string, err: any)
	table.insert(W.errors, where .. ": " .. tostring(err))
	log("LUA ERROR", where, err)
end

local function enqueue(fn)
	table.insert(W.queue, fn)
end

local function drain()
	local steps = 0
	while steps < 5000 do
		steps += 1
		if #W.queue > 0 then
			local fn = table.remove(W.queue, 1)
			local ok, err = pcall(fn)
			if not ok then
				record_error("callback", err)
			end
		elseif #W.timers > 0 then
			table.sort(W.timers, function(a, b)
				if a.due == b.due then
					return a.seq < b.seq
				end
				return a.due < b.due
			end)
			local t = table.remove(W.timers, 1)
			if not t.cancelled then
				W.clock = math.max(W.clock, t.due)
				local ok, err = pcall(t.fn)
				if not ok then
					record_error("timer", err)
				end
			end
		else
			return
		end
	end
	record_error("drain", "callbacks/timers never settle (5000 steps)")
	W.queue = {}
	W.timers = {}
end

------------------------------------------------------------------------------
-- Fake filesystem: /Applications → ROOT/Applications, HOME is real, relative
-- paths are the plugin dir (writes go to a scratch data dir), anything else
-- does not exist.

local DATA = ROOT .. "/plugin-data"

local function app_visible(path: string, folder: string): boolean
	if not W.apps then
		return false
	end
	if W.only_apps == nil or path == folder then
		return true
	end
	local first = string.match(string.sub(path, #folder + 2), "^([^/]+)")
	return first ~= nil and W.only_apps[first] == true
end

local function real(path: string, write: boolean?): string
	if type(path) ~= "string" then
		error("path must be a string", 3)
	end
	if contains(path, "/../") or string.sub(path, -3) == "/.." then
		return ROOT .. "/__outside__"
	end
	if string.sub(path, 1, 1) ~= "/" then
		local rel = string.gsub(path, "^%./", "")
		if write then
			return DATA .. "/" .. rel
		end
		if fs.isFile(DATA .. "/" .. rel) or fs.isDir(DATA .. "/" .. rel) then
			return DATA .. "/" .. rel
		end
		return PLUGIN .. "/" .. rel
	end
	if path == "/Applications" or string.sub(path, 1, 14) == "/Applications/" then
		return if app_visible(path, "/Applications") then ROOT .. path else ROOT .. "/__noapps__" .. path
	end
	if path == HOME or string.sub(path, 1, #HOME + 1) == HOME .. "/" then
		local user_apps = HOME .. "/Applications"
		if (path == user_apps or string.sub(path, 1, #user_apps + 1) == user_apps .. "/") and not app_visible(path, user_apps) then
			return ROOT .. "/__noapps__" .. path
		end
		return path
	end
	if path == DATA or string.sub(path, 1, #DATA + 1) == DATA .. "/" then
		return path
	end
	return ROOT .. "/__outside__" .. path
end

local function exists(r: string): boolean
	return fs.isFile(r) or fs.isDir(r)
end

------------------------------------------------------------------------------
-- tern.ui: plain TSP-like nodes.

local function node(kind, props, children)
	return { k = kind, p = props or {}, c = children }
end

local ui = {}
ui.span = function(t, s)
	return { t = t, s = s }
end
ui.link = function(t, href, s)
	return { t = t, href = href, s = s }
end
ui.path = function(p, cwd)
	return { t = p, s = "path" }
end
ui.text = function(spans)
	return node("text", { spans = spans })
end
ui.col = function(children)
	return node("col", {}, children)
end
ui.lines = function(children)
	return node("lines", {}, children)
end
ui.row = function(children)
	return node("row", {}, children)
end
ui.card = function(head, children)
	return node("card", { head = head }, children)
end
ui.section = function(head, children)
	return node("section", { head = head }, children)
end
ui.rule = function(label)
	return node("rule", { label = label })
end
ui.badge = function(t, tone)
	return node("badge", { text = t, tone = tone })
end
ui.kv = function(items)
	return node("kv", { items = items })
end
ui.md = function(text)
	return node("md", { text = text })
end
ui.list = function(items)
	local kids = {}
	for i, it in items do
		kids[i] = node("item", {
			label = it.label,
			detail = it.detail,
			value = it.value,
			icon = it.icon,
			tone = it.tone,
		})
	end
	return node("list", {}, kids)
end
ui.node = function(kind, props, children)
	return node(kind, props, children)
end
ui.el = function(tag, props, children)
	return node("el:" .. tag, props, children)
end
setmetatable(ui, {
	__index = function(_, k)
		return function(...)
			return node(k, { args = { ... } })
		end
	end,
})

local function collect_text(v, out, seen)
	seen = seen or {}
	if type(v) == "string" then
		table.insert(out, v)
	elseif type(v) == "table" and not seen[v] then
		seen[v] = true
		for key, x in v do
			if key ~= "s" and key ~= "key" and key ~= "selected" and key ~= "icon" and key ~= "tone" then
				collect_text(x, out, seen)
			end
		end
	end
	return out
end

local function text_of(v): string
	return table.concat(collect_text(v, {}), " ")
end

-- Keyed items of a region: { id, text } for every node with a key below a
-- keyed list, ids joined from the keyed ancestors as Tern does.
local function keyed_items(region_name: string, root)
	local out = {}
	local function walk(n, path)
		if type(n) ~= "table" then
			return
		end
		local p = n.p or {}
		local here = path
		if type(p.key) == "string" and n ~= root then
			here = path .. "." .. p.key
			if n.k == "item" then
				table.insert(out, { id = here, text = text_of(p), list_id = path })
			end
		end
		for _, c in n.c or {} do
			walk(c, here)
		end
	end
	walk(root, region_name)
	return out
end

------------------------------------------------------------------------------
-- Processes: the exporter runs for real; anything else is an external launch.

local function basename(p: string): string
	return string.match(p, "([^/]+)$") or p
end

local function is_python(argv): boolean
	return string.match(basename(argv[1]), "^python") ~= nil
end

local function run_python(argv, opts)
	local args = { PLUGIN .. "/bench/py_shim.py" }
	for i = 2, #argv do
		table.insert(args, argv[i])
	end
	local env = {
		BP_KEYCHAIN = W.keychain,
		BP_SHIM_LOG = SHIM_LOG,
		HOME = if W.home then HOME else ROOT .. "/__nohome__",
	}
	for k, v in opts.env or {} do
		env[k] = v
	end
	local cwd = if opts.cwd then real(opts.cwd) else PLUGIN
	local r = process.exec("python3", args, { cwd = cwd, env = env, stdio = { stdin = opts.stdin } })
	return { status = r.code, stdout = r.stdout, stderr = r.stderr, timed_out = false }
end

local function execute(argv, opts)
	if is_python(argv) then
		return run_python(argv, opts)
	end
	-- Never run: recorded as the external launch it would be.
	table.insert(EXTERNAL_LAUNCHES, table.concat(argv, " "))
	return { status = 0, stdout = "", stderr = "", timed_out = false }
end

-- Keychain services the exporter looked up in this scenario.
local function keychain_reads(): { string }
	local out = {}
	if fs.isFile(SHIM_LOG) then
		for line in string.gmatch(fs.readFile(SHIM_LOG), "[^\n]+") do
			local ok, v = pcall(serde.decode, "json", line)
			if ok and type(v) == "table" then
				table.insert(out, tostring(v.service))
			end
		end
	end
	return out
end

------------------------------------------------------------------------------
-- Tern's embedded browser: blocks over persistent per-profile cookie stores.

local function deep_copy_json(v)
	if type(v) ~= "table" then
		return v
	end
	return serde.decode("json", serde.encode("json", v))
end

local function pane_live(id: any): boolean
	for _, p in W.panes do
		if p.pane == id then
			return true
		end
	end
	return false
end

local function store_of(name: string)
	W.stores[name] = W.stores[name] or {}
	return W.stores[name]
end

local function store_size(s): number
	local n = 0
	for _ in s do
		n += 1
	end
	return n
end

local function live_block(id: any)
	local b = W.bblocks[id]
	if b == nil or b.closed then
		return nil
	end
	return b
end

local function navigate(b, url: string)
	b.url = url
	for _, p in W.panes do
		if p.pane == b.block then
			p.url = url
		end
	end
	if url ~= "about:blank" then
		table.insert(W.navs, { block = b.block, profile = b.profile, url = url, cookies = store_size(store_of(b.store)) })
	end
end

local function close_block(id: any): boolean
	local b = live_block(id)
	if b == nil then
		return false
	end
	b.closed = true
	for i, p in W.panes do
		if p.pane == id then
			table.remove(W.panes, i)
			break
		end
	end
	if W.focused == id then
		W.focused = b.owner
	end
	return true
end

local function browser_op(op)
	local kind = op.op
	if kind == "open" then
		C.native_open += 1
		if W.fail.open then
			return { error = "browser: could not open a web view" }, nil
		end
		if type(op.owner) ~= "number" or not pane_live(op.owner) then
			return { error = "open: owner must be a pane of this window" }, nil
		end
		if op.profile ~= nil and (type(op.profile) ~= "string" or op.profile == "") then
			return { error = "open: profile must be a non-empty string" }, nil
		end
		local url = if op.url == nil then "about:blank" else op.url
		if type(url) ~= "string" then
			return { error = "open: url must be a string" }, nil
		end
		W.next_block += 1
		local b = { block = W.next_block, profile = op.profile, store = op.profile or "", url = "about:blank", owner = op.owner, closed = false, docked = false }
		W.bblocks[b.block] = b
		table.insert(W.panes, { pane = b.block, kind = "browser", title = "", url = "about:blank", cwd = "", floating = true })
		if op.profile ~= nil then
			TERN_OPENS += 1
		end
		navigate(b, url)
		return { ok = { block = b.block, url = url } }, nil
	elseif kind == "setCookie" then
		C.native_cookie_write += 1
		local b = live_block(op.block)
		if b == nil then
			return { error = "setCookie: no such browser block" }, nil
		end
		local c = op.cookie
		if type(c) ~= "table" or type(c.name) ~= "string" or type(c.value) ~= "string" or (type(c.domain) ~= "string" and type(c.url) ~= "string") then
			return { error = "setCookie: invalid cookie" }, nil
		end
		if W.fail.setCookie == "envelope" or W.reject_cookie == c.name then
			return { error = "setCookie: WebKit rejected the cookie" }, nil
		elseif W.fail.setCookie == "nil" then
			return nil, "browser: the native call failed"
		end
		local where = c.domain or c.url
		local key = where .. "|" .. (c.path or "/") .. "|" .. c.name
		store_of(b.store)[key] = { name = c.name, value = c.value, domain = where, path = c.path or "/" }
		return { ok = {} }, nil
	elseif kind == "goto" or kind == "reload" then
		C.native_nav += 1
		local b = live_block(op.block)
		if b == nil then
			return { error = kind .. ": no such browser block" }, nil
		end
		navigate(b, if kind == "goto" then op.url else b.url)
		return { ok = {} }, nil
	elseif kind == "close" then
		C.native_close += 1
		if not close_block(op.block) then
			return { error = "close: no such browser block" }, nil
		end
		return { ok = {} }, nil
	elseif kind == "cookies" then
		C.native_read += 1
		local b = live_block(op.block)
		if b == nil then
			return { error = "cookies: no such browser block" }, nil
		end
		local list = {}
		for _, c in store_of(b.store) do
			table.insert(list, table.clone(c))
		end
		return { ok = { cookies = list } }, nil
	elseif kind == "blocks" then
		C.native_read += 1
		local blocks = {}
		for _, b in W.bblocks do
			if not b.closed then
				table.insert(blocks, { block = b.block, url = b.url, title = "" })
			end
		end
		table.sort(blocks, function(a, b)
			return a.block < b.block
		end)
		return { ok = { blocks = blocks } }, nil
	elseif kind == "state" then
		C.native_read += 1
		local b = live_block(op.block or W.focused)
		if b == nil then
			return { error = "state: no browser block" }, nil
		end
		return { ok = { block = b.block, url = b.url, title = "" } }, nil
	end
	return { error = "harness: browser op " .. tostring(kind) .. " not mocked" }, nil
end

------------------------------------------------------------------------------
-- VMs.

local new_vm

-- A window callback gets a fresh cx; `gone` models the window closing first.
local function awaitable(vm, resolve, gone: (() -> boolean)?)
	return {
		next = function(_, fn)
			enqueue(function()
				local r, e = resolve()
				fn(r, e, if gone ~= nil and gone() then nil else vm.cx)
			end)
		end,
	}
end

local function strict(name: string, t)
	return setmetatable(t, {
		__index = function(_, k)
			local what = name .. "." .. tostring(k)
			W.unmocked[what] = true
			error("harness: " .. what .. " is not mocked", 2)
		end,
	})
end

local function claimed(res): boolean
	return type(res) == "table" and (res.handled == true or res.url ~= nil or res.block ~= nil)
end

-- What Tern does with a link click or an EffectCx:open: the window's last
-- link route may claim it; otherwise the built-in open (recorded) runs.
local function route_link(url: string, pane: number, mods)
	local vm = W.window_vm
	local route = W.link_routes[#W.link_routes]
	if vm == nil or route == nil then
		table.insert(W.fallthroughs, url)
		return nil, false
	end
	local ok, res = pcall(route, { url = url, pane = pane, mods = table.clone(mods or NO_MODS) }, vm.cx)
	if not ok then
		record_error("route.link", res)
		res = nil
	end
	if not claimed(res) then
		table.insert(W.fallthroughs, url)
	end
	return res, true
end

local function make_window_cx(vm)
	local cx = {}
	local function pane_info(id)
		if id == "@focused" then
			id = W.focused
		end
		for _, p in W.panes do
			if p.pane == id then
				return p
			end
		end
		return nil
	end
	cx.session = strict("cx.session", {
		focused = function(_)
			return W.focused
		end,
		panes = function(_)
			return W.panes
		end,
		pane = function(_, id)
			return pane_info(id)
		end,
		resolve = function(_, spec)
			if spec == "@focused" then
				return W.focused
			end
			return nil
		end,
		tabs = function(_)
			return { { tab = 1, position = 1, pane = W.focused, cwd = HOME } }
		end,
		tab_of = function(_, id)
			return if pane_info(id) then 1 else nil
		end,
		layout = function(_, tab)
			if tab ~= 1 then
				return nil
			end
			return { tab = 1, root = { pane = TERMINAL_PANE }, floats = W.floats, zoomed = false, focus = W.focused }
		end,
	})
	cx.layout = strict("cx.layout", {
		focus = function(_, pane)
			table.insert(W.actions, "focus:" .. tostring(pane))
		end,
		dock = function(_, pane, target, dir, _reveal)
			C.native_dock += 1
			local b = live_block(pane)
			if b == nil then
				return false, "no such pane"
			end
			if target ~= nil and not pane_live(target) then
				return false, "no such target pane"
			end
			b.docked = true
			b.dock_target = target
			b.dock_dir = dir
			for _, p in W.panes do
				if p.pane == pane then
					p.floating = nil
				end
			end
			return true, nil
		end,
		close = function(_, pane)
			C.native_close += 1
			close_block(pane)
		end,
	})
	cx.browser = strict("cx.browser", {
		call = function(_, op)
			-- The op runs when called, whether or not the caller awaits it.
			table.insert(W.browser_ops, deep_copy_json(op))
			if op.op == "setCookie" and W.fail.setCookie == "raise" then
				C.native_cookie_write += 1
				error("browser: native bridge raised", 2)
			end
			local res, err = browser_op(op)
			return awaitable(vm, function()
				return res, err
			end)
		end,
	})
	function cx.pick(_, opts)
		if type(opts) ~= "table" or type(opts.items) ~= "table" or #opts.items == 0 then
			error("cx:pick: items must hold at least one choice", 2)
		end
		for _, it in opts.items do
			if type(it.label) ~= "string" then
				error("cx:pick: every item needs a string label", 2)
			end
		end
		table.insert(W.picks, opts)
		return awaitable(vm, function()
			local answer = W.pick_answer
			if answer == nil then
				return nil, nil
			end
			return answer(opts), nil
		end)
	end
	function cx.prompt(_, _opts)
		return awaitable(vm, function()
			return nil, nil
		end)
	end
	function cx.toast(_, level, text, sub)
		table.insert(W.toasts, { level = level, text = tostring(text), sub = sub and tostring(sub) })
	end
	function cx.open(_, target, how)
		-- Window cx:open skips routes: Tern's built-in open (default store).
		table.insert(W.opens, target)
	end
	function cx.copy(_, text)
		table.insert(W.actions, "copy")
	end
	function cx.action(_, name)
		table.insert(W.actions, "action:" .. name)
		local id = string.match(name, "^plugin%." .. string.gsub(PLUGIN_ID, "%-", "%%-") .. "%.(.+)$")
		if id and W.commands[id] then
			W.commands[id].run(cx)
		end
	end
	function cx.command(_, id)
		table.insert(W.actions, "command:" .. id)
	end
	function cx.new_block(_, kind, args, how, reveal)
		table.insert(W.new_blocks, kind)
		if kind == BLOCK_KIND then
			return BLOCK_PANE
		end
		return nil
	end
	return strict("cx", cx)
end

local function make_block_cx(vm)
	return strict("BlockCx", {
		pane = BLOCK_PANE,
		cwd = HOME,
		cols = 100,
		rows = 40,
		toast = function(_, level, text, sub)
			table.insert(W.toasts, { level = level, text = tostring(text), sub = sub and tostring(sub) })
		end,
		open = function(_, target)
			-- EffectCx:open reaches the window's route.link, from this pane.
			table.insert(W.host_opens, target)
			if not W.hold_host_open then
				enqueue(function()
					route_link(target, BLOCK_PANE, NO_MODS)
				end)
			end
		end,
		copy = function() end,
		render = function() end,
		save = function() end,
		exit = function() end,
		frame = function() end,
	})
end

local function make_tern(vm)
	local window = vm.context == "window"
	local t = {}
	t.context = vm.context
	t.runtime = { os = "macos", arch = "aarch64", context = vm.context, platform = "desktop" }
	local function noop() end
	t.log = {
		debug = noop,
		info = noop,
		warn = function(...)
			log("warn", ...)
		end,
		error = function(...)
			log("error", ...)
		end,
	}
	t.json = {
		encode = function(v, pretty)
			return serde.encode("json", v, pretty == true)
		end,
		decode = function(text)
			C.decode_bytes += #text
			local ok, v = pcall(serde.decode, "json", text)
			if not ok then
				error("tern.json.decode: " .. tostring(v), 2)
			end
			return v
		end,
		array = function(x)
			return x or {}
		end,
		null = newproxy(false),
	}
	t.now = function()
		return os.clock() * 1000
	end
	t.getenv = function(name)
		C.getenv += 1
		if name == "HOME" then
			return if W.home then HOME else nil
		elseif name == "USER" then
			return "tester"
		elseif name == "PATH" then
			return "/usr/bin:/bin:/usr/sbin:/sbin"
		end
		return nil
	end
	t.timer = function(ms, fn)
		C.timers += 1
		W.seq += 1
		local entry = { due = W.clock + (ms or 0), seq = W.seq, fn = function()
			fn(vm.cx)
		end }
		table.insert(W.timers, entry)
		return {
			cancel = function()
				entry.cancelled = true
			end,
		}
	end
	t.sleep = function(ms)
		return {
			next = function(_, fn)
				t.timer(ms, function()
					fn(nil, nil, vm.cx)
				end)
			end,
		}
	end
	-- One store shared by the plugin's host and window VMs, as in Tern.
	t.kv = {
		get = function(key)
			C.kv_get += 1
			return deep_copy_json(W.kv[key])
		end,
		set = function(key, value)
			C.kv_set += 1
			W.kv[key] = deep_copy_json(value)
		end,
	}
	t.fs = {
		read = function(path, max)
			C.fs_read += 1
			local r = real(path)
			if not fs.isFile(r) then
				error("tern.fs.read: " .. path .. ": No such file or directory", 2)
			end
			local s = fs.readFile(r)
			if max ~= nil and #s > max then
				error("tern.fs.read: " .. path .. " is larger than " .. max .. " bytes", 2)
			end
			C.read_bytes += #s
			return s
		end,
		write = function(path, text)
			C.fs_mut += 1
			local r = real(path, true)
			local dir = string.match(r, "^(.*)/[^/]+$")
			if dir and not fs.isDir(dir) then
				fs.writeDir(dir)
			end
			fs.writeFile(r, text)
		end,
		list = function(path)
			C.fs_list += 1
			local r = real(path)
			if not fs.isDir(r) then
				error("tern.fs.list: " .. path .. ": No such directory", 2)
			end
			local names = fs.readDir(r)
			if W.only_apps and (path == "/Applications" or path == HOME .. "/Applications") then
				local kept = {}
				for _, n in names do
					if W.only_apps[n] then
						table.insert(kept, n)
					end
				end
				names = kept
			end
			table.sort(names)
			return names
		end,
		exists = function(path)
			C.fs_exists += 1
			return exists(real(path))
		end,
		mkdir = function(path)
			C.fs_mut += 1
			fs.writeDir(real(path, true))
		end,
		remove = function(path)
			C.fs_mut += 1
			local r = real(path, true)
			if fs.isDir(r) then
				fs.removeDir(r)
			elseif fs.isFile(r) then
				fs.removeFile(r)
			end
		end,
	}
	t.process = {
		run = function(argv, a, b)
			local opts, cb = nil, nil
			if type(a) == "function" then
				cb = a
			else
				opts, cb = a, b
			end
			if type(argv) ~= "table" or #argv == 0 then
				error("tern.process.run: argv must be a non-empty array", 2)
			end
			for _, s in argv do
				if type(s) ~= "string" then
					error("tern.process.run: argv entries must be strings", 2)
				end
			end
			C.proc += 1
			local copy = table.clone(argv)
			local o = opts or {}
			table.insert(W.procs, { argv = copy, opts = o, context = vm.context })
			local result = nil
			local function get()
				if result == nil then
					result = execute(copy, o)
				end
				return result
			end
			local function gone(): boolean
				return W.gone_on_process
			end
			if cb then
				enqueue(function()
					local r = get()
					cb(r, if gone() then nil else vm.cx)
				end)
				return nil
			end
			return awaitable(vm, function()
				return get(), nil
			end, gone)
		end,
	}
	t.fetch = function()
		error("harness: network is disabled", 2)
	end
	t.ui = ui
	t.parse = {}
	t.on = function(name, fn)
		W.on[name] = W.on[name] or {}
		table.insert(W.on[name], { fn = fn, context = vm.context })
	end
	if window then
		t.command = function(def)
			if type(def) ~= "table" or type(def.id) ~= "string" or string.match(def.id, "^[%w_%-]+$") == nil then
				error("tern.command: invalid id " .. tostring(def and def.id), 2)
			end
			if type(def.title) ~= "string" or type(def.run) ~= "function" then
				error("tern.command: title and run are required", 2)
			end
			if W.commands[def.id] then
				table.insert(W.dup_ids, def.id)
			else
				table.insert(W.command_order, def.id)
			end
			W.commands[def.id] = def
		end
		t.bind = function(chord, action)
			table.insert(W.binds, { chord = chord, action = action })
		end
		t.override = function() end
		t.route = {
			link = function(fn)
				table.insert(W.link_routes, fn)
			end,
			open = function() end,
		}
		t.chrome = {
			status = function(fn)
				table.insert(W.status_fns, fn)
			end,
			tab_title = function() end,
			window_title = function() end,
			refresh = function() end,
		}
		t.css = function() end
		t.carly = strict("tern.carly", {
			context = function() end,
			export = function() end,
		})
	else
		t.block = {
			define = function(id, def)
				W.blocks[id] = def
			end,
		}
		t.lens = { define = function() end }
		t.pane = {
			list = function()
				return { { pane = BLOCK_PANE, title = "Browser Profiles", program = BLOCK_KIND, cwd = HOME } }
			end,
			write = function() end,
		}
	end
	return strict("tern", t)
end

local SAFE_GLOBALS = {
	"string", "table", "math", "os", "utf8", "bit32", "buffer", "coroutine",
	"pcall", "xpcall", "error", "assert", "type", "typeof", "tostring", "tonumber",
	"pairs", "ipairs", "next", "select", "setmetatable", "getmetatable",
	"rawget", "rawset", "rawequal", "rawlen", "unpack", "newproxy", "vector",
}

new_vm = function(context: string)
	local vm = { context = context, modules = {} }
	vm.tern = make_tern(vm)
	vm.cx = if context == "window" then make_window_cx(vm) else nil
	local env = { tern = vm.tern, print = function() end, _VERSION = "Luau" }
	for _, name in SAFE_GLOBALS do
		env[name] = (_G :: any)[name] or getfenv()[name]
	end
	vm.env = env
	local function load_module(rel: string)
		rel = string.gsub(rel, "^%./", "")
		local cached = vm.modules[rel]
		if cached then
			return cached.value
		end
		local file = nil
		for _, cand in { rel, rel .. ".luau", rel .. ".lua", rel .. "/init.luau" } do
			if fs.isFile(PLUGIN .. "/" .. cand) then
				file = cand
				break
			end
		end
		if file == nil then
			error("module not found: " .. rel, 2)
		end
		local dir = string.match(file, "^(.*)/[^/]+$") or ""
		local menv = setmetatable({
			require = function(p)
				if string.sub(p, 1, 2) == "./" then
					p = (if dir ~= "" then dir .. "/" else "") .. string.sub(p, 3)
				elseif string.sub(p, 1, 3) == "../" then
					local parent = string.match(dir, "^(.*)/[^/]+$") or ""
					p = (if parent ~= "" then parent .. "/" else "") .. string.sub(p, 4)
				elseif string.sub(p, 1, 6) == "@self/" then
					p = string.sub(file, 1, -6) .. "/" .. string.sub(p, 7)
				end
				return vm.load(p)
			end,
		}, { __index = env, __newindex = env })
		local fn = luau.load(fs.readFile(PLUGIN .. "/" .. file), {
			debugName = file,
			environment = menv,
			injectGlobals = false,
		})
		local value = fn()
		vm.modules[rel] = { value = value }
		return value
	end
	vm.load = load_module
	return vm
end

------------------------------------------------------------------------------
-- Scenario helpers.

local function load_window()
	local vm = new_vm("window")
	W.window_vm = vm
	local ok, err = pcall(vm.load, WINDOW_ENTRY)
	if not ok then
		record_error("load window", err)
		return vm, false
	end
	for _, h in W.on.window_start or {} do
		local ok2, err2 = pcall(h.fn, vm.cx)
		if not ok2 then
			record_error("window_start", err2)
		end
	end
	drain()
	return vm, true
end

local function load_host()
	local vm = new_vm("host")
	local ok, err = pcall(vm.load, HOST_ENTRY)
	if not ok then
		record_error("load host", err)
		return vm, false
	end
	drain()
	return vm, true
end

local function run_command(vm, id): boolean
	local def = W.commands[id]
	if def == nil then
		return false
	end
	local ok, err = pcall(def.run, vm.cx)
	if not ok then
		record_error("command " .. id, err)
	end
	drain()
	return true
end

local function item_text(it): string
	return table.concat({ it.label or "", it.detail or "", it.group or "" }, " ")
end

local function profile_text_ok(text: string, e): boolean
	return contains(text, e.name) and contains(text, e.b.token)
end

local function find_item(opts, e)
	for _, it in opts.items do
		if profile_text_ok(item_text(it), e) then
			return it
		end
	end
	return nil
end

local function expected_named(name: string)
	for _, e in EXPECTED do
		if e.name == name then
			return e
		end
	end
	error("no expected profile " .. name)
end

local function choose(e)
	return function(opts)
		return find_item(opts, e)
	end
end

local function last_pick()
	return W.picks[#W.picks]
end

local function open_via_switch(vm, e)
	W.pick_answer = choose(e)
	run_command(vm, "switch")
end

-- The palette command that opens `e` directly.
local function profile_command(e): string?
	for _, id in W.command_order do
		local def = W.commands[id]
		local title = string.lower(def.title)
		if id ~= "switch" and contains(def.title, e.name) and contains(def.title, e.b.token)
			and not contains(title, "link") and not contains(title, "cookie") and not contains(title, "sign") and not contains(title, "copy") then
			return id
		end
	end
	return nil
end

local function click(vm, url, mods)
	if W.link_routes[#W.link_routes] == nil then
		return nil, false
	end
	local res, has = route_link(url, TERMINAL_PANE, mods)
	drain()
	return res, has
end

local function python_runs(): number
	local n = 0
	for _, p in W.procs do
		if is_python(p.argv) then
			n += 1
		end
	end
	return n
end

local function ops_of(kind: string, from: number?): number
	local n = 0
	for i = (from or 0) + 1, #W.browser_ops do
		if W.browser_ops[i].op == kind then
			n += 1
		end
	end
	return n
end

local function store_values(name: string): { [string]: string }
	local out = {}
	for _, c in W.stores[name] or {} do
		out[c.name] = c.value
	end
	return out
end

local function same_map(a, b): boolean
	for k, v in a do
		if b[k] ~= v then
			return false
		end
	end
	for k, v in b do
		if a[k] ~= v then
			return false
		end
	end
	return true
end

-- The Tern store of `e` holds exactly the source's live cookies.
local function store_exact(e): boolean
	return same_map(store_values(store_name(e)), expected_cookies(e))
end

local function live_blocks(name: string)
	local out = {}
	for _, b in W.bblocks do
		if not b.closed and b.profile == name then
			table.insert(out, b)
		end
	end
	return out
end

-- A live block of `e`'s store shows `url`, and every time a page of that
-- store was shown its sign-ins were already in.
local function signed_in_at(e, url: string): boolean
	local name = store_name(e)
	local want = store_size(expected_cookies(e))
	for _, n in W.navs do
		if n.profile == name and n.cookies < want then
			return false
		end
	end
	for _, b in live_blocks(name) do
		if b.url == url then
			return true
		end
	end
	return false
end

local function navs_of(name: string): number
	local n = 0
	for _, nav in W.navs do
		if nav.profile == name then
			n += 1
		end
	end
	return n
end

local function error_toasts(): number
	local n = 0
	for _, t in W.toasts do
		if t.level == "error" then
			n += 1
		end
	end
	return n
end

local function toasts_leak_secrets(): boolean
	for _, t in W.toasts do
		for _, v in ALL_SECRET_VALUES do
			if contains(t.text, v) or contains(t.sub, v) then
				return true
			end
		end
	end
	return false
end

-- Tern's default store and the user's own browser block are as they were.
local function default_untouched(): boolean
	local key = DEFAULT_COOKIE.domain .. "|" .. DEFAULT_COOKIE.path .. "|" .. DEFAULT_COOKIE.name
	if store_size(W.stores[""]) ~= 1 or W.stores[""][key] == nil or W.stores[""][key].value ~= DEFAULT_COOKIE.value then
		return false
	end
	for _, op in W.browser_ops do
		if op.block == BROWSER_PANE and op.op ~= "blocks" and op.op ~= "state" and op.op ~= "cookies" then
			return false
		end
		if op.op == "open" and op.profile == nil then
			return false
		end
	end
	local b = W.bblocks[BROWSER_PANE]
	return b == nil or (not b.closed and b.url == "https://app.example.com/dash")
end

-- A first open of `e` that went right: one export, the source's cookies in
-- its own store before the home page shows, no errors, nothing external.
local function first_open_ok(e, url: string?): boolean
	return python_runs() == 1
		and store_exact(e)
		and signed_in_at(e, url or HOME_PAGE)
		and error_toasts() == 0
		and #W.errors == 0
		and default_untouched()
end

-- After a failed copy: no page shown in that store, no block left behind,
-- and an error the user can read.
local function failed_cleanly(e): boolean
	local name = store_name(e)
	return navs_of(name) == 0 and #live_blocks(name) == 0 and error_toasts() > 0 and #W.fallthroughs == 0 and #W.opens == 0
end

-- Clears injected failures and opens `e` again: the copy must run afresh
-- and succeed.
local function retry_succeeds(vm, e): boolean
	W.fail = {}
	W.reject_cookie = nil
	W.gone_on_process = false
	W.keychain = KEYCHAIN
	W.toasts = {}
	local before = python_runs()
	open_via_switch(vm, e)
	return python_runs() == before + 1 and store_exact(e) and signed_in_at(e, HOME_PAGE) and error_toasts() == 0
end

-- Selected profile id of the host block's view.
local function block_selected(view): string?
	local found = nil
	local function walk(n)
		if type(n) ~= "table" or found then
			return
		end
		local p = n.p or {}
		if type(p.selected) == "string" then
			found = string.match(p.selected, "^main%.list%.(.+)$")
			return
		end
		for _, c in n.c or {} do
			walk(c)
		end
	end
	walk(view.main)
	return found
end

local function expected_by_id(id: string?)
	for _, e in EXPECTED do
		if source_id(e) == id then
			return e
		end
	end
	return nil
end

------------------------------------------------------------------------------
-- Checks.

local results = {}
local spec_points, spec_max = 0, 0
local all_errors = 0

local function check(name: string, weight: number, fn: () -> any, world_opts: any?)
	new_world(world_opts)
	local ok, v = pcall(fn)
	local frac = 0
	if ok then
		if v == true then
			frac = 1
		elseif type(v) == "number" then
			frac = math.clamp(v, 0, 1)
		end
	else
		log("CHECK RAISED", name, v)
	end
	all_errors += #W.errors
	spec_points += weight * frac
	spec_max += weight
	table.insert(results, { name = name, weight = weight, frac = frac, errors = #W.errors, err = if ok then nil else v })
end

-- Fraction of `list` for which `fn(e)` holds, each in a fresh world.
local function each(list, fn, world_opts): number
	local good = 0
	for _, e in list do
		new_world(world_opts)
		local ok, v = pcall(fn, e)
		if ok and v == true then
			good += 1
		elseif not ok then
			log("CASE RAISED", e.name, v)
		end
		all_errors += #W.errors
	end
	return good / #list
end

-- Loading ------------------------------------------------------------------

check("window half loads", 2, function()
	local _, ok = load_window()
	return ok and #W.errors == 0
end)

check("host half loads and defines the block", 1, function()
	local _, ok = load_host()
	return ok and W.blocks.profiles ~= nil
end)

check("command ids are unique", 1, function()
	load_window()
	return #W.command_order > 0 and #W.dup_ids == 0
end)

-- Discovery and the picker (unchanged UX) ----------------------------------

check("switch command opens a picker", 2, function()
	local vm = load_window()
	run_command(vm, "switch")
	return #W.picks == 1
end)

for _, e in EXPECTED do
	check("picker lists " .. e.b.token .. " / " .. e.name, 1, function()
		local vm = load_window()
		run_command(vm, "switch")
		local opts = last_pick()
		return opts ~= nil and find_item(opts, e) ~= nil
	end)
end

check("picker hides drift, hostile and uninstalled profiles", 2, function()
	local vm = load_window()
	run_command(vm, "switch")
	local opts = last_pick()
	if opts == nil then
		return false
	end
	for _, it in opts.items do
		local text = item_text(it)
		for _, bad in FORBIDDEN_TEXT do
			if contains(text, bad) then
				return false
			end
		end
	end
	return true
end)

check("picker groups items by browser", 1, function()
	local vm = load_window()
	run_command(vm, "switch")
	local opts = last_pick()
	if opts == nil then
		return false
	end
	local seen_group = {}
	local last = nil
	for _, e in EXPECTED do
		local it = find_item(opts, e)
		if it == nil or type(it.group) ~= "string" or not contains(it.group, e.b.token) then
			return false
		end
	end
	for _, it in opts.items do
		if it.group ~= last then
			if seen_group[it.group] then
				return false
			end
			seen_group[it.group] = true
			last = it.group
		end
	end
	return true
end)

check("picker shows signed-in accounts", 2, function()
	local vm = load_window()
	run_command(vm, "switch")
	local opts = last_pick()
	if opts == nil then
		return false
	end
	local n, good = 0, 0
	for _, e in EXPECTED do
		if e.account ~= "" then
			n += 1
			local it = find_item(opts, e)
			if it and contains(item_text(it), e.account) then
				good += 1
			end
		end
	end
	return good / n
end)

check("picker says profiles open in Tern", 1, function()
	local vm = load_window()
	run_command(vm, "switch")
	local opts = last_pick()
	local def = W.commands.switch
	return opts ~= nil and (contains(opts.placeholder, "Tern") or (def ~= nil and contains(def.title, "Tern")))
end)

check("dismissing the picker does nothing", 2, function()
	local vm = load_window()
	W.pick_answer = nil
	run_command(vm, "switch")
	return #W.picks == 1 and #W.browser_ops == 0 and #W.procs == 0 and #W.toasts == 0
end)

check("Chrome-only setup speaks of Chrome, not browsers", 2, function()
	local vm = load_window()
	local def = W.commands.switch
	if def == nil or string.sub(def.title, 1, 6) ~= "Chrome" then
		return false
	end
	for _, id in W.command_order do
		if contains(W.commands[id].title, "Browser") then
			return false
		end
	end
	run_command(vm, "switch")
	local opts = last_pick()
	if opts == nil or #opts.items ~= 2 then
		return false
	end
	for _, it in opts.items do
		if it.group ~= nil then
			return false
		end
	end
	return find_item(opts, expected_named("Chrome Main")) ~= nil and find_item(opts, expected_named("Chrome Client")) ~= nil
end, { only_apps = { ["Google Chrome.app"] = true } })

check("switcher has a default key binding", 1, function()
	load_window()
	local action = "plugin." .. PLUGIN_ID .. ".switch"
	for _, b in W.binds do
		if b.action == action then
			return true
		end
	end
	local def = W.commands.switch
	return def ~= nil and type(def.keys) == "table" and #def.keys > 0
end)

-- Opening a profile inside Tern ---------------------------------------------

check("switch opens the chosen profile inside Tern, signed in", 6, function()
	return each(EXPECTED_OK, function(e)
		local vm = load_window()
		open_via_switch(vm, e)
		return first_open_ok(e)
	end)
end)

check("first open copies every live site cookie with the browser's own Keychain item", 6, function()
	local cases = {}
	for _, e in EXPECTED_OK do
		-- Profiles whose source holds live encrypted cookies: those need the key.
		local cs = cookie_spec(e)
		local needs_key = false
		for _, row in (if cs then cs.rows else {}) do
			if row.encrypt and row.expires ~= "past" then
				needs_key = true
			end
		end
		if needs_key then
			table.insert(cases, e)
		end
	end
	return each(cases, function(e)
		local vm = load_window()
		open_via_switch(vm, e)
		local reads = keychain_reads()
		for _, s in reads do
			if s ~= e.b.keychain then
				return false
			end
		end
		return #reads >= 1 and store_exact(e) and not toasts_leak_secrets()
	end)
end)

check("the profile opens docked beside the focused pane", 2, function()
	local vm = load_window()
	local e = expected_named("Chrome Main")
	open_via_switch(vm, e)
	local blocks = live_blocks(store_name(e))
	return #blocks == 1 and blocks[1].docked and blocks[1].owner == TERMINAL_PANE and blocks[1].dock_target == TERMINAL_PANE
end)

check("a focused float opens the profile beside the pane under it", 1, function()
	local vm = load_window()
	local e = expected_named("Chrome Client")
	open_via_switch(vm, e)
	local blocks = live_blocks(store_name(e))
	return #blocks == 1 and blocks[1].docked and blocks[1].dock_target == TERMINAL_PANE and signed_in_at(e, HOME_PAGE)
end, { float = true })

check("a fresh profile without a cookie database opens without a Keychain prompt", 2, function()
	local vm = load_window()
	local e = expected_named("Personal")
	open_via_switch(vm, e)
	if not (#keychain_reads() == 0 and first_open_ok(e)) then
		return false
	end
	open_via_switch(vm, e)
	return python_runs() == 1 and signed_in_at(e, HOME_PAGE)
end)

check("expired-only and plaintext-only sources read no Keychain", 2, function()
	return each({ expected_named("Vivaldi Daily"), expected_named("Helium Lite") }, function(e)
		local vm = load_window()
		open_via_switch(vm, e)
		return #keychain_reads() == 0 and first_open_ok(e)
	end)
end)

check("reopening uses the saved Tern profile without exporting again", 5, function()
	local vm = load_window()
	local e = expected_named("Chrome Main")
	open_via_switch(vm, e)
	if not first_open_ok(e) then
		return 0
	end
	local parts = 0
	local writes = ops_of("setCookie")
	local navs = navs_of(store_name(e))
	open_via_switch(vm, e)
	if python_runs() == 1 and ops_of("setCookie") == writes and navs_of(store_name(e)) > navs and store_exact(e) then
		parts += 1
	end
	-- A new window (or plugin reload) still knows the profile is set up.
	navs = navs_of(store_name(e))
	local vm2 = load_window()
	local id = profile_command(e)
	if id then
		run_command(vm2, id)
	end
	if id and python_runs() == 1 and ops_of("setCookie") == writes and navs_of(store_name(e)) > navs and store_exact(e) then
		parts += 1
	end
	return parts / 2
end)

check("each source profile gets its own Tern store", 4, function()
	local vm = load_window()
	local list = { expected_named("Chrome Main"), expected_named("Work"), expected_named("Chrome Client"), expected_named("Edge Work") }
	for _, e in list do
		open_via_switch(vm, e)
	end
	local named = 0
	for name in W.stores do
		if name ~= "" then
			named += 1
		end
	end
	if named ~= #list or not default_untouched() then
		return false
	end
	for _, e in list do
		if not store_exact(e) or not signed_in_at(e, HOME_PAGE) or #live_blocks(store_name(e)) ~= 1 then
			return false
		end
	end
	return python_runs() == #list
end)

check("Tern's own browser store and block are never touched", 3, function()
	local vm = load_window()
	local e = expected_named("Chrome Main")
	open_via_switch(vm, e)
	W.pick_answer = choose(expected_named("Edge Work"))
	run_command(vm, "links")
	click(vm, "https://example.org/a", NO_MODS)
	W.pick_answer = choose(expected_named("Work"))
	run_command(vm, "import")
	return default_untouched() and store_exact(e) and store_exact(expected_named("Edge Work")) and store_exact(expected_named("Work"))
end, { browser_block = true })

check("per-profile palette commands open inside Tern without a picker", 3, function()
	return each(EXPECTED_OK, function(e)
		local vm = load_window()
		local id = profile_command(e)
		if id == nil then
			return false
		end
		run_command(vm, id)
		return #W.picks == 0 and first_open_ok(e)
	end)
end)

check("picker sees a profile created after the window started", 2, function()
	local vm = load_window()
	run_command(vm, "switch")
	local state_path = SUPPORT .. "/Google/Chrome/Local State"
	local original = fs.readFile(state_path)
	local data = serde.decode("json", original)
	data.profile.info_cache["Profile 5"] = { name = "Chrome Fresh", user_name = "" }
	table.insert(data.profile.profiles_order, "Profile 5")
	fs.writeDir(SUPPORT .. "/Google/Chrome/Profile 5")
	fs.writeFile(state_path, serde.encode("json", data))
	local ok, res = pcall(function()
		run_command(vm, "switch")
		local opts = last_pick()
		local fresh = { b = BROWSERS.chrome, dir = "Profile 5", name = "Chrome Fresh", account = "" }
		if opts == nil or find_item(opts, fresh) == nil then
			return false
		end
		open_via_switch(vm, fresh)
		return store_exact(fresh) and signed_in_at(fresh, HOME_PAGE) and error_toasts() == 0
	end)
	fs.writeFile(state_path, original)
	fs.removeDir(SUPPORT .. "/Google/Chrome/Profile 5")
	return ok and res
end)

-- Failures never pass for a sign-in ----------------------------------------

check("refused Keychain access: no page, no block left, retry works", 4, function()
	local vm = load_window()
	local e = expected_named("Chrome Main")
	W.keychain = KEYCHAIN_DENIED
	open_via_switch(vm, e)
	local parts = 0
	if failed_cleanly(e) and ops_of("setCookie") == 0 and not toasts_leak_secrets() then
		parts += 1
	end
	if retry_succeeds(vm, e) then
		parts += 1
	end
	return parts / 2
end)

check("undecryptable source cookies fail without a half sign-in", 2, function()
	local vm = load_window()
	local e = expected_named("Chromium Dev")
	open_via_switch(vm, e)
	return failed_cleanly(e) and store_size(W.stores[store_name(e)] or {}) == 0
end)

check("a cookie Tern's browser rejects fails the copy and stays retryable", 4, function()
	local vm = load_window()
	local e = expected_named("Chrome Main")
	W.reject_cookie = "tok"
	open_via_switch(vm, e)
	local parts = 0
	if failed_cleanly(e) and not toasts_leak_secrets() then
		parts += 1
	end
	if retry_succeeds(vm, e) then
		parts += 1
	end
	return parts / 2
end)

check("a native cookie write that errors or raises never counts as signed in", 3, function()
	local good = 0
	for _, mode in { "nil", "raise" } do
		new_world()
		local vm = load_window()
		local e = expected_named("Edge Work")
		W.fail.setCookie = mode
		open_via_switch(vm, e)
		local clean = navs_of(store_name(e)) == 0 and #W.fallthroughs == 0
		W.errors = {}
		if clean and retry_succeeds(vm, e) then
			good += 1
		end
	end
	return good / 2
end)

check("a failed Tern browser open explains and stays retryable", 2, function()
	local vm = load_window()
	local e = expected_named("Work")
	W.fail.open = true
	open_via_switch(vm, e)
	return failed_cleanly(e) and retry_succeeds(vm, e)
end)

check("a window closed mid-copy writes nothing and stays retryable", 2, function()
	local vm = load_window()
	local e = expected_named("Work")
	W.gone_on_process = true
	open_via_switch(vm, e)
	local quiet = ops_of("setCookie") == 0 and navs_of(store_name(e)) == 0 and #live_blocks(store_name(e)) == 0
	return quiet and retry_succeeds(vm, e)
end)

-- Link routing --------------------------------------------------------------

check("link route is registered and idle by default", 2, function()
	local vm = load_window()
	local res, has = click(vm, "https://example.org/a", NO_MODS)
	return has and not claimed(res) and #W.browser_ops == 0 and #W.procs == 0
end)

check("links picker opens plain clicks inside Tern in that profile", 4, function()
	local vm = load_window()
	local e = expected_named("Edge Work")
	W.pick_answer = choose(e)
	if not run_command(vm, "links") or #W.picks == 0 then
		return false
	end
	-- Two plain clicks before any exporter/Keychain/cookie callback settles:
	-- both pages open in the profile's store, after one export.
	local parts = 0
	local ra = route_link("https://example.org/a", TERMINAL_PANE, NO_MODS)
	local rb = route_link("https://example.org/b", TERMINAL_PANE, NO_MODS)
	drain()
	if claimed(ra) and claimed(rb) and first_open_ok(e, "https://example.org/a") and signed_in_at(e, "https://example.org/b") then
		parts += 1
	end
	local res = click(vm, "https://example.org/c", NO_MODS)
	if claimed(res) and python_runs() == 1 and signed_in_at(e, "https://example.org/c") and error_toasts() == 0 then
		parts += 1
	end
	return parts / 2
end)

check("modifier clicks and non-http links fall through", 2, function()
	local vm = load_window()
	W.pick_answer = choose(expected_named("Edge Home"))
	if not run_command(vm, "links") then
		return false
	end
	local fails = 0
	for _, m in { "cmd", "alt", "shift", "ctrl" } do
		local mods = table.clone(NO_MODS)
		mods[m] = true
		if claimed((click(vm, "https://example.org/a", mods))) then
			fails += 1
		end
	end
	for _, u in { "file:///etc/passwd", "javascript:alert(1)", "mailto:a@b.test", "chrome://settings" } do
		if claimed((click(vm, u, NO_MODS))) then
			fails += 1
		end
	end
	return fails == 0 and ops_of("open") == 0 and #W.procs == 0
end)

check("links picker can hand links back to Tern", 2, function()
	local vm = load_window()
	W.pick_answer = choose(expected_named("Edge Home"))
	if not run_command(vm, "links") then
		return false
	end
	local stop_seen = false
	W.pick_answer = function(opts)
		for _, it in opts.items do
			if contains(item_text(it), "Tern") then
				stop_seen = true
				return it
			end
		end
		return nil
	end
	run_command(vm, "links")
	local res = click(vm, "https://example.org/b", NO_MODS)
	return stop_seen and not claimed(res) and ops_of("open") == 0 and #W.procs == 0
end)

check("links picker marks the current target", 1, function()
	local vm = load_window()
	local e = expected_named("Edge Home")
	W.pick_answer = choose(e)
	if not run_command(vm, "links") then
		return false
	end
	W.pick_answer = nil
	run_command(vm, "links")
	local opts = last_pick()
	local it = opts and find_item(opts, e)
	if not it or it.current ~= true then
		return false
	end
	for _, other in opts.items do
		if other ~= it and other.current == true then
			return false
		end
	end
	return true
end)

check("routing to a deleted source profile clears the route", 2, function()
	local vm = load_window()
	local e = expected_named("Chrome Client")
	W.pick_answer = choose(e)
	if not run_command(vm, "links") then
		return false
	end
	local dir = SUPPORT .. "/Google/Chrome/Profile 2"
	local moved = dir .. ".moved"
	fs.move(dir, moved)
	local ok, res = pcall(click, vm, "https://example.org/c", NO_MODS)
	fs.move(moved, dir)
	if not ok or claimed(res) then
		return false
	end
	-- The profile is back, but the route was dropped, not left pending.
	local again = click(vm, "https://example.org/d", NO_MODS)
	return not claimed(again) and ops_of("open") == 0 and #W.procs == 0
end)

-- Copying sign-ins again ----------------------------------------------------

check("copy sign-ins again refreshes only the chosen profile's store", 4, function()
	local vm = load_window()
	local e = expected_named("Chrome Main")
	open_via_switch(vm, e)
	if not store_exact(e) then
		return false
	end
	-- Signed out of one site in Tern, and set a Tern-only cookie meanwhile.
	local store = W.stores[store_name(e)]
	for key, c in store do
		if c.name == "sid" then
			store[key] = nil
		end
	end
	store[".tern.test|/|tern_only"] = { name = "tern_only", value = "kept", domain = ".tern.test", path = "/" }
	W.pick_answer = choose(e)
	run_command(vm, "import")
	local got = store_values(store_name(e))
	local want = table.clone(expected_cookies(e))
	want.tern_only = "kept"
	return python_runs() == 2 and same_map(got, want) and #live_blocks(store_name(e)) >= 1 and default_untouched() and error_toasts() == 0
end, { browser_block = true })

check("copy sign-ins again needs no focused browser page", 1, function()
	local vm = load_window()
	local e = expected_named("Edge Work")
	W.pick_answer = choose(e)
	run_command(vm, "import")
	return python_runs() == 1 and store_exact(e) and #live_blocks(store_name(e)) >= 1 and error_toasts() == 0
end)

check("error toasts never carry cookie values", 1, function()
	local vm = load_window()
	open_via_switch(vm, expected_named("Chrome Main"))
	W.reject_cookie = "bsid"
	open_via_switch(vm, expected_named("Work"))
	W.keychain = KEYCHAIN_DENIED
	open_via_switch(vm, expected_named("Edge Work"))
	return #W.toasts > 0 and not toasts_leak_secrets()
end)

-- The host block -------------------------------------------------------------

local function block_setup()
	local hvm = load_host()
	local def = W.blocks.profiles
	assert(def, "no block")
	local cx = make_block_cx(hvm)
	local state = def.init(cx, {}, nil)
	return def, cx, state
end

local function block_item(def, state, cx, e)
	local view = def.view(state, cx)
	for _, it in keyed_items("main", view.main) do
		if profile_text_ok(it.text, e) then
			return it
		end
	end
	return nil
end

check("block lists every profile", 2, function()
	local def, cx, state = block_setup()
	local text = text_of(def.view(state, cx))
	local good = 0
	for _, e in EXPECTED do
		if contains(text, e.name) then
			good += 1
		end
	end
	for _, bad in FORBIDDEN_TEXT do
		if contains(text, bad) then
			return 0
		end
	end
	return good / #EXPECTED
end)

check("block Enter opens the profile inside Tern", 3, function()
	load_window()
	local def, cx, state = block_setup()
	local e = expected_by_id(block_selected(def.view(state, cx)))
	if e == nil then
		return false
	end
	def.key(state, { name = "enter", ctrl = false, alt = false, shift = false, meta = false }, cx)
	drain()
	if copy_fails(e) then
		return failed_cleanly(e)
	end
	return first_open_ok(e) and #W.fallthroughs == 0
end)

check("block row activation opens that profile inside Tern", 2, function()
	load_window()
	local def, cx, state = block_setup()
	local e = expected_named("Chrome Client")
	local it = block_item(def, state, cx, e)
	if it == nil then
		return false
	end
	def.event(state, { ev = "activate", id = it.list_id, item = it.id }, cx)
	drain()
	return first_open_ok(e) and #W.fallthroughs == 0
end)

check("block keys move and open distinct profiles", 2, function()
	load_window()
	local def, cx, state = block_setup()
	local k = function(name)
		return def.key(state, { name = name, ctrl = false, alt = false, shift = false, meta = false }, cx)
	end
	local first = expected_by_id(block_selected(def.view(state, cx)))
	k("enter")
	drain()
	k("down")
	local second = expected_by_id(block_selected(def.view(state, cx)))
	k("enter")
	drain()
	if first == nil or second == nil or first == second then
		return false
	end
	return #live_blocks(store_name(first)) == 1 and #live_blocks(store_name(second)) == 1
end)

check("block 'l' routes links into Tern", 2, function()
	local wvm = load_window()
	local def, cx, state = block_setup()
	local e = expected_named("Chrome Main")
	local target = block_item(def, state, cx, e)
	if target == nil then
		return false
	end
	if def.event then
		def.event(state, { ev = "select", id = target.list_id, item = target.id }, cx)
	end
	def.key(state, { name = "l", text = "l", ctrl = false, alt = false, shift = false, meta = false }, cx)
	drain()
	local res = click(wvm, "https://example.org/d", NO_MODS)
	return claimed(res) and first_open_ok(e, "https://example.org/d")
end)

check("forged or replayed block opens import nothing", 3, function()
	local wvm = load_window()
	local def, cx, state = block_setup()
	local e = expected_named("Chrome Client")
	local it = block_item(def, state, cx, e)
	if it == nil then
		return false
	end
	W.hold_host_open = true
	def.event(state, { ev = "activate", id = it.list_id, item = it.id }, cx)
	drain()
	local uri = W.host_opens[#W.host_opens]
	if type(uri) ~= "string" then
		return false
	end
	local parts = 0
	local function nothing(f)
		local opens, runs = ops_of("open"), python_runs()
		f()
		drain()
		return ops_of("open") == opens and python_runs() == runs
	end
	-- From another pane than the block that asked.
	if nothing(function()
		route_link(uri, TERMINAL_PANE, NO_MODS)
	end) then
		parts += 1
	end
	-- The real request from the block opens the profile …
	route_link(uri, BLOCK_PANE, NO_MODS)
	drain()
	if signed_in_at(e, HOME_PAGE) and store_exact(e) then
		parts += 1
	end
	-- … once: a replay does nothing.
	if nothing(function()
		route_link(uri, BLOCK_PANE, NO_MODS)
	end) then
		parts += 1
	end
	-- Nor does the same URI in a window no block asked.
	new_world()
	load_window()
	if nothing(function()
		route_link(uri, BLOCK_PANE, NO_MODS)
	end) then
		parts += 1
	end
	return parts / 4
end)

-- Robustness ---------------------------------------------------------------

check("no HOME: loads and the switcher explains", 2, function()
	local vm, ok = load_window()
	if not ok then
		return false
	end
	run_command(vm, "switch")
	return #W.errors == 0 and #W.browser_ops == 0 and #W.procs == 0 and (#W.toasts > 0 or #W.picks > 0)
end, { home = false })

check("no browsers installed: the switcher explains", 1, function()
	local vm, ok = load_window()
	if not ok or W.commands.switch == nil then
		return false
	end
	run_command(vm, "switch")
	return #W.errors == 0 and #W.toasts > 0 and #W.browser_ops == 0 and #W.procs == 0
end, { apps = false })

------------------------------------------------------------------------------
-- Efficiency (op-weighted cost of the hot paths).

local metrics = {}

local function median(xs)
	table.sort(xs)
	return xs[math.ceil(#xs / 2)]
end

do
	new_world()
	local s = snapshot()
	local vm = load_window()
	metrics.ws_cost = cost_since(s)

	s = snapshot()
	local rows = 0
	for _, id in W.command_order do
		local def = W.commands[id]
		local visible = true
		if def.available then
			local ok, v = pcall(def.available, vm.cx)
			visible = ok and v == true
		end
		if visible then
			rows += 1
		end
	end
	metrics.avail_cost = cost_since(s)
	metrics.palette_rows = rows
	metrics.palette_commands = #W.command_order

	s = snapshot()
	for _, fn in W.status_fns do
		pcall(fn, { pane = TERMINAL_PANE, title = "zsh", cwd = HOME, kind = "terminal", program = "zsh", busy = false })
	end
	metrics.status_cost = cost_since(s)

	-- First open of a profile with cookies on four sites: export + import.
	local main = expected_named("Chrome Main")
	s = snapshot()
	open_via_switch(vm, main)
	metrics.cold_open_cost = cost_since(s)

	s = snapshot()
	open_via_switch(vm, main)
	metrics.warm_open_cost = cost_since(s)

	s = snapshot()
	click(vm, "https://example.org/x", NO_MODS)
	metrics.link_off_cost = cost_since(s)

	W.pick_answer = choose(main)
	run_command(vm, "links")
	s = snapshot()
	click(vm, "https://example.org/y", NO_MODS)
	metrics.link_on_cost = cost_since(s)

	W.pick_answer = choose(main)
	s = snapshot()
	run_command(vm, "import")
	metrics.recopy_cost = cost_since(s)

	new_world()
	local hvm = load_host()
	s = snapshot()
	local def = W.blocks.profiles
	if def then
		local cx = make_block_cx(hvm)
		pcall(function()
			local state = def.init(cx, {}, nil)
			def.view(state, cx)
		end)
	end
	metrics.block_cost = cost_since(s)

	-- Wall-clock (informational; noisy). cold_open_ms includes the exporter.
	local ws, pk, co = {}, {}, {}
	for i = 1, 7 do
		new_world()
		local t0 = os.clock()
		local v = load_window()
		table.insert(ws, (os.clock() - t0) * 1000)
		t0 = os.clock()
		W.pick_answer = nil
		run_command(v, "switch")
		table.insert(pk, (os.clock() - t0) * 1000)
		if i <= 3 then
			local w0 = os.clock()
			open_via_switch(v, main)
			table.insert(co, (os.clock() - w0) * 1000)
		end
	end
	metrics.ws_ms = median(ws)
	metrics.pick_ms = median(pk)
	metrics.cold_open_ms = median(co)
end

-- Every scenario above, judged once all have run.
check("no external browser is ever launched; profiles open in Tern", 4, function()
	if #EXTERNAL_LAUNCHES > 0 then
		log("external launches", table.concat(EXTERNAL_LAUNCHES, " | "))
	end
	return #EXTERNAL_LAUNCHES == 0 and TERN_OPENS > 0
end)

local io_cost = metrics.ws_cost
	+ metrics.avail_cost
	+ 2 * metrics.status_cost
	+ metrics.cold_open_cost
	+ 3 * metrics.warm_open_cost
	+ 5 * metrics.link_off_cost
	+ 2 * metrics.link_on_cost
	+ 0.5 * metrics.recopy_cost
	+ metrics.block_cost
	+ 0.5 * metrics.palette_rows

------------------------------------------------------------------------------
-- Report.

local failed = {}
for _, r in results do
	local mark = if r.frac >= 1 then "PASS" elseif r.frac > 0 then "PART" else "FAIL"
	if r.frac < 1 then
		table.insert(failed, r.name)
	end
	local extra = if r.err then "  (raised: " .. tostring(r.err) .. ")" elseif r.errors > 0 then "  (" .. r.errors .. " Lua errors)" else ""
	print(string.format("%s %4.1f/%-2d %s%s", mark, r.weight * r.frac, r.weight, r.name, extra))
end
local unmocked = {}
for k in W.unmocked do
	table.insert(unmocked, k)
end
if #unmocked > 0 then
	print("unmocked APIs touched: " .. table.concat(unmocked, ", "))
end

local function fmt(x: number): string
	return string.format("%.3f", x)
end

local score = 10 * spec_points - io_cost
print("METRIC score=" .. fmt(score))
print("METRIC spec_points=" .. fmt(spec_points))
print("METRIC spec_max=" .. fmt(spec_max))
print("METRIC checks_failed=" .. #failed)
print("METRIC io_cost=" .. fmt(io_cost))
for _, k in {
	"ws_cost", "avail_cost", "status_cost", "cold_open_cost", "warm_open_cost", "link_off_cost", "link_on_cost",
	"recopy_cost", "block_cost", "palette_rows", "palette_commands", "ws_ms", "pick_ms", "cold_open_ms",
} do
	print("METRIC " .. k .. "=" .. fmt(metrics[k]))
end
print("METRIC external_launches=" .. #EXTERNAL_LAUNCHES)
print("METRIC lua_errors=" .. all_errors)
if #failed > 0 then
	print("ASI failed_checks=" .. serde.encode("json", failed))
end
