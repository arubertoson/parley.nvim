# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Test (Lua):** `just test`
  - Requires Neovim and installed `mini.nvim`.
- **Test file (Lua):** `just test-file tests/test_review.lua`
- **Test (TypeScript):** `npm test`
  - Requires Node with native TypeScript support.
- **Formatting (Lua):** `just format`
- **Formatting check (Lua):** `just format-check`

## Directory Structure

- Neovim plugin: `lua/parley/` and `plugin/`
- Pi extension: `pi/`
- Tests: `tests/`
