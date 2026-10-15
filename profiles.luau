--!strict
-- Shared by both halves: the installed Chromium browsers, their profiles and
-- the launcher.
--
-- Reads only the profile directory names, display names and signed-in
-- addresses from each browser's "Local State" file. No cookies, tokens,
-- history or other profile data are read (cookie import goes through
-- export_cookies.py, on request only).

-- One Chromium browser this plugin knows (macOS).
export type Browser = {
	key: string, -- stable id, part of profile ids
	name: string, -- display name
	app: string, -- bundle name under /Applications or ~/Applications
	data: string, -- user-data directory under ~/Library/Application Support
	keychain: string, -- the Keychain service holding its cookie key
}

-- A browser found on this machine: its registry entry plus where it is.
export type Installed = {
	key: string,
	name: string,
	app: string,
	data: string,
	keychain: string,
	bundle: string, -- absolute path of the app bundle `open` launches
	root: string, -- absolute user-data directory
}

export type Profile = {
	id: string, -- "<browser key>/<dir>", stable across loads
	browser: Installed,
	dir: string, -- "Default", "Profile 1", …
	name: string, -- display name
	account: string, -- signed-in address, when the browser reports one
	last_used: boolean,
}

local SUPPORT = "Library/Application Support"
local KEY_LINK = "link_profile"

local M = {}

-- Registry order breaks ties in listing order (see `load`).
M.BROWSERS = {
	{ key = "brave", name = "Brave", app = "Brave Browser.app", data = "BraveSoftware/Brave-Browser", keychain = "Brave Safe Storage" },
	{ key = "brave-beta", name = "Brave Beta", app = "Brave Browser Beta.app", data = "BraveSoftware/Brave-Browser-Beta", keychain = "Brave Safe Storage" },
	{ key = "brave-nightly", name = "Brave Nightly", app = "Brave Browser Nightly.app", data = "BraveSoftware/Brave-Browser-Nightly", keychain = "Brave Safe Storage" },
	{ key = "chrome", name = "Chrome", app = "Google Chrome.app", data = "Google/Chrome", keychain = "Chrome Safe Storage" },
	{ key = "chrome-beta", name = "Chrome Beta", app = "Google Chrome Beta.app", data = "Google/Chrome Beta", keychain = "Chrome Safe Storage" },
	{ key = "chrome-dev", name = "Chrome Dev", app = "Google Chrome Dev.app", data = "Google/Chrome Dev", keychain = "Chrome Safe Storage" },
	{ key = "chrome-canary", name = "Chrome Canary", app = "Google Chrome Canary.app", data = "Google/Chrome Canary", keychain = "Chrome Safe Storage" },
	{ key = "chromium", name = "Chromium", app = "Chromium.app", data = "Chromium", keychain = "Chromium Safe Storage" },
	{ key = "edge", name = "Edge", app = "Microsoft Edge.app", data = "Microsoft Edge", keychain = "Microsoft Edge Safe Storage" },
	{ key = "edge-beta", name = "Edge Beta", app = "Microsoft Edge Beta.app", data = "Microsoft Edge Beta", keychain = "Microsoft Edge Safe Storage" },
	{ key = "edge-dev", name = "Edge Dev", app = "Microsoft Edge Dev.app", data = "Microsoft Edge Dev", keychain = "Microsoft Edge Safe Storage" },
	{ key = "edge-canary", name = "Edge Canary", app = "Microsoft Edge Canary.app", data = "Microsoft Edge Canary", keychain = "Microsoft Edge Safe Storage" },
	{ key = "vivaldi", name = "Vivaldi", app = "Vivaldi.app", data = "Vivaldi", keychain = "Vivaldi Safe Storage" },
	{ key = "helium", name = "Helium", app = "Helium.app", data = "net.imput.helium", keychain = "Helium Storage Key" },
	{ key = "yandex", name = "Yandex", app = "Yandex.app", data = "Yandex/YandexBrowser", keychain = "Yandex Safe Storage" },
	{ key = "whale", name = "Whale", app = "Whale.app", data = "Naver/Whale", keychain = "Whale Safe Storage" },
} :: { Browser }

local by_key: { [string]: Browser } = {}
for _, b in M.BROWSERS do
	by_key[b.key] = b
end

-- Bundle paths found so far, by browser key, so a link click does not stat
-- the Applications folders again. Each listing of the folders starts over.
local bundles: { [string]: string } = {}

local function home(): string?
	local h = tern.getenv("HOME")
	return if h == nil or h == "" then nil else h
end

-- `b` as found on this machine; remembers where its bundle is.
local function locate(b: Browser, bundle: string, h: string): Installed
	bundles[b.key] = bundle
	return {
		key = b.key,
		name = b.name,
		app = b.app,
		data = b.data,
		keychain = b.keychain,
		bundle = bundle,
		root = h .. "/" .. SUPPORT .. "/" .. b.data,
	}
end

-- The names in an Applications folder, as a set (empty when it cannot be
-- listed).
local function app_names(dir: string): { [string]: boolean }
	local set: { [string]: boolean } = {}
	local ok, names = pcall(tern.fs.list, dir)
	if ok then
		for _, n in names do
			set[n] = true
		end
	end
	return set
end

-- The registry browsers whose bundle is in /Applications or ~/Applications,
-- in registry order, or an empty list and a reason. Each folder is listed
-- once, however many browsers the registry knows.
local function installed(): ({ Installed }, string?)
	local h = home()
	if h == nil then
		return {}, "HOME is not set"
	end
	local system = app_names("/Applications")
	local user = app_names(h .. "/Applications")
	local out: { Installed } = {}
	table.clear(bundles)
	for _, b in M.BROWSERS do
		local bundle = if system[b.app]
			then "/Applications/" .. b.app
			elseif user[b.app] then h .. "/Applications/" .. b.app
			else nil
		if bundle ~= nil then
			table.insert(out, locate(b, bundle, h))
		end
	end
	if #out == 0 then
		return out, "No Chromium browser was found in /Applications or ~/Applications"
	end
	return out, nil
end

-- A profile directory fit to pass to a browser: one plain path component,
-- not "."-like and NUL-free, so it can neither traverse out of the
-- user-data directory nor smuggle anything past argv handling.
function M.valid_dir(dir: string): boolean
	if dir == "" or string.find(dir, "/", 1, true) ~= nil then
		return false
	end
	if string.find(dir, "\0", 1, true) ~= nil then
		return false
	end
	return string.sub(dir, 1, 1) ~= "."
end

local function plain(v: any): string
	return if type(v) == "string" then v else ""
end

-- Index just past the JSON value that starts at `i` in `s`, or nil when it
-- does not end. Scalars end at their delimiter, which stays unconsumed.
local function skip_value(s: string, i: number): number?
	local b = string.byte(s, i)
	if b == 34 then -- string
		local j = i + 1
		while true do
			local q = string.find(s, '["\\]', j)
			if q == nil then
				return nil
			end
			if string.byte(s, q) == 92 then
				j = q + 2
			else
				return q + 1
			end
		end
	elseif b == 123 or b == 91 then -- object or array
		local depth = 0
		local j = i
		while true do
			local q = string.find(s, '[%[%]{}"]', j)
			if q == nil then
				return nil
			end
			local c = string.byte(s, q)
			if c == 34 then
				local e = skip_value(s, q)
				if e == nil then
					return nil
				end
				j = e
			else
				depth += if c == 123 or c == 91 then 1 else -1
				j = q + 1
				if depth == 0 then
					return j
				end
			end
		end
	end
	return (string.find(s, "[,}%]]", i))
end

-- The `profile` object of a Local State text, or nil when it has none.
-- Local State is mostly unrelated data (variation seeds, per-feature state)
-- that is slower to walk or decode than to skip, so each `"profile":{`
-- object is sliced out and decoded alone until one holds an `info_cache`
-- table; other members nest "profile" keys of their own (`legacy.profile`),
-- which that test rejects. A file this misses is decoded whole.
local function profile_section(text: string): { [string]: any }?
	local from = 1
	while true do
		-- A plain search is far faster than a pattern over the whole text.
		local at = string.find(text, '"profile"', from, true)
		if at == nil then
			break
		end
		from = at + 9
		local _, brace = string.find(text, "^%s*:%s*{", from)
		if brace == nil then
			continue
		end
		local stop = skip_value(text, brace)
		if stop == nil then
			break
		end
		local ok, v = pcall(tern.json.decode, string.sub(text, brace, stop - 1))
		if ok and type(v) == "table" and type((v :: { [string]: any }).info_cache) == "table" then
			return v :: { [string]: any }
		end
	end
	local ok, v = pcall(tern.json.decode, text)
	local p = if ok and type(v) == "table" then (v :: { [string]: any }).profile else nil
	return if type(p) == "table" then p :: { [string]: any } else nil
end

-- One browser's profiles: its own order when it names one, then any
-- directories it forgot to list, alphabetically. Entries without an
-- info_cache table (drift) and unsafe directory names are dropped.
-- Returns when any of them was last active (seconds; 0 when unknown).
local function browser_profiles(b: Installed, out: { Profile }): number
	local ok, text = pcall(tern.fs.read, b.root .. "/Local State", 4 * 1024 * 1024)
	if not ok then
		return 0
	end
	local p = profile_section(text)
	if p == nil or type(p.info_cache) ~= "table" then
		tern.log.warn("brave-profiles", b.name .. "'s Local State is not the JSON this plugin expects")
		return 0
	end
	local cache = p.info_cache :: { [string]: any }

	local seen: { [string]: boolean } = {}
	local dirs: { string } = {}
	local function take(d: any)
		if type(d) == "string" and not seen[d] and type(cache[d]) == "table" and M.valid_dir(d) then
			seen[d] = true
			table.insert(dirs, d)
		end
	end
	if type(p.profiles_order) == "table" then
		for _, v in (p.profiles_order :: { any }) do
			take(v)
		end
	end
	local extras: { string } = {}
	for d in cache do
		if type(d) == "string" and not seen[d] then
			table.insert(extras, d)
		end
	end
	table.sort(extras)
	for _, d in extras do
		take(d)
	end

	local last = plain(p.last_used)
	local recent = 0
	for _, d in dirs do
		local info = cache[d] :: { [string]: any }
		local name = plain(info.name)
		if type(info.active_time) == "number" and info.active_time > recent then
			recent = info.active_time
		end
		table.insert(out, {
			id = b.key .. "/" .. d,
			browser = b,
			dir = d,
			name = if name ~= "" then name else d,
			account = plain(info.user_name),
			last_used = d == last,
		})
	end
	return recent
end

-- Every profile of every installed browser, the most recently used browser
-- first (registry order on ties), each browser's profiles in its own order.
-- A browser whose Local State is missing or malformed contributes nothing.
-- Returns the list and nil, or an empty list and a reason.
function M.load(): ({ Profile }, string?)
	local browsers, err = installed()
	if err ~= nil then
		return {}, err
	end
	local groups: { { list: { Profile }, recent: number, rank: number } } = {}
	for rank, b in browsers do
		local list: { Profile } = {}
		local recent = browser_profiles(b, list)
		table.insert(groups, { list = list, recent = recent, rank = rank })
	end
	table.sort(groups, function(x, y)
		if x.recent ~= y.recent then
			return x.recent > y.recent
		end
		return x.rank < y.rank
	end)
	local out: { Profile } = {}
	for _, g in groups do
		table.move(g.list, 1, #g.list, #out + 1, out)
	end
	if #out == 0 then
		return out, "No profiles were found in the installed browsers"
	end
	return out, nil
end

-- The browser name every profile of `list` shares, or nil when they come
-- from several browsers (or none). Someone who only uses Chrome is then
-- shown "Chrome", not browser groups.
function M.sole_browser(list: { Profile }): string?
	local first = list[1]
	if first == nil then
		return nil
	end
	for _, p in list do
		if p.browser.key ~= first.browser.key then
			return nil
		end
	end
	return first.browser.name
end

function M.find(list: { Profile }, id: string?): Profile?
	if id == nil then
		return nil
	end
	for _, p in list do
		if p.id == id then
			return p
		end
	end
	return nil
end

-- The profile a stored id names, without reading Local State: its browser
-- (bundle from the last `load()`, else looked up now) and directory. The
-- name is the directory. Nil when the id is malformed, the browser is not
-- installed or HOME is unset; the directory itself is not checked.
function M.resolve(id: string): Profile?
	local key, dir = string.match(id, "^([^/]+)/(.+)$")
	local b = if key ~= nil then by_key[key] else nil
	if b == nil or dir == nil or not M.valid_dir(dir) then
		return nil
	end
	local h = home()
	if h == nil then
		return nil
	end
	local bundle = bundles[b.key]
	if bundle == nil then
		for _, path in { "/Applications/" .. b.app, h .. "/Applications/" .. b.app } do
			if tern.fs.exists(path) then
				bundle = path
				break
			end
		end
	end
	if bundle == nil then
		return nil
	end
	return { id = id, browser = locate(b, bundle, h), dir = dir, name = dir, account = "", last_used = false }
end

-- The id of the profile this plugin routes links to, or nil. A corrupt
-- store raises (per the kv contract); treat that as "no routing" so
-- commands and the route keep working.
function M.link_id(): string?
	local ok, v = pcall(tern.kv.get, KEY_LINK)
	if not ok then
		return nil
	end
	return if type(v) == "string" then v else nil
end

function M.set_link_id(id: string?)
	tern.kv.set(KEY_LINK, id)
end

-- Opens profile `p` in its browser, optionally at `url`.
--
-- Validation problems and spawn failures return a reason synchronously;
-- `done` sees the launch command's result (and, in a window, a fresh cx)
-- when it starts. `url` must be http(s) so a link can never smuggle in
-- another browser flag.
function M.launch(p: Profile, url: string?, done: ((r: ProcessResult, cx: WindowCx?) -> ())?): string?
	if tern.runtime.os ~= "macos" then
		return "opening browsers from Tern is macOS-only"
	end
	if not M.valid_dir(p.dir) then
		return "invalid browser profile directory"
	end
	if url ~= nil and string.match(url, "^https?://") == nil then
		return "only http(s) URLs can be opened"
	end
	-- `open` is given the bundle path that was found, not an app name, so
	-- the bundle that runs is the one that was checked.
	local argv: { string } = { "open", "-n", p.browser.bundle, "--args", "--profile-directory=" .. p.dir }
	if url ~= nil then
		table.insert(argv, url)
	end
	local ok, err = pcall(function()
		tern.process.run(argv, { timeout_ms = 15000 }, function(r: ProcessResult, cx: WindowCx?)
			if done ~= nil then
				done(r, cx)
			end
		end)
	end)
	if not ok then
		return tostring(err)
	end
	return nil
end

-- Exports profile `p`'s live cookies for `host`'s site, decrypted, through
-- export_cookies.py (it reads the browser's Cookies database and asks the
-- Keychain for the browser's Safe Storage key; macOS prompts the user to
-- allow that). `done` gets the cookies in the shape of Tern's browser
-- `setCookie` op, or a reason. Validation problems and spawn failures return
-- a reason synchronously.
function M.export_cookies(p: Profile, host: string, done: (cookies: { any }?, err: string?, cx: WindowCx?) -> ()): string?
	if tern.runtime.os ~= "macos" then
		return "importing browser cookies is macOS-only"
	end
	if not M.valid_dir(p.dir) then
		return "invalid browser profile directory"
	end
	if string.match(host, "^[%w.-]+$") == nil then
		return "not a plain host name: " .. host
	end
	local b = p.browser
	local ok, err = pcall(function()
		-- `cwd = "."` is the plugin directory, where the script lives. The
		-- generous timeout covers the Keychain prompt waiting for the user.
		tern.process.run(
			{ "/usr/bin/python3", "export_cookies.py", "--data", b.data, "--keychain", b.keychain, p.dir, host },
			{ cwd = ".", timeout_ms = 120000 },
			function(r: ProcessResult, cx: WindowCx?)
				if r.status ~= 0 then
					local why = "timed out waiting for the Keychain"
					if not r.timed_out then
						why = (string.gsub(r.stderr, "%s+$", ""))
					end
					done(nil, if why ~= "" then why else "export_cookies.py exited with status " .. r.status, cx)
					return
				end
				local okd, data = pcall(tern.json.decode, r.stdout)
				if not okd or type(data) ~= "table" then
					done(nil, "export_cookies.py printed something other than a cookie list", cx)
					return
				end
				done(data :: { any }, nil, cx)
			end
		)
	end)
	if not ok then
		return tostring(err)
	end
	return nil
end

return M
