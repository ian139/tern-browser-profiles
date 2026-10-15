--!strict
-- The `profiles` block: the machine's Brave profiles as a list, launched
-- from Tern.
--
-- Keys: ↑/↓ (or k/j) move, Home/End jump, ⏎ (or double-click) open Brave
-- in the profile, l routes Tern's http(s) link clicks to it, r reloads.

local profiles = require("./profiles")
local ui = tern.ui

local LIST_ID = "main.list."

type State = {
	cx: BlockCx,
	list: { profiles.Profile },
	problem: string?,
	cursor: string?, -- selected profile directory
}

local function index_of(state: State): number
	for i, p in state.list do
		if p.dir == state.cursor then
			return i
		end
	end
	return 0
end

local function move(state: State, to: number)
	local p = state.list[math.clamp(to, 1, math.max(1, #state.list))]
	if p then
		state.cursor = p.dir
	end
end

-- Whether the block's pane still runs (a ended block leaves the list).
local function pane_runs(pane: number): boolean
	for _, info in tern.pane.list() do
		if info.pane == pane then
			return true
		end
	end
	return false
end

local function launch(cx: BlockCx, pane: number, p: profiles.Profile)
	local spawn_error = profiles.launch(p.dir, nil, function(r: ProcessResult)
		if r.status ~= 0 and pane_runs(pane) then
			cx:toast("error", "Brave did not open " .. p.name, "open exited with status " .. r.status)
		end
	end)
	if spawn_error then
		cx:toast("error", "Brave did not open " .. p.name, spawn_error)
	end
end

local function toggle_link(state: State, cx: BlockCx)
	local p = state.list[index_of(state)]
	if p == nil then
		return
	end
	-- Read the store, not a cached copy: any window (or this block) may
	-- have changed it since the last reload.
	if profiles.link_dir() == p.dir then
		profiles.set_link_dir(nil)
		cx:toast("info", "Links open in Tern again")
	else
		profiles.set_link_dir(p.dir)
		cx:toast("success", "Links open in " .. p.name, "Click a link with ⌘, ⌥, ⇧ or ⌃ to open it in Tern")
	end
end

local function reload(state: State)
	state.list, state.problem = profiles.load()
	state.cursor = nil
	local first = state.list[1]
	if first then
		state.cursor = first.dir
	end
end

local function problem_view(text: string): Node
	return ui.card({ ui.span("Brave Profiles", "strong") }, {
		ui.md(text .. "  Press **r** to look again."),
	})
end

local function list_view(state: State): Node
	local linked = profiles.link_dir()
	local items: { Item } = {}
	for _, p in state.list do
		local label: { Span | string } = { ui.span(p.name) }
		if p.last_used then
			table.insert(label, ui.span("  last used", "dim"))
		end
		if linked == p.dir then
			table.insert(label, ui.span("  ← links", "success"))
		end
		table.insert(items, {
			label = label,
			detail = { ui.span(p.dir, "muted path") },
			value = if p.account ~= "" then { ui.span(p.account, "muted") } else nil,
		})
	end
	local list = ui.list(items)
	local kids = list.c or {}
	for i, p in state.list do
		local cp: { [string]: any } = kids[i].p or {}
		cp.key = p.dir
		kids[i].p = cp
	end
	local lp: { [string]: any } = list.p or {}
	lp.key = "list"
	lp.selected = if state.cursor then LIST_ID .. state.cursor else nil
	lp.empty = { ui.span("Brave reports no profiles.", "muted") }
	lp.max = { lines = math.max(4, state.cx.rows - 6) }
	list.p = lp
	return list
end

local function dock_view(state: State): Node
	local status: { Span | string } = { ui.span(#state.list .. " profiles", "strong") }
	local linked = profiles.find(state.list, profiles.link_dir())
	if linked then
		table.insert(status, ui.span("  links → " .. linked.name, "success"))
	end
	return ui.col({
		ui.lines({
			ui.text(status),
			ui.text({ ui.span("↑↓ move  ⏎ open  l route links  r reload", "dim") }),
		}),
	})
end

local def: BlockDef<State> = {
	init = function(cx: BlockCx, _args: { string }, _saved: any): State
		local state: State = { cx = cx, list = {}, problem = nil, cursor = nil }
		reload(state)
		return state
	end,

	title = function(_state: State): string?
		return "Brave Profiles"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		local main = if state.problem ~= nil then problem_view(state.problem) else list_view(state)
		return { main = ui.col({ main }), dock = if state.problem == nil then dock_view(state) else nil }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		-- Letters match the key's name, so a pasted "r" is just text and
		-- nothing happens for keys the block does not use.
		if key.name == "paste" or key.ctrl or key.alt or key.meta then
			return false
		end
		local i = index_of(state)
		local k = key.name
		if k == "up" or k == "k" then
			move(state, i - 1)
		elseif k == "down" or k == "j" then
			move(state, i + 1)
		elseif k == "home" then
			move(state, 1)
		elseif k == "end" then
			move(state, #state.list)
		elseif k == "enter" then
			local p = state.list[i]
			if p == nil then
				return false
			end
			launch(cx, state.cx.pane, p)
		elseif k == "l" then
			toggle_link(state, cx)
		elseif k == "r" then
			reload(state)
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			state.cursor = string.sub(ev.item, #LIST_ID + 1)
			if ev.ev == "activate" then
				local p = profiles.find(state.list, state.cursor)
				if p then
					launch(cx, state.cx.pane, p)
				end
			end
		end
	end,
}

tern.block.define("profiles", def)
