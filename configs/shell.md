# shell config

Depending on your OS and shell flavor, these may need to be done in **one** of several files:
- `~/.bashrc`
- `~/.zshrc` (macOS)

## safety first

Add:
```bash
# Aliases to help avoid some mistakes:
alias cp='cp -aiv'
alias mkdir='mkdir -v'
alias mv='mv -iv'
alias rm='rm -Iv'

alias chmod='chmod -vv'
alias chown='chown -vv'

alias lsblk='lsblk -o "NAME,FSTYPE,FSVER,LABEL,FSAVAIL,SIZE,FSUSE%,MOUNTPOINTS,UUID"'
```
- `-a` - `cp` only, copy file attributes, ctime, and mtime
- `-i` - interactive, any overwrites will ask for confirmation
- `-I` - interactive when removing 3+ files
- `-v` - verbose, show all actions taken
- `-vv` - `chmod` and `chown` only, verbose output even when no changes are made
  - macOS / zsh doesn't output when no changes are made even with `-vv`

## `ls`

Add:
```bash
alias ls="ls --color=auto -AFHhl"
```
(make sure this doesn't override other `ls` aliases)
- `--color=auto` - GNU coreutils only (e.g., macOS zsh likely won't support this)
- `A` - almost-all (simply excludes . and ..)
- `F` - append indicator to each entry (`*` = executable, `/` = directory, `@` = symlink, etc.)
- `H` - displays symlink targets
- `h` - human readable sizes (e.g., 10K, 10M, etc.)
- `l` - (lowercase L) displays listing in long format (one per line)

## Sort directories first (`ls`)

Add:
```bash
alias ls="ls --color=auto --group-directories-first -AFHhl"
```
(does not work on macOS as of Jan 2025)

## terminal colors (macOS)

Since macOS is based on FreeBSD and FreeBSD doesn't have `dircolors`, we have to set a different setting.

Add:
```bash
export CLICOLOR=YES
```
(`dircolors` is specific to GNU coreutils and it's typically included on non-embedded Linux distributions, but may not be included by default in all unix flavors)

Alternatively, add:
```bash
alias ls="ls -AFGHhl"
```
- `G` - displays color (**macOS only**, equivalent to `CLICOLOR=YES`)
