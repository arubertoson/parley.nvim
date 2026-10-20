---One-row help for the focused composer only. Visibility lasts for this Neovim
---process; closing the editor releases presentation, never a draft or its undo.
---The optional fallback float owns disposable scratch text and never takes focus.
local module_path = ...
local M = {}
local api = vim.api
local enabled = false
local namespace

---@class ParleyComposer.HelpFooter
---@field window? integer Non-focusing fallback presentation.
---@field buffer? integer Disposable scratch text, not a draft.
---@field row? ParleyNoteLine Last rendered chunks.

---@return boolean
function M.is_enabled()
    return enabled
end

function M.toggle()
    if vim.fn.mode() ~= "n" then
        return
    end
    enabled = not enabled
end

local function keycode(key)
    key = key:gsub("<([^>]+)>", function(name)
        if name:lower() == "leader" then
            return vim.g.mapleader or "\\"
        elseif name:lower() == "localleader" then
            return vim.g.maplocalleader or "\\"
        end
        return "<" .. name .. ">"
    end)
    return api.nvim_replace_termcodes(key, true, true, true)
end

local function readable_key(key)
    local names = {
        cr = "Enter",
        ["return"] = "Enter",
        esc = "Esc",
        space = "Space+",
        bs = "Backspace",
        leader = "<leader>",
        localleader = "<localleader>",
    }
    local modifiers = { c = "Ctrl-", s = "Shift-", a = "Alt-", m = "Alt-", d = "Super-" }
    key = key:gsub("<([^>]+)>", function(name)
        local prefix = ""
        while modifiers[name:sub(1, 1):lower()] and name:sub(2, 2) == "-" do
            prefix = prefix .. modifiers[name:sub(1, 1):lower()]
            name = name:sub(3)
        end
        local label = names[name:lower()] or name
        if prefix ~= "" and #name == 1 then
            label = name:upper()
        end
        return prefix .. label
    end)
    return (key:gsub(" ", "Space+"):gsub("%+$", ""))
end

---Select the first effective configured key per action, in the current mode.
---Only complete hints that fit are included; never wrap, clip a key or list aliases.
---Passive map queries avoid temporary buffer/window switches while typing.
---@param buffer integer
---@param bindings ParleyComposer.Mapping[]
---@param mode 'n'|'i'
---@param width integer
---@return ParleyNoteLine? row
function M.row(buffer, bindings, mode, width)
    if not enabled then
        return
    end
    local mappings = api.nvim_buf_get_keymap(buffer, mode)
    local function action_key(name)
        for _, binding in ipairs(bindings) do
            if binding.name == name and binding.mode == mode then
                local wanted = keycode(binding.key)
                for _, mapping in ipairs(mappings) do
                    local owned = mapping.desc == binding.description
                        and (
                            mapping.callback == binding.action
                            or (type(binding.action) == "string" and mapping.rhs == binding.action)
                        )
                    if owned and keycode(mapping.lhs) == wanted then
                        return readable_key(binding.key)
                    end
                end
            end
        end
    end
    local function native_key(key)
        local wanted = keycode(key)
        for _, maps in ipairs({ mappings, api.nvim_get_keymap(mode) }) do
            for _, mapping in ipairs(maps) do
                if keycode(mapping.lhs) == wanted then
                    return
                end
            end
        end
        return readable_key(key)
    end

    local next_key, previous_key = action_key("next"), action_key("previous")
    local navigation_key, navigation_label
    if next_key and previous_key then
        local prefix, suffix = next_key:match("^(.-%-)([^%-]+)$")
        local previous_prefix, previous_suffix = previous_key:match("^(.-%-)([^%-]+)$")
        if prefix and prefix == previous_prefix then
            navigation_key = prefix .. suffix .. "/" .. previous_suffix
        else
            navigation_key = next_key .. "/" .. previous_key
        end
        navigation_label = "messages"
    elseif next_key then
        navigation_key, navigation_label = next_key, "next message"
    elseif previous_key then
        navigation_key, navigation_label = previous_key, "prev message"
    end

    local hints = {
        { key = action_key("accept") or action_key("accept_normal"), label = "save" },
        { key = action_key("newline"), label = "newline" },
        {
            key = mode == "i" and native_key("<Esc>") or nil,
            label = "normal",
        },
        { key = action_key("close"), label = "close" },
        { key = navigation_key, label = navigation_label },
        { key = action_key("help") or action_key("help_normal"), label = "help" },
    }
    local row, used = {}, 0
    for _, hint in ipairs(hints) do
        if hint.key then
            local separator = used > 0 and " · " or ""
            local size = vim.fn.strdisplaywidth(separator .. hint.key .. " " .. hint.label)
            if used + size <= width - 2 then
                row[#row + 1] = { separator, "ParleyComposerHelp" }
                row[#row + 1] = { hint.key, "ParleyComposerHelpKey" }
                row[#row + 1] = { " " .. hint.label, "ParleyComposerHelp" }
                used = used + size
            end
        end
    end
    if #row == 0 then
        return
    end
    -- Only the annotation has a dark background, with a one-cell inset.
    -- Unused space remains part of the composer rather than a full-width strip.
    table.insert(row, 1, { " ", "ParleyComposerHelp" })
    row[#row + 1] = { " ", "ParleyComposerHelp" }
    table.insert(row, 1, { string.rep(" ", width - used - 2), "ParleyReviewNoteActive" })
    return row
end

---@param footer ParleyComposer.HelpFooter Repeated close is safe.
function M.close(footer)
    local window, buffer = footer.window, footer.buffer
    footer.window, footer.buffer, footer.row = nil, nil, nil
    if window and api.nvim_win_is_valid(window) and api.nvim_win_get_buf(window) == buffer then
        api.nvim_win_close(window, true)
    end
    if buffer and api.nvim_buf_is_valid(buffer) then
        api.nvim_buf_delete(buffer, { force = true })
    end
end

---Editors without borrowed source room use the same single row below the border.
---@param footer ParleyComposer.HelpFooter Caller closes on teardown/setup failure.
---@param row ParleyNoteLine
---@param config vim.api.keyset.win_config Source-relative position and width.
function M.present(footer, row, config)
    if not footer.buffer or not api.nvim_buf_is_valid(footer.buffer) then
        footer.buffer = api.nvim_create_buf(false, true)
        vim.bo[footer.buffer].bufhidden = "hide"
        footer.row = nil
    end
    if not vim.deep_equal(footer.row, row) then
        namespace = namespace or api.nvim_create_namespace(module_path .. ".footer")
        local text = {}
        for _, chunk in ipairs(row) do
            text[#text + 1] = chunk[1]
        end
        api.nvim_buf_set_lines(footer.buffer, 0, -1, false, { table.concat(text) })
        api.nvim_buf_clear_namespace(footer.buffer, namespace, 0, -1)
        local column = 0
        for _, chunk in ipairs(row) do
            if #chunk[1] > 0 then
                api.nvim_buf_set_extmark(footer.buffer, namespace, 0, column, {
                    end_col = column + #chunk[1],
                    hl_group = chunk[2],
                })
            end
            column = column + #chunk[1]
        end
        footer.row = row
    end
    config.height = 1
    if
        footer.window
        and api.nvim_win_is_valid(footer.window)
        and api.nvim_win_get_buf(footer.window) ~= footer.buffer
    then
        -- An external action replaced our display. Leave its window alone.
        footer.window = nil
    end
    if not footer.window or not api.nvim_win_is_valid(footer.window) then
        config.style = "minimal"
        config.border = "none"
        config.focusable = false
        config.mouse = false
        config.noautocmd = true
        config.zindex = 60
        footer.window = api.nvim_open_win(footer.buffer, false, config)
        vim.wo[footer.window].wrap = false
        vim.wo[footer.window].signcolumn = "no"
        vim.wo[footer.window].winhighlight =
            "Normal:ParleyReviewNoteActive,NormalFloat:ParleyReviewNoteActive,EndOfBuffer:ParleyReviewNoteActive"
    else
        api.nvim_win_set_config(footer.window, config)
    end
end

return M
