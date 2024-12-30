## sources list recommendations

## debian

- Add `contrib non-free non-free-firmware` to each line
- Comment out deb-src entries unless you're going to build from source
- Add backports entry just to be safe
  - `deb http://deb.debian.org/debian/ <release>-backports main contrib non-free non-free-firmware`
