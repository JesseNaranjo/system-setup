# nano options

Create `/etc/nanorc` or `~/.nanorc`, if it doesn't already exist.

**Warning:** do not blindly overwrite `/etc/nanorc` if you go that route!

```shell
set atblanks
set autoindent
set constantshow
set indicator
set linenumbers
set minibar
set mouse
set multibuffer
set nonewlines
set smarthome
set tabsize 4
```
(consider adding to root user as well, if you went the home folder route)

# homebrew nano

By default, nano looks for syntax definitions at `/usr/share/nano/*.nanorc`. When installed using Homebrew, the install path is different and you must add:

```shell
include "/opt/homebrew/share/nano/*.nanorc"
```
