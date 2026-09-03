if exists('b:did_ftplugin') | finish | endif
let b:did_ftplugin = 1
setlocal commentstring=--\ %s
setlocal comments=s1:--(,mb:\ ,ex:)--,:--
setlocal suffixesadd=.ldn
let b:undo_ftplugin = 'setlocal commentstring< comments< suffixesadd<'
