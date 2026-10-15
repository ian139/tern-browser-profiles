--!strict
-- The `profiles` block: every profile of every installed Chromium browser as
-- a list, each opened in its own Tern browser.
--
-- Keys: ↑/↓ (or k/j) move, Home/End jump, ⏎ (or double-click) open the
-- profile in Tern, l routes Tern's http(s) link clicks to it, r reloads.

local profiles = require("./profiles")
local ui = tern.ui

local LIST_ID = "main.list."

type State = {
	cx: BlockCx,
	list: { profiles.Profile },
	problem: string?,
	cursor: string?, -- selected profile id
}

local function index_of(state: State): number
	for i, p in state.list do
		if p.id == state.cursor then
			return i
		end
	end
	return 0
end

local function move(state: State, to: number)
	local p = state.list[math.clamp(to, 1, math.max(1, #state.list))]
	if p then
		state.cursor = p.id
	end
end

-- The host has no browser, so the window opens it: a one-shot request for
-- this pane, then the open URI the window's link route takes it from.
local function open_in_tern(cx: BlockCx, p: profiles.Profile)
	local uri, err = profiles.request_open(cx.pane, p.id)
	if uri == nil then
		cx:toast("error", "Tern's browser did not open " .. p.browser.name .. ": " .. p.name, err)
		return
	end
	cx:open(uri)
end

local function toggle_link(state: State, cx: BlockCx)
	local p = state.list[index_of(state)]
	if p == nil then
		return
	end
	-- Read the store, not a cached copy: any window (or this block) may
	-- have changed it since the last reload.
	if profiles.link_id() == p.id then
		profiles.set_link_id(nil)
		cx:toast("info", "Links open in Tern's default browser again")
	else
		profiles.set_link_id(p.id)
		cx:toast(
			"success",
			"Links open in Tern as " .. p.browser.name .. ": " .. p.name,
			"Click a link with ⌘, ⌥, ⇧ or ⌃ to open it in Tern's default browser"
		)
	end
end

local function reload(state: State)
	state.list, state.problem = profiles.load()
	state.cursor = nil
	local first = state.list[1]
	if first then
		state.cursor = first.id
	end
end

local function problem_view(text: string): Node
	return ui.card({ ui.span("Browser Profiles", "strong") }, {
		ui.md(text .. "  Press **r** to look again."),
	})
end

local function list_view(state: State, linked: string?): Node
	-- The browser name only tells profiles apart when there are several.
	local grouped = profiles.sole_browser(state.list) == nil
	local items: { Item } = {}
	for _, p in state.list do
		local label: { Span | string } = { ui.span(p.name) }
		if p.last_used then
			table.insert(label, ui.span("  last used", "dim"))
		end
		if linked == p.id then
			table.insert(label, ui.span("  ← links", "success"))
		end
		table.insert(items, {
			label = label,
			detail = if grouped then { ui.span(p.browser.name, "muted") } else nil,
			value = if p.account ~= "" then { ui.span(p.account, "muted") } else nil,
		})
	end
	local list = ui.list(items)
	local kids = list.c or {}
	for i, p in state.list do
		local cp: { [string]: any } = kids[i].p or {}
		cp.key = p.id
		kids[i].p = cp
	end
	local lp: { [string]: any } = list.p or {}
	lp.key = "list"
	lp.selected = if state.cursor then LIST_ID .. state.cursor else nil
	lp.empty = { ui.span("No browser profiles found.", "muted") }
	lp.max = { lines = math.max(4, state.cx.rows - 6) }
	list.p = lp
	return list
end

local function dock_view(state: State, linked: string?): Node
	local status: { Span | string } = { ui.span(#state.list .. " profiles", "strong") }
	local target = profiles.find(state.list, linked)
	if target then
		table.insert(status, ui.span("  links → " .. target.browser.name .. ": " .. target.name, "success"))
	end
	return ui.col({
		ui.lines({
			ui.text(status),
			ui.text({ ui.span("↑↓ move  ⏎ open in Tern  l route links  r reload", "dim") }),
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
		return "Browser Profiles"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		if state.problem ~= nil then
			return { main = ui.col({ problem_view(state.problem) }) }
		end
		local linked = profiles.link_id()
		return { main = ui.col({ list_view(state, linked) }), dock = dock_view(state, linked) }
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
			open_in_tern(cx, p)
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
					open_in_tern(cx, p)
				end
			end
		end
	end,
}

tern.block.define("profiles", def)
