default:
    @just --list

test:
    @nvim --headless --noplugin -u tests/init.lua -c "lua MiniTest.run()"

test-file file:
    @nvim --headless --noplugin -u tests/init.lua -c "lua MiniTest.run_file('{{file}}')"

format:
    @stylua .

format-check:
    @stylua --check .
