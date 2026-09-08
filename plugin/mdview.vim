"=================================================
" File: plugin/mdview.vim
" Description: In-buffer markdown rendering.
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD

" Avoid installing twice.
if exists('g:loaded_mdview')
    finish
endif
let g:loaded_mdview = 0


"=================================================
" render automatically when a buffer's filetype is in g:mdview_Filetypes
if !exists('g:mdview_AutoEnable')
    let g:mdview_AutoEnable = 1
endif

if !exists('g:mdview_Filetypes')
    let g:mdview_Filetypes = ['markdown']
endif

" icon drawn in place of the `#` markers, one per heading level
if !exists('g:mdview_HeadingIcons')
    let g:mdview_HeadingIcons = ['◈ ', '◆ ', '▸ ', '▹ ', '· ', '· ']
endif

" icons drawn in place of `-` `*` `+`, cycled by list nesting depth
if !exists('g:mdview_BulletIcons')
    let g:mdview_BulletIcons = ['● ', '○ ', '◆ ', '◇ ']
endif

if !exists('g:mdview_CheckedIcon')
    let g:mdview_CheckedIcon = '󰱒 '
endif

if !exists('g:mdview_UncheckedIcon')
    let g:mdview_UncheckedIcon = '󰄱 '
endif

" drawn in place of the `>` of a block quote, once per nesting level
if !exists('g:mdview_QuoteIcon')
    let g:mdview_QuoteIcon = '▎ '
endif

" character the thematic break rule is drawn with
if !exists('g:mdview_RuleChar')
    let g:mdview_RuleChar = '─'
endif

" percent of the heading's own colour mixed into Normal's background to tint the
" heading row, 0 for no heading background at all
if !exists('g:mdview_HeadingBlend')
    let g:mdview_HeadingBlend = 15
endif

" percent of white (dark colorscheme) or black (light one) mixed into Normal's
" background to tint a fenced code block
if !exists('g:mdview_CodeBlockBlend')
    let g:mdview_CodeBlockBlend = 8
endif

" tint the body of a ```diff block per line, red for removals, green for
" additions, the way a forge renders one
if !exists('g:mdview_DiffHighlight')
    let g:mdview_DiffHighlight = 1
endif

" hues mixed into the background for diff rows, and how much of them. The
" colorscheme's own DiffAdd/DiffDelete are deliberately not used: many schemes
" desaturate them into blues and mauves, which defeats the point of showing
" additions as green and removals as red.
" Named diff palettes, selected with g:mdview_DiffPalette. A removal colour
" wants its green and blue channels equal: g:mdview_DiffVibrance preserves hue,
" so any imbalance is amplified -- G above B turns the red to rust as it deepens,
" and B above G turns it pink. The skew is noted per palette where it exists.
let s:PALETTES = {
    \ 'github':    {'add': 0x3FB950, 'delete': 0xFF5555, 'hunk': 0xD2A8FF},
    \ 'rose-pine': {'add': 0x9CCFD8, 'delete': 0xEB6F92, 'hunk': 0xC4A7E7},
    \ 'vivid':     {'add': 0x00CC44, 'delete': 0xFF3333, 'hunk': 0xB362FF},
    \ 'muted':     {'add': 0x7FA87F, 'delete': 0xBE8080, 'hunk': 0xA394C0},
    \ }
"   github     GitHub's dark mode. Neutral red, pale lavender.
"   rose-pine  foam / love / iris. love skews pink (G-B = -35), so vibrance
"              deepens it toward pink rather than red. rose-pine has no green,
"              so additions use foam, a cyan.
"   vivid      saturated primaries, for a high-contrast terminal.
"   muted      desaturated, for a light or low-contrast terminal.

" draw a rule where a diff block's fences are, instead of hiding those lines
if !exists('g:mdview_DiffBorder')
    let g:mdview_DiffBorder = 1
endif

if !exists('g:mdview_DiffPalette')
    let g:mdview_DiffPalette = 'github'
endif

" Individual overrides. -1 means "take it from the palette".
if !exists('g:mdview_DiffAddColor')
    let g:mdview_DiffAddColor = -1
endif

if !exists('g:mdview_DiffDeleteColor')
    let g:mdview_DiffDeleteColor = -1
endif

if !exists('g:mdview_DiffHunkColor')
    let g:mdview_DiffHunkColor = -1
endif

if !exists('g:mdview_DiffBlend')
    let g:mdview_DiffBlend = 30
endif

" push the diff hues toward full saturation, 0 for the colour as given. Raising
" this deepens the colour without brightening it, which is what "more vibrant"
" usually means; blending toward white does the opposite.
if !exists('g:mdview_DiffVibrance')
    let g:mdview_DiffVibrance = 0
endif

" how a diff row carries its colour:
"   'text'       -- colour the row's text, leave the background alone. Keeps a
"                   transparent window transparent.
"   'background' -- tint the row's background and leave its text alone, the way
"                   a forge renders one. Needs a background to tint: see
"                   g:mdview_BackgroundColor.
if !exists('g:mdview_DiffStyle')
    let g:mdview_DiffStyle = 'text'
endif

" The colour to blend tints against when `Normal` is transparent. Neovim cannot
" read the terminal's own background, so a tint has nothing to mix with and is
" simply skipped. Set this to the terminal's background (e.g. 0x191724) to get
" tints back without giving up transparency elsewhere.
if !exists('g:mdview_BackgroundColor')
    let g:mdview_BackgroundColor = -1
endif


"=================================================
" Colour arithmetic for the derived backgrounds below. Colours are 24-bit
" 0xRRGGBB integers, which is what nvim_get_hl and nvim_set_hl both speak.

" `pct` percent of `over` mixed into `under`.
function! s:blend(under, over, pct) abort
    let l:r = (and(a:under, 0xFF0000) / 0x10000 * (100 - a:pct)
            \  + and(a:over, 0xFF0000) / 0x10000 * a:pct) / 100
    let l:g = (and(a:under, 0x00FF00) / 0x100 * (100 - a:pct)
            \  + and(a:over, 0x00FF00) / 0x100 * a:pct) / 100
    let l:b = (and(a:under, 0x0000FF) * (100 - a:pct)
            \  + and(a:over, 0x0000FF) * a:pct) / 100
    return l:r * 0x10000 + l:g * 0x100 + l:b
endfunction

" Push a colour toward full saturation, keeping its brightest channel fixed so
" the hue and the perceived brightness both survive. Each channel is moved
" further from the brightest one by `pct` percent; at 0 the colour is unchanged,
" at 100 the gap doubles.
function! s:saturate(rgb, pct) abort
    if a:pct <= 0
        return a:rgb
    endif
    let l:r = and(a:rgb, 0xFF0000) / 0x10000
    let l:g = and(a:rgb, 0x00FF00) / 0x100
    let l:b = and(a:rgb, 0x0000FF)
    let l:max = max([l:r, l:g, l:b])
    let l:out = []
    for l:c in [l:r, l:g, l:b]
        call add(l:out, max([0, l:max - (l:max - l:c) * (100 + a:pct) / 100]))
    endfor
    return l:out[0] * 0x10000 + l:out[1] * 0x100 + l:out[2]
endfunction

" Perceived brightness, so a tint can move away from the background rather than
" toward it. Weights are the usual 299/587/114.
function! s:isDark(rgb) abort
    let l:lum = and(a:rgb, 0xFF0000) / 0x10000 * 299
            \ + and(a:rgb, 0x00FF00) / 0x100 * 587
            \ + and(a:rgb, 0x0000FF) * 114
    return l:lum / 1000 < 128
endfunction

" The colour to tint against: an explicitly declared background, else Normal's
" own. Returns -1 when there is nothing to blend with -- no true colour, or a
" transparent `Normal` with no declared substitute. Callers skip their tint in
" that case rather than invent a background the terminal may not have.
function! s:baseBg() abort
    if !has('gui_running') && !&termguicolors
        return -1
    endif
    if g:mdview_BackgroundColor >= 0
        return g:mdview_BackgroundColor
    endif
    return get(nvim_get_hl(0, {'name': 'Normal', 'link': v:false}), 'bg', -1)
endfunction

" Derived groups are re-set outright rather than declared `default`. A `default`
" definition is refused once the group exists, which would freeze the colour at
" whatever the first colorscheme produced -- the one thing a derived colour must
" not do. To override one of these, set it from a ColorScheme autocmd after this
" plugin's own, as with any colour a plugin computes.
function! s:setHl(name, opts) abort
    call nvim_set_hl(0, a:name, a:opts)
endfunction

" A fenced block needs a background of its own. Linking it to an existing group
" does not work: CursorLine collides with 'cursorline' inside the block, and
" @markup.raw.block supplies a foreground only. Tint Normal's own background
" instead -- toward white on a dark colorscheme, toward black on a light one --
" so the block reads as a block whatever the colorscheme.
function! s:codeBlockHighlight() abort
    let l:bg = s:baseBg()
    if l:bg < 0 || g:mdview_CodeBlockBlend <= 0
        " Nothing to tint against, or tinting turned off. Clear the group so the
        " block keeps whatever the window already shows, transparency included.
        call s:setHl('MdviewCodeBlock', {})
        return
    endif
    let l:toward = s:isDark(l:bg) ? 0xFFFFFF : 0x000000
    call s:setHl('MdviewCodeBlock',
        \ {'bg': s:blend(l:bg, l:toward, g:mdview_CodeBlockBlend)})
endfunction

" Diff rows are tinted toward an explicit hue rather than linked to the
" colorscheme's DiffAdd/DiffDelete. Those groups exist for :diffthis, where
" schemes routinely mute them -- rose-pine's "add" is a blue-grey and its
" "delete" a mauve -- and a diff block that does not read as red and green has
" no reason to be coloured at all.
" An explicit override wins; otherwise the selected palette supplies the colour.
" An unknown palette name falls back to 'github' rather than leaving the diff
" groups undefined.
" A heading background has the same problem and one more colour to work with.
" @markup.heading.N is a text face -- a foreground and `bold` -- so using it as
" a line background recolours the row's text and draws no background at all,
" which is what this group did until it was computed. Tint Normal's background
" toward the level's own foreground instead, so each level keeps a colour of its
" own, and toward white or black when the colorscheme gives the level no
" foreground to borrow.
function! s:headingHighlight(level) abort
    let l:name = 'MdviewH'.a:level.'Bg'
    let l:bg = s:baseBg()
    if l:bg < 0 || g:mdview_HeadingBlend <= 0
        " Nothing to tint against, or tinting turned off. Clear the group so the
        " heading keeps whatever the window already shows, transparency included.
        call s:setHl(l:name, {})
        return
    endif
    let l:hue = get(nvim_get_hl(
        \ 0, {'name': '@markup.heading.'.a:level, 'link': v:false}), 'fg', -1)
    if l:hue < 0
        let l:hue = s:isDark(l:bg) ? 0xFFFFFF : 0x000000
    endif
    call s:setHl(l:name, {'bg': s:blend(l:bg, l:hue, g:mdview_HeadingBlend)})
endfunction

function! s:diffColor(role, override) abort
    if a:override >= 0
        return a:override
    endif
    return get(s:PALETTES, g:mdview_DiffPalette, s:PALETTES['github'])[a:role]
endfunction

function! s:diffHighlight(name, raw) abort
    let l:hue = s:saturate(a:raw, g:mdview_DiffVibrance)
    let l:bg = s:baseBg()
    " 'background' style needs something to blend with. With nothing to blend
    " with, fall back to colouring the text rather than painting a background
    " over a window the user chose to keep transparent.
    if g:mdview_DiffStyle ==# 'background' && l:bg >= 0
        call s:setHl(a:name, {'bg': s:blend(l:bg, l:hue, g:mdview_DiffBlend)})
        return
    endif
    " The hue itself. Lifting it toward white would raise the brightness by
    " washing the colour out, which is the opposite of what a diff row wants:
    " deepen the colour or pick a brighter one instead of diluting a darker one.
    call s:setHl(a:name, {'fg': l:hue})
endfunction


"=================================================
" Highlight defaults. Links into @markup.* are dropped when the colorscheme
" changes, so they are re-declared from the ColorScheme event below.
function! s:highlights() abort
    for level in range(1, 6)
        exe 'highlight default link Mdview'.'H'.level.' @markup.heading.'.level
    endfor
    highlight default link MdviewBullet     @markup.list
    highlight default link MdviewOrdered    @markup.list
    highlight default link MdviewChecked    @markup.list.checked
    highlight default link MdviewUnchecked  @markup.list.unchecked
    highlight default link MdviewQuote      @markup.quote
    highlight default link MdviewRule       @punctuation.special
    highlight default link MdviewDiffHunk   DiffChange
    highlight default link MdviewDiffBorder MdviewRule

    call s:codeBlockHighlight()
    for level in range(1, 6)
        call s:headingHighlight(level)
    endfor
    call s:diffHighlight('MdviewDiffAdd',    s:diffColor('add', g:mdview_DiffAddColor))
    call s:diffHighlight('MdviewDiffDelete', s:diffColor('delete', g:mdview_DiffDeleteColor))
    call s:diffHighlight('MdviewDiffHunk',   s:diffColor('hunk', g:mdview_DiffHunkColor))
endfunction

call s:highlights()


"=================================================
" Rendering is opt-in per buffer, but a markdown buffer opts itself in unless
" the user turns g:mdview_AutoEnable off. This group is the plugin's own and is
" never touched by :MdviewDisable, which only clears the Mdview group.
function! s:autoEnable() abort
    if g:mdview_AutoEnable && index(g:mdview_Filetypes, &filetype) >= 0
        call mdview#Enable()
    endif
endfunction

" Window options are keyed by window rather than by buffer, so the window that
" stops showing an mdview buffer -- `:e other.txt` -- is where they have to be
" handed back, and no autocmd bound to that buffer fires there. These are
" therefore global, and live in this group for the same reason ColorScheme does:
" :MdviewDisable clears the Mdview group, and a window still owes its options
" back afterwards. mdview cannot have touched a window before its autoload half
" has run, which is what keeps a session that never opens markdown from sourcing
" it.
function! s:onWinEnter() abort
    if exists('g:autoloaded_mdview')
        call mdview#OnWinEnter()
    endif
endfunction

function! s:onWinNew() abort
    if exists('g:autoloaded_mdview')
        call mdview#OnWinNew()
    endif
endfunction

augroup Mdview_Plugin
    au!
    au FileType    * call s:autoEnable()
    au ColorScheme * call s:highlights()
    au WinNew      * call s:onWinNew()
    au BufWinEnter,WinEnter * call s:onWinEnter()
augroup END


"=================================================
" User commands.
command! -nargs=0 -bar MdviewToggle  :call mdview#Toggle()
command! -nargs=0 -bar MdviewEnable  :call mdview#Enable()
command! -nargs=0 -bar MdviewDisable :call mdview#Disable()

" vim: set et fdm=marker sts=4 sw=4:
