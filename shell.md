## runtime config options

Depending on your OS and shell flavor, these may need to be done in **one** of several files:
- `~/.bashrc`
- `~/.zshrc` (macOS)

### `ls`

Add:
```
alias ls="ls -AhHl"
```
(make sure this doesn't override other `ls` aliases)
- `A` - almost-all (simply excludes . and ..)
- `h` - human readable sizes (e.g., 10K, 10M, etc.)
- `H` - displays symlink targets
- `l` - (lowercase L) displays listing in long format (one per line)

## Terminal colors (macOS)

Since macOS is based on FreeBSD and FreeBSD doesn't have `dircolors`, we have to set a different setting.

Add:
```
export CLICOLOR=YES
```
(`dircolors` is specific to GNU coreutils and it's typically included on non-embedded Linux distributions, but may not be included by default in all unix flavors)
