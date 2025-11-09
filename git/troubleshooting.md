## git fetch, push, etc. hangs

**The cause:** VPN
**Solutions (choose 1):**
- Disconnect the VPN
- Change MTU: `ip link set dev eth0 mtu 1200`

`git` inside an LXC container inside a VM was failing `git fetch` and `git push` - the commands would just hang.

Some solutions online suggest adding `KexAlgorithms=ecdh-sha2-nistp521` to ~/.ssh/config, which solves the `git fetch` problem but not `git push`.

Apparently a high network device MTU causes this issue. The VM and LXC have MTU set to 1500. Overriding that to 1200 fixes the issue.

```
ip link set dev eth0 mtu 1200
```

References:
- https://github.com/tailscale/tailscale/issues/4140 (https://github.com/tailscale/tailscale/issues/4140#issuecomment-1218251725)
- https://unix.stackexchange.com/a/739213/274357
