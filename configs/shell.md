# shell config

Depending on your OS and shell flavor, these may need to be done in **one** of several files:
- `~/.bashrc`
- `~/.zshrc` (macOS)

## safety first

Add:
```bash
# Some more alias to avoid making mistakes:
alias rm='rm -v' # -i
alias cp='cp -aiv'
alias mv='mv -iv'
```
- `-a` - `cp` only, copy file attributes, ctime, and mtime
- `-i` - interactive, any overwrites will ask for confirmation
- `-v` - verbose, show all actions taken

## `ls`

Add:
```bash
alias ls="ls -AFHhl"
```
(make sure this doesn't override other `ls` aliases)
- `A` - almost-all (simply excludes . and ..)
- `F` - append indicator to each entry (`*` = executable, `/` = directory, `@` = symlink, etc.)
- `H` - displays symlink targets
- `h` - human readable sizes (e.g., 10K, 10M, etc.)
- `l` - (lowercase L) displays listing in long format (one per line)

## Sort directories first (`ls`)

Add:
```bash
alias ls="ls --group-directories-first -AFHhl"
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
