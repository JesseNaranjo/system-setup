## debian sources recommendations

- Add `contrib non-free non-free-firmware` to each line
- Comment out deb-src entries unless you're going to build from source
- Change URLs to https, if you're into that sort of thing (which I am)
- Add backports entry to get newer versions backported to the release
  - `deb https://deb.debian.org/debian/ <release>-backports main contrib non-free non-free-firmware`
