# Configuration files

Currently, this repository contains scripts for the following softwares:
- bash
- neovim
- tmux
- kwin

## Scripts

###  bash / tmux

#### Installation

Simply copy these scripts to your home directory.

### Neovim

See [this documentation](./nvim/README.md) for more details.

### Kwin

#### Description

The [kwin](kwin) directory contains a KWin script allowing a user to toggle the focus of various windows:

| Window   | Shortcut |
| -------- | -------- |
| Konsole  | `Meta+M` |
| Firefox  | `Meta+F` |

#### Installation

To install the Kwin script, follow these steps:

```shell
# Clone this repository
git clone https://github.com/theogilbert/confs/

# Install the script
kpackagetool6 --type=KWin/Script -i confs/kwin/togglewindow
```

#### Contributing

If you have modified these scripts, you can apply your modifications by following these steps:

1. Update the script in the KWin registry
    ```shell
    kpackagetool6 --type=KWin/Script -u confs/kwin/togglewindow
    ```
2. Open the `KWin Scripts` window.
3. Uncheck the `Toggle Focus` script and click on Apply.
4. Check the `Toggle Focus` script and click on Apply.

If you encounter issues after applying your modifications, you can troubleshoot the script by printing to stdout using `console.info(...)`.

You can then view these logs through `journalctl`:

```shell
journalctl -f
```
