set nocompatible
execute 'set runtimepath^=' . fnameescape($LANDIN_HIGHLIGHT_ROOT . '/vim')
filetype plugin indent on
syntax enable
execute 'edit ' . fnameescape($LANDIN_HIGHLIGHT_ROOT . '/tests/lexical.ldn')

call assert_equal('landin', &filetype, 'Landin filetype detection')
call assert_equal('-- %s', &commentstring, 'Landin commentstring')

function! s:AssertGroup(needle, expected)
  let l:line = search(a:needle, 'nw')
  let l:text = getline(l:line)
  let l:column = match(l:text, a:needle) + 1
  let l:actual = synIDattr(synID(l:line, l:column, 1), 'name')
  call assert_equal(a:expected, l:actual, a:needle . ' syntax group')
endfunction

call s:AssertGroup('public', 'landinKeyword')
call s:AssertGroup('u23', 'landinWidthType')
call s:AssertGroup('0x2a', 'landinNumber')
call s:AssertGroup('documentation comment', 'landinDocComment')
call s:AssertGroup('nested block comment', 'landinBlockComment')
call s:AssertGroup('escaped', 'landinString')
call s:AssertGroup('raw$', 'landinRawString')

if !empty(v:errors)
  for error in v:errors
    echoerr error
  endfor
  cquit
endif
quitall!
