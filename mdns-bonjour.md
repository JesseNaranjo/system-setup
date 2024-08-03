## Useful commands

### Discover services supported by the local device

Command: `dns-sd -B _services._dns-sd._udp`

Example output:
```
Browsing for _services._dns-sd._udp
DATE: ---Sat 03 Aug 2024---
10:19:28.487  ...STARTING...
Timestamp     A/R    Flags  if Domain               Service Type         Instance Name
10:19:28.489  Add        3  14 .                    _tcp.local.          _companion-link
10:19:28.489  Add        3   1 .                    _tcp.local.          _companion-link
10:19:28.489  Add        2  15 .                    _tcp.local.          _companion-link
10:19:28.780  Add        2  15 .                    _tcp.local.          _alexa
10:19:29.703  Add        3  15 .                    _udp.local.          _sleep-proxy
10:19:29.703  Add        3  15 .                    _tcp.local.          _srpl-tls
10:19:29.703  Add        3  15 .                    _udp.local.          _trel
10:19:29.703  Add        3  15 .                    _udp.local.          _meshcop
10:19:29.704  Add        3  15 .                    _tcp.local.          _raop
10:19:29.704  Add        2  15 .                    _tcp.local.          _airplay
10:19:29.955  Add        2  15 .                    _tcp.local.          _hap
```

### Discover devices that support the specified type (e.g., "_companion-link")

Command: `dns-sd -B _companion-link._tcp`

Example output:
```
Browsing for _companion-link._tcp
DATE: ---Sat 03 Aug 2024---
10:27:51.438  ...STARTING...
Timestamp     A/R    Flags  if Domain               Service Type         Instance Name
10:27:51.439  Add        3  14 local.               _companion-link._tcp. <example-machine-local>
10:27:51.439  Add        3   1 local.               _companion-link._tcp. <example-machine-local>
10:27:51.439  Add        3  15 local.               _companion-link._tcp. <example-machine-local>
10:27:51.439  Add        3  15 local.               _companion-link._tcp. <example-machine-1>
10:27:51.439  Add        2  15 local.               _companion-link._tcp. <example-device-1>
10:28:01.607  Add        3  15 local.               _companion-link._tcp. <example-machine-2>
10:28:01.607  Add        2  15 local.               _companion-link._tcp. <example-machine-2>
10:28:01.619  Add        2  15 local.               _companion-link._tcp. <example-device-2>
```
