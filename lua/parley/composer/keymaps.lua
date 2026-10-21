---Key defaults for the portable composer, plus normalization shared by its host.
---Resolution copies keys; it never installs mappings or retains caller tables.
local M = {}

---@alias ParleyKeymapKeys string|string[]|false
---@alias ParleyKeymapOverrides table<string, ParleyKeymapKeys>|false

---@class ParleyComposer.Keymaps
---@field accept? ParleyKeymapKeys Normal/Insert: accept locally and close.
---@field accept_normal? ParleyKeymapKeys Normal-only: accept locally and leave the surrounding thread.
---@field newline? ParleyKeymapKeys Insert: insert a newline.
---@field close? ParleyKeymapKeys Normal/Insert: close and retain unfinished edits.
---@field next? ParleyKeymapKeys Normal/Insert: visit the next note.
---@field previous? ParleyKeymapKeys Normal/Insert: visit the previous note.
---@field help? ParleyKeymapKeys Normal-only: toggle contextual hotkey footer.
---@field help_normal? ParleyKeymapKeys Optional Normal-only help alias.

local composer_defaults = {
    accept = "<CR>",
    accept_normal = "q",
    newline = { "<C-j>", "<C-CR>" },
    close = "<C-c>",
    next = "<C-n>",
    previous = "<C-p>",
    help = "<leader>?",
    help_normal = false,
}

---An omitted action retains its defaults; false or an empty list disables it.
---Invalid configuration throws before any mappings are installed.
---@param defaults table<string, ParleyKeymapKeys>
---@param overrides? ParleyKeymapOverrides
---@return table<string, string[]> keys Fresh normalized action keys.
function M.resolve(defaults, overrides)
    if overrides ~= nil and overrides ~= false and type(overrides) ~= "table" then
        error("Parley: keymaps must be an action table or false", 2)
    end
    if type(overrides) == "table" then
        for name in pairs(overrides) do
            if defaults[name] == nil then
                error("Parley: unknown keymap action " .. tostring(name), 2)
            end
        end
    end

    local resolved = {}
    for name, default in pairs(defaults) do
        local value = default
        if overrides == false then
            value = false
        elseif overrides and overrides[name] ~= nil then
            value = overrides[name]
        end

        local keys = {}
        if value ~= false then
            if type(value) == "string" then
                value = { value }
            end
            if type(value) ~= "table" or not vim.islist(value) then
                error("Parley: keymap " .. name .. " must be a key, list of keys, or false", 2)
            end
            for _, key in ipairs(value) do
                if type(key) ~= "string" or key == "" then
                    error("Parley: keymap " .. name .. " requires non-empty key strings", 2)
                end
                keys[#keys + 1] = key
            end
        end
        resolved[name] = keys
    end
    return resolved
end

---Freeze leader expansion at installation, not at teardown or help rendering.
---@param key string
---@return string
function M.concrete(key)
    return (
        key:gsub("<([^>]+)>", function(name)
            if name:lower() == "leader" then
                return vim.g.mapleader or "\\"
            elseif name:lower() == "localleader" then
                return vim.g.maplocalleader or "\\"
            end
            return "<" .. name .. ">"
        end)
    )
end

---@param overrides? ParleyComposer.Keymaps|false
---@return table<string, string[]> keys Fresh normalized composer keys.
function M.resolve_composer(overrides)
    return M.resolve(composer_defaults, overrides)
end

return M
