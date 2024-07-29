## Default options

Depending on your OS, these may need to be done in **one** of several files:
- `~/.bashrc`
- `~/.zshrc` (macOS)

### `ls`

Add:
```
alias ls="ls -ahl"
```
(make sure this doesn't override other `ls` aliases)

## Terminal colors (macOS)

Since macOS is based on FreeBSD and FreeBSD doesn't have `dircolors`, we have to set a different setting.

Add:
```
export CLICOLOR=YES
```
(`dircolors` is specific to GNU coreutils and it's typically included on non-embedded Linux, but not in other unix systems)
