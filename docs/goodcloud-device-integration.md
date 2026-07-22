# GoodCloud Device-Side Integration & Support

How a GL.iNet router connects to **GoodCloud** (goodcloud.xyz) for remote management,
what the connection depends on, and a step-by-step runbook for diagnosing and fixing a
router that shows **offline** in GoodCloud.

This is the **device half** of the picture. For the **cloud/client half** — the web/API
contract (auth, request signing, `rtty/run` provisioning, relay consumption) — see
[`goodcloud-remote-access.md`](goodcloud-remote-access.md). For designing an app that
consumes the relay, see [`relay-integration-design.md`](relay-integration-design.md).

> Verified live on a **GL.iNet E5800** (Mudi 2 5G), firmware **4.8.5**, OpenWrt 23.05.4
> (SDX75), 2026-07-21. Commands and log lines below are the real ones observed.

---

## 1. Overview: two sides of GoodCloud

```
   ROUTER (device side)                          GOODCLOUD (cloud side)
   ┌────────────────────┐                        ┌───────────────────────────┐
   │ gl-cloud daemon     │◄── MQTT (TLS 28883) ──►│ regional MQTT broker       │
   │  (control channel)  │                        │ (presence, commands, RPC)  │
   │                     │                        │                           │
   │ rtty client ────────┼──── WSS (relay) ──────►│ rttys server (data path)   │
   │  (on demand)        │                        │  proxies LAN host:port     │
   └────────────────────┘                        └───────────────────────────┘
```

- **Control channel** — `gl-cloud` keeps a persistent **MQTT-over-TLS** connection to a
  regional broker. This is what makes the device show **online** and lets the cloud push
  commands (including "start a remote-access session").
- **Data path** — when you click *Remote GUI / Remote SSH* (or an app calls `rtty/run`),
  the router's **rtty** client dials GL's **rttys** server and proxies a chosen LAN
  `host:port` back over WebSocket. This is a separate, on-demand connection; see the
  cloud-side doc for the client contract.

If the **control channel** can't establish, the device is offline in GoodCloud and no
relay can be provisioned — even if the router itself has perfectly good internet.

---

## 2. The `gl-cloud` daemon

- Binary: `/usr/bin/gl-cloud`, run under GL's `eco` (lua-eco) supervisor:
  `ps w | grep gl-cloud` → `/usr/bin/eco /usr/bin/gl-cloud`.
- Init script: `/etc/init.d/gl_cloud` (`start` / `stop` / `restart`).
- Logs to syslog with the `gl-cloud[pid]` tag — read with `logread | grep gl-cloud`.
- Exposes a ubus object `gl-cloud` (see §5).

### Config schema — `/etc/config/gl-cloud` (`uci show gl-cloud`)

```
gl-cloud.@cloud[0]=cloud
gl-cloud.@cloud[0].enable='1'                       # 0 disables the daemon
gl-cloud.@cloud[0].log='INFO'                       # log level
gl-cloud.@cloud[0].server='gslb-eu.goodcloud.xyz'   # GSLB entry point (see §6)
gl-cloud.@cloud[0].token='…'                         # device bind token (account-scoped secret)
gl-cloud.@cloud[0].username='keith'                 # bound account
gl-cloud.@cloud[0].email='keith@example.net'        # bound account email
gl-cloud.@cloud[0].bindtime='1784615856182'         # epoch-ms of bind
gl-cloud.@cloud[0].bindtype='self'                  # 'self' = bound to your own account
```

- `server` is the **GSLB (global server load balancer) entry hostname**, *not* the broker.
  The daemon resolves it, fetches a CA and a broker assignment from it, then connects to
  whatever broker the backend hands back (§6).
- `token` is the per-device binding secret. **Treat it as a credential** — anyone with it
  plus the account context can manage the device. Do not commit it or paste it into logs.

---

## 3. Connection lifecycle

A healthy start looks exactly like this in `logread`:

```
gl-cloud: lua-eco version: 3.14.0
gl-cloud: Ubus services init done.
gl-cloud: fetch ca from: https://gslb-eu.goodcloud.xyz/getCaCert/ca.crt      # 1. get CA
gl-cloud: fetch server from: https://gslb-eu.goodcloud.xyz/v2/device/auth    # 2. get broker
gl-cloud: connect mqtt broker: 18.209.114.161 28883                          # 3. dial broker (TLS)
gl-cloud: conack: 0 connection accepted                                      # 4. connected ✓
```

1. **Fetch CA** — HTTPS GET `…/getCaCert/ca.crt`. The daemon needs this CA to validate the
   broker's TLS cert. Expects a `200` with the cert body.
2. **Fetch server** — HTTPS GET `…/v2/device/auth`. Returns the broker host/port to use
   (region-selected server-side).
3. **Connect MQTT broker** — TLS to `<broker>:28883`.
4. **`conack: 0 connection accepted`** — MQTT CONNACK success. Device is now **online**.

### The failure signature

```
gl-cloud: fetch ca from: https://gslb-eu.goodcloud.xyz/getCaCert/ca.crt
gl-cloud: fetch ca fail with code 302        ← never got the cert
gl-cloud: reconnect mqtt in 160s...          ← backs off, retries forever
```

`fetch ca fail with code 302` means step 1 failed: instead of the cert body it got a
redirect/garbage — most often because **`gslb-*.goodcloud.xyz` resolved to a null / wrong
IP** (see §7). The daemon then loops on a **160-second** reconnect timer indefinitely, and
the device stays offline. This is the canonical "GoodCloud broken but internet is fine"
symptom.

---

## 4. `gl-cloud` ubus interface

`ubus -v list gl-cloud`:

```
"bind":     {"id":"String","url":"String","token":"String"}
"rebind":   {"url":"String","token":"String"}
"unbind":   {}
"status":   {}
"alive":    {}
"trace":    {}
"notify":                       {}
"notify-network-info":          {}
"notify-sim-status":            {}
"cellular_event":               {}
"bind_url":                     {}
"dump_features":                {}
"dump_subscribe_attributes":    {}
"subscribe_events_notify":      {}
"set_log_level":  {"level":"Integer"}
```

- **`status`** — current cloud connection state. First thing to call when scripting a check.
- **`bind` / `unbind`** — attach/detach the device to a GoodCloud account (normally driven by
  the app or the router UI's GoodCloud page, which supplies `id`/`url`/`token`).
- **`rebind`** — re-point to a different GSLB `url` (and/or `token`) **without a full
  unbind/bind cycle**. This is the clean way to move regions if you ever need to; it updates
  the binding in place. (In practice rarely needed — see §6.)
- **`set_log_level`** — bump verbosity when debugging (`level` integer).

---

## 5. Region / GSLB topology

`server` looks region-specific, but the region name in the hostname is mostly cosmetic. As
observed (2026-07-21):

| GSLB hostname             | Resolves to        | Backend                       |
|---------------------------|--------------------|-------------------------------|
| `gslb-eu.goodcloud.xyz`   | `34.199.215.175`   | AWS **us-east-1** (international) |
| `gslb-us.goodcloud.xyz`   | `34.199.215.175`   | **same IP** — us-east-1        |
| `gslb.goodcloud.xyz`      | `120.79.223.158`   | Alibaba Cloud (**China**)      |

- `gslb-eu` and `gslb-us` are the **same international endpoint**. Real region/broker
  selection happens server-side at `…/v2/device/auth`, which returns a specific broker
  (e.g. `18.209.114.161` = us-east-1). **Rebinding `gslb-eu` → `gslb-us` is a no-op.**
- The only genuinely different backend is plain `gslb.goodcloud.xyz` (China/Alibaba), which
  is *worse* for a North-American device.
- **Takeaway:** don't chase latency by editing `server`. The broker is assigned by the
  backend; there is no user-selectable us-west option here, and us-east-1 (~70 ms from the
  US west coast) is fine for management + relay control traffic.

If you *do* need to change region deliberately (e.g. moving to the China backend), use the
`rebind` ubus method with the new GSLB `url` and the existing `token` rather than hand-editing
uci, so the binding stays consistent.

---

## 6. The DNS dependency — the trap

**`gl-cloud` resolves names through the router's *system* resolver**
(`/etc/resolv.conf` → `/tmp/resolv.conf.d/resolv.conf.auto`), which is populated from each
**WAN interface's DHCP-provided DNS** (`peerdns`). It does **not** go through the LAN-facing
AdGuard Home / dnsmasq that your client devices use.

This split is the whole trap:

- **LAN clients** query AdGuard (`127.0.0.1:53` on the router), which has its own upstreams —
  so from a laptop, `goodcloud.xyz` resolves fine.
- **`gl-cloud` (and other router system processes)** query the WAN-provided DNS servers
  directly. If the upstream network (e.g. the WISP / WiFi-repeater network you're getting
  WAN from) **filters `goodcloud.xyz`**, `gl-cloud` gets the poisoned answer and fails —
  even though every client on the LAN resolves it correctly.

So a GoodCloud outage can be invisible from any client device and only reproducible from the
router's own shell. **Always test resolution from the router, per-resolver.**

### Why a filtered domain produces `0.0.0.0` / `::`

DNS filters (AdGuard, Pi-hole, some carrier/WISP resolvers) answer a *blocked* domain with a
null address — `0.0.0.0` for A, `::` for AAAA — rather than NXDOMAIN. A stub resolver treats
that as a **successful** answer and stops (it won't fall through to the next `nameserver`), so
`gl-cloud` dutifully "connects" to `0.0.0.0`, which fails as the `302`/CA-fetch error.

---

## 7. Support runbook

Symptom: device shows **offline** in GoodCloud; router has working internet.

### Step 1 — confirm it's the control channel

```sh
logread | grep -i gl-cloud | tail -20
```

Look for the `fetch ca fail` / `reconnect mqtt in 160s` loop (§3). If you instead see
`conack: 0 connection accepted` and no recent errors, `gl-cloud` is fine — the problem is
elsewhere (account/app side).

### Step 2 — check the daemon is even running

```sh
ps w | grep -v grep | grep gl-cloud        # expect: /usr/bin/eco /usr/bin/gl-cloud
uci -q get gl-cloud.@cloud[0].enable       # expect: 1
```

### Step 3 — resolve `goodcloud.xyz` from the router, per resolver

This is the decisive test. Compare the **system resolver** against a known-good public one:

```sh
# What gl-cloud actually gets (system resolver = WAN peerdns):
nslookup gslb-eu.goodcloud.xyz

# Known-good control:
nslookup gslb-eu.goodcloud.xyz 8.8.8.8
```

- Both return a real public IP → DNS is fine; look at connectivity/firewall/time instead.
- System resolver returns **`0.0.0.0` / `::`** but `8.8.8.8` returns a real IP → **upstream
  DNS is filtering goodcloud.** Continue to Step 4.

### Step 4 — find *which* upstream resolver is poisoning it

List the system resolvers and query each one directly:

```sh
cat /tmp/resolv.conf.d/resolv.conf.auto        # shows nameservers grouped by interface

for s in <each nameserver>; do
  echo -n "$s -> "; nslookup gslb-eu.goodcloud.xyz $s 2>/dev/null | awk '/^Address/{a=$NF} END{print a}'
done

# Control domain to prove it's goodcloud-specific, not a dead resolver:
nslookup apple.com <suspect-nameserver>
```

The offending server returns `0.0.0.0`/`::` for goodcloud but resolves `apple.com` normally.
Note **which interface** it belongs to in `resolv.conf.auto` (e.g. `wwan` = WiFi-repeater WAN,
`modem_cpu` = the 5G modem, `wan` = wired).

Confirm it's *not* the router's own AdGuard being blamed:

```sh
nslookup gslb-eu.goodcloud.xyz 127.0.0.1       # local AdGuard/dnsmasq
grep -rin goodcloud /etc/AdGuardHome/           # is goodcloud in a blocklist/user rule?
```

If `127.0.0.1` resolves it correctly and there's no goodcloud match in AdGuard, the block is
**upstream**, not on this router.

### Step 5 — fix: stop the router trusting the poisoned upstream DNS

Override DNS on the **active WAN interface** (the one carrying the bad resolver — identify it
in Step 4). Example for a WiFi-repeater WAN named `wwan`:

```sh
uci set network.wwan.peerdns='0'                 # ignore DHCP-provided DNS
uci set network.wwan.dns='1.1.1.1 8.8.8.8'       # use known-good resolvers
uci commit network
/etc/init.d/network reload
```

Notes:
- Set this on the interface that actually provides the poisoned resolver. Check the default
  routes / metrics to know which WAN is primary: `ip route | grep default`
  (lowest `metric` wins), and `uci show network | grep '=interface'` to list interfaces.
- This changes **only the router's system resolver**. LAN clients / AdGuard are unaffected.
- Verify the new resolv.conf: `cat /tmp/resolv.conf.d/resolv.conf.auto` should now list your
  custom nameservers for that interface.

### Step 6 — verify the fix

```sh
nslookup gslb-eu.goodcloud.xyz                   # now returns a real public IP
/etc/init.d/gl_cloud restart                     # don't wait for the 160s backoff
sleep 8
logread | grep -i gl-cloud | tail -15
```

Success = the full lifecycle from §3 ending in **`conack: 0 connection accepted`**. The
device returns to **online** in GoodCloud within seconds.

---

## 8. Not-a-bug: distinguishing GoodCloud from Tailscale

GoodCloud and Tailscale are **independent** remote-access paths and fail independently. Don't
assume "remote access is down" means both are broken.

| | GoodCloud (`gl-cloud`) | Tailscale (`tailscaled`) |
|---|---|---|
| Transport | MQTT/TLS to a GL broker + rtty relay | WireGuard + DERP |
| DNS path | router **system resolver** (WAN peerdns) | its own control-plane names (`*.tailscale.com`) |
| Health check | `logread \| grep gl-cloud` → `conack: 0` | `tailscale status`; `tailscale netcheck`; `tailscale debug prefs` |
| "Working" looks like | device online in GoodCloud dashboard | `BackendState: Running`, `Self.Online: true`, `Health: []` |

Common confusion: **`tailscale status` listing many peers as `offline`** does **not** mean
Tailscale is broken — those are other devices that are simply powered off. If the router's own
node shows `Self.Online: true` with an empty `Health` array and `netcheck` reaches a nearby
DERP, Tailscale on the router is healthy regardless of peer states. A domain-filtering upstream
DNS (the GoodCloud failure above) typically does **not** affect Tailscale, because Tailscale
doesn't resolve `goodcloud.xyz` and reaches its control plane over paths the filter isn't
touching.

---

## 9. Quick reference

```sh
# Health
logread | grep -i gl-cloud | tail -20
ubus call gl-cloud status
ps w | grep -v grep | grep gl-cloud

# DNS diagnosis (run ON the router)
cat /tmp/resolv.conf.d/resolv.conf.auto
nslookup gslb-eu.goodcloud.xyz            # system resolver (what gl-cloud sees)
nslookup gslb-eu.goodcloud.xyz 8.8.8.8    # control
nslookup gslb-eu.goodcloud.xyz 127.0.0.1  # local AdGuard

# Fix (adjust interface name to the active WAN)
uci set network.<wan-iface>.peerdns='0'
uci set network.<wan-iface>.dns='1.1.1.1 8.8.8.8'
uci commit network && /etc/init.d/network reload

# Kick the daemon after fixing DNS
/etc/init.d/gl_cloud restart

# Region (usually unnecessary — gslb-eu == gslb-us)
ubus call gl-cloud rebind '{"url":"gslb-eu.goodcloud.xyz","token":"<token>"}'
```
