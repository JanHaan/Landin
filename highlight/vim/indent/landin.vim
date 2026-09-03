if exists('b:did_indent') | finish | endif
let b:did_indent = 1
setlocal autoindent
setlocal indentexpr=GetLandinIndent()
setlocal indentkeys=o,O,0=end,0=else,0=elsif,0=\|
let b:undo_indent = 'setlocal autoindent< indentexpr< indentkeys<'

if exists('*GetLandinIndent') | finish | endif
function! GetLandinIndent()
  let l:previous = prevnonblank(v:lnum - 1)
  if l:previous == 0 | return 0 | endif
  let l:indent = indent(l:previous)
  let l:line = substitute(getline(l:previous), '--.*$', '', '')
  if l:line =~# '\v(=|\<(then|begin|struct|concept|variant)\>)\s*$'
    let l:indent += shiftwidth()
  endif
  if getline(v:lnum) =~# '^\s*\%(end\>\|else\>\|elsif\>\||\)'
    let l:indent -= shiftwidth()
  endif
  return max([0, l:indent])
endfunction
