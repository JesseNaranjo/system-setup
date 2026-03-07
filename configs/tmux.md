# tmux options

Create `/etc/tmux.conf` (Linux), `/opt/homebrew/etc/tmux.conf` (macOS), or `~/.tmux.conf`, if it doesn't already exist.

```
set -g base-index 1
set -g pane-base-index 1
set -g default-terminal "tmux-256color"

set -g history-limit 50000
set -g mouse on
#set -g remain-on-exit on

set -g window-style 'bg=color235'
set -g window-active-style 'bg=color233'

set -g pane-border-lines double

set -g prefix C-a
unbind C-b

bind | split-window -hc "#{pane_current_path}"
bind \\ split-window -hc "#{pane_current_path}"
unbind %
bind - split-window -vc "#{pane_current_path}"
bind _ split-window -vc "#{pane_current_path}"
unbind \"
```
