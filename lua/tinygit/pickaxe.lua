local M = {}
local fn = vim.fn
local u = require("tinygit.utils")
local a = vim.api
--------------------------------------------------------------------------------

---@class currentPickaxe saves metadata for the current pickaxe operation
---@field hashList string[] list of all hashes where the string was found
---@field filename string
---@field query string search query pickaxed for

---@type currentPickaxe
local currentPickaxe = { hashList = {}, filename = "", query = "" }

--------------------------------------------------------------------------------

---@param commitLine string
---@return string formatted text
local function commitFormatter(commitLine)
	local _, commitMsg, date, author = unpack(vim.split(commitLine, "\t"))
	return table.concat({ commitMsg, date, author }, " · ")
end

---@param commitIdx number index of the selected commit in the list of commits
local function showDiff(commitIdx)
	local hashList = currentPickaxe.hashList
	local hash = hashList[commitIdx]
	local filename = currentPickaxe.filename
	local query = currentPickaxe.query

	-- get diff
	local diff = fn.system { "git", "show", hash, "--format=", "--", filename }
	if u.nonZeroExit(diff) then return end
	local diffLines = vim.split(diff, "\n")
	-- remove first four lines (irrelevant diff header)
	for _ = 1, 4 do 
		table.remove(diffLines, 1)
	end
	-- empty line for extmark, as side effect also shifts line numbers up, which
	-- then match the zero-based line numbers for nvim_buf_add_highlight
	table.insert(diffLines, 1, "") 

	-- remove diff signs and remember line numbers
	local diffAddLines = {}
	local diffDelLines = {}
	local diffPreProcLines = {}
	for i = 1, #diffLines, 1 do
		local firstChar = diffLines[i]:sub(1, 1)
		if firstChar == "+" then
			table.insert(diffAddLines, i)
		elseif firstChar == "-" then
			table.insert(diffDelLines, i)
		elseif firstChar == "@" then
			table.insert(diffPreProcLines, i)
		end
		diffLines[i] = diffLines[i]:sub(2)
	end

	-- open new win with diff
	local height = 0.8
	local width = 0.8
	local bufnr = a.nvim_create_buf(true, true)
	a.nvim_buf_set_lines(bufnr, 0, -1, false, diffLines)
	a.nvim_buf_set_name(bufnr, hash .. " " .. filename)
	a.nvim_buf_set_option(bufnr, "modifiable", false)
	local winnr = a.nvim_open_win(bufnr, true, {
		relative = "win",
		-- center of current win
		width = math.floor(width * a.nvim_win_get_width(0)),
		height = math.floor(height * a.nvim_win_get_height(0)),
		row = math.floor((1 - height) * a.nvim_win_get_height(0) / 2),
		col = math.floor((1 - width) * a.nvim_win_get_width(0) / 2),
		title = filename .. " @ " .. hash,
		title_pos = "center",
		border = "single",
		style = "minimal",
		zindex = 1, -- below nvim-notify floats
	})
	a.nvim_win_set_option(winnr, "list", false)
	a.nvim_win_set_option(winnr, "signcolumn", "no")

	-- Highlighting
	-- INFO not using `diff` filetype, since that would remove filetype-specific highlighting
	local ft = vim.filetype.match { filename = filename }
	a.nvim_buf_set_option(bufnr, "filetype", ft)

	local ns = a.nvim_create_namespace("tinygit.pickaxe_diff")
	for _, ln in pairs(diffAddLines) do
		a.nvim_buf_add_highlight(bufnr, ns, "DiffAdd", ln, 0, -1)
	end
	for _, ln in pairs(diffDelLines) do
		a.nvim_buf_add_highlight(bufnr, ns, "DiffDelete", ln, 0, -1)
	end
	for _, ln in pairs(diffPreProcLines) do
		a.nvim_buf_add_highlight(bufnr, ns, "PreProc", ln, 0, -1)
	end

	-- search for the query
	if query ~= "" then
		fn.matchadd("Search", query) -- highlight, CAVEAT: is case-sensitive
		vim.fn.search(query) -- move cursor
		vim.fn.execute("/" .. query, "silent!") -- insert query so only `n` needs to be pressed
	end

	-- keymaps: info message as extmark
	local infotext = "n/N: next/prev occurrence  ·  <Tab>/<S-Tab>: next/prev commit  ·  q: close"
	vim.api.nvim_buf_set_extmark(bufnr, 1, 0, 0, {
		virt_text = { { infotext, "DiagnosticVirtualTextInfo" } },
		virt_text_pos = "overlay",
	})

	-- keymaps: closing
	local function close()
		vim.api.nvim_win_close(winnr, true)
		a.nvim_buf_delete(bufnr, { force = true })
	end
	vim.keymap.set("n", "q", close, { buffer = bufnr, nowait = true })
	vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, nowait = true })

	-- keymaps: next/prev commit
	vim.keymap.set("n", "<Tab>", function()
		if commitIdx == #hashList then
			u.notify("Already on last commit", "warn")
			return
		end
		a.nvim_win_close(winnr, true)
		a.nvim_buf_delete(bufnr, { force = true })
		showDiff(commitIdx + 1)
	end, { buffer = bufnr, nowait = true })
	vim.keymap.set("n", "<S-Tab>", function()
		if commitIdx == 1 then
			u.notify("Already on first commit", "warn")
			return
		end
		a.nvim_win_close(winnr, true)
		a.nvim_buf_delete(bufnr, { force = true })
		showDiff(commitIdx - 1)
	end, { buffer = bufnr, nowait = true })
end

--------------------------------------------------------------------------------

function M.searchFileHistory()
	if u.notInGitRepo() then return end

	local filename = fn.expand("%")
	vim.ui.input({ prompt = "󰊢 Search File History" }, function(query)
		if not query then return end -- aborted
		local response
		if query == "" then
			response = fn.system { "git", "log", "--format=%h\t%s\t%cr\t%cn", "--", filename }
		else
			response = fn.system {
				"git",
				"log",
				"--format=%h\t%s\t%cr\t%cn", -- format: hash, subject, date, author
				"--pickaxe-regex",
				"--regexp-ignore-case",
				("-S%s"):format(query),
				"--",
				filename,
			}
		end

		-- guards
		if u.nonZeroExit(response) then return end
		response = vim.trim(response)
		if response == "" then
			u.notify(('No commits found where "%s" was changed.'):format(query))
			return
		end

		-- data
		local commits = vim.split(response, "\n")
		local hashList = vim.tbl_map(function(commitLine)
			local hash = vim.split(commitLine, "\t")[1]
			return hash
		end, commits)
		currentPickaxe = {
			hashList = hashList,
			query = query,
			filename = filename,
		}

		-- select
		vim.ui.select(commits, {
			prompt = "󰊢 Select Commit",
			format_item = commitFormatter,
			kind = "tinygit.pickaxe_diff",
		}, function(_, commitIdx)
			if not commitIdx then return end -- aborted selection
			showDiff(commitIdx)
		end)
	end)
end

--------------------------------------------------------------------------------
return M
