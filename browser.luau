--!strict
-- The window half's Tern browser: opens a source profile in its own named,
-- persistent Tern browser store, docked beside the focused pane.
--
-- The first time (and on an explicit copy-again), all of the profile's live
-- cookies are copied into that store before anything loads; later opens
-- reuse the store as it is. Cookie values never reach a toast or the log.

local profiles = require("./profiles")

local START = "https://www.google.com/"

local M = {}

-- Browser blocks this window opened, so links clicked inside one stay there.
local opened: { [number]: boolean } = {}
-- Source profiles whose sign-ins this window is copying now.
local copying: { [string]: boolean } = {}

-- Runs browser op `op`; `done` gets its `ok` table, or nil and a reason,
-- and the fresh cx (nil when the window is gone). Error envelopes, failed
-- or missing answers and a raising call all become reasons.
local function call(cx: WindowCx, op: { [string]: any }, done: (ok: { [string]: any }?, err: string?, cx: WindowCx?) -> ())
	local started, pending = pcall(function()
		return cx.browser:call(op)
	end)
	if not started then
		done(nil, tostring(pending), cx)
		return
	end
	pending:next(function(res: BrowserResult?, e: string?, next_cx: WindowCx?)
		if e ~= nil then
			done(nil, e, next_cx)
		elseif res == nil then
			done(nil, "Tern's browser gave no answer", next_cx)
		elseif res.error ~= nil then
			done(nil, tostring(res.error.message), next_cx)
		elseif type(res.ok) ~= "table" then
			done(nil, "Tern's browser gave no answer", next_cx)
		else
			done(res.ok, nil, next_cx)
		end
	end)
end

-- The tiled pane a new browser opens over and docks beside: the focused
-- pane, or the pane a focused floating block floats over. Nil when nothing
-- is focused.
local function owner_pane(cx: WindowCx): number?
	local focused = cx.session:focused()
	if focused == nil then
		return nil
	end
	local ok, over = pcall(function(): number?
		local info = cx.session:pane(focused)
		if info == nil or not info.floating then
			return nil
		end
		local tab = cx.session:tab_of(focused)
		local layout = if tab ~= nil then cx.session:layout(tab) else nil
		if layout ~= nil then
			for _, f in layout.floats do
				if f.pane == focused then
					return f.over
				end
			end
		end
		return nil
	end)
	return if ok and over ~= nil then over else focused
end

-- Opens `p`'s Tern browser at `url` and docks it right of the owner pane;
-- `done` gets the block, or nil and a reason, and the fresh cx.
local function open_block(cx: WindowCx, p: profiles.Profile, url: string, done: (block: number?, err: string?, cx: WindowCx?) -> ())
	local found = owner_pane(cx)
	if found == nil then
		done(nil, "Focus a pane in this window first", cx)
		return
	end
	local owner: number = found
	call(cx, { op = "open", owner = owner, url = url, profile = profiles.store(p) }, function(ok, err, open_cx)
		local block = if ok ~= nil then ok.block else nil
		if type(block) ~= "number" then
			done(nil, err or "Tern's browser opened no block", open_cx)
			return
		end
		opened[block] = true
		if open_cx ~= nil then
			local layout = open_cx.layout
			local ran, docked, why = pcall(function()
				return layout:dock(block, owner, "right")
			end)
			if not ran or not docked then
				open_cx:toast("info", "Tern's browser stayed floating", if ran then why else tostring(docked))
			end
		end
		done(block, nil, open_cx)
	end)
end

-- Sets `cookies` one at a time in `block`'s store (thousands of pending
-- native calls at once would flood the window), stopping at the first one
-- the store rejects; `done` gets nil or that reason, and the fresh cx.
local function set_cookies(cx: WindowCx, block: number, cookies: { any }, done: (err: string?, cx: WindowCx?) -> ())
	local function step(i: number, step_cx: WindowCx)
		local cookie = cookies[i]
		if cookie == nil then
			done(nil, step_cx)
			return
		end
		call(step_cx, { op = "setCookie", block = block, cookie = cookie }, function(ok, err, next_cx)
			if ok == nil then
				done(err, next_cx)
			elseif next_cx ~= nil then
				step(i + 1, next_cx)
			else
				done(nil, nil)
			end
		end)
	end
	step(1, cx)
end

-- Whether `pane` is a Tern browser this window opened for a profile.
function M.owns(pane: number): boolean
	return opened[pane] == true
end

-- Opens profile `p` in its own Tern browser, at `url` or a start page.
-- Copies its sign-ins first when they were never copied, or when `recopy`
-- asks to copy them again; the page loads only after every cookie landed.
-- Failures are toasts; a block opened for a failed copy is closed again.
function M.open(cx: WindowCx, p: profiles.Profile, url: string?, recopy: boolean?)
	local target = url or START
	local who = p.browser.name .. ": " .. p.name
	if cx.session:focused() == nil then
		cx:toast("error", "Tern's browser did not open " .. who, "Focus a pane in this window first")
		return
	end
	if not recopy and profiles.copied(p.id) then
		open_block(cx, p, target, function(block, err, open_cx)
			if block == nil and open_cx ~= nil then
				open_cx:toast("error", "Tern's browser did not open " .. who, err)
			end
		end)
		return
	end
	if copying[p.id] then
		cx:toast("info", "Already copying sign-ins from " .. who)
		return
	end
	if not tern.fs.exists(p.browser.root .. "/" .. p.dir) then
		cx:toast("error", "No " .. who .. " profile on this Mac", "Open it from the Mac where " .. p.browser.name .. " has it")
		return
	end
	local failed = "Could not copy sign-ins from " .. who
	copying[p.id] = true
	cx:toast("info", "Copying sign-ins from " .. who .. " into Tern", "macOS may ask to allow the " .. p.browser.keychain .. " Keychain item")
	local spawn_error = profiles.export_cookies(p, nil, function(cookies, export_err, export_cx)
		if cookies == nil or export_cx == nil then
			copying[p.id] = nil
			if export_cx ~= nil then
				export_cx:toast("error", failed, export_err)
			end
			return
		end
		open_block(export_cx, p, "about:blank", function(block, open_err, open_cx)
			if block == nil or open_cx == nil then
				copying[p.id] = nil
				if open_cx ~= nil then
					open_cx:toast("error", "Tern's browser did not open " .. who, open_err)
				end
				return
			end
			set_cookies(open_cx, block, cookies, function(set_err, set_cx)
				copying[p.id] = nil
				if set_cx == nil then
					return
				end
				local mark_err = if set_err == nil then profiles.set_copied(p.id) else nil
				if set_err ~= nil or mark_err ~= nil then
					opened[block] = nil
					call(set_cx, { op = "close", block = block }, function() end)
					set_cx:toast("error", failed, if set_err ~= nil then "Tern's browser refused a cookie: " .. set_err else mark_err)
					return
				end
				set_cx:toast(
					"success",
					if #cookies > 0 then "Copied sign-ins from " .. who else who .. " had no sign-ins to copy",
					if #cookies > 0 then "Copied " .. #cookies .. " cookies into its own Tern browser" else nil
				)
				call(set_cx, { op = "goto", block = block, url = target }, function(ok, goto_err, goto_cx)
					if ok == nil and goto_cx ~= nil then
						goto_cx:toast("error", "Tern's browser did not load " .. target, goto_err)
					end
				end)
			end)
		end)
	end)
	if spawn_error then
		copying[p.id] = nil
		cx:toast("error", failed, spawn_error)
	end
end

return M
