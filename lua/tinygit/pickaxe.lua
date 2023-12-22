local M = {}
local fn = vim.fn
local u = require("tinygit.utils")
local a = vim.api
local config = require("tinygit.config").config.historySearch
--------------------------------------------------------------------------------

---@class currentRun
---@field hashList string[] ordered list of all hashes where the string/function was found
---@field filename string
---@field query string search query pickaxed for
---@field originalCwd? string cwd before running history search

---saves metadata for the current operation
---@type currentRun
local currentRun = { hashList = {}, filename = "", query = "" }

---if `autoUnshallowIfNeeded = true`, will also run `git fetch --unshallow`
---@return boolean -- whether the repo is shallow
local function repoIsShallow()
	local isShallow = vim.trim(fn.system { "git", "rev-parse", "--is-shallow-repository" }) == "true"
	if not isShallow then return false end

	if config.autoUnshallowIfNeeded then
		u.notify("Auto-Unshallowing repo…", "info", "History Search")
		-- delayed, so notification shows up before fn.system blocks execution
		vim.defer_fn(function() fn.system { "git", "fetch", "--unshallow" } end, 300)
		return false
	else
		u.notify(
			"Aborting: Repository is shallow.\nRun `git fetch --unshallow`.",
			"warn",
			"History Search"
		)
		return true
	end
end

-- assuming the current cwd is a git repo
local function cdToGitRoot()
	local gitroot = vim.trim(fn.system { "git", "rev-parse", "--show-toplevel" })
	if gitroot ~= vim.loop.cwd() then vim.cmd.cd(gitroot) end
end

--------------------------------------------------------------------------------

---@param commitIdx number index of the selected commit in the list of commits
---@param type "file"|"function"
local function showDiff(commitIdx, type)
	local ns = a.nvim_create_namespace("tinygit.pickaxe_diff")
	local hashList = currentRun.hashList
	local hash = hashList[commitIdx]
	local query = currentRun.query
	local date = vim.trim(fn.system { "git", "log", "-n1", "--format=%cr", hash })
	local shortMsg = vim.trim(fn.system({ "git", "log", "-n1", "--format=%s", hash }):sub(1, 50))

	-- determine filename in case of renaming
	local filenameInPresent = currentRun.filename
	cdToGitRoot() -- in case cwd is not the git root
	local nameHistory = vim.trim(fn.system {
		"git",
		"log",
		hash .. "^..",
		"--follow",
		"--name-status", -- show filename changes, format: [M|Rxx] <nameAtCommit> [<newFilename>]
		"--format=", -- suppress commit info
		"--",
		filenameInPresent,
	})
	local lastLine = table.remove(vim.split(nameHistory, "\n"))
	local filenameAtCommit = lastLine:match("^M%s+(.+)") -- M <nameAtCommit>
		or lastLine:match("^R%d+%s+.+   (.+)") -- Rxxx <nameAtCommit> <newFilename>
		or lastLine:match("^R%d+%s+.+\t(.+)") -- SIC sometimes outputs spaces, sometimes tabs
	assert(filenameAtCommit, "filenameAtCommit not matched via pattern.")

	-- get diff
	local diff
	if type == "file" then
		diff = fn.system {
			"git",
			"show",
			hash,
			"--format=",
			"--",
			filenameAtCommit,
		}
	elseif type == "function" then
		diff = fn.system {
			"git",
			"log",
			hash,
			"--format=",
			"-n1",
			("-L:%s:%s"):format(query, filenameAtCommit),
		}
	end

	if u.nonZeroExit(diff) then return end
	local diffLines = vim.split(vim.trim(diff), "\n")
	for _ = 1, 4 do -- remove first four lines (irrelevant diff header)
		table.remove(diffLines, 1)
	end
	table.insert(diffLines, 1, "") -- empty line for extmark

	-- remove diff signs and remember line numbers
	local diffAddLines = {}
	local diffDelLines = {}
	local diffHunkHeaderLines = {}
	for i = 1, #diffLines, 1 do
		local line = diffLines[i]
		if line:find("^%+") then
			table.insert(diffAddLines, i - 1)
		elseif line:find("^%-") then
			table.insert(diffDelLines, i - 1)
		elseif line:find("^@@") then
			table.insert(diffHunkHeaderLines, i - 1)
			-- removing preproc info, since it breaks ft highlighting
			diffLines[i] = line:gsub("@@.-@@", "")
		end
		diffLines[i] = diffLines[i]:sub(2)
	end

	-- create new buf with diff
	local bufnr = a.nvim_create_buf(false, true)
	a.nvim_buf_set_lines(bufnr, 0, -1, false, diffLines)
	a.nvim_buf_set_name(bufnr, hash .. " " .. filenameAtCommit)
	a.nvim_buf_set_option(bufnr, "modifiable", false)

	-- open new win for the buff
	local width = math.min(config.diffPopup.width, 0.99)
	local height = math.min(config.diffPopup.height, 0.99)

	local winnr = a.nvim_open_win(bufnr, true, {
		relative = "win",
		-- center of current win
		width = math.floor(width * a.nvim_win_get_width(0)),
		height = math.floor(height * a.nvim_win_get_height(0)),
		row = math.floor((1 - height) * a.nvim_win_get_height(0) / 2),
		col = math.floor((1 - width) * a.nvim_win_get_width(0) / 2),
		title = (" %s (%s) "):format(shortMsg, date),
		title_pos = "center",
		border = config.diffPopup.border,
		style = "minimal",
		zindex = 1, -- below nvim-notify floats
	})
	a.nvim_win_set_option(winnr, "list", false)
	a.nvim_win_set_option(winnr, "signcolumn", "no")

	-- Highlighting
	-- INFO not using `diff` filetype, since that would remove filetype-specific highlighting
	local ft = vim.filetype.match { filename = vim.fs.basename(filenameAtCommit) }
	a.nvim_buf_set_option(bufnr, "filetype", ft)

	for _, ln in pairs(diffAddLines) do
		a.nvim_buf_add_highlight(bufnr, ns, "DiffAdd", ln, 0, -1)
	end
	for _, ln in pairs(diffDelLines) do
		a.nvim_buf_add_highlight(bufnr, ns, "DiffDelete", ln, 0, -1)
	end
	for _, ln in pairs(diffHunkHeaderLines) do
		a.nvim_buf_add_highlight(bufnr, ns, "PreProcLine", ln, 0, -1)
		vim.api.nvim_set_hl(0, "PreProcLine", { underline = true })
	end

	-- search for the query
	if query ~= "" and type == "file" then
		fn.matchadd("Search", query) -- highlight, CAVEAT: is case-sensitive

		vim.opt_local.ignorecase = true -- consistent with `--regexp-ignore-case`
		vim.opt_local.smartcase = false

		vim.fn.setreg("/", query) -- so `n` searches directly
		vim.cmd.normal { "n", bang = true } -- move to first match
	end

	-- keymaps: info message as extmark
	local infotext = "<[S-]Tab>: prev/next commit   q: close   yh: yank hash"
	if type == "file" then infotext = infotext .. "   n/N: next/prev occurrence" end
	a.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
		virt_text = { { infotext, "DiagnosticVirtualTextInfo" } },
		virt_text_pos = "overlay",
	})

	-- keymaps: closing
	local keymap = vim.keymap.set
	local opts = { buffer = bufnr, nowait = true }
	local function close()
		a.nvim_win_close(winnr, true)
		a.nvim_buf_delete(bufnr, { force = true })
		-- restore the original cwd
		if currentRun.originalCwd ~= vim.loop.cwd() then vim.cmd.cd(currentRun.originalCwd) end
	end
	keymap("n", "q", close, opts)
	keymap("n", "<Esc>", close, opts)

	-- keymaps: next/prev commit
	keymap("n", "<Tab>", function()
		if commitIdx == #hashList then
			u.notify("Already on last commit", "warn")
			return
		end
		close()
		showDiff(commitIdx + 1, type)
	end, opts)
	keymap("n", "<S-Tab>", function()
		if commitIdx == 1 then
			u.notify("Already on first commit", "warn")
			return
		end
		close()
		showDiff(commitIdx - 1, type)
	end, opts)

	-- keymaps: yank hash
	keymap("n", "yh", function()
		vim.fn.setreg("+", hash)
		u.notify("Copied hash: " .. hash)
	end, opts)
end

---@param commitList string raw response from `git log`, will be validated
---@param type "file"|"function"
local function selectFromCommits(commitList, type)
	-- GUARD
	if u.nonZeroExit(commitList) then return end
	commitList = vim.trim(commitList)
	if commitList == "" then
		u.notify(('No commits found where "%s" was changed.'):format(currentRun.query))
		return
	end

	-- save data
	local commits = vim.split(commitList, "\n")
	currentRun.hashList = vim.tbl_map(function(commitLine)
		local hash = vim.split(commitLine, "\t")[1]
		return hash
	end, commits)

	-- select
	local autocmdId = u.commitList.setupAppearance()
	local searchMode = currentRun.query == "" and vim.fs.basename(currentRun.filename) or currentRun.query
	vim.ui.select(commits, {
		prompt = ('󰊢 Commits that changed "%s"'):format(searchMode),
		format_item = u.commitList.selectorFormatter,
		kind = "tinygit.pickaxeDiff",
	}, function(_, commitIdx)
		a.nvim_del_autocmd(autocmdId)
		if not commitIdx then return end -- aborted selection
		showDiff(commitIdx, type)
	end)
end

---@param funcname? string -- nil: aborted
local function selectFromFunctionHistory(funcname)
	if not funcname or funcname == "" then return end
	local response = fn.system {
		"git",
		"log",
		"--format=" .. u.commitList.gitlogFormat,
		"--follow", -- follow file renamings
		("-L:%s:%s"):format(funcname, currentRun.filename),
		"--no-patch",
	}
	selectFromCommits(response, "function")
end

--------------------------------------------------------------------------------

function M.searchFileHistory()
	if u.notInGitRepo() or repoIsShallow() then return end
	currentRun.filename = a.nvim_buf_get_name(0)
	currentRun.originalCwd = vim.loop.cwd()

	vim.ui.input({ prompt = "󰊢 Search File History" }, function(query)
		if not query then return end -- aborted
		currentRun.query = query
		local response
		if query == "" then
			-- without argument, search all commits that touched the current file
			response = fn.system {
				"git",
				"log",
				"--format=" .. u.commitList.gitlogFormat,
				"--follow", -- follow file renamings
				"--",
				currentRun.filename,
			}
		else
			response = fn.system {
				"git",
				"log",
				"--format=" .. u.commitList.gitlogFormat,
				"--regexp-ignore-case",
				"-G" .. query,
				"--follow", -- follow file renamings
				"--",
				currentRun.filename,
			}
		end
		selectFromCommits(response, "file")
	end)
end

function M.functionHistory()
	-- GUARD
	if u.notInGitRepo() or repoIsShallow() then return end
	if vim.tbl_contains({ "json", "yaml", "toml", "css" }, vim.bo.ft) then
		u.notify(vim.bo.ft .. " does not have any functions.", "warn")
		return
	end

	currentRun.filename = a.nvim_buf_get_name(0)
	currentRun.originalCwd = vim.loop.cwd()

	-- TODO figure out how to query treesitter for function names, and use
	-- treesitter instead?
	local lspWithSymbolSupport = false
	local clients = vim.lsp.get_active_clients { bufnr = 0 }
	for _, client in pairs(clients) do
		if client.server_capabilities.documentSymbolProvider then
			lspWithSymbolSupport = true
			break
		end
	end

	if lspWithSymbolSupport then
		-- 1. query LSP for symbols,
		-- 2. filter by kind "function"/"method", prompt to select a name,
		-- 3. prompt to select a commit that changed that function/method
		vim.lsp.buf.document_symbol {
			on_list = function(response)
				local funcsObjs = vim.tbl_filter(
					function(item) return item.kind == "Function" or item.kind == "Method" end,
					response.items
				)
				if #funcsObjs == 0 then
					local client = vim.lsp.get_client_by_id(response.context.client_id)
					u.notify(("LSP (%s) could not find any functions."):format(client), "warn")
				end

				local funcNames = vim.tbl_map(function(item)
					if item.kind == "Function" then
						return item.text:gsub("^%[Function%] ", "")
					elseif item.kind == "Method" then
						return item.text:match("%[Method%]%s+([^%(]+)")
					end
				end, funcsObjs)
				vim.ui.select(
					funcNames,
					{ prompt = "󰊢 Select Function:", kind = "tinygit.functionSelect" },
					function(funcname)
						currentRun.query = funcname
						selectFromFunctionHistory(funcname)
					end
				)
			end,
		}
	else
		vim.ui.input({ prompt = "󰊢 Search History of Function named:" }, function(funcname)
			currentRun.query = funcname
			selectFromFunctionHistory(funcname)
		end)
	end
end

--------------------------------------------------------------------------------
return M
