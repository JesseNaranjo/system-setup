## gnu screen options

Create `/etc/screenrc` or `~/.screenrc`, if it doesn't already exist.

```
startup_message off

mousetrack on
scrollback 9999
```
(As of Feb'25, on macOS, it has to be `/etc/screenrc` and *not* `/opt/homebrew/etc/screenrc`)
