## Install Packages

- aptitude
- mc
- sudo

### Add sudoers

```
adduser <username> sudo
```
(may require log out and back in)

### aptitude options

- Forget which packages are "new" whenever the package lists are updated
- Forget which packages are "new" whenever packages are installed or removed

## Update `/etc/issue`

I recommend leaving the existing contents in place. This content typically describes the installed system and version.

Add the following, where `<iface>` represents the interface name:
```
\4{<iface>}
\6{<iface>}
```
(leave the curly braces in!)

Example from Debian 12 (include additional blank lines for better visibility):
```
Debian GNU/Linux 12 \n \1

\4{eth0}
\6{eth0}

```
