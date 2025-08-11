" wp-commit-msg.vim - WordPress commit message linter
" Maintainer: jonsurrell

if exists('g:loaded_wp_commit_msg')
  finish
endif
let g:loaded_wp_commit_msg = 1

" Initialize the plugin
lua require('wp-commit-msg').setup()