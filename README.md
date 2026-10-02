### Description

In-buffer markdown rendering. Headings get an icon and a tinted row, list
bullets and checkboxes get glyphs, block quotes get a bar, thematic breaks get
a rule across the window, and fenced code blocks lose their fences and gain a
background. A fenced `diff` block is coloured per row, the way a forge shows
one.

Nothing is written to the buffer. Every effect is an extmark -- conceal, inline
virtual text, a line highlight, a virtual line -- so the file on disk is
untouched, undo is untouched, and `:w` writes exactly what you typed. The line
the cursor is on shows its raw source so it can be edited; move off it and it
renders again.

It uses Treesitter on the backend, so it needs Neovim 0.11 or newer and the
`markdown` parser -- which Neovim 0.11 bundles, so in practice there is nothing
to install. Rendering costs about one window's worth of work per redraw, not
one document's.

Full documentation is in `:help mdview`.

### Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "jjohnson-99/mdview",
    ft = "markdown",
    -- Options are read by plugin/mdview.vim as it is sourced, so they have to
    -- be set before the plugin loads: init, not config.
    init = function()
        vim.g.mdview_DiffPalette     = "github"
        vim.g.mdview_DiffDeleteColor = 0xEB6F92
    end,
    config = function()
        vim.keymap.set("n", "<leader>zm", vim.cmd.MdviewToggle)
    end
}
```

The `init` / `config` split is not decoration. lazy.nvim runs `config` *after*
the plugin's files have been sourced, and the colour options are read at source
time, when the highlight groups are computed. Set those in `init` or they do
nothing until your next colorscheme change. See [Options](#options) for which
options are which.

Run `:helptags ALL` after installing to build the help tags.

To work on a local checkout instead, swap the repository for its path:

```lua
{
    "mdview",
    dir = "~/plugins/mdview",
    ft = "markdown",
}
```

### Usage

Open a markdown file. It renders. To turn it off for a buffer, or to render a
buffer whose filetype is not in `g:mdview_Filetypes`, use one of:

| Command          | Effect                                                    |
| ---------------- | --------------------------------------------------------- |
| `:MdviewToggle`  | Render the current buffer, or stop rendering it.          |
| `:MdviewEnable`  | Render it. Works with `g:mdview_AutoEnable` off.          |
| `:MdviewDisable` | Stop, clear every extmark, hand the window options back.  |

While a buffer is rendered mdview holds two window-local options -- it sets
`conceallevel` to `2` and `concealcursor` to empty -- in every window showing
that buffer, and gives them back when the buffer stops being rendered or the
window stops showing it. An option you have changed in the meantime is left
alone. Toggling on and off leaves the window as it was found.

`concealcursor` being empty is what reveals the cursor's own line. It also
reveals whatever Neovim's own markdown queries conceal there, so bold markers
and link destinations come back on the cursor row as well.

### Options

```vim
" Render automatically when a buffer's filetype is in g:mdview_Filetypes.
" :MdviewEnable works regardless of this (default: 1)
let g:mdview_AutoEnable = 1
let g:mdview_Filetypes  = ['markdown']

" Glyphs. Each carries its own trailing space, because the marker it replaces
" is concealed along with the space that followed it.
let g:mdview_HeadingIcons   = ['◈ ', '◆ ', '▸ ', '▹ ', '· ', '· ']
let g:mdview_BulletIcons    = ['● ', '○ ', '◆ ', '◇ ']  " cycled by nesting depth
let g:mdview_CheckedIcon    = '󰱒 '   " Nerd Font
let g:mdview_UncheckedIcon  = '󰄱 '   " Nerd Font
let g:mdview_QuoteIcon      = '▎ '
let g:mdview_RuleChar       = '─'

" Backgrounds. Both are inert on a transparent colorscheme -- see below.
let g:mdview_HeadingBlend   = 15  " percent of the heading's own colour, 0 = off
let g:mdview_CodeBlockBlend = 8   " percent tint over Normal's background, 0 = off

" Diff blocks: a fenced block whose language is diff, patch or udiff
let g:mdview_DiffHighlight  = 1        " colour diff rows at all
let g:mdview_DiffBorder     = 1        " rule above and below the body
let g:mdview_DiffPalette    = 'github' " github | rose-pine | vivid | muted
let g:mdview_DiffAddColor   = -1       " -1 = take it from the palette
let g:mdview_DiffDeleteColor= -1
let g:mdview_DiffHunkColor  = -1
let g:mdview_DiffVibrance   = 0        " percent toward full saturation
let g:mdview_DiffStyle      = 'text'   " 'text' or 'background'
let g:mdview_DiffBlend      = 30       " percent of the hue mixed into the
                                       " background, 'background' style only

" The colour to blend tints against when Normal is transparent, as 0xRRGGBB.
" -1 means "use Normal's background, and skip the tint if it has none".
let g:mdview_BackgroundColor = -1
```

**When a change takes effect** differs by option, and this catches people.

The colour options -- `HeadingBlend`, `CodeBlockBlend`, `BackgroundColor` and
every `Diff*` -- are read while the highlight groups are computed, which happens
once as the plugin is sourced and again on every `ColorScheme`. Setting one
later changes nothing until the next colorscheme change. To apply one now:

```vim
:let g:mdview_DiffPalette = 'rose-pine'
:doautocmd ColorScheme
```

The glyph options, plus `DiffHighlight` and `DiffBorder`, are read every time a
viewport is parsed. A render is cached against the buffer's text, the visible
rows and the window width, so a changed glyph appears at the next event that
moves one of those -- an edit, a scroll, a resize. To apply one now:

```vim
:MdviewDisable | MdviewEnable
```

**Transparent backgrounds.** Neovim cannot read the terminal's own background
colour, so when `Normal` has no background there is genuinely nothing for a
tint to mix with. mdview does not invent one: guessing a stand-in paints an
opaque block over a window you chose to keep clear. On a transparent
colorscheme `g:mdview_HeadingBlend` and `g:mdview_CodeBlockBlend` do nothing at
any value, and `g:mdview_DiffStyle = 'background'` falls back to `'text'`. Set
`g:mdview_BackgroundColor` to the terminal's colour to get the tints back
without giving up transparency elsewhere. The glyphs, rules and diff text
colour work either way.

### Highlight groups

Thirteen are `highlight default link` and can be overridden the ordinary way:
`MdviewH1`-`MdviewH6` (the heading icons), `MdviewBullet`, `MdviewOrdered`,
`MdviewChecked`, `MdviewUnchecked`, `MdviewQuote`, `MdviewRule` and
`MdviewDiffBorder`.

Ten are **computed** from `Normal`'s background and the options above, and
re-derived on every `ColorScheme`: `MdviewH1Bg`-`MdviewH6Bg`,
`MdviewCodeBlock`, `MdviewDiffAdd`, `MdviewDiffDelete` and `MdviewDiffHunk`. A
plain `:highlight MdviewCodeBlock ...` holds until the next colorscheme change
and is then overwritten. To override one for good, set it from a `ColorScheme`
autocmd of your own, declared after the plugin has loaded so yours runs second:

```vim
augroup MyMdviewColors
    autocmd!
    autocmd ColorScheme * highlight MdviewCodeBlock guibg=#21202e
augroup END
```

### Limitations

These are known and reproduced, not guesses.

**Tables are not rendered at all**, and this was investigated and rejected
rather than skipped. Glyph substitution helps only tables whose source is
already aligned; padding cells to a common width produced ~428-column rows on a
real document. Laying a table out to fit the window is the only approach that
would help, and it cannot be scrolled: a 21-row table lays out to 101 screen
rows, and every topline inside a hidden range collapses to the row after the
table, so the middle of the grid is unreachable by any scroll.

**Inline markup is not mdview's.** Bold, italic, code spans and links are
concealed and coloured by Neovim's own bundled `markdown_inline` queries. They
work because mdview sets `conceallevel`, which means they need Treesitter
highlighting on for markdown -- without it the emphasis markers and link
brackets stay visible while the block rendering works normally. mdview also
cannot turn that concealment *off*: conceal is additive, and the only mechanism
that would suppress it is shipping a replacement query file, which would make
mdview the owner of every inline colour in your markdown. That is why there is
no `g:mdview_ConcealLinks`.

**One buffer in two windows renders for one of them.** Extmarks are
buffer-global, so mdview follows a single window's viewport, cursor and width.
A second window scrolled elsewhere shows raw markdown, and rules in an unequal
vertical split are sized for the focused window and re-size every time focus
moves.

**`:set number` leaves a rule stale for one keystroke.** `number`, `signcolumn`
and `foldcolumn` each change how many cells are left for text and fire no
resize event at all, so a rule keeps its old length until the next render for
any other reason. A cursor move corrects it.

**Setext underlines stay visible.** An underlined heading gets its row tinted;
the `===` or `---` beneath it is still drawn. Related, and a genuine
inconsistency: a setext heading nested in a list item tints its underline row
as well, where one at top level does not.

**A thematic break inside a block quote wraps onto a second screen row.** The
rule is sized against the raw line, which does not account for the quote bar
mdview inserts on the same row. A `---` at top level, or indented in a list
item, is correct.

**A document that hides more of itself than it shows draws its bottom rows
raw.** Hiding a line makes room for another at the bottom, so mdview re-reads
the viewport until it settles, bounded at four windows' worth of lines and
twelve passes. Ordinary markdown settles on the first pass; a file of nothing
but empty fenced blocks never settles.

**Ordered list markers are recoloured and nothing more** -- no conceal, no
replacement, no right-alignment. Their digits are content rather than syntax,
and aligning `8.` to the width of `10.` needs the whole enclosing list, which
is not a property of the viewport.

**An unclosed fenced block renders nothing** until its closing fence exists.
Rendering it would background the rest of the file the moment you opened one.

Rendering is buffer-scoped, so `:MdviewDisable` in one window stops rendering
everywhere that buffer is shown.

### Roadmap

Feature-complete for what it set out to do. Expect fixes rather than features.
