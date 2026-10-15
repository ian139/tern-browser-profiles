--!strict
-- Shared by both halves: the Brave profile list and the launcher.
--
-- Reads only the profile directory names, display names and signed-in
-- addresses from Brave's "Local State" file. No cookies, tokens, history
-- or other profile data are read.

export type Profile = {
	dir: string, -- "Default", "Profile 1", …
	name: string, -- display name
	account: string, -- signed-in address, when Brave reports one
	last_used: boolean,
}

local STATE = "Library/Application Support/BraveSoftware/Brave-Browser"
local KEY_LINK = "link_dir"

local M = {}

-- Where the Brave support directory is on this machine, or nil without a home.
function M.base_dir(): string?
	local home = tern.getenv("HOME")
	if home == nil or home == "" then
		return nil
	end
	return home .. "/" .. STATE
end

-- The exact Brave bundle this plugin launches (and pre-checks), or nil.
-- `open` is given this path, not an app name, so the bundle that runs is
-- the one that was checked.
function M.bundle(): string?
	local home = tern.getenv("HOME")
	local candidates = { "/Applications/Brave Browser.app" }
	if home ~= nil and home ~= "" then
		table.insert(candidates, home .. "/Applications/Brave Browser.app")
	end
	for _, path in candidates do
		if tern.fs.exists(path) then
			return path
		end
	end
	return nil
end

function M.installed(): boolean
	return M.bundle() ~= nil
end

-- A profile directory fit to pass to Brave: one plain path component,
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

-- The profile list: Brave's own order when it names one, Default always
-- present, any directories Brave forgot to list appended alphabetically.
-- Returns the list and nil, or an empty list and a reason.
function M.load(): ({ Profile }, string?)
	local base = M.base_dir()
	if base == nil then
		return {}, "HOME is not set"
	end
	local ok, text = pcall(tern.fs.read, base .. "/Local State", 4 * 1024 * 1024)
	if not ok then
		return {}, "Brave was not found on this machine (no " .. base .. ")"
	end
	local okd, data = pcall(tern.json.decode, text)
	if not okd or type(data) ~= "table" or type((data :: { [string]: any }).profile) ~= "table" then
		return {}, "Brave's Local State is not the JSON this plugin expects"
	end
	local p = (data :: { [string]: any }).profile :: { [string]: any }
	local cache = if type(p.info_cache) == "table" then p.info_cache :: { [string]: any } else nil
	if cache == nil then
		return {}, "Brave reports no profiles"
	end

	local seen: { [string]: boolean } = {}
	local dirs: { string } = {}

	-- Brave's order first, but only entries that really are profiles:
	-- a name in profiles_order whose info_cache entry is missing or not a
	-- table is drift, not a profile.
	if type(p.profiles_order) == "table" then
		for _, v in (p.profiles_order :: { any }) do
			if type(v) == "string" and type(cache[v]) == "table" and not seen[v] then
				seen[v] = true
				table.insert(dirs, v)
			end
		end
	end
	-- Directories Brave has but does not list, alphabetically.
	local extras: { string } = {}
	for d, v in cache do
		if type(d) == "string" and type(v) == "table" and not seen[d] then
			seen[d] = true
			table.insert(extras, d)
		end
	end
	table.sort(extras)
	for _, d in extras do
		table.insert(dirs, d)
	end
	-- Default first when nothing above produced it (info_cache drift).
	if not seen["Default"] then
		table.insert(dirs, 1, "Default")
	end

	local last = plain(p.last_used)
	local out: { Profile } = {}
	for _, d in dirs do
		local info = cache[d]
		local name = if type(info) == "table" then plain((info :: { [string]: any }).name) else ""
		if name == "" then
			name = d
		end
		local account = if type(info) == "table" then plain((info :: { [string]: any }).user_name) else ""
		table.insert(out, {
			dir = d,
			name = name,
			account = account,
			last_used = d == last,
		})
	end
	return out, nil
end

function M.find(list: { Profile }, dir: string?): Profile?
	if dir == nil then
		return nil
	end
	for _, p in list do
		if p.dir == dir then
			return p
		end
	end
	return nil
end

-- The directory of the profile this plugin routes links to, or nil.
-- A corrupt store raises (per the kv contract); treat that as "no
-- routing" so commands and the route keep working.
function M.link_dir(): string?
	local ok, v = pcall(tern.kv.get, KEY_LINK)
	if not ok then
		return nil
	end
	return if type(v) == "string" then v else nil
end

function M.set_link_dir(dir: string?)
	tern.kv.set(KEY_LINK, dir)
end

-- Opens Brave in profile `dir`, optionally at `url`.
--
-- Validation problems and spawn failures return a reason synchronously;
-- `done` sees the launch command's result (and, in a window, a fresh cx)
-- when it starts. `url` must be http(s) so a link can never smuggle in
-- another Brave flag.
function M.launch(dir: string, url: string?, done: ((r: ProcessResult, cx: WindowCx?) -> ())?): string?
	if tern.runtime.os ~= "macos" then
		return "opening Brave from Tern is macOS-only"
	end
	if not M.valid_dir(dir) then
		return "invalid Brave profile directory"
	end
	if url ~= nil and string.match(url, "^https?://") == nil then
		return "only http(s) URLs can be opened"
	end
	local bundle = M.bundle()
	if bundle == nil then
		return "Brave Browser.app was not found (looked in /Applications and ~/Applications)"
	end
	local argv: { string } = { "open", "-n", bundle, "--args", "--profile-directory=" .. dir }
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

-- Exports profile `dir`'s live cookies, decrypted, through export_cookies.py
-- (it reads Brave's Cookies database and asks the Keychain for the "Brave
-- Safe Storage" key; macOS prompts the user to allow that). `done` gets the
-- cookies of `host`'s site in the shape of Tern's browser `setCookie` op, or
-- a reason. Validation problems and spawn failures return a reason synchronously.
function M.export_cookies(
	dir: string,
	host: string,
	done: (cookies: { any }?, err: string?, cx: WindowCx?) -> ()
): string?
	if tern.runtime.os ~= "macos" then
		return "importing Brave cookies is macOS-only"
	end
	if not M.valid_dir(dir) then
		return "invalid Brave profile directory"
	end
	if string.match(host, "^[%w.-]+$") == nil then
		return "not a plain host name: " .. host
	end
	local ok, err = pcall(function()
		-- `cwd = "."` is the plugin directory, where the script lives. The
		-- generous timeout covers the Keychain prompt waiting for the user.
		tern.process.run(
			{ "/usr/bin/python3", "export_cookies.py", dir, host },
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
