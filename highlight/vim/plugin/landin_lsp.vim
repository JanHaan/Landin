" `refine lsp`, the Landin compiler's language server, for vim-lsp
" (https://github.com/prabirshrestha/vim-lsp): diagnostics, definitions,
" hover, formatting and quick fixes from the compiler's own stages.  It is
" registered only when vim-lsp is installed and `refine` is on the path, so
" without either this does nothing.
if exists('g:loaded_landin_lsp') | finish | endif
let g:loaded_landin_lsp = 1

function! s:register() abort
  if !executable('refine') || !exists('*lsp#register_server')
    return
  endif
  call lsp#register_server({
        \ 'name': 'refine',
        \ 'cmd': {server_info -> ['refine', 'lsp']},
        \ 'allowlist': ['landin'],
        \ })
endfunction

augroup landin_lsp
  autocmd!
  autocmd User lsp_setup call s:register()
augroup END
