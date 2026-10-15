--!nocheck
-- Benchmark + behaviour harness for the brave-profiles Tern plugin.
--
--   lune run bench/harness.luau -- PLUGIN_DIR FIXTURE_ROOT
--
-- Loads the plugin's window and host halves into sandboxed VMs with a mocked
-- `tern` API backed by a fake macOS tree (bench/make_fixtures.py): system
-- apps under FIXTURE_ROOT/Applications (seen as /Applications), a real HOME
-- at FIXTURE_ROOT/home with Chromium-family browsers' "Local State" files.
-- Launches are recorded, never run; the cookie exporter runs for real through
-- bench/py_shim.py with a fake Keychain.
--
-- Contract the checks hold the plugin to (window half, action ids are
-- `plugin.brave-profiles.<id>`):
--   switch   palette command: cx:pick over every launchable profile of every
--            installed Chromium browser; the chosen item launches it.
--   links    palette command: cx:pick of routing targets (profiles plus an
--            item whose text contains "Tern" that stops routing).
--   import   palette command: cx:pick of profiles; copies the focused browser
--            block's site cookies from the chosen profile, then reloads it.
--   a palette command per profile whose title names the profile and browser.
--   tern.route.link: routes plain http(s) clicks to the chosen profile.
-- Host half: block `profiles` listing the same profiles.
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
-- Expected profiles (from the spec).

local BROWSERS = {}
for _, b in SPEC.browsers do
	BROWSERS[b.key] = b
end

local function app_path(b): string?
	if b.location == "system" then
		return "/Applications/" .. b.app
	elseif b.location == "home" then
		return HOME .. "/Applications/" .. b.app
	end
	return nil
end

local EXPECTED = {} -- launchable profiles {b, dir, name, account}
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

------------------------------------------------------------------------------
-- Op accounting.

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
}

local function snapshot()
	return table.clone(C)
end

local function cost_since(s): number
	local d = {}
	for k, v in C do
		d[k] = v - s[k]
	end
	return 3 * d.fs_read
		+ d.fs_exists
		+ 2 * d.fs_list
		+ 5 * d.fs_mut
		+ d.kv_get
		+ 2 * d.kv_set
		+ 25 * d.proc
		+ 0.1 * d.getenv
		+ d.timers
		+ (d.read_bytes + d.decode_bytes) / 32768
end

------------------------------------------------------------------------------
-- The world one scenario runs in.

local W

local function new_world(opts)
	opts = opts or {}
	W = {
		home = opts.home ~= false,
		apps = opts.apps ~= false,
		kv = {},
		procs = {},
		toasts = {},
		picks = {},
		pick_answer = nil,
		browser_ops = {},
		opens = {},
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
		focused = opts.focused or TERMINAL_PANE,
		panes = opts.panes or {
			{ pane = TERMINAL_PANE, kind = "terminal", title = "zsh", cwd = HOME },
		},
		unmocked = {},
	}
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
		return if W.apps then ROOT .. path else ROOT .. "/__noapps__" .. path
	end
	if path == HOME or string.sub(path, 1, #HOME + 1) == HOME .. "/" then
		local user_apps = HOME .. "/Applications"
		if not W.apps and (path == user_apps or string.sub(path, 1, #user_apps + 1) == user_apps .. "/") then
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
-- Processes.

local function basename(p: string): string
	return string.match(p, "([^/]+)$") or p
end

local function app_exists_named(name: string): boolean
	for _, b in SPEC.browsers do
		if b.location ~= nil and (b.app == name or b.app == name .. ".app" or b.bundle_id == name) then
			return true
		end
	end
	return false
end

local function run_python(argv, opts)
	local args = { PLUGIN .. "/bench/py_shim.py" }
	for i = 2, #argv do
		table.insert(args, argv[i])
	end
	local env = {
		BP_KEYCHAIN = ROOT .. "/keychain.json",
		BP_SHIM_LOG = ROOT .. "/shim.log",
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
	local exe = argv[1]
	local base = basename(exe)
	if string.match(base, "^python") then
		return run_python(argv, opts)
	end
	if exe == "open" or exe == "/usr/bin/open" then
		for i = 2, #argv do
			local a = argv[i]
			if a == "--args" then
				break
			end
			if string.sub(a, -4) == ".app" or string.sub(a, -5) == ".app/" then
				if not exists(real(a)) then
					return { status = 1, stdout = "", stderr = "Unable to find application " .. a, timed_out = false }
				end
			elseif (argv[i - 1] == "-a" or argv[i - 1] == "-b") and string.sub(a, 1, 1) ~= "/" then
				if not app_exists_named(a) then
					return { status = 1, stdout = "", stderr = "Unable to find application named '" .. a .. "'", timed_out = false }
				end
			end
		end
		return { status = 0, stdout = "", stderr = "", timed_out = false }
	end
	if contains(exe, ".app/Contents/MacOS/") then
		if not fs.isFile(real(exe)) then
			return { status = -1, stdout = "", stderr = "spawn failed: no such file", timed_out = false }
		end
		return { status = 0, stdout = "", stderr = "", timed_out = false }
	end
	return { status = 127, stdout = "", stderr = "harness: command not available: " .. exe, timed_out = false }
end

------------------------------------------------------------------------------
-- VMs.

local function deep_copy_json(v)
	if type(v) ~= "table" then
		return v
	end
	return serde.decode("json", serde.encode("json", v))
end

local new_vm

local function awaitable(vm, resolve)
	return {
		next = function(_, fn)
			enqueue(function()
				local r, e = resolve()
				fn(r, e, vm.cx)
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

local function make_window_cx(vm)
	local cx = {}
	cx.session = strict("cx.session", {
		focused = function(_)
			return W.focused
		end,
		panes = function(_)
			return W.panes
		end,
		pane = function(_, id)
			for _, p in W.panes do
				if p.pane == id or (id == "@focused" and p.pane == W.focused) then
					return p
				end
			end
			return nil
		end,
		resolve = function(_, spec)
			if spec == "@focused" then
				return W.focused
			end
			return nil
		end,
		tabs = function(_)
			return {}
		end,
	})
	cx.layout = strict("cx.layout", {
		focus = function(_, pane)
			table.insert(W.actions, "focus:" .. tostring(pane))
		end,
	})
	cx.browser = strict("cx.browser", {
		call = function(_, op)
			-- The op runs when called, whether or not the caller awaits it.
			table.insert(W.browser_ops, deep_copy_json(op))
			local res = (function()
				local kind = op.op
				if kind == "blocks" then
					local blocks = {}
					for _, p in W.panes do
						if p.kind == "browser" then
							table.insert(blocks, { block = p.pane, url = p.url, title = p.title })
						end
					end
					return { ok = { blocks = blocks } }, nil
				elseif kind == "setCookie" then
					local c = op.cookie
					if type(c) ~= "table" or type(c.name) ~= "string" or type(c.value) ~= "string" then
						return { error = "invalid cookie" }, nil
					end
					return { ok = {} }, nil
				elseif kind == "goto" or kind == "reload" then
					return { ok = {} }, nil
				elseif kind == "state" then
					for _, p in W.panes do
						if p.kind == "browser" and (op.block == nil or op.block == p.pane) then
							return { ok = { block = p.pane, url = p.url, title = p.title } }, nil
						end
					end
					return { error = "no browser block" }, nil
				end
				return { error = "harness: browser op " .. tostring(kind) .. " not mocked" }, nil
			end)()
			return awaitable(vm, function()
				return res, nil
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
			table.insert(W.opens, target)
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
			if cb then
				enqueue(function()
					cb(get(), vm.cx)
				end)
				return nil
			end
			return awaitable(vm, function()
				return get(), nil
			end)
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
				return { { pane = BLOCK_PANE, title = "Brave Profiles", program = BLOCK_KIND, cwd = HOME } }
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

local function launched(procs, e, url: string?): boolean
	local app = e.b.app
	local stem = string.sub(app, 1, -5)
	for _, p in procs do
		local has_app, has_dir, has_url = false, false, url == nil
		for _, a in p.argv do
			if a == stem or a == e.b.bundle_id or string.sub(a, -#app - 1) == "/" .. app or string.sub(a, -#app - 2) == "/" .. app .. "/" or contains(a, "/" .. app .. "/Contents/MacOS/") then
				has_app = true
			end
			if a == "--profile-directory=" .. e.dir then
				has_dir = true
			end
			if url ~= nil and a == url then
				has_url = true
			end
		end
		if has_app and has_dir and has_url then
			return true
		end
	end
	return false
end

local function launch_procs()
	local out = {}
	for _, p in W.procs do
		local b = basename(p.argv[1])
		if not string.match(b, "^python") then
			table.insert(out, p)
		end
	end
	return out
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

local function click(vm, url, mods)
	local route = W.link_routes[#W.link_routes]
	if route == nil then
		return nil, false
	end
	local req = { url = url, pane = TERMINAL_PANE, mods = mods or { cmd = false, alt = false, shift = false, ctrl = false } }
	local ok, res = pcall(route, req, vm.cx)
	if not ok then
		record_error("route.link", res)
		res = nil
	end
	drain()
	return res, true
end

local function claimed(res): boolean
	return type(res) == "table" and (res.handled == true or res.url ~= nil or res.block ~= nil)
end

local function with_browser_block(url: string)
	return {
		focused = BROWSER_PANE,
		panes = {
			{ pane = TERMINAL_PANE, kind = "terminal", title = "zsh", cwd = HOME },
			{ pane = BROWSER_PANE, kind = "browser", title = "Example", url = url, cwd = "" },
		},
	}
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

-- The switcher -------------------------------------------------------------

check("switch command opens a picker", 4, function()
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

check("picking launches the chosen browser + profile", 4, function()
	local good = 0
	for _, e in EXPECTED do
		new_world()
		local vm = load_window()
		W.pick_answer = choose(e)
		run_command(vm, "switch")
		local procs = launch_procs()
		if #procs == 1 and launched(procs, e) and #W.errors == 0 then
			local bad_toast = false
			for _, t in W.toasts do
				if t.level == "error" then
					bad_toast = true
				end
			end
			if not bad_toast then
				good += 1
			end
		end
	end
	return good / #EXPECTED
end)

check("dismissing the picker does nothing", 2, function()
	local vm = load_window()
	W.pick_answer = nil
	run_command(vm, "switch")
	return #W.picks == 1 and #launch_procs() == 0 and #W.toasts == 0
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
	-- groups are contiguous runs
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
		W.pick_answer = choose(fresh)
		W.procs = {}
		run_command(vm, "switch")
		return launched(launch_procs(), fresh)
	end)
	fs.writeFile(state_path, original)
	fs.removeDir(SUPPORT .. "/Google/Chrome/Profile 5")
	return ok and res
end)

check("switcher has a default key binding", 2, function()
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

-- Direct palette commands ---------------------------------------------------

check("one palette command per profile opens it", 3, function()
	local good = 0
	for _, e in EXPECTED do
		new_world()
		local vm = load_window()
		local hit = nil
		for _, id in W.command_order do
			local def = W.commands[id]
			if id ~= "switch" and contains(def.title, e.name) and contains(def.title, e.b.token) and not contains(string.lower(def.title), "link") and not contains(string.lower(def.title), "cookie") then
				hit = id
				break
			end
		end
		if hit then
			run_command(vm, hit)
			local procs = launch_procs()
			if #W.picks == 0 and #procs == 1 and launched(procs, e) then
				good += 1
			end
		end
	end
	return good / #EXPECTED
end)

-- Link routing -------------------------------------------------------------

local NO_MODS = { cmd = false, alt = false, shift = false, ctrl = false }

check("link route is registered and idle by default", 2, function()
	local vm = load_window()
	local res, has = click(vm, "https://example.org/a", NO_MODS)
	return has and not claimed(res) and #launch_procs() == 0
end)

check("links picker routes clicks to the chosen profile", 3, function()
	local vm = load_window()
	local e = expected_named("Edge Home")
	W.pick_answer = choose(e)
	if not run_command(vm, "links") or #W.picks == 0 then
		return false
	end
	local res = click(vm, "https://example.org/a", NO_MODS)
	local procs = launch_procs()
	return claimed(res) and #procs == 1 and launched(procs, e, "https://example.org/a")
end)

check("modifier clicks and non-http links stay in Tern", 2, function()
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
	return fails == 0 and #launch_procs() == 0
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
	return stop_seen and not claimed(res) and #launch_procs() == 0
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

check("routing to a deleted profile lets the click through", 2, function()
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
	return ok and not claimed(res) and #launch_procs() == 0
end)

check("block 'l' routes links for the window", 2, function()
	local hvm = load_host()
	local def = W.blocks.profiles
	if def == nil then
		return false
	end
	local cx = make_block_cx(hvm)
	local state = def.init(cx, {}, nil)
	local view = def.view(state, cx)
	local e = expected_named("Chrome Main")
	local target = nil
	for _, it in keyed_items("main", view.main) do
		if profile_text_ok(it.text, e) then
			target = it
		end
	end
	if target == nil then
		return false
	end
	if def.event then
		def.event(state, { ev = "select", id = target.list_id, item = target.id }, cx)
	end
	def.key(state, { name = "l", text = "l", ctrl = false, alt = false, shift = false, meta = false }, cx)
	drain()
	local wvm = load_window()
	local res = click(wvm, "https://example.org/d", NO_MODS)
	return claimed(res) and launched(launch_procs(), e, "https://example.org/d")
end)

-- Cookie import ------------------------------------------------------------

local function import_check(cookie_spec)
	return function()
		local vm = load_window()
		local b = BROWSERS[cookie_spec.browser]
		local e = nil
		for _, x in EXPECTED do
			if x.b == b and x.dir == cookie_spec.profile then
				e = x
			end
		end
		assert(e, "spec cookie profile not expected")
		W.pick_answer = choose(e)
		if not run_command(vm, "import") then
			return false
		end
		local got, order_ok, reloaded = {}, true, false
		local count = 0
		for _, op in W.browser_ops do
			if op.op == "setCookie" then
				if reloaded or op.block ~= BROWSER_PANE then
					order_ok = false
				end
				got[op.cookie.name] = op.cookie.value
				count += 1
			elseif (op.op == "goto" or op.op == "reload") and op.block == BROWSER_PANE then
				reloaded = true
			end
		end
		local n = 0
		for name, value in cookie_spec.expected do
			n += 1
			if got[name] ~= value then
				return false
			end
		end
		for _, t in W.toasts do
			for _, value in cookie_spec.expected do
				if contains(t.text, value) or contains(t.sub, value) then
					return false
				end
			end
		end
		log("import", cookie_spec.browser, "cookies", count, "of", n, "order_ok", order_ok, "reloaded", reloaded)
		return count == n and order_ok and reloaded
	end
end

for i, cs in SPEC.cookies do
	check(
		"import signs the browser block in with " .. cs.browser .. " cookies",
		if i == 1 then 4 else 2,
		import_check(cs),
		with_browser_block(cs.focused_url)
	)
end

check("import without a focused browser block explains itself", 1, function()
	local vm = load_window()
	W.pick_answer = choose(expected_named("Chrome Main"))
	if not run_command(vm, "import") then
		return false
	end
	local python = #W.procs - #launch_procs()
	return python == 0 and #W.toasts > 0
end)

-- Block --------------------------------------------------------------------

local function block_setup()
	local hvm = load_host()
	local def = W.blocks.profiles
	assert(def, "no block")
	local cx = make_block_cx(hvm)
	local state = def.init(cx, {}, nil)
	return def, cx, state
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

check("block row activation launches that profile", 2, function()
	local def, cx, state = block_setup()
	local view = def.view(state, cx)
	local e = expected_named("Chrome Client")
	for _, it in keyed_items("main", view.main) do
		if profile_text_ok(it.text, e) then
			def.event(state, { ev = "activate", id = it.list_id, item = it.id }, cx)
			drain()
			local procs = launch_procs()
			return #procs == 1 and launched(procs, e)
		end
	end
	return false
end)

check("block keys move and open", 2, function()
	local def, cx, state = block_setup()
	local k = function(name)
		return def.key(state, { name = name, ctrl = false, alt = false, shift = false, meta = false }, cx)
	end
	def.view(state, cx)
	k("enter")
	drain()
	local first = launch_procs()
	if #first ~= 1 then
		return false
	end
	W.procs = {}
	k("down")
	def.view(state, cx)
	k("enter")
	drain()
	local second = launch_procs()
	if #second ~= 1 then
		return false
	end
	local a = table.concat(first[1].argv, "\0")
	local b = table.concat(second[1].argv, "\0")
	return a ~= b and contains(b, "--profile-directory=")
end)

-- Robustness ---------------------------------------------------------------

check("no HOME: loads and the switcher explains", 2, function()
	local vm, ok = load_window()
	if not ok then
		return false
	end
	run_command(vm, "switch")
	return #W.errors == 0 and #launch_procs() == 0 and (#W.toasts > 0 or #W.picks > 0)
end, { home = false })

check("no browsers installed: the switcher explains", 1, function()
	local vm, ok = load_window()
	if not ok or W.commands.switch == nil then
		return false
	end
	run_command(vm, "switch")
	return #W.errors == 0 and #W.toasts > 0 and #launch_procs() == 0
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

	s = snapshot()
	W.pick_answer = choose(expected_named("Chrome Client"))
	run_command(vm, "switch")
	metrics.switch_cost = cost_since(s)

	s = snapshot()
	click(vm, "https://example.org/x", NO_MODS)
	metrics.link_off_cost = cost_since(s)

	W.pick_answer = choose(expected_named("Edge Home"))
	run_command(vm, "links")
	s = snapshot()
	click(vm, "https://example.org/y", NO_MODS)
	metrics.link_on_cost = cost_since(s)

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

	-- Wall-clock (informational; noisy).
	local ws, pk = {}, {}
	for _ = 1, 7 do
		new_world()
		local t0 = os.clock()
		local v = load_window()
		table.insert(ws, (os.clock() - t0) * 1000)
		t0 = os.clock()
		W.pick_answer = nil
		run_command(v, "switch")
		table.insert(pk, (os.clock() - t0) * 1000)
	end
	metrics.ws_ms = median(ws)
	metrics.pick_ms = median(pk)
end

local io_cost = metrics.ws_cost
	+ metrics.avail_cost
	+ 2 * metrics.status_cost
	+ metrics.switch_cost
	+ 5 * metrics.link_off_cost
	+ 2 * metrics.link_on_cost
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
for _, k in { "ws_cost", "avail_cost", "status_cost", "switch_cost", "link_off_cost", "link_on_cost", "block_cost", "palette_rows", "palette_commands", "ws_ms", "pick_ms" } do
	print("METRIC " .. k .. "=" .. fmt(metrics[k]))
end
print("METRIC lua_errors=" .. all_errors)
if #failed > 0 then
	print("ASI failed_checks=" .. serde.encode("json", failed))
end
