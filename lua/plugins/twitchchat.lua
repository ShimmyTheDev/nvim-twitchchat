local M = {}

-- Helper function to wrap a single line to a maximum width.
local function wrap_text(text, width)
	local lines = {}
	while vim.fn.strdisplaywidth(text) > width do
		local breakpoint = width
		local subtext = text:sub(1, breakpoint)
		local last_space = subtext:match(".*()%s+")
		if last_space and last_space > 1 then
			breakpoint = last_space - 1
		end
		table.insert(lines, text:sub(1, breakpoint))
		text = text:sub(breakpoint + 1):gsub("^%s+", "")
	end
	if text ~= "" then
		table.insert(lines, text)
	end
	return lines
end

-- Setup function for configurable options.
M.setup = function(user_opts)
	-- Default options.
	local default_opts = {
		width = 40, -- window width (characters)
		height = 20, -- window height (lines)
		row = 1,
		col = vim.o.columns - 45,
		border = "single",
		title = { { "Twitch Chat" } },
		title_pos = "right",
		winblend = 10,
		max_lines = 100,
		channel = "",
		client_id = "", -- Twitch API client ID (required)
		client_secret = "", -- Twitch API client secret (required)
	}
	local opts = vim.tbl_deep_extend("force", default_opts, user_opts or {})

	local prev_win = vim.api.nvim_get_current_win()

	local win_opts = {
		style = "minimal",
		relative = "editor",
		width = opts.width,
		height = opts.height,
		row = opts.row,
		col = opts.col,
		border = opts.border,
		focusable = false,
		title = opts.title,
		title_pos = opts.title_pos,
	}
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, false, win_opts)
	vim.api.nvim_set_option_value("winblend", opts.winblend, { win = win })
	vim.api.nvim_set_option_value("wrap", true, { win = win })

	-- Make buffer non-editable.
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("readonly", true, { buf = buf })

	-- Autocommand: if focus enters our chat window, switch back to the previous window.
	vim.api.nvim_create_autocmd("WinEnter", {
		buffer = buf,
		callback = function()
			if vim.api.nvim_get_current_win() == win then
				vim.api.nvim_set_current_win(prev_win)
			end
		end,
	})

	-- Define a highlight group for the nickname: bold with 10% transparency.
	vim.api.nvim_set_hl(0, "TwitchChatNickname", { bold = true, blend = 10, fg = "#ffffff" })
	local ns = vim.api.nvim_create_namespace("TwitchChat")

	local function fetch_oauth_token()
		local http = require("socket.http")
		local ltn12 = require("ltn12")
		local json = require("cjson")
		local url = "https://id.twitch.tv/oauth2/token"
		local body = "client_id="
			.. opts.client_id
			.. "&client_secret="
			.. opts.client_secret
			.. "&grant_type=client_credentials"
		local response = {}

		local res, code, headers = http.request({
			url = url,
			method = "POST",
			headers = {
				["Content-Type"] = "application/x-www-form-urlencoded",
				["Content-Length"] = tostring(#body),
			},
			source = ltn12.source.string(body),
			sink = ltn12.sink.table(response),
		})

		local response_body = table.concat(response)
		local data = json.decode(response_body)
		if code == 200 then
			return data.access_token
		else
			print("Failed to fetch OAuth token: " .. response_body)
			return nil
		end
	end

	local oauth_token = fetch_oauth_token()
	if not oauth_token then
		return
	end

	local socket = require("socket")
	local ws = socket.tcp()
	ws:settimeout(5)
	local success, err = ws:connect("irc.chat.twitch.tv", 6667)
	if not success then
		print("Failed to connect: " .. err)
		return
	end
	ws:settimeout(0)
	ws:send("PASS oauth:" .. oauth_token .. "\r\n")
	ws:send("NICK justinfan12345\r\n")
	ws:send("JOIN #" .. opts.channel .. "\r\n")

	local timer = vim.loop.new_timer()
	timer:start(0, 100, function()
		local data, err = ws:receive("*l")
		if data then
			if data:match("PRIVMSG") then
				local user = data:match(":([%w_]+)!")
				local message = data:match("PRIVMSG%s+#[%w_]+%s+:(.+)")
				if user and message then
					vim.schedule(function()
						-- Temporarily allow modifications.
						vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
						vim.api.nvim_set_option_value("readonly", false, { buf = buf })

						local full_line = user .. ": " .. message
						-- Split by newline (if any) then wrap each line.
						local raw_lines = vim.split(full_line, "\n")
						local wrapped = {}
						for _, l in ipairs(raw_lines) do
							for _, w in ipairs(wrap_text(l, opts.width)) do
								table.insert(wrapped, w)
							end
						end

						local current_line = vim.api.nvim_buf_line_count(buf)
						vim.api.nvim_buf_set_lines(buf, current_line, current_line, false, wrapped)
						-- Highlight the nickname on the first wrapped line.
						vim.api.nvim_buf_add_highlight(buf, ns, "TwitchChatNickname", current_line, 0, #user)

						-- Trim the buffer if it exceeds the max lines.
						local total = vim.api.nvim_buf_line_count(buf)
						if total > opts.max_lines then
							vim.api.nvim_buf_set_lines(buf, 0, total - opts.max_lines, false, {})
						end

						vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
						vim.api.nvim_set_option_value("readonly", true, { buf = buf })
					end)
				end
			end
		elseif err and err ~= "timeout" then
			timer:stop()
			ws:close()
		end
	end)
end

return M
