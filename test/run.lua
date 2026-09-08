-- test/run.lua
--
-- Golden-file harness over the one pure function in the plugin:
--
--   nvim --headless -u NONE -l test/run.lua          check every fixture
--   MDVIEW_UPDATE=1 nvim --headless -u NONE -l test/run.lua   rewrite the goldens
--
-- Each test/fixtures/<name>.md is parsed, its full-buffer op list is serialised
-- deterministically, and the result is compared with test/fixtures/<name>.expected.
-- Exits non-zero on the first mismatch so it can gate a commit.
--
-- `-u NONE` is deliberate: it keeps the user's config out of the result, and the
-- markdown parser Neovim bundles is enough to parse every fixture. That parser's
-- version is therefore baked into the goldens -- a Neovim upgrade that changes the
-- markdown grammar will show up here as a diff, which is the point.
--
-- Only the Lua half is covered. Extmark placement, option handling and the autocmd
-- lifecycle are Vimscript and are checked by the acceptance criteria in DESIGN.md
-- section 9.
--
-- Two checks per fixture. The goldens record the ops for the whole buffer, which
-- is the content of the rendering. The viewport sweep below then asks for every
-- (srow, erow) window over the same fixture and checks the shape of what comes
-- back, because a golden taken over the whole buffer cannot see an op that is
-- only malformed when the window starts halfway down a node.

local script = debug.getinfo(1, "S").source:sub(2)
local test_dir = vim.fs.dirname(script)
local root = vim.fs.dirname(test_dir)
local fixture_dir = test_dir .. "/fixtures"

vim.opt.runtimepath:append(root)

-- The thematic-break rule and the diff-block border are sized from the window
-- width, so a golden is only meaningful at a stated width. get_render_ops takes
-- that width as an argument, so pin it here rather than let whoever runs the
-- harness decide it. (Setting 'columns' would not do: headless Neovim has no UI
-- to resize, so the window keeps its 80 cells whatever 'columns' says.)
local WIDTH = 80

local backend = require("mdview.backend")

local UPDATE = vim.env.MDVIEW_UPDATE ~= nil and vim.env.MDVIEW_UPDATE ~= ""

-- Quote a field so trailing spaces and empty strings stay visible in a diff.
-- Icon glyphs are left as themselves: the goldens are meant to be read.
local function quote(s)
    if s == "" then
        return '""'
    end
    return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
end

-- One line per op. The backend already sorts, but sorting again here means a
-- change to its ordering shows up as a real diff rather than silently passing.
local function serialise(ops)
    local sorted = vim.deepcopy(ops)
    table.sort(sorted, function(a, b)
        if a.row ~= b.row then return a.row < b.row end
        if a.col ~= b.col then return a.col < b.col end
        if a.kind ~= b.kind then return a.kind < b.kind end
        if a.hl ~= b.hl then return a.hl < b.hl end
        return a.text < b.text
    end)

    local lines = {}
    for _, o in ipairs(sorted) do
        lines[#lines + 1] = string.format(
            "%-9s (%d,%d)-(%d,%d) p%-4d %-18s %s",
            o.kind, o.row, o.col, o.end_row, o.end_col,
            o.priority, o.hl == "" and "-" or o.hl, quote(o.text))
    end
    if #lines == 0 then
        lines[1] = "(no ops)"
    end
    return lines
end

local function buffer_for(path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].filetype = "markdown"
    return bufnr
end

local function ops_for(path)
    local bufnr = buffer_for(path)
    return backend.get_render_ops(bufnr, 0, vim.api.nvim_buf_line_count(bufnr) - 1, WIDTH)
end

-- What an op has to satisfy for the Vimscript half to be able to place it, over
-- and above matching a golden.
--
-- A byte range that runs backwards is the one that matters: nvim_buf_set_extmark
-- accepts `(22,2)-(22,0)` without complaint and draws the wrong thing, so nothing
-- surfaces at runtime. It comes from a renderer measuring a line the render never
-- fetched, which is also why a row outside the requested window is an error here
-- -- with `hide_line` the exception, since hiding a line is what moves the window
-- and so is deliberately not clipped to it.
local KINDS = {
    conceal = true, replace = true, inline = true, hl = true,
    line = true, hide_line = true, above = true, below = true,
}

local function op_faults(o, srow, erow, lines)
    local faults = {}
    local function fault(fmt, ...) faults[#faults + 1] = string.format(fmt, ...) end

    if not KINDS[o.kind] then
        fault("unknown kind %q", tostring(o.kind))
        return faults
    end
    if o.end_row < o.row or (o.end_row == o.row and o.end_col < o.col) then
        fault("range runs backwards")
    end
    if o.kind ~= "hide_line" and (o.row < srow or o.end_row > erow) then
        fault("row outside the requested window")
    end
    for _, pos in ipairs({ { o.row, o.col }, { o.end_row, o.end_col } }) do
        local line = lines[pos[1] + 1]
        if not line then
            fault("row %d past the end of the buffer", pos[1])
        elseif pos[2] > #line then
            fault("column %d past the end of row %d (%d bytes)", pos[2], pos[1], #line)
        end
    end
    return faults
end

local function describe(o)
    return string.format("%s (%d,%d)-(%d,%d) %s", o.kind, o.row, o.col,
        o.end_row, o.end_col, quote(o.text))
end

-- Every window over the fixture, not a sample: the fixtures are tens of lines,
-- and the defect this was written for showed up in exactly three of the 55
-- windows over the file that has it.
local function sweep(path)
    local bufnr = buffer_for(path)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local last = #lines - 1
    local windows, reported = 0, 0

    for srow = 0, last do
        for erow = srow, last do
            windows = windows + 1
            for _, o in ipairs(backend.get_render_ops(bufnr, srow, erow, WIDTH)) do
                for _, fault in ipairs(op_faults(o, srow, erow, lines)) do
                    reported = reported + 1
                    if reported <= 5 then
                        print(string.format("     [%d..%d] %s: %s", srow, erow, fault, describe(o)))
                    end
                end
            end
        end
    end
    if reported > 5 then
        print(string.format("     ... and %d more", reported - 5))
    end
    return windows, reported
end

-- First differing line, with a little context either side.
local function report_diff(name, expected, actual)
    print("FAIL " .. name)
    local n = math.max(#expected, #actual)
    local first
    for i = 1, n do
        if expected[i] ~= actual[i] then
            first = i
            break
        end
    end
    print(string.format("     %d expected lines, %d actual; first difference at line %d",
        #expected, #actual, first or 0))
    for i = math.max(1, (first or 1) - 2), math.min(n, (first or 1) + 2) do
        local e, a = expected[i], actual[i]
        if e == a then
            print("       " .. i .. "   " .. (e or ""))
        else
            if e then print("       " .. i .. " - " .. e) end
            if a then print("       " .. i .. " + " .. a) end
        end
    end
end

local fixtures = vim.fn.glob(fixture_dir .. "/*.md", false, true)
table.sort(fixtures)

if #fixtures == 0 then
    print("no fixtures found in " .. fixture_dir)
    os.exit(1)
end

local failed, updated = 0, 0

for _, path in ipairs(fixtures) do
    local name = vim.fs.basename(path):gsub("%.md$", "")
    local golden = fixture_dir .. "/" .. name .. ".expected"
    local ops = ops_for(path)
    local actual = serialise(ops)
    local count = #ops .. " op" .. (#ops == 1 and "" or "s")

    if UPDATE then
        vim.fn.writefile(actual, golden)
        updated = updated + 1
        print("updated " .. name .. " (" .. count .. ")")
    elseif vim.fn.filereadable(golden) == 0 then
        print("FAIL " .. name .. ": no golden at " .. golden
            .. " (run with MDVIEW_UPDATE=1 to create it)")
        failed = failed + 1
    else
        local expected = vim.fn.readfile(golden)
        if vim.deep_equal(expected, actual) then
            print("ok   " .. name .. " (" .. count .. ")")
        else
            report_diff(name, expected, actual)
            failed = failed + 1
        end
    end
end

if UPDATE then
    print(string.format("\n%d golden file(s) written. Read the diff before committing:"
        .. " an updated golden is only correct if you checked it.", updated))
    os.exit(0)
end

local windows, faults = 0, 0
for _, path in ipairs(fixtures) do
    local name = vim.fs.basename(path):gsub("%.md$", "")
    local w, f = sweep(path)
    windows, faults = windows + w, faults + f
    if f > 0 then
        print("FAIL " .. name .. ": " .. f .. " malformed op(s) over " .. w .. " windows")
        failed = failed + 1
    end
end

print(string.format("\n%d fixture(s), %d viewport windows, %d malformed op(s), %d failed",
    #fixtures, windows, faults, failed))
os.exit(failed == 0 and 0 or 1)
