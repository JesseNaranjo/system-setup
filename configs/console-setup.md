## console setup options

Ensure the following packages are installed:
- `console-setup`

### console font size

To manually configure the console, reconfigure the package:
```
dpkg-reconfigure console-setup
```

Change:
```
FONTSIZE="16x32"
```
(this is especially useful if you have a 4k monitor and the boot screen and console fonts look tiny)
