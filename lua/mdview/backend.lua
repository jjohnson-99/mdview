-- lua/mdview/backend.lua
--
-- Treesitter -> render ops. This half of the plugin reads the tree and returns
-- data; it never places an extmark, sets an option or touches buffer text.
--
-- An op record is the whole contract with autoload/mdview.vim:
--
--   row, col, end_row, end_col   0-based, end_col exclusive, BYTE offsets
--   kind                         conceal | replace | hl | line | hide_line
--                                | above | below
--   text                         replacement / virtual text, "" when unused
--   hl                           highlight group, "" when unused
--   priority                     extmark priority
--
-- Every field is present on every record: luaeval drops nil values and the
-- Vimscript side would then have to guard each access. Columns are byte offsets
-- because that is what both treesitter and nvim_buf_set_extmark speak; the two
-- uses of display width in this file are labelled where they occur, and both
-- measure against the `width` argument.

local M = {}

-- Backgrounds sit under the markers so a heading icon keeps its own colour.
local PRIO_BACKGROUND = 90
local PRIO_MARKER = 100

local DEFAULT_HEADING_ICONS = { "\xe2\x97\x88 ", "\xe2\x97\x86 ", "\xe2\x96\xb8 ",
                                "\xe2\x96\xb9 ", "\xc2\xb7 ", "\xc2\xb7 " } -- ◈ ◆ ▸ ▹ · ·
local DEFAULT_BULLET_ICONS = { "\xe2\x97\x8f ", "\xe2\x97\x8b ",
                               "\xe2\x97\x86 ", "\xe2\x97\x87 " }           -- ● ○ ◆ ◇
local DEFAULT_CHECKED_ICON = "\xf3\xb0\xb1\x92 "                            -- 󰱒
local DEFAULT_UNCHECKED_ICON = "\xf3\xb0\x84\xb1 "                          -- 󰄱
local DEFAULT_QUOTE_ICON = "\xe2\x96\x8e "                                  -- ▎
local DEFAULT_RULE_CHAR = "\xe2\x94\x80"                                    -- ─

-- Options are read on every render so `:let g:mdview_...` takes effect on the
-- next redraw rather than on the next :MdviewEnable.
local function opt(name, default)
    local value = vim.g[name]
    if value == nil then
        return default
    end
    return value
end


--=================================================
-- Op construction and viewport clipping.

local function op(kind, row, col, end_row, end_col, text, hl, priority)
    return {
        row = row,
        col = col,
        end_row = end_row,
        end_col = end_col,
        kind = kind,
        text = text or "",
        hl = hl or "",
        priority = priority,
    }
end

-- Buffer line for an absolute row. nil when the row is outside the slice this
-- render fetched, which every caller but on_thematic_break has already ruled
-- out by the shape of the node it captured. Returning "" instead measured such
-- a row as empty and emitted ops whose byte range ran backwards, which
-- nvim_buf_set_extmark accepts without complaint.
local function line_at(ctx, row)
    return ctx.lines[row - ctx.srow + 1]
end

-- Byte column of the first non-space at or after `col`. Markers such as `#` and
-- `[ ]` do not include the space that separates them from the text, so the ops
-- that replace them swallow it and let the icon carry its own spacing instead.
local function skip_spaces(line, col)
    local stop = line:find("[^ ]", col + 1)
    return stop and (stop - 1) or #line
end

-- Byte column just past the last non-space in `[col, end_col)`. The mirror of
-- skip_spaces, for a marker node that swallows the whitespace after it rather
-- than before: `2.   item` gives one marker node five columns wide.
local function trim_trailing(line, col, end_col)
    local text = line:sub(col + 1, end_col):match("^(.-)%s*$")
    return col + #text
end

-- Last row a block node actually occupies. Block nodes end at column 0 of the
-- following line (`# H1` on row 0 has range (0,0)-(1,0)), so a line background
-- taken straight from the node range bleeds onto the next line.
local function last_row(node)
    local end_row, end_col = node:end_()
    if end_col == 0 and end_row > node:start() then
        return end_row - 1
    end
    return end_row
end

-- A multi-line node straddling the viewport edge still has visible rows, so its
-- line ops are clamped rather than dropped.
local function add_line(ctx, row, end_row, hl)
    row = math.max(row, ctx.srow)
    end_row = math.min(end_row, ctx.erow)
    if end_row < row then
        return
    end
    ctx.ops[#ctx.ops + 1] = op("line", row, 0, end_row, 0, "", hl, PRIO_BACKGROUND)
end

local function add(ctx, record)
    ctx.ops[#ctx.ops + 1] = record
end


--=================================================
-- Renderers, one per capture name.

local function on_atx_heading(ctx, node, capture)
    local level = tonumber(capture:sub(-1))
    local row, col = node:start()
    local _, marker_end = node:end_()
    local line = line_at(ctx, row)

    local icons = opt("mdview_HeadingIcons", DEFAULT_HEADING_ICONS)
    add(ctx, op("replace", row, col, row, skip_spaces(line, marker_end),
        icons[level] or "", "MdviewH" .. level, PRIO_MARKER))

    -- A heading's optional closing `#` sequence has no node of its own, so it
    -- is found in the line text instead.
    local close = line:find("%s+#+%s*$", marker_end + 1)
    if close then
        add(ctx, op("conceal", row, close - 1, row, #line, "", "", PRIO_MARKER))
    end

    add_line(ctx, row, row, "MdviewH" .. level .. "Bg")
end

-- There is no marker to conceal, so a setext heading renders as a background
-- over its text rows and nothing else. The underline stays visible: section 1.1
-- asks for a background and nothing more, and hiding it is a change to that.
--
-- Whether a heading row carries a background at all is g:mdview_HeadingBlend,
-- which the highlight group answers on its own: at 0 MdviewHNBg is cleared and
-- the op draws nothing.
local function on_setext_heading(ctx, node, capture)
    local content = node:field("heading_content")[1]
    if not content then
        return
    end
    local level = tonumber(capture:sub(-1))
    add_line(ctx, content:start(), last_row(content), "MdviewH" .. level .. "Bg")
end

-- Nesting depth comes from the count of enclosing `list` nodes. Deriving it
-- from the indent column would need a spaces-per-level guess, and markdown
-- indents a sublist by the width of its parent's marker, not by 'shiftwidth'.
local function list_depth(node)
    local depth = 0
    local parent = node:parent()
    while parent do
        if parent:type() == "list" then
            depth = depth + 1
        end
        parent = parent:parent()
    end
    return math.max(depth - 1, 0)
end

local TASK_MARKERS = {
    ["task_list_marker_checked"]   = true,
    ["task_list_marker_unchecked"] = true,
}

-- A task marker is a sibling of the list marker, so a task item is recognised
-- by looking across at the parent's other children rather than down.
local function is_task_item(marker)
    local item = marker:parent()
    if not item then
        return false
    end
    for child in item:iter_children() do
        if TASK_MARKERS[child:type()] then
            return true
        end
    end
    return false
end

-- List markers include their trailing space, so concealing the whole node and
-- letting the icon supply its own space keeps the text where it was.
--
-- A task item shows only its checkbox: the marker is concealed with nothing in
-- its place, which puts the checkbox where the bullet would have been. The
-- indent ahead of the marker is not part of the node, so nesting still reads.
local function on_bullet(ctx, node)
    local row, col = node:start()
    local _, end_col = node:end_()
    if is_task_item(node) then
        add(ctx, op("conceal", row, col, row, end_col, "", "", PRIO_MARKER))
        return
    end
    local icons = opt("mdview_BulletIcons", DEFAULT_BULLET_ICONS)
    local icon = icons[(list_depth(node) % #icons) + 1]
    add(ctx, op("replace", row, col, row, end_col, icon, "MdviewBullet", PRIO_MARKER))
end

-- An ordered marker is recoloured where it stands and nothing else happens to
-- it. Its digits are content, not syntax, and they are variable width, so a
-- conceal loses what the item is numbered and a replacement moves every column
-- after it. The unordered case can swap `-` for a bullet only because the two
-- are one cell each and the `-` itself carries no information.
--
-- The highlight stops before the whitespace the node swallows, so the group is
-- over the marker as written rather than over the gap as well.
local function on_ordered(ctx, node)
    local row, col = node:start()
    local _, end_col = node:end_()
    add(ctx, op("hl", row, col, row,
        trim_trailing(line_at(ctx, row), col, end_col),
        "", "MdviewOrdered", PRIO_MARKER))
end

-- A task marker is a sibling of the list marker, not a child of it, so the two
-- are handled independently: the marker is concealed and the checkbox replaces
-- the `[ ]` in its own right.
local function on_task_marker(ctx, node, capture)
    local checked = capture == "checked"
    local row, col = node:start()
    local _, end_col = node:end_()
    local icon = checked and opt("mdview_CheckedIcon", DEFAULT_CHECKED_ICON)
        or opt("mdview_UncheckedIcon", DEFAULT_UNCHECKED_ICON)
    add(ctx, op("replace", row, col, row, skip_spaces(line_at(ctx, row), end_col),
        icon, checked and "MdviewChecked" or "MdviewUnchecked", PRIO_MARKER))
end

local function on_quote_marker(ctx, node)
    local row, col = node:start()
    local _, end_col = node:end_()
    add(ctx, op("replace", row, col, row, end_col,
        opt("mdview_QuoteIcon", DEFAULT_QUOTE_ICON), "MdviewQuote", PRIO_MARKER))
end

-- A continuation carries one `>` per enclosing quote, e.g. `> > ` inside a
-- nested quote, so the bar is drawn as many times as there are markers.
--
-- The node also covers the indent of any enclosing list item: inside `- item`
-- the continuation is `  > `, not `> `. The replacement therefore starts at the
-- first marker rather than at the node, which would conceal that indent and
-- snap the line to column 0 while the quote's own first row stayed indented.
local function on_quote_continuation(ctx, node)
    local row, col = node:start()
    local end_row, end_col = node:end_()
    if end_row ~= row then
        return
    end
    local text = line_at(ctx, row):sub(col + 1, end_col)
    local marker = text:find(">")
    if not marker then
        return
    end
    local _, markers = text:gsub(">", "")
    add(ctx, op("replace", row, col + marker - 1, row, end_col,
        opt("mdview_QuoteIcon", DEFAULT_QUOTE_ICON):rep(markers),
        "MdviewQuote", PRIO_MARKER))
end

-- Replace everything from `col` to the end of `row` with a rule drawn across
-- the remaining width.
--
-- Display width, not bytes: the rule is measured in screen cells. The indent it
-- starts after is one deduction; the text it replaces is the other, because
-- Neovim still counts concealed text when it decides where a line wraps, and a
-- rule that filled the window would spill onto a second screen line.
local function add_rule(ctx, row, col, hl)
    local line = line_at(ctx, row)
    local char = opt("mdview_RuleChar", DEFAULT_RULE_CHAR)
    local indent = vim.fn.strdisplaywidth(line:sub(1, col))
    local hidden = vim.fn.strdisplaywidth(line:sub(col + 1))
    local cells = math.max(ctx.width - indent - hidden, 1)
    local count = math.max(math.floor(cells / vim.fn.strdisplaywidth(char)), 1)
    add(ctx, op("replace", row, col, row, #line, char:rep(count), hl, PRIO_MARKER))
end

-- A rule drawn on a line of its own, above or below `row`.
--
-- The border cannot go on the fence line itself. Neovim's own markdown
-- highlights set `conceal_lines` on every fenced_code_block_delimiter, hiding
-- that row outright, and an extmark in another namespace cannot undo it -- so a
-- rule placed there is invisible to anyone with treesitter highlighting on.
-- Attaching it to the first and last body rows instead keeps it visible either
-- way. Nothing is concealed on a virtual line, so its width is only the text
-- width less the indent.
local function add_virt_rule(ctx, row, indent_col, above, hl)
    if row < ctx.srow or row > ctx.erow then
        return
    end
    local line = line_at(ctx, row)
    local char = opt("mdview_RuleChar", DEFAULT_RULE_CHAR)
    local indent = vim.fn.strdisplaywidth(line:sub(1, indent_col))
    local cells = math.max(ctx.width - indent, 1)
    local count = math.max(math.floor(cells / vim.fn.strdisplaywidth(char)), 1)
    add(ctx, op(above and "above" or "below", row, 0, row, 0,
        string.rep(" ", indent) .. char:rep(count), hl, PRIO_MARKER))
end

-- Inside a block quote a thematic break spans two rows -- the `---` and the `>`
-- continuation under it -- so the query yields it for a viewport that starts on
-- the second one. The rule belongs on the first row, which is not on screen,
-- and the line it would be measured against was never fetched.
local function on_thematic_break(ctx, node)
    local row, col = node:start()
    if row < ctx.srow or row > ctx.erow then
        return
    end
    add_rule(ctx, row, col, "MdviewRule")
end

-- A fenced block hides both its fence lines and backgrounds the rows between
-- them. The body comes from the delimiters rather than from
-- `code_fence_content`, which is absent for an empty block and, for a block
-- indented inside a list item, runs on to the next line's indent instead of
-- ending on its own last row. An empty block has no body rows at all and so
-- draws the two hides and nothing else.
--
-- A block with one delimiter has not been closed yet, and the grammar runs it
-- to the end of the document. Rendering that would background every remaining
-- line of the file the moment an opening fence is typed, so nothing is drawn
-- until the closing fence appears.
--
-- Unlike the background, the hides are not clipped to the viewport: hiding a
-- line changes the viewport, and an op that depended on the viewport could then
-- undo the reason it was emitted.
local DIFF_LANGUAGES = {
    ["diff"]  = true,
    ["patch"] = true,
    ["udiff"] = true,
}

-- The language named by the block's info string, lowercased, or nil for a bare
-- fence. `info_string` is an ordinary child rather than a field, so it is found
-- by type.
local function block_language(ctx, node)
    for child in node:iter_children() do
        if child:type() == "info_string" then
            for grandchild in child:iter_children() do
                if grandchild:type() == "language" then
                    return vim.treesitter.get_node_text(grandchild, ctx.bufnr):lower()
                end
            end
        end
    end
    return nil
end

-- A diff row is classified by its first byte, the way every diff reader does
-- it. `---` and `+++` file headers fall out as removals and additions, which is
-- what a forge shows as well.
--
-- The marker is read past the block's own indent: a fence inside a list item
-- indents its whole body, and testing byte 1 would see that indent's space and
-- classify every row as context.
local function diff_group(line, indent)
    local first = line:sub(indent + 1, indent + 1)
    if first == "+" then
        return "MdviewDiffAdd"
    elseif first == "-" then
        return "MdviewDiffDelete"
    elseif line:sub(indent + 1, indent + 2) == "@@" then
        return "MdviewDiffHunk"
    end
    return "MdviewCodeBlock"
end

local function on_fenced_code_block(ctx, node)
    local delimiters = {}
    for child in node:iter_children() do
        if child:type() == "fenced_code_block_delimiter" then
            delimiters[#delimiters + 1] = child
        end
    end
    if #delimiters < 2 then
        return
    end
    local open_row, open_col = delimiters[1]:start()
    local close_row, close_col = delimiters[#delimiters]:start()
    local is_diff = opt("mdview_DiffHighlight", 1) ~= 0
        and DIFF_LANGUAGES[block_language(ctx, node)]

    add(ctx, op("hide_line", open_row, 0, open_row, 0, "", "", PRIO_MARKER))
    add(ctx, op("hide_line", close_row, 0, close_row, 0, "", "", PRIO_MARKER))

    -- Borders bracket the body, so an empty block gets none: there is no row to
    -- hang them on, and two rules with nothing between them is not a block.
    if is_diff and opt("mdview_DiffBorder", 1) ~= 0
        and close_row - open_row > 1 then
        add_virt_rule(ctx, open_row + 1, open_col, true, "MdviewDiffBorder")
        add_virt_rule(ctx, close_row - 1, open_col, false, "MdviewDiffBorder")
    end

    if is_diff then
        -- One op per row rather than one for the block, so additions and
        -- removals can differ. The loop is clamped to the viewport first: a
        -- long diff would otherwise cost a row of work per line of the block.
        for row = math.max(open_row + 1, ctx.srow),
                  math.min(close_row - 1, ctx.erow) do
            add_line(ctx, row, row, diff_group(line_at(ctx, row), open_col))
        end
        return
    end

    add_line(ctx, open_row + 1, close_row - 1, "MdviewCodeBlock")
end

local RENDERERS = {
    ["heading.1"] = on_atx_heading,
    ["heading.2"] = on_atx_heading,
    ["heading.3"] = on_atx_heading,
    ["heading.4"] = on_atx_heading,
    ["heading.5"] = on_atx_heading,
    ["heading.6"] = on_atx_heading,
    ["setext.1"] = on_setext_heading,
    ["setext.2"] = on_setext_heading,
    ["bullet"] = on_bullet,
    ["ordered"] = on_ordered,
    ["checked"] = on_task_marker,
    ["unchecked"] = on_task_marker,
    ["quote"] = on_quote_marker,
    ["quote.continuation"] = on_quote_continuation,
    ["rule"] = on_thematic_break,
    ["code.block"] = on_fenced_code_block,
}


--=================================================

-- srow/erow are 0-based inclusive line bounds: the viewport, so that the cost
-- of a render is bounded by the window rather than by the document. `width` is
-- the cells the window has for buffer text, and is passed in rather than
-- measured here so that the caller's cache key covers every input a render
-- reads; measuring it from the current window instead left the rule sized for
-- whatever the width had been the last time the rows changed.
function M.get_render_ops(bufnr, srow, erow, width)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
    if not ok or not parser then
        return {}
    end

    local query = vim.treesitter.query.get("markdown", "mdview")
    if not query then
        return {}
    end

    srow = math.max(srow, 0)
    erow = math.min(erow, vim.api.nvim_buf_line_count(bufnr) - 1)
    width = math.max(width, 1)
    if erow < srow then
        return {}
    end

    -- Root tree only: every capture below is a markdown node, and a fenced
    -- block's language comes from its own `info_string` rather than from the
    -- injected tree. Parsing injections would cost a full-document parse per
    -- render to build trees `parser:trees()` does not return. Inline markup is
    -- left to Neovim's own markdown_inline queries; see DESIGN.md section 9.
    parser:parse()

    local ctx = {
        bufnr = bufnr,
        srow = srow,
        erow = erow,
        width = width,
        lines = vim.api.nvim_buf_get_lines(bufnr, srow, erow + 1, false),
        ops = {},
    }

    for _, tree in ipairs(parser:trees()) do
        -- The row bounds clip inside the iteration; nodes that straddle an edge
        -- are still yielded, and their ops are clamped as they are built.
        for id, node in query:iter_captures(tree:root(), bufnr, srow, erow + 1) do
            local capture = query.captures[id]
            local render = RENDERERS[capture]
            if render then
                render(ctx, node, capture)
            end
        end
    end

    table.sort(ctx.ops, function(a, b)
        if a.row ~= b.row then return a.row < b.row end
        if a.col ~= b.col then return a.col < b.col end
        return a.kind < b.kind
    end)
    return ctx.ops
end


return M
