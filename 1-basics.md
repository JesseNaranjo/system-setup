## Update `/etc/issue`

Leave the first line unmodified. It typically looks like this:
```
Debian GNU/Linux {version} \n \1
```

Add the following, where `{iface}` represents the interface name:
```
\4{iface}
\6{iface}
```

Example (including additional blank lines for better visibility):
```
Debian GNU/Linux 12 \n \1

\4{eth0}
\6{eth0}

```
