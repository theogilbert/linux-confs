# NVIM configuration

This directory contains my Neovim configuration.

It includes a minimal set of plugin to use VIM as an IDE.

## Security risk mitigation

Although I personnally vetted some plugins (mini.statusline, sonokai), other plugins are too large to vet without spending dozen of hours it.\
Instead, I rely on the popularity of a plugin to assess whether it is safe to add to my configuration. I rely on GitHub stars, recommendations from varying sources, the number of contributors and the date of the most recent commit.\
I then vendor plugins to my configuration and try to keep them up to date, although I never use too recent releases to reduce the risk of supply chain attack. My mitigation strategy to reduce this risk is to use plugins with a broad userbase, and to install versions which are at least a couple of weeks old. My hope is that in that time, such attacks would be detected by one of the library's many users.

## Requirements

- nvim 0.10.2 or later

## Installation

To install this configuration:

1. Place the `.config/nvim/` directory in `~/.config/`.
2. Place the `.local/share/nvim/` directory in `~/.local/share/`.

## Included plugins

### Sonokai

The `sainnhe/sonokai` plugin adds an improved colorscheme.

### mini.statusline

The `echasnovski/mini.nvim` repository includes a `mini.statusline` plugin.

This plugin defines a statusline.

