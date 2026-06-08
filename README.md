# WG Relay Manager

WG Relay Manager allows a WireGuard Easy server to operate as a relay node and forward all client traffic through a remote WireGuard exit node.

## Features

* Upload WireGuard exit configuration
* Start and stop exit tunnels
* Enable and disable routing
* View tunnel status
* Web management interface
* Automatic recovery after reboot
* Complete uninstall support

## Installation

```bash
bash <(curl -Ls https://raw.githubusercontent.com/YOUR_REPO/main/install.sh)
```

## Access

Open:

http://SERVER_IP:8090

## Tunnel Management

Upload a valid:

wg-exit.conf

from your exit node.

Use:

* Start Tunnel
* Stop Tunnel
* Restart Tunnel

from the Web UI.

## Route Control

Enable Route:

All WireGuard Easy clients will use the exit node.

Disable Route:

Clients will use the relay node's local internet connection.

## Status

The dashboard shows:

* Tunnel state
* Endpoint
* Handshake time
* RX/TX traffic
* Route state

## Uninstall

```bash
wg-relay uninstall
```

or from the Web UI.

## Notes

WireGuard Easy remains responsible for user management.

WG Relay Manager only controls forwarding and routing.
