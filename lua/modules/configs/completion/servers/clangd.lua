-- https://github.com/neovim/nvim-lspconfig/blob/master/lsp/clangd.lua

local uv = vim.uv or vim.loop
local root_markers = { ".clangd", "compile_commands.json", "compile_flags.txt", "CMakeLists.txt", ".git" }

local function get_clangd_binary()
	local preferred = "/usr/bin/clangd"
	if vim.fn.executable(preferred) == 1 then
		return preferred
	end

	local resolved = vim.fn.exepath("clangd")
	if resolved ~= "" then
		return resolved
	end

	return "clangd"
end

local function switch_source_header_splitcmd(bufnr, splitcmd, client)
	local method_name = "textDocument/switchSourceHeader"
	---@diagnostic disable-next-line:param-type-mismatch
	if not client or not client:supports_method(method_name) then
		return vim.notify(
			("Method %s is not supported by any active server attached to buffer"):format(method_name),
			vim.log.levels.ERROR,
			{ title = "LSP Error!" }
		)
	end
	local params = vim.lsp.util.make_text_document_params(bufnr)
	client:request(method_name, params, function(err, result)
		if err then
			error(tostring(err))
		end
		if not result then
			vim.notify("corresponding file cannot be determined")
			return
		end
		vim.api.nvim_command(splitcmd .. " " .. vim.uri_to_fname(result))
	end, bufnr)
end

local function symbol_info(bufnr, client)
	local method_name = "textDocument/symbolInfo"
	---@diagnostic disable-next-line:param-type-mismatch
	if not client or not client:supports_method(method_name) then
		return vim.notify("Clangd client not found", vim.log.levels.ERROR)
	end
	local win = vim.api.nvim_get_current_win()
	local params = vim.lsp.util.make_position_params(win, client.offset_encoding)
	---@diagnostic disable-next-line:param-type-mismatch
	client:request(method_name, params, function(err, res)
		if err or #res == 0 then
			-- Clangd always returns an error, there is no reason to parse it
			return
		end
		local container = string.format("container: %s", res[1].containerName) ---@type string
		local name = string.format("name: %s", res[1].name) ---@type string
		vim.lsp.util.open_floating_preview({ name, container }, "", {
			height = 2,
			width = math.max(string.len(name), string.len(container)),
			focusable = false,
			focus = false,
			title = "Symbol Info",
		})
	end, bufnr)
end

local function get_binary_path_list(binaries)
	local path_list = {}
	for _, binary in ipairs(binaries) do
		local path = vim.fn.exepath(binary)
		if path ~= "" then
			table.insert(path_list, path)
		end
	end
	return table.concat(path_list, ",")
end

local function is_file(path)
	local stat = uv.fs_stat(path)
	return stat ~= nil and stat.type == "file"
end

local function is_dir(path)
	local stat = uv.fs_stat(path)
	return stat ~= nil and stat.type == "directory"
end

local function find_compile_commands_dir(root_dir)
	if not root_dir or root_dir == "" then
		return nil
	end

	if is_file(vim.fs.joinpath(root_dir, "compile_commands.json")) then
		return root_dir
	end

	local candidates = {
		"build",
		"build-debug",
		"build-release",
		"cmake-build-debug",
		"cmake-build-release",
		"cmake-build-relwithdebinfo",
		"debug",
		"release",
		"out",
		"out/build",
	}

	for _, candidate in ipairs(candidates) do
		local dir = vim.fs.joinpath(root_dir, candidate)
		if is_dir(dir) and is_file(vim.fs.joinpath(dir, "compile_commands.json")) then
			return dir
		end
	end

	for name, file_type in vim.fs.dir(root_dir) do
		if file_type == "directory" and (name:match("^build") or name:match("^cmake%-build")) then
			local dir = vim.fs.joinpath(root_dir, name)
			if is_file(vim.fs.joinpath(dir, "compile_commands.json")) then
				return dir
			end
		end
	end

	return nil
end

local base_cmd = {
	get_clangd_binary(),
	"-j=12",
	"--enable-config",
	-- You MUST set this arg ↓ to your c/cpp compiler location (if not included)!
	"--query-driver=" .. get_binary_path_list({ "clang++", "clang", "gcc", "g++" }),
	"--all-scopes-completion",
	"--background-index",
	"--clang-tidy",
	"--completion-parse=auto",
	"--completion-style=bundled",
	"--function-arg-placeholders=true",
	"--header-insertion-decorators",
	"--header-insertion=iwyu",
	"--limit-references=1000",
	"--limit-results=300",
	"--pch-storage=memory",
}

local function build_clangd_cmd(root_dir)
	local cmd = vim.deepcopy(base_cmd)
	local compile_commands_dir = find_compile_commands_dir(root_dir)
	if compile_commands_dir then
		table.insert(cmd, "--compile-commands-dir=" .. compile_commands_dir)
	end
	return cmd
end

local function show_clangd_config(client)
	local root_dir = client.config.root_dir
	local compile_commands_dir = find_compile_commands_dir(root_dir)
	local cwd = client.config.cmd_cwd or root_dir or vim.uv.cwd()
	local lines = {
		("client: %s"):format(client.name),
		("root_dir: %s"):format(root_dir or "<nil>"),
		("cwd: %s"):format(cwd or "<nil>"),
		("compile_commands_dir: %s"):format(compile_commands_dir or "<nil>"),
		("cmd: %s"):format(table.concat(build_clangd_cmd(root_dir), " ")),
	}

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "clangd config" })
end

-- https://github.com/neovim/nvim-lspconfig/blob/master/lua/lspconfig/configs/clangd.lua
return function(defaults)
	vim.lsp.config("clangd", {
		name = "clangd",
		capabilities = vim.tbl_deep_extend("keep", { offsetEncoding = { "utf-16", "utf-8" } }, defaults.capabilities),
		single_file_support = true,
		root_markers = root_markers,
		cmd = function(dispatchers, config)
			return vim.lsp.rpc.start(build_clangd_cmd(config.root_dir), dispatchers, {
				cwd = config.cmd_cwd or config.root_dir,
				env = config.cmd_env,
				detached = config.detached,
			})
		end,
		on_attach = function(client, bufnr)
			vim.api.nvim_buf_create_user_command(bufnr, "LspClangdSwitchSourceHeader", function()
				switch_source_header_splitcmd(bufnr, "edit", client)
			end, { desc = "Open source/header in a new vsplit" })

			vim.api.nvim_buf_create_user_command(bufnr, "LspClangdSwitchSourceHeaderVsplit", function()
				switch_source_header_splitcmd(bufnr, "vsplit", client)
			end, { desc = "Open source/header in a new vsplit" })

			vim.api.nvim_buf_create_user_command(bufnr, "LspClangdSwitchSourceHeaderSplit", function()
				switch_source_header_splitcmd(bufnr, "split", client)
			end, { desc = "Open source/header in a new split" })

			vim.api.nvim_buf_create_user_command(bufnr, "LspClangdShowSymbolInfo", function()
				symbol_info(bufnr, client)
			end, { desc = "Show symbol info" })

			vim.api.nvim_buf_create_user_command(bufnr, "LspClangdShowConfig", function()
				show_clangd_config(client)
			end, { desc = "Show clangd root/cmd/compile_commands config" })
		end,
	})
end
