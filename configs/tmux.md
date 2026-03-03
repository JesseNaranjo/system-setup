# tmux options

Create `/etc/tmux.conf` or `~/.tmux.conf`, if it doesn't already exist.

```
set -g mouse on
set -g history-limit 50000
set -g base-index 1
set -g pane-base-index 1
set -g default-terminal "tmux-256color"
```
