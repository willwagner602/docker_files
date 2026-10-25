# Host DNS: split-horizon shortcut for `*.willwagner.me` (wbw-ha)

Without this, LAN clients and containers resolve `*.willwagner.me` to the
public IP and every connection hairpins out the WAN edge and back — adding
10–25s per connection to self-hosted services that sit metres away.

The fix has two halves:

1. **Pi-hole side** (declarative in `general/pihole.yml`): a dnsmasq wildcard
   `address=/willwagner.me/10.0.0.16` via `FTLCONF_misc_dnsmasq_lines_0`, plus
   explicit `FTLCONF_dns_hosts_*` entries for names that must NOT follow the
   wildcard (`usg` lives at `10.0.0.1`). Exact entries always beat the
   wildcard, so a future subdomain hosted elsewhere needs only one new
   `FTLCONF_dns_hosts_n` line here.
2. **Host side** (this document): wbw-ha's own resolver must send `*.willwagner.me`
   to Pi-hole. Nothing in Docker can do this — it is OS configuration, so it is
   recorded here rather than automated. Run once per host, sudo required:

```bash
# 1) systemd-resolved: use Pi-hole as the global resolver (persists reboots)
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNS=10.0.0.16\nDomains=~.\n' | sudo tee /etc/systemd/resolved.conf.d/pihole.conf
sudo systemctl restart systemd-resolved

# 2) system resolver file: Pi-hole first, gateway as fallback
sudo rm /etc/resolv.conf
printf 'nameserver 10.0.0.16\nnameserver 10.0.0.1\n' | sudo tee /etc/resolv.conf
```

`/etc/nsswitch.conf` on this host has no `resolve` NSS module, so glibc reads
`/etc/resolv.conf` directly — step 2 is the one that changes behaviour;
step 1 keeps systemd-resolved itself consistent.

Verify:

```bash
getent hosts unifi.willwagner.me   # expect 10.0.0.16, not the WAN IP
```

The second `nameserver 10.0.0.1` is deliberate: if the Pi-hole container is
down, DNS degrades to the gateway (hairpin returns) instead of failing hard.

Revert:

```bash
sudo rm /etc/resolv.conf /etc/systemd/resolved.conf.d/pihole.conf
sudo ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved
```
