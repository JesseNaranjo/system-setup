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

### sort directories first

Add:
```bash
alias ls="ls --color=auto --group-directories-first -AFHhl"
```
(does not work on macOS as of Jan 2025)

### terminal colors (macOS)

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

## `lsblk`

```
alias lsblk='lsblk -o "NAME,FSTYPE,FSVER,LABEL,FSAVAIL,SIZE,FSUSE%,MOUNTPOINTS,UUID"'
```

## `lxc-ls`

```
alias lxc-ls='lxc-ls -f'
```

## `7z` compression helpers

```
alias 7z-ultra1="7z a -t7z -m0=lzma2 -mx=9 -md=256m -mfb=273 -mmf=bt4 -ms=on -mmt"
alias 7z-ultra2="7z a -t7z -m0=lzma2 -mx=9 -md=512m -mfb=273 -mmf=bt4 -ms=on -mmt"
alias 7z-ultra3="7z a -t7z -m0=lzma2 -mx=9 -md=1536m -mfb=273 -mmf=bt4 -ms=on -mmt"
```

<sup>Note: keep in mind that 7-zip on macOS (installed via Homebrew) is called using `7zz` (rather than `7z`).</sup>

| Switch | Effect | Trade-offs |
| - | - | - |
| `-m0=lzma2` | LZMA2 handles mixed data well and multithreads cleanly. | Slightly slower to decompress than plain LZMA. |
| `-mx=9` | Turns on “Ultra” profile: larger dictionary, more passes, bt4 match-finder by default. | Steeper CPU usage; only \~1–3 % extra ratio compared to `-mx=7`. |
| `-md=256m` <sup>(ultra1)</sup><br>`-md=512m` <sup>(ultra2)</sup><br>`-md=1536m` <sup>(ultra3)</sup> | Dictionary the compressor uses to find repeated chunks. Bigger = better until it’s ≈ biggest individual file. Needs the **same RAM to *decompress***. 32-bit 7-Zip can only handle 128 MiB. | 1.5 GiB encode RAM + 1.5 GiB decode RAM; on low-RAM systems extraction can fail. |
| `-mfb=273` | “Fast bytes” – how far encoder scans for a match. Max value gives slight gains for highly repetitive data. | Increases encode time a bit. |
| `-mmf=bt4` | Deep binary-tree search gives best ratio. (`bt2/3` and hash-chain variants are faster but looser.) | Slowest search algorithm. |
| `-ms=on`<br>`-ms=4g`<br>`-ms=32g` | Solid archives treat many files as one stream so the dictionary works across file boundaries. Massive win on lots of small/text files. | One changed file → you must repack almost the whole archive; random extraction can be slow. |
| `-mmt[=N]` | Uses N threads (all cores if none given). | High memory use because each thread has its own buffers. |
