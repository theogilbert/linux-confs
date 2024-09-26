set shiftwidth=4
set smarttab
set expandtab
set tabstop=8
set softtabstop=0

set foldmethod=syntax
set foldlevelstart=20

set wildmode=list:longest

let mapleader=','

set cursorline
syntax on

syntax on
set t_Co=256
set cursorline
if exists('+termguicolors')
  let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
  let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
  set termguicolors
endif

" checks if your terminal has 24-bit color support
if (has("termguicolors"))
    set termguicolors
    hi LineNr ctermbg=NONE guibg=NONE
endif

inoremap <Tab> <Esc>
vnoremap <Tab> <Esc>

set wrap!
set number

inoremap <Tab> <Esc>
vnoremap <Tab> <Esc>

set statusline=
set statusline +=%1*\ %n\ %*      " buffer number
set statusline +=%4*%<%F%*        " full path
set statusline +=%2*%m%*          " modified flag 
set statusline +=%1*\ %=%l%*     " current line
set statusline +=%1*/%L%*         " total line
set statusline +=%2*\ col=%v%*    " column number
set statusline +=%1*\ char=0x%B%* " char under cursor
set statusline +=%1*\ off=0x%O%* " char offset in bytes
