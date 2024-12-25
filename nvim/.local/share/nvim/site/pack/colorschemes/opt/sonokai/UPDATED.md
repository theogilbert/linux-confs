# What changed from the original plugin

## Source

This plugin is based off the commit `fd42b20963c34dfc1744ac31f6a6efe78f4edad2` of `sainnhe/sonokai`.

## Modifications

To facilitate vetting this plugin, some unnecessary files have been removed.

These files are:

```
└── sonokai
    ├── .git
    │   └── *
    ├── .githooks
    │   └── pre-commit
    ├── .github
    │   └── ISSUE_TEMPLATE
    │       ├── bug_report_gui.yml
    │       ├── bug_report_tui.yml
    │       └── config.yml
    ├── autoload
    │   ├── airline
    │   │   └── themes
    │   │       └── sonokai.vim
    │   └── lightline
    │       └── colorscheme
    │           └── sonokai.vim
    ├── lua
    │   └── lualine
    │       └── themes
    │           └── sonokai.lua
```

The `*.vim` and `*.lua` files are used to configure the theme of various status line libraries.

As I am using the `mini.statusline` library for my statusline, these are not necessary.

