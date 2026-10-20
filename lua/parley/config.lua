---Optional key choices only. Hosts and UI lifecycles own the mappings.
---Each configuration call replaces prior choices without retaining caller tables.
local keymaps = require("parley.composer.keymaps")
local discussion = require("parley.discussion")
local M = {}

---@class ParleyConfig.ReviewKeymaps
---@field comment? ParleyKeymapKeys Normal/Visual: compose a line/range note.
---@field edit? ParleyKeymapKeys Normal/Visual: resume or compose a note.
---@field enter? ParleyKeymapKeys Normal: read history or continue the previewed draft.
---@field reply? ParleyKeymapKeys Normal: reply directly to a thread preview (demo host).
---@field next? ParleyKeymapKeys Normal: visit the next note.
---@field previous? ParleyKeymapKeys Normal: visit the previous note.

---@class ParleyConfig.Keymaps
---@field review? ParleyConfig.ReviewKeymaps|false
---@field composer? ParleyComposer.Keymaps|false
---@field discussion? ParleyDiscussion.Keymaps|false

---@class ParleyConfig.Options
---@field keymaps? ParleyConfig.Keymaps|false False disables all groups of defaults.

---@class ParleyConfig.Resolved
---@field review table<string, string[]>
---@field composer table<string, string[]>
---@field discussion table<string, string[]>

local review_defaults = {
    comment = "c",
    edit = "C",
    enter = "<CR>",
    reply = false,
    next = "<C-n>",
    previous = "<C-p>",
}

---@type ParleyConfig.Resolved
local configured = {
    review = keymaps.resolve(review_defaults),
    composer = keymaps.resolve_composer(),
    discussion = discussion.resolve_keymaps(),
}

---Validate all groups before replacing configuration. The public setup action
---must ensure review mode is inactive; existing mapping ownership never migrates.
---@param options? ParleyConfig.Options
function M.configure(options)
    if options == nil then
        options = {}
    end
    if type(options) ~= "table" then
        error("Parley: setup expects an options table", 2)
    end
    for name in pairs(options) do
        if name ~= "keymaps" then
            error("Parley: unknown option " .. tostring(name), 2)
        end
    end

    local groups = options.keymaps
    if groups == nil then
        groups = {}
    elseif groups == false then
        groups = { review = false, composer = false, discussion = false }
    elseif type(groups) ~= "table" then
        error("Parley: keymaps expects review/composer/discussion groups or false", 2)
    end
    for name in pairs(groups) do
        if name ~= "review" and name ~= "composer" and name ~= "discussion" then
            error("Parley: unknown keymap group " .. tostring(name), 2)
        end
    end

    configured = {
        review = keymaps.resolve(review_defaults, groups.review),
        composer = keymaps.resolve_composer(groups.composer),
        discussion = discussion.resolve_keymaps(groups.discussion),
    }
end

---Borrow read-only until the next configure call. Active reviews retain their
---snapshot so teardown always uses exactly the keys installed at activation.
---@return ParleyConfig.Resolved
function M.get()
    return configured
end

return M
