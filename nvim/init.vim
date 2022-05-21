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

