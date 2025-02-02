# gnu screen options

Create `/etc/screenrc` or `~/.screenrc`, if it doesn't already exist.

**Warning:** do not blindly overwrite `/etc/screenrc` if you go that route!

```
mousetrack on
scrollback 9999
startup_message off
```
(As of Feb'25, on macOS, this file has to be `/etc/screenrc` and *not* `/opt/homebrew/etc/screenrc`)
