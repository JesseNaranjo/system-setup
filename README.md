# readme

This repository contains a (hopefully) updated list of (personal) OS preferences and scripts that I use regularly when setting up new installs. This will include a lot for everything - Linux, macOS, Windows, etc.

## repo structure

This readme file will contain the primary set of packages / components that I install and a high level record of setting changes.

And the rest of the repository consists of files and folders representing additional tools that don't always get installed or configured.

## install packages

- aptitude
- curl
- htop
- mc
- screen
- sudo

## add sudoers

```
adduser <username> sudo
```
(may require log out and back in)

## update `/etc/issue`

I recommend leaving the existing contents in place. This content typically describes the installed system and version.

Add the following, where `<iface>` represents the interface name:
```
wire: \4{<iface>0} / \6{<iface>0}
wifi: \4{<iface>1} / \6{<iface>1}
```
(leave the curly braces in!)

Example from Debian 12 (include additional blank lines for better visibility):
```
Debian GNU/Linux 12 \n \1

wire: \4{eth0} / \6{eth0}
wifi: \4{wlan0} / \6{wlan0{


```
