# parley.nvim

> Let's talk about this change.

`parley.nvim` keeps the review beside the code—not in a permanent chat panel.
Freeze a set of changes in Pi, read them in Neovim, and leave comments where they
belong. Hand over a review turn when you are ready; read the replies and follow up.

Pi remains available while you review. Reopening a review restores the original
code, even if the working copy or branch has changed.

## The loop

1. Run `/review` in Pi; choose the scope and curate the context to share.
2. Run `:ReviewStart` in Neovim; select the frozen review in this workspace.
3. Navigate the changes, compare both sides, and collect comments.
4. Submit explicitly with `:ReviewTurn`; replies wait until Pi is available.
5. Follow up beside the code, or detach and return later.

Saving comments is not submission. The implementation conversation is not copied
into the review automatically.

## What it deliberately is not

Parley is not an autonomous fixer, an agent dashboard, or a replacement editor.
It does not check out revisions, branch your Pi conversation, launch another agent
process, or grant permission to change code. Your configuration owns the layout
and statusline.

## Status and requirements

Personal software, still under development; no release or compatibility promise.

- Neovim with the experimental `nvim__ns_set` API; tested on 0.13-dev.
- An interactive Pi process; integration tested with Pi 1.1.0.
- Git or jj for the workspace, and Unix-domain socket support.

## Installation

Install the two parts separately from the same local checkout.

### 1. Neovim

Register the checkout in your Neovim configuration/plugin manager, or add it to
`runtimepath` during startup:

```lua
vim.opt.runtimepath:prepend("/absolute/path/to/parley.nvim")
```

No `setup()` call is required.

### 2. Pi

```sh
pi install /absolute/path/to/parley.nvim
```

Alternatively, add that path to `packages` in `~/.pi/agent/settings.json`.
Run `/reload` or restart Pi afterward. When migrating, remove the old `review.ts`
extension so only Parley registers `/review`. Neither part installs the other.

## Review controls

| Command | Action |
| --- | --- |
| `:ReviewStart` | Select and attach to a workspace review |
| `:ReviewSave` | Save comments without starting an agent turn |
| `:ReviewTurn` | Explicitly submit saved comments |
| `:ReviewReply` | Compose an explicitly linked follow-up |
| `:ReviewStop` | Detach without closing or deleting the review |
| `:ReviewClose` | Close the review, retaining its contents |

In the review buffer, use `[c` / `]c` to navigate changes, `c` to comment on a line
or visual selection, `C` to comment on a hunk, and `<Space>` to compare both sides.
`<CR>` edits a selected note; in the composer it saves the comment.
`<F1>` shows the available buffer-local controls.
