# Firewall — ufw and Docker are two separate problems

## Why ufw alone is not enough

ufw manages the **INPUT** chain: packets addressed to the host itself.

Docker publishes container ports by writing rules into **NAT/PREROUTING** and
**FORWARD**: packets routed *through* the host to a container. Those packets
never reach INPUT, so ufw never sees them.

The consequence is blunt: `docker run -p 5432:5432 postgres` is reachable from
the internet even with `ufw deny 5432` in place, and `ufw status` shows nothing
amiss. This is documented Docker behaviour, not a bug — Docker considers port
publishing an explicit request that the firewall shouldn't second-guess.

## The rule that matters

In this architecture the stack publishes **nothing** to the host, so the exposure
above shouldn't arise. But "shouldn't arise" is a property maintained by everyone
remembering, and the failure is silent. The `DOCKER-USER` rules make it
mechanical.

`DOCKER-USER` is a chain Docker provides specifically for operator rules, and it
is evaluated **before** Docker's own FORWARD rules.

## Why not a blanket DROP

This is the trap, and it breaks everything rather than merely weakening it.

`DOCKER-USER` hangs off FORWARD. Container-**originated** traffic traverses
FORWARD too — a container reaching out to the internet is forwarded, exactly like
a packet arriving for a published port. A chain-wide `-j DROP` therefore blocks:

- `cloudflared` connecting outbound to Cloudflare's edge — the entire public plane
- the backup uploader reaching R2 and B2 — the entire backup path
- any container fetching anything, ever

In an architecture whose defining property is *outbound-only*, dropping outbound
is dropping everything. The box stays up, ufw looks perfect, and nothing works.

## The correct shape

```
iptables -I DOCKER-USER 1 -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
iptables -I DOCKER-USER 2 -i <public-iface> -j DROP
```

Read in evaluation order:

1. **Return traffic is released.** Packets belonging to a connection a container
   already established go back to FORWARD for normal processing.
2. **New inbound on the public interface is dropped.** Anything arriving from the
   internet that isn't part of an existing conversation dies here.

Container egress is untouched, because a container's *outgoing* packet doesn't
arrive on the public interface — and its *reply* is `ESTABLISHED`, caught by
rule 1.

**Order is load-bearing.** Reply packets for container-initiated connections
arrive **on the public interface**. If the DROP came first it would eat every
one of them, and all outbound connections would hang — which looks like a
network problem, not a firewall problem, and burns an afternoon.

`-j RETURN` rather than `-j ACCEPT`: RETURN hands the packet back to FORWARD so
Docker's own rules still apply. ACCEPT would short-circuit them.

## Assert both properties

The mistake is asymmetric — it's easy to verify "nothing gets in" and never
notice you've also blocked "things can get out". So check both:

```bash
docker-firewall.sh verify              # rule presence and order
EGRESS_TEST=1 docker-firewall.sh verify # plus a real container reaching the internet
```

The egress assertion is the one that catches a blanket DROP. Without it, a
broken firewall passes verification and fails in production when cloudflared
can't reconnect after a restart.

## Persistence

iptables rules do not survive a reboot on their own. `iptables-persistent`
(`netfilter-persistent save`) writes them to `/etc/iptables/`. Without it the
protection silently disappears at the first reboot — and since the stack
publishes nothing anyway, you may not notice for months.

Install it, save, then reboot deliberately and re-run `verify` before trusting it.

## IPv6

If Docker has IPv6 enabled there is a separate `ip6tables` DOCKER-USER chain, and
rules in the IPv4 chain do nothing for it. The script applies to both when the
v6 chain exists. If you enable Docker IPv6 later, re-run `apply`.

## Interaction with the provider firewall

A cloud firewall (Hetzner Cloud Firewall, AWS security groups) filters *before*
traffic reaches the host, so it does cover Docker-published ports. It's a fine
extra layer and this repo treats it as optional — depending on it would break the
provider-agnostic goal, and it doesn't help the moment you're on a provider that
doesn't offer one.
