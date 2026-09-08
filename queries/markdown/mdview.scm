; Block-level captures for mdview. The capture name selects a renderer in
; lua/mdview/backend.lua, and where a renderer rewrites a byte range it is the
; range of the node captured here.

(atx_heading (atx_h1_marker) @heading.1)
(atx_heading (atx_h2_marker) @heading.2)
(atx_heading (atx_h3_marker) @heading.3)
(atx_heading (atx_h4_marker) @heading.4)
(atx_heading (atx_h5_marker) @heading.5)
(atx_heading (atx_h6_marker) @heading.6)

; The whole heading is captured, not the underline that names the level: the
; underline sits a row below the text it belongs to, and capturing it would drop
; the heading whenever the viewport ends on the text row.
(setext_heading (setext_h1_underline)) @setext.1
(setext_heading (setext_h2_underline)) @setext.2

[
  (list_marker_minus)
  (list_marker_star)
  (list_marker_plus)
] @bullet

; Recoloured in place, never rewritten: an ordered marker's digits are content
; rather than syntax, so there is nothing to conceal them in favour of.
[
  (list_marker_dot)
  (list_marker_parenthesis)
] @ordered

(task_list_marker_checked)   @checked
(task_list_marker_unchecked) @unchecked

(block_quote_marker) @quote

; Every line of a block quote after the first carries its own `>` inside a
; block_continuation. The grammar reuses that node for list and fenced-block
; indentation as well, so match only the ones that hold a marker.
((block_continuation) @quote.continuation
  (#match? @quote.continuation ">"))

(thematic_break) @rule

; The block, not its delimiters: the body sits between the two delimiter
; children, and finding them from the block is what tells a closed block from
; one still being typed.
(fenced_code_block) @code.block
