"=================================================
" File: autoload/mdview.vim
" Description: In-buffer markdown rendering.
" Author: Jeremy Johnson <js.johnson990@gmail.com>
" License: BSD


" Avoid installing twice.
if exists('g:autoloaded_mdview')
    finish
endif
let g:autoloaded_mdview = 0

" One namespace for the whole plugin: extmarks are buffer-scoped already, and a
" single namespace makes "clear everything mdview drew" a single call.
let s:ns = nvim_create_namespace('mdview')

" Placing extmarks can move the view and so fire WinScrolled, which would call
" straight back into Render().
let s:rendering = 0

" How many times s:view.Render() may re-read the viewport before giving up on
" it settling. Each pass reveals the rows the last one hid, and those rows can
" hide lines of their own: measured, a fenced block every three lines needs
" eight passes to settle a 22-row window, and ordinary markdown needs one. The
" cap is the backstop for a viewport that never settles at all, because an
" unbounded loop in a render path is how an editor hangs.
let s:MAX_SETTLE = 12

" The most of a document one render will look at, as a multiple of the window
" height. A hidden line makes room for another at the bottom, so a viewport is
" honestly taller than its window on a document that hides much of itself. Past
" a few windows' worth it hides faster than the settling reveals -- a file of
" nothing but empty fenced blocks never settles at all -- and every further pass
" costs a parse of the whole range again. Rows past the bound draw raw, which is
" the only outcome available for a document that is more hidden than shown.
let s:MAX_VIEWPORT = 4

" The window options every window showing an mdview buffer needs, and the
" values mdview sets them to. 'concealcursor' is empty so Neovim declines to
" conceal the cursor line in any mode; s:view.Place() suppressing the same ops
" is the other half of that, and the two must agree or the raw text and its
" replacement both draw.
let s:OWNED = {'conceallevel': 2, 'concealcursor': ''}

" Op kinds that hide or shift the text they sit on, and so are dropped on the
" cursor's own row: the line has to read as it was written to be edited. `hl`,
" `line`, `above` and `below` are kept, because none of them changes the text
" and dropping them would flicker a heading background or a diff border off and
" on as the cursor passed through.
let s:CURSOR_SUPPRESSED =
    \ {'conceal': 1, 'replace': 1, 'inline': 1, 'hide_line': 1}

" What each s:OWNED option was in a window before mdview first set it, keyed by
" window id.
"
" Keyed by window rather than kept on the view because the options belong to the
" window, which outlives its reason for having them: `:e other.txt` has to give
" them back while the view that set them is still alive elsewhere.
"
" A window's record is kept for as long as the window lives, not only while
" mdview is rendering in it. Neovim remembers window-local options per buffer
" per window and replays them, so a window returning to an mdview buffer reports
" mdview's own 'conceallevel' before any autocmd runs; a snapshot taken then
" records 2 as the value to restore and the option is stranded for good.
let s:saved = {}

" The window mdview most recently took the options of and was standing in. A
" window opened from it inherits its option values, and mdview#OnWinNew() needs
" to know which window that was: `winnr('#')` names the source of a split, but
" is 0 for `:tabnew`, `:tabedit` and for a float, all of which inherit the
" options just the same.
let s:lastwin = 0


"=================================================
function! s:new(obj) abort
    let newobj = deepcopy(a:obj)
    call newobj.Init()
    return newobj
endfunction

" The view rendering a buffer, or {} when rendering is off for it.
function! s:get(bufnr) abort
    return getbufvar(a:bufnr, 'mdview', {})
endfunction

function! s:capErow(srow, erow, height) abort
    return min([a:erow, a:srow + s:MAX_VIEWPORT * a:height])
endfunction

function! s:textWidth(wininfo) abort
    return a:wininfo.width - a:wininfo.textoff
endfunction

" [first row, last row, cursor row, text width] on screen for a buffer, the
" rows 0-based, read from the window showing it: the current window when that is
" showing the buffer, else the first window that is. A buffer in no window has
" no viewport, so the whole of it is rendered, with -1 for the cursor row so
" nothing is suppressed and 'columns' for a width that cannot be measured. The
" last row is bounded by s:MAX_VIEWPORT.
"
" The width is the cells left for buffer text once 'number', 'signcolumn' and
" the fold column have taken theirs, which is what a rule has to be sized to.
" It is read here, from the same window the rows came from, so that the backend
" takes it as an argument: measured on the far side of the boundary instead, it
" was an input to the rendering that the cache key in s:view.Render() could not
" see, and a resize that left the rows alone kept the old rule forever.
"
" Extmarks are buffer-global, so one buffer in two windows can only follow one
" cursor. Preferring the current window makes that the one being typed in, and
" falling back to the first leaves the rendering alone when focus moves away
" entirely rather than reflowing the window nobody is looking at. The width
" follows the same window for the same reason, so the two windows of a vertical
" split render to the width of whichever one is being used.
function! s:context(bufnr) abort
    if bufnr('%') == a:bufnr
        let srow = line('w0') - 1
        return [srow, s:capErow(srow, line('w$') - 1, winheight(0)), line('.') - 1,
            \ s:textWidth(getwininfo(win_getid())[0])]
    endif
    for info in getwininfo()
        if info.bufnr == a:bufnr
            return [info.topline - 1,
                \ s:capErow(info.topline - 1, info.botline - 1, info.height),
                \ nvim_win_get_cursor(info.winid)[0] - 1,
                \ s:textWidth(info)]
        endif
    endfor
    return [0, nvim_buf_line_count(a:bufnr) - 1, -1, &columns]
endfunction


"=================================================
" Window options. s:OWNED is window-local, so a buffer shown in a second window
" renders unconcealed there unless the options are set there too -- and a window
" that stops showing an mdview buffer has to have them put back, whether it was
" the view that went away or the window that moved on.

function! s:winOptions(winid) abort
    let out = {}
    for name in keys(s:OWNED)
        let out[name] = nvim_get_option_value(name, {'win': a:winid})
    endfor
    return out
endfunction

function! s:ownWin(winid) abort
    if !nvim_win_is_valid(a:winid)
        return
    endif
    " A window reporting exactly s:OWNED says nothing about what the user had --
    " the values are either still mdview's or ones Neovim has just replayed --
    " so the existing record stands. So does a window reporting what mdview last
    " handed back. Anything else means the options have been taken over since,
    " and that is what to restore from now on.
    let now = s:winOptions(a:winid)
    if !has_key(s:saved, a:winid)
        \ || (now !=# s:OWNED && now !=# s:saved[a:winid])
        let s:saved[a:winid] = now
    endif
    for [name, value] in items(s:OWNED)
        call nvim_set_option_value(name, value, {'win': a:winid})
    endfor
    " Only when this is the window being stood in: mdview#Enable() owns every
    " window showing the buffer, and a window opened next inherits from the one
    " the user is in, not from the last of that list.
    if a:winid == win_getid()
        let s:lastwin = a:winid
    endif
endfunction

function! s:releaseWin(winid) abort
    for [name, value] in items(s:OWNED)
        " Put back only what mdview still holds. An option that has since
        " been set by the user or another plugin belongs to them now, and
        " restoring over it would be its own kind of leftover state. This also
        " makes the call idempotent: a window already released costs two reads.
        if nvim_get_option_value(name, {'win': a:winid}) ==# value
            call nvim_set_option_value(
                \ name, s:saved[a:winid][name], {'win': a:winid})
        endif
    endfor
endfunction

" Hand the options back to every remembered window that is not showing an
" enabled buffer, and forget the windows that have closed. Disabling, `:e
" other.txt`, `:bdelete`, a window closing and a split that turned into
" something else all reach the restore through here.
function! s:syncWins() abort
    for key in keys(s:saved)
        let winid = str2nr(key)
        if !nvim_win_is_valid(winid)
            call remove(s:saved, key)
        elseif empty(s:get(nvim_win_get_buf(winid)))
            call s:releaseWin(winid)
        endif
    endfor
endfunction


"=================================================
" One view per buffer, stored as b:mdview. Buffer-scoped rather than
" tab-scoped, unlike s:symbols in the symbols plugin, because what is rendered
" follows the buffer rather than the window layout.

let s:view = {}

function! s:view.Init() abort
    let self.bufnr = bufnr('%')
    let self.ns = s:ns
    let self.ops = []

    " What self.ops was parsed for, and what it was last placed for. Together
    " they key the two halves of Render(): text, viewport or window width
    " invalidates the ops, the cursor row only invalidates the placement.
    let self.key = []
    let self.cursorrow = -1
endfunction


" All enabled buffers share the Mdview group, so only this buffer's autocmds
" are cleared -- never the whole group.
"
" BufWinEnter and WinEnter are not here. They have to fire for a window that has
" stopped showing this buffer, which no autocmd bound to this buffer ever does,
" so they are global and live in plugin/mdview.vim with WinNew.
function! s:view.BindAu() abort
    augroup Mdview
        exe 'au! * <buffer='.self.bufnr.'>'
        exe 'au TextChanged,TextChangedI <buffer='.self.bufnr.'> call mdview#Update()'
        exe 'au CursorMoved,CursorMovedI <buffer='.self.bufnr.'> call mdview#Update()'
        exe 'au WinScrolled              <buffer='.self.bufnr.'> call mdview#Update()'
        exe 'au BufUnload                <buffer='.self.bufnr.'> call mdview#Detach(str2nr(expand("<abuf>")))'
    augroup END
endfunction


" Two costs, kept apart. Parsing is a treesitter query over the viewport and
" only the buffer's text or the viewport can invalidate it. Placing is a clear
" and ~150 extmark calls, and additionally depends on where the cursor is. So a
" bare cursor move re-places the cached ops and never enters Lua, and a move
" within one row does nothing at all.
"
" The loop settles the viewport. A `hide_line` takes a buffer line off the
" screen and so makes room for another one at the bottom, past the range the ops
" were parsed for -- and no event fires to say the viewport grew. Each pass
" reads the viewport again and picks those rows up, and the rows it picks up can
" hide lines of their own, so one extra pass is not enough: a document with a
" fenced block every three lines still has raw fences drawn on its bottom rows
" after two. The loop therefore runs until the viewport stops moving, which on
" the common path is the second pass observing no change and breaking before it
" parses anything.
function! s:view.Render() abort
    if s:rendering || !bufloaded(self.bufnr)
        return
    endif
    let s:rendering = 1
    try
        for attempt in range(s:MAX_SETTLE)
            let [srow, erow, cursorrow, width] = s:context(self.bufnr)
            let key = [nvim_buf_get_changedtick(self.bufnr), srow, erow, width]
            if key == self.key && cursorrow == self.cursorrow
                break
            endif
            if key != self.key
                let self.ops = luaeval(
                    \ 'require("mdview.backend").get_render_ops(_A[1], _A[2], _A[3], _A[4])',
                    \ [self.bufnr, srow, erow, width])
                let self.key = key
            endif
            let self.cursorrow = cursorrow
            call self.Place()
        endfor
    finally
        let s:rendering = 0
    endtry
endfunction

" Draw the cached ops, minus the ones the cursor's row suppresses. The whole
" namespace is cleared rather than the viewport, because ops placed for an
" earlier viewport are still on the buffer. Placement is not diffed: at this
" size working out what changed costs more than redoing it.
function! s:view.Place() abort
    call nvim_buf_clear_namespace(self.bufnr, self.ns, 0, -1)
    for op in self.ops
        if has_key(s:CURSOR_SUPPRESSED, op.kind)
            \ && op.row <= self.cursorrow && self.cursorrow <= op.end_row
            continue
        endif
        call self.ApplyOp(op)
    endfor
endfunction


" The whole of the op contract. Every kind the backend may ever emit is
" translated here and nowhere else.
function! s:view.ApplyOp(op) abort
    let opts = {'priority': a:op.priority}
    let chunk = empty(a:op.hl) ? [a:op.text] : [a:op.text, a:op.hl]

    if a:op.kind ==# 'conceal'
        let opts.end_row = a:op.end_row
        let opts.end_col = a:op.end_col
        let opts.conceal = ''
    elseif a:op.kind ==# 'replace'
        " Neovim's conceal draws a single character at most, so a multi-char
        " replacement is a conceal plus inline virtual text on the same mark.
        let opts.end_row = a:op.end_row
        let opts.end_col = a:op.end_col
        let opts.conceal = ''
        let opts.virt_text = [chunk]
        let opts.virt_text_pos = 'inline'
    elseif a:op.kind ==# 'inline'
        let opts.virt_text = [chunk]
        let opts.virt_text_pos = 'inline'
    elseif a:op.kind ==# 'hl'
        let opts.end_row = a:op.end_row
        let opts.end_col = a:op.end_col
        let opts.hl_group = a:op.hl
    elseif a:op.kind ==# 'line'
        let opts.end_row = a:op.end_row
        let opts.line_hl_group = a:op.hl
        let opts.hl_eol = v:true
    elseif a:op.kind ==# 'hide_line'
        let opts.end_row = a:op.end_row
        let opts.conceal_lines = ''
    elseif a:op.kind ==# 'above'
        let opts.virt_lines = [[chunk]]
        let opts.virt_lines_above = v:true
    elseif a:op.kind ==# 'below'
        let opts.virt_lines = [[chunk]]
    else
        return
    endif

    call nvim_buf_set_extmark(self.bufnr, self.ns, a:op.row, a:op.col, opts)
endfunction


"=================================================
" User command functions.

function! mdview#Enable() abort
    if !empty(s:get(bufnr('%')))
        return
    endif
    let b:mdview = s:new(s:view)
    call b:mdview.BindAu()
    " Every window already showing the buffer, not just this one: WinEnter
    " reaches the others eventually, but until then they would render the same
    " extmarks with nothing concealed.
    for winid in win_findbuf(b:mdview.bufnr)
        call s:ownWin(winid)
    endfor
    call b:mdview.Render()
endfunction

function! mdview#Disable() abort
    call mdview#Detach(bufnr('%'))
endfunction

function! mdview#Toggle() abort
    if empty(s:get(bufnr('%')))
        call mdview#Enable()
    else
        call mdview#Disable()
    endif
endfunction


"=================================================
" Autocmd handlers.

function! mdview#Update() abort
    let view = s:get(bufnr('%'))
    if !empty(view)
        call view.Render()
    endif
endfunction

" Bound for every window entered, not only those showing an enabled buffer: the
" window that has stopped showing one is the only place `:e other.txt` can be
" caught, and by then nothing on the mdview buffer fires.
function! mdview#OnWinEnter() abort
    call s:syncWins()
    let view = s:get(bufnr('%'))
    if !empty(view)
        call s:ownWin(win_getid())
        call view.Render()
    endif
endfunction

" A new window inherits the window options of the one it was opened from, so a
" window opened off an mdview window starts out concealed whatever it goes on to
" show. Inherit the saved originals along with them, and s:syncWins() then
" either keeps them, when the new window shows an enabled buffer, or gives them
" back when it does not. Snapshotting what such a window reports instead records
" mdview's own values as the user's and strands them there for good.
"
" A window holding anything other than s:OWNED inherited nothing of mdview's,
" whatever it was opened from, and gets no record: what it holds is the user's,
" and a record would only invite s:syncWins() to hand back values mdview never
" took. That is the whole test -- `:tabnew` and a float leave `winnr('#')` at 0
" and so name no source at all, and a float opened without entering it does not
" inherit the options in the first place.
function! mdview#OnWinNew() abort
    let winid = win_getid()
    if s:winOptions(winid) !=# s:OWNED
        return
    endif
    let source = winnr('#') ? win_getid(winnr('#')) : s:lastwin
    if has_key(s:saved, source)
        let s:saved[winid] = copy(s:saved[source])
    endif
endfunction

" Takes the buffer explicitly: BufUnload fires for a buffer that need not be
" the current one.
function! mdview#Detach(bufnr) abort
    let view = s:get(a:bufnr)
    if empty(view)
        return
    endif
    if bufloaded(a:bufnr)
        call nvim_buf_clear_namespace(a:bufnr, view.ns, 0, -1)
    endif
    augroup Mdview
        exe 'au! * <buffer='.a:bufnr.'>'
    augroup END
    call nvim_buf_del_var(a:bufnr, 'mdview')
    " After the view is gone, so that a window kept only for this buffer no
    " longer counts as showing an enabled one.
    call s:syncWins()
endfunction

" vim: set et fdm=marker sts=4 sw=4:
