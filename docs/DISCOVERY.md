# Discovery

How Choragus finds Sonos speakers on the local network. As of v4.0 the app runs two parallel discovery transports (SSDP + Bonjour) so it works on both flat home networks and segmented networks where Sonos lives in a separate VLAN.

## The problem v4.0 solved

Before v4.0 the app relied solely on SSDP M-SEARCH multicast to `239.255.255.250:1900`. SSDP works fine on flat networks where every device shares one broadcast domain, but it commonly does not cross VLAN boundaries — and IoT segmentation is increasingly common (UniFi's IoT VLAN, OPNsense, pfSense, Firewalla, AmpliFi, and most "smart home" guest networks).

Symptom: plain TCP unicast to a speaker's IP on port 1400 worked fine (so playback would have worked once the speaker was found), but discovery returned zero speakers. The result was unusable.

## The fix — Bonjour alongside SSDP

Sonos speakers also advertise the `_sonos._tcp` Bonjour service. Bonjour (mDNS) is a different protocol on a different multicast group (`224.0.0.251:5353`), and most modern routers reflect mDNS across VLAN boundaries by default — many ship with a "mDNS reflector" or "Avahi reflector" enabled out of the box specifically because AirPlay, AirDrop, HomeKit, and Sonos all depend on it.

The Bonjour TXT record carries the same `location` URL that SSDP returns in its M-SEARCH response, plus the household ID:

```
PTR _sonos._tcp.local
TXT location=http://192.168.1.x:1400/xml/device_description.xml
TXT householdid=Sonos_xxxxxxxxxxxx
```

Once the location URL is extracted, the rest of the pipeline (device-description fetch → topology → browse) is unchanged.

## Architecture

```
┌─────────────────────────────────────────┐
│            SonosManager                 │
│   handleDiscoveredDevice(location:)     │  ← single entry point
└────────────────▲─────────▲──────────────┘
                 │         │
       ┌─────────┴───┐ ┌───┴──────────────┐
       │ SSDPDiscovery │ │ MDNSDiscovery   │
       │  (UDP socket) │ │  (NWBrowser)    │
       └───────────────┘ └─────────────────┘
                 ▲         ▲
                 └────┬────┘
                      │
            ┌─────────┴─────────┐
            │ SpeakerDiscovery  │  ← protocol abstraction
            └───────────────────┘
```

### `SpeakerDiscovery` (protocol)

Hides the choice of transport behind a single interface. `SonosManager` only sees `SpeakerDiscovery`. Backed by either a single transport or a parallel-merge wrapper depending on the user's chosen mode.

### `SSDPDiscovery`

UDP multicast using BSD sockets. Sends:

```
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 3
ST: urn:schemas-upnp-org:device:ZonePlayer:1
```

Parses HTTP-like responses, extracts the `LOCATION` header, filters for "ZonePlayer" or "Sonos" so non-Sonos UPnP devices on the network are ignored. Receive loop on a background `DispatchQueue`. `rescan()` re-sends without recreating the socket.

### `MDNSDiscovery`

`NWBrowser` over `_sonos._tcp`. Resolves the TXT record on each result, extracts `location` and `householdid`, hands off to the same downstream pipeline.

## Discovery modes

User-selectable in **Settings → Discovery**:

| Mode | SSDP | Bonjour | When to use |
|------|:----:|:-------:|-------------|
| **Auto** *(default)* | ✓ | ✓ | Everyone. Both transports run; whichever finds a given speaker first wins, location-URL dedup handles the case where both find it |
| **Bonjour** | — | ✓ | Diagnostic. If Auto produces phantom speakers (rare), restricting to Bonjour can isolate the issue |
| **Legacy Multicast** | ✓ | — | Diagnostic. Original behaviour, kept as an escape hatch for networks where Bonjour misbehaves |

In Auto mode, both transports are kicked off in parallel on `SonosManager.startDiscovery()` and again on every `rescan()` (every 30 s by default). Results merge by location URL, so speakers visible to both transports are added once.

## Household-ID short-circuit

Sonos speakers expose a `GetHouseholdID` SOAP action that the app needs in order to partition speakers into S1 / S2 systems on networks where both coexist. Pre-v4.0, `GetHouseholdID` was always a SOAP round-trip to every speaker.

With Bonjour, the household ID is already in the TXT record. `MDNSDiscovery` populates `device.householdID` from the TXT before the topology pipeline runs, and `handleDiscoveredDevice` skips the SOAP fetch when the field is already set. This is a measurable win on S1 hardware, which throttles aggressively under request pressure during topology discovery.

## VLAN guidance for users

If speakers don't show up in **Auto** mode, the most common causes (in order of likelihood):

1. **macOS Local Network permission denied.** Choragus asks for it on first launch; if denied, both SSDP and Bonjour silently see zero results. Fix in System Settings → Privacy & Security → Local Network.
2. **Router doesn't reflect mDNS across the speaker VLAN.** UniFi: enable "Enable mDNS Reflector" in the relevant network. OPNsense: install and enable the Avahi service (cross-VLAN reflection). Firewalla: enable "mDNS Forwarding" per network.
3. **Router blocks SSDP multicast across VLANs and Bonjour reflection isn't enabled either.** Either fix the router, or move the Mac onto the same VLAN as the speakers.
4. **Mac is on a guest network that has client-isolation enabled.** Discovery can't see speakers if your own NIC is firewalled from the broadcast domain. Switch to a non-isolated network.

## Implementation notes

### `Info.plist`

```xml
<key>NSBonjourServices</key>
<array>
    <string>_sonos._tcp</string>
</array>
<key>NSLocalNetworkUsageDescription</key>
<string>Choragus uses your local network to find and control Sonos speakers.</string>
```

`NSLocalNetworkUsageDescription` covers both SSDP and Bonjour — the user sees one prompt on first launch regardless of which transport is being exercised first.

### Dedup by location URL

The location URL is the canonical identity of a speaker as far as Choragus is concerned (same URL → same speaker, period). Both SSDP and Bonjour produce a location URL; `handleDiscoveredDevice` writes into the `devices` dictionary keyed by UUID (extracted from the device description), so a duplicate URL becomes a no-op or an equality-guarded write.

### `rescan()` cadence

30 seconds, kicked from a single timer in `SonosManager`. Both transports run on every tick. Topology refresh is throttled per-household (10 s) so SSDP response bursts during home-theater bundle advertisements don't cascade into duplicate `GetZoneGroupState` calls.

## Credits

The VLAN issue was reported by [@mbieh](https://github.com/mbieh) ([SonosController#11](https://github.com/scottwaters/SonosController/issues/11)) with a verification dump and a parallel-merge design recommendation. The initial `MDNSDiscovery` + `SpeakerDiscovery` protocol abstraction was contributed by [@steventamm](https://github.com/steventamm) in [SonosController#12](https://github.com/scottwaters/SonosController/issues/12), which also kicked off the 13-locale translation work for the Discovery picker.
