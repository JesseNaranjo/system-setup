# ghostty terminfo over ssh

Ghostty renders with the `xterm-ghostty` terminfo entry. Remote hosts that lack it
break interactive TUIs (`nano`, `htop`, `vim`) with `Error opening terminal: xterm-ghostty`.

## Recommended Ghostty config

In `~/.config/ghostty/config` (Linux) or
`~/Library/Application Support/com.mitchellh.ghostty/config` (macOS):

```
shell-integration-features = ssh-terminfo,ssh-env
```

`ssh-terminfo` auto-installs the entry on first connect; `ssh-env` forwards
`COLORTERM`/`TERM_PROGRAM` (the remote `sshd` must list them in `AcceptEnv`).

## When automatic install isn't enough

Ghostty's built-in `ssh-terminfo` install is **per-user only** and is skipped when
ssh is invoked by wrapper tools (`mosh`, `rsync`, `git`, `scp`), non-interactive
shells, scripts, or some `ProxyJump`/`RemoteCommand` setups. It caches per
`user@host` (manage with `ghostty +ssh-cache`), so a failed or stale install is not
retried. Because it writes to `~/.terminfo`, other users on the remote — including
`root` after `su`/`sudo` — still can't resolve `xterm-ghostty`.

For a reliable, **system-wide** install (all users, including root), use:

```
utils/push-ghostty-terminfo.sh user@host
```

See `utils/README.md` for options (`--user`, `--force`).
