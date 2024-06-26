local M = {}
local icons = require("tinygit.config").config.statusline.branchState.icons
--------------------------------------------------------------------------------

---Returns info ahead, behind, and divergence of the local branch with the
---remote one
---@param bufnr? number
---@return string blame lualine stringifys result, so need to return empty string instead of nil
---@nodiscard
local function getBranchState(bufnr)
	bufnr = bufnr or 0

	-- GUARD valid buffer
	if not vim.api.nvim_buf_is_valid(bufnr) then return "" end
	if vim.api.nvim_get_option_value("buftype", { buf = bufnr }) ~= "" then return "" end
	local cwd = vim.uv.cwd()
	if not cwd then return "" end

	local allBranchInfo = vim.system({ "git", "-C", cwd, "branch", "--verbose" }):wait()
	-- GUARD not in git repo
	if allBranchInfo.code ~= 0 then return "" end

	-- get only line on current branch (starting with `*`)
	local branches = vim.split(allBranchInfo.stdout, "\n")
	local currentBranchInfo
	for _, line in pairs(branches) do
		currentBranchInfo = line:match("^%* .*")
		if currentBranchInfo then break end
	end
	if not currentBranchInfo then return "" end
	local ahead = currentBranchInfo:match("ahead (%d+)")
	local behind = currentBranchInfo:match("behind (%d+)")

	if ahead and behind then
		return (icons.diverge .. " %s/%s"):format(ahead, behind)
	elseif ahead then
		return icons.ahead .. ahead
	elseif behind then
		return icons.behind .. behind
	end
	return ""
end

--------------------------------------------------------------------------------

---@param bufnr? number
function M.refreshBranchState(bufnr) vim.b.tinygit_branchState = getBranchState(bufnr) end

vim.api.nvim_create_autocmd({ "BufEnter", "DirChanged", "FocusGained" }, {
	group = vim.api.nvim_create_augroup("tinygit_branchState", { clear = true }),
	callback = function(ctx)
		-- so buftype is set before checking the buffer
		vim.defer_fn(function() M.refreshBranchState(ctx.buf) end, 1)
	end,
})

vim.defer_fn(getBranchState, 1) -- initialize in case of lazy-loading

function M.getBranchState() return vim.b.tinygit_branchState or "" end

--------------------------------------------------------------------------------
return M
