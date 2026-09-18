# Changelog

All notable changes to Lanarchy (`donnie.homelab-mesh`) are documented here.
The version in `manifest.json` is the single source of truth.

## 0.21.0 - 2026-09-18

- **Notifications off means it is not an alarm.** Silencing a host still counted
  it as down, so it kept the bar icon red and the header on "1 DOWN" for a
  machine you had deliberately muted, which is the one state muting exists to
  remove. A muted host that is not up counts as `muted` instead: still in the
  total, still red on its own card, and shown as "n muted" in the header, but no
  longer an alarm. One change covers the icon colour, the bar readout, the
  tooltip and the alarm state, because all four read the same count
- **Remove is on the card's own action row.** Getting a box off the map meant
  Setup, find it in the list, open it, Delete, Confirm delete; and for a
  discovered box there was no path at all. Selecting a card now offers Remove
  next to Rename and Hide. It asks once before acting, and moving to another
  card cancels a half-pressed Remove. A curated node stops existing; a
  discovered one goes on the ignored list so discovery stops re-adding it
- **Fixed: "Move to LAN" did nothing on a discovered card.** It only rewrote
  inventory nodes, so for a discovered box it matched nothing, wrote the same
  list back, and then jumped to the List tab, which made it look as though
  something had happened. Hiding a discovered card now tells discovery to stop
  offering it
- **"Move to LAN" is now "Hide".** It named the LAN bucket card, which was
  removed in 0.17.0, so the label pointed at a place the user could no longer see

## 0.20.0 - 2026-09-18

- **Discovered machines report their traffic.** A discovered host was pinged and
  nothing more, so it could never produce a byte rate: its uplink was drawn as a
  permanently idle line. Because curated nodes sort first, that guaranteed the
  map's overflow row looked dead no matter what. Discovery only calls a
  candidate a "machine" when it has an open login port, so it now gets the same
  counter read a curated node gets. A host without a usable key returns nothing,
  keeps its ping-only row, and stays dashed
- **A refusal is remembered for ten minutes.** An open login port is not a key
  you hold, and a host that refuses BatchMode burns the full SSH connect timeout
  every cycle: measured here, one such box took a probe pass from 8.6s to 11.6s
  against a 15s interval. Refusals back off, so steady-state cost is only the
  hosts that answer, and a box that later gains a key is picked up on the next
  retry rather than needing a restart
- **Click a card to follow its own path.** The row lane is a shared bus, so five
  hosts' wires overlay into one line and there was no way to tell whose traffic
  was whose. Selecting a card now dims every other route and animates only that
  host's packets. Nothing is added to the default view, and the exit to the
  internet never recedes because it is on every host's path
- Telemetry brings real OS identification with it, so several boxes that showed
  a TTL guess of `UNIX?` now read `LINUX · WIRED` from their own `uname`

## 0.19.0 - 2026-09-17

- **No wire crosses a card any more.** Every machine uplink ran down to a single
  lane beneath the whole grid, so once the grid wrapped to a second row, every
  card in the first row had to get past the second row to reach it. The only way
  through was the 8px gap between two columns, which put the wire on the card
  borders: traffic appearing to run through the cards. Each row now has its own
  lane in the gutter directly below it, and those lanes empty into one vertical
  trunk in a corridor reserved to the right of the grid. Four segments, each in
  space nothing is drawn in: down into its own row's lane, right along that
  lane, down the trunk, then into the gateway's left face at its midline
- **Rows have a real gutter.** The 10px gap between machine rows could not hold
  a lane with clearance on either side, so routing that was technically outside
  the cards still read as running through them
- **A link with no telemetry is dashed.** It used to look exactly like a
  measured link that happens to be idle, because both are a static line, which
  reads as "the map is broken" rather than "nothing is measuring this box". Only
  hosts whose byte counters can be read report rates, so most discovered devices
  are legitimately unmeasured. The legend says which is which
- **Removed the last motion that was not data.** A set of helpers made an
  unmeasured link's dashes crawl at a tenth pace: movement with nothing measured
  behind it. Nothing called them any more, but the comment still promised the
  behaviour. The only thing that moves on the map is a packet standing for bytes
  something actually counted

## 0.18.1 - 2026-09-17

- **One flapping device no longer fills "what just changed".** A sleeping phone
  transitions every few minutes, so the newest-first strip was six rows of the
  same phone and every other change on the network was pushed out of view. Each
  node gets one row now, its latest change, with a `×n` count so "flipped
  forty times" is still visible in the row it earned
- **Deleted devices stop reporting.** The history ring keeps 24 hours, so it
  outlives a node: a device removed from the inventory still appeared in the
  strip under its raw id, as a bare UUID, with nothing left to give it a name.
  Status changes and flap counts now cover only what the panel is actually showing
- **Every unstable host is named**, not just the worst one. It said
  "unstable: <one host>" while others flapped just as hard, unmentioned
- **"MACHINE" is gone from the card header.** A card of machines gains nothing
  from being told each one is a machine. An unknown OS says nothing and the row
  falls back to how the box is connected
- **Fixed: the map relayed out twice on every resize.** `mapArea` recalculated
  the layout when its height changed, but that height is an *output* of the
  layout, so the layout was fed its own result, costing a second full pass and a
  repaint each time the topology grew a row

## 0.18.0 - 2026-09-17

- **The map uses its whole width.** The layout reserved a 23% band for the
  router zone and a 34% rail for externals, so more than half the map was held
  for a zone divider that no longer exists and an internet card that is now an
  arrow. Only what the gateway card and the exit label actually occupy is
  reserved; everything else goes to the machines
- **The gateway is centred on the grid it serves.** It was positioned to meet
  the collection lane, which pushed it off-centre against every other card: the
  card was being bent to fit the wiring. The wiring bends now, not the card, and
  an uplink arriving beside the gateway runs along the lane and turns into its
  midline
- **Traffic no longer hides under the cards.** The collection lane sat 12px
  below the card undersides, so the drops feeding it read as little hooks tucked
  out of sight. The lane has real clearance and each drop leaves its card on a
  stub long enough to read as a line
- **Fixed: the collection lane was clipped off the bottom.** Map height was
  measured from the lowest card, but the lane runs below it, so the lane and its
  feeders were cut at the panel edge

## 0.17.1 - 2026-09-17

- **Actually absorbs a curated router this time.** The 0.17.0 change did not
  reach the file: the edit matched nothing and was reported as done anyway. An
  inventory node whose MAC or address is the gateway's is now genuinely folded
  into the gateway card, keeping the name you gave it
- **A flapping device no longer notifies.** A phone that sleeps transitions a
  dozen times an hour, and alerting on each one is how a useful alarm becomes
  something you turn off. Anything the panel already reports as unstable (4+
  transitions in the last hour) is excluded from down notifications

## 0.17.0 - 2026-09-17

- **The LAN bucket is gone.** It aggregated leftover `host` rows and LAN metrics
  into a card on the topology that was neither a device nor a link. The Devices
  drawer already aggregates, as a list you can act on, and the metrics it carried
  (dns time, neighbour count) are real, so they moved to the footer with the
  other measurements
- **Fixed: the router still had its own card** when it was in the inventory. The
  previous fix only excluded *discovered* candidates, so a curated router drew a
  machine card beside the gateway card representing the same hardware. An
  inventory node matching the gateway is now absorbed into it, keeping the name
  the user gave it
- **The map uses the space it has.** Cards widen to fill their row instead of
  staying at a fixed width and leaving a third of the map blank, and the map asks
  for exactly the height its content needs. The old floor was reserving room for
  the bucket that no longer exists, which is where the dead area came from

## 0.16.1 - 2026-09-17

- **The internet is an arrow, not a card.** It is not a box on your network and
  it was spending a card's worth of the map to say so. It is now an arrow out of
  the gateway with `INTERNET` and the latency and public IP set in the margin the
  gateway card already leaves, costing no layout at all
- **Fixed: the router appeared twice**, once as the default gateway and again as a
  machine card. A router commonly answers on more than one address (a LAN address
  plus a management or VLAN one), and discovery read the second as an unrelated
  client. Anything sharing the gateway's MAC or address is never offered as a
  client, and the same applies to whatever the controller reports as the gateway

## 0.16.0 - 2026-09-17

- **A device you add by hand gets its own card.** Adding `Spike-iPhone` classed it
  as a `host`, and hosts are collapsed into the LAN bucket, so it vanished into a
  cluster instead of appearing on the map. That is also why a LAN BUCKET card
  suddenly existed. `host` is for reverse-proxy names, not for something you just
  asked to see
- **Fixed: an overrides write could delete nodes.** Ignoring, renaming or changing
  a setting resent the panel's in-memory node list, so any node added since that
  copy was taken was silently dropped. Overrides now send no nodes at all and the
  collector keeps what is on disk
- **Adding something takes you to it.** The row leaves the "to add" list
  immediately and the panel returns to the map, instead of leaving you sitting in
  Setup wondering whether it worked
- **The panel always opens on the map**, rather than whichever tab was last used
- Escape cancels an edit in progress before it navigates anywhere, deleting a node
  leaves its form, and leaving Setup returns to the map

## 0.15.2 - 2026-09-17

- **Fixed: the right-click bar chooser showed its heading and no options.** The
  0.13.0 health rewrite replaced a block of the file that also held
  `barDisplayModes`, `barText` and `setBarDisplay`, so the chooser's model was
  undefined and its Repeater produced nothing. Restored
- The readout mode formerly called **WAN rates** is now **Host traffic**, because
  that is what it sums: the interface counters of hosts with telemetry. An
  existing `barDisplay: wan` setting is migrated

## 0.15.1 - 2026-09-17

- **The way out is just a chain now.** Gone: the full-height vertical line down
  the middle of the map, the ROUTER caption, the INTERNAL and EXTERNAL captions,
  and the container drawn around the gateway and Internet cards. The picture is
  already ordered left to right, so a line separating two halves of it was
  furniture
- The gateway and Internet are ordinary cards, the same height and shape as every
  machine, because that is what they are: two more nodes in the chain

## 0.15.0 - 2026-09-17

- **Ignore looked broken because nothing happened when you clicked it.** The
  write was correct, but the on-screen lists are only replaced when the next
  snapshot arrives, so the row sat there for up to a full probe interval. Ignore
  and adopt now drop the row immediately
- The **Ignored (N)** drawer counts what the panel holds rather than what the
  last snapshot said, so it updates the moment you act
- **Restore all** existed as a function with nothing able to call it. It has a
  button now, shown when more than one device is ignored
- **Rename from the Devices drawer**, in place, without finding the card first
- Device management is scriptable: `ignore <mac>`, `restore <mac>`,
  `rename <mac> <name>`, `overrides`. These call the same functions the buttons
  do, so testing them tests the real path

## 0.14.0 - 2026-09-17

- **The way out of the LAN is drawn properly.** The gateway used to float inside
  a large empty vertical band, joined to the Internet by a thin line - the least
  convincing rendering of what is conceptually the most important link on the
  map. The router band is now a slim boundary, the **default gateway** and
  **Internet** cards sit aligned either side of it at the collection lane, and a
  bold directional link with sockets connects them
- The Internet card states what is actually known: reachability, RTT, the real
  public IP, and **"WAN traffic unmeasured"** in as many words. The link is
  topology only and deliberately carries no animation, because nothing here can
  read the gateway's WAN interface
- **Uplinks no longer cross the cards below them.** A card in the first row
  dropped straight down to the collection lane, which after the band began
  wrapping meant straight through the card in the second row. Drops now step into
  the gap between columns first

## 0.13.1 - 2026-09-17

- A machine on **its own network with mains power keeps discovering** even with
  the panel closed. 0.13.0 made discovery conditional on someone looking, which
  meant a desktop that is never opened showed only what had been curated by hand
  — the behaviour this plugin exists to replace. On battery, or on any network
  not known to be home, it still waits
- The gate's reason string never says `mains` on a network it does not
  recognise. It is shown to the user and written to the log, so it has to be true

## 0.13.0 - 2026-09-17

Honesty and cost pass. Everything known to be wrong, fixed.

- **One health model.** Every surface counted separately, over overlapping
  arrays, so a failure in the LAN bucket was counted twice and "ALL CLEAR"
  appeared whenever nothing was explicitly *down* - degraded and unknown nodes
  were silently clear, and the bar excluded the gateway and Internet entirely, so
  a red Internet card could sit beside a green tick. There is now one
  deduplicated model with explicit up / degraded / down / unknown, read by the
  bar, the status pill and the IPC alike
- Staleness depends on a **ticking clock**. It was computed from `Date.now()`
  inside a binding, and elapsed time alone cannot invalidate a binding, so a
  stopped collector could keep reading as fresh
- **The Internet card no longer reports throughput it cannot measure.** That
  figure was the sum of the LAN interface counters presented as internet traffic:
  it counts traffic that never leaves the LAN and misses every host without
  telemetry. It is now reported as **monitored hosts**, and the gateway-to-internet
  edge carries no flow, because nothing here can read the gateway's WAN interface
- **The router column is a divider, not a wire.** It carried a lit, animated
  full-height spine through empty space, which read as traffic on a link that does
  not exist
- **The discovery gate fails closed.** An unset `homeGatewayMac`, or an unreadable
  gateway, used to disable the rule entirely and let the subnet sweep run on any
  network. Discovery is now refused unless we are on a network known to be home.
  Home is adopted on first run, because a gate that needs you to look up a MAC
  first is a gate nobody switches on
- Container and hypervisor bridges are not the lab. `docker0`, `virbr*`, `veth*`
  and friends are excluded, so container and libvirt addresses stop appearing as
  machines
- **Sparklines spawn nothing.** Each one launched a Python process every four
  seconds and re-parsed the whole history file: roughly ten processes a second on
  a forty-row lab. The collector now builds every series in one pass and the
  component just draws
- Inventory writes are **queued**. One Process was reused with no queue, and
  changing a running Process's command applies to its next run, so a second click
  during a write updated the screen and never reached disk
- `_airplay` / `_raop` mean **Apple device**, not macOS. iPhones, HomePods and
  Apple TVs publish them, so calling that macOS badged a phone as a Mac with
  confidence - worse than the vaguer TTL guess it replaced
- Internet reachability falls back to a **TCP handshake on 443** when ICMP is
  filtered, instead of reporting an outage
- The collector **exits when its own source changes**, so a plugin update stops
  leaving a daemon running the previous version behind a flock
- `docs/architecture.md` no longer claims that being away means no probing

## 0.12.0 - 2026-09-17

- **New device alarm.** Lanarchy remembers every MAC it has ever seen. Hardware
  that turns up later is announced once, appears in a **NEW ON YOUR NETWORK**
  tray with its name, address, kind and how long ago it arrived, and offers
  **adopt** or **ignore**. Turns the plugin into a quiet tripwire
  - The **first run is a baseline, not an alarm**. Everything is new the first
    time you look at a network, and announcing all of it is how a tripwire
    becomes noise that gets muted on day one
  - A device must be seen twice before it counts, so a one-off ARP entry is not
    an arrival, and each arrival is announced exactly once
  - Anything already in the inventory or dismissed is not news
  - Turn it off with `settings.newDeviceNotify: false`
- **UniFi devices are on the map.** With an API key, access points and switches
  are named and given their role from the controller, so an access point stops
  being an anonymous address
- The Internet node carries the **real public IP**, taken from the gateway's WAN
  address, instead of only a latency figure
- A device the controller reports as `OFFLINE` while it is demonstrably
  reachable is now treated as **unknown**, not down, and the collector's own
  probe decides. Drawing a working access point as dead is worse than saying so

## 0.11.0 - 2026-09-17

- **The running version is on screen.** `LANARCHY v0.11.0` in the panel header,
  on the bar tooltip, and as `omarchy-shell lanarchy version`. It is read from
  `manifest.json` at runtime, so the number shown is necessarily the one that
  shipped
- **Rename from the card.** Double-click a name on the map to edit it in place:
  Enter commits, Escape cancels. It writes through the same MAC-anchored path as
  every other rename, so it lands on every surface at once
- Release rule written down in `AGENTS.md`: a user-visible change bumps
  `manifest.json` in the same commit, adds the CHANGELOG entry under that exact
  version, and updates the README badge

## 0.10.0 - 2026-09-17

- **A name you set is anchored to the MAC, and follows the box everywhere.** An
  address is a lease: naming by address means the name follows whatever answers
  there next. Names key on the hardware, and fall back to an address only when no
  MAC can be learned at all
- **One place applies it.** Every row the plugin shows passes through the same
  stamp, so a rename reaches the map, the list, Setup, the detail pane and the
  notifications together. The discovered name is kept as `discoveredLabel`
- Editing a node's **Label** in the form now also records the MAC-anchored name,
  so the two ways of naming a box agree
- Inventory nodes learn their MAC automatically, from the node, then history,
  then the ARP table, so a name has something durable to attach to

## 0.9.3 - 2026-09-17

- **Rename could not be typed into.** The key catcher was switched off with
  `enabled`, which Qt propagates to every descendant, so pressing Rename disabled
  the very text field and buttons it opened. It now uses the catcher's `blocked`
  property, which forwards keys to descendants instead, and rename state is
  cleared when the panel closes
- `inventory_cli dump` returns `names` as well as `ignored`. Without it the panel
  reset its in-memory names to empty on every reload, so a later rename or
  removal wrote that empty list back over saved names

## 0.9.2 - 2026-09-17

- **Edges no longer cut through the cards.** A machine's uplink now leaves the
  bottom of its card, drops into a clear lane under the whole machine grid, and
  only then runs sideways to the gateway. The generic orthogonal router picks a
  mid-gap corridor, which was correct while machines were one row and landed on
  top of the row below once the band started wrapping
- **Fixed: dismissals and renames were destroyed by the next ordinary save.**
  `inventory_cli write` preserved `settings` and `edges` when a payload omitted
  them but not `ignored` and `names`, and the panel never sent them, so removing
  a device or renaming a box was silently undone as soon as anything else was
  saved

## 0.9.1 - 2026-09-17

- CPython's `__pycache__` no longer lands in the plugin tree either. Importing any
  module wrote bytecode next to the code, which the shell's plugin watcher reads
  as a change and answers with a reload. Every python the panel spawns now sets
  `PYTHONPYCACHEPREFIX` into the state directory

## 0.9.0 - 2026-09-17

- **Runtime state no longer lives in the plugin directory.** The shell watches a
  local plugin tree and hot-reloads the plugin whenever anything under it
  changes, so writing `snapshot.json` every probe (and a panel heartbeat every 8
  seconds) reloaded the plugin about once a second: measured at **296 reloads in
  five minutes**, which makes the panel flicker and restart while you are using
  it. Everything writable now lives in `$XDG_STATE_HOME/lanarchy`
  (`~/.local/state/lanarchy`), and existing files are migrated there once,
  without overwriting
- `smoke.sh` now asserts that no writable path resolves inside the plugin tree,
  so this cannot regress
- **Breaking:** `unifi-secrets.json` moves to `~/.local/state/lanarchy/`

## 0.8.2 - 2026-09-17

- **Plugin IPC works again.** The handler claimed the plugin id as its target, but
  the host's own `Ui/Panel` base already registers one there, and a second
  registration for the same target is discarded. Every function was silently
  gone. The target is now `lanarchy`: `omarchy-shell lanarchy status`
- Fixed a `TypeError` that fired on every repaint when no node had flapped. A QML
  binding is evaluated whether or not its item is visible, so guarding with
  `visible:` was not enough

## 0.8.1 - 2026-09-17

- **The map wraps instead of cramming, and the panel grows to fit it.** Cards were
  spread evenly across one row and then refused to shrink below a readable width,
  so past about six machines every card overlapped its neighbour. Capacity now
  comes from the available width and the band wraps; everything below it flows
  from where that band actually ended
- The popup no longer caps itself at 760 scaled pixels. The host already clamps to
  the space the screen has, so the cap only made the panel clip its own content on
  a display with room to spare. It scrolls in one case only: content taller than
  the screen itself
- The notify chip appears only when a node is **muted**. "ALERT" on every card
  stated the default while consuming half the width of a narrow card, which forced
  the platform line to elide to "LINUX..."

## 0.8.0 - 2026-09-17

- **The network fills the map; the inventory only records your overrides.** A
  discovered box you never curated now gets a card. Previously you had to add
  every machine by hand before it existed to the plugin, so a lab of 30 devices
  showed 4
- Speakers, TVs and phones are listed in a bounded **Devices** drawer rather than
  drawn as topology. **Remove** dismisses one, keyed by MAC so it stays dismissed
  when its address changes, and **Ignored (N)** restores it
- **Rename any box, including a discovered one.** The name is stored against the
  hardware, so it survives a DHCP move. A curated node still edits in place
- **The map draws the real topology.** With no reverse proxy configured, the hub
  fell back to "the first machine in the list", so the map asserted that every
  box routed through whichever machine happened to be first, including a
  machine wired to itself. It now uses the actual default gateway
- **An Internet node beyond the gateway**, with reachability and the measured
  aggregate crossing it. That edge is the one whose traffic can honestly be
  attributed: everything leaving these hosts crosses it
- Cards state **wired** or **wifi** beside the platform, and say nothing when the
  link is genuinely unknown
- Adding a device already in the inventory is refused by identity (MAC, address,
  dns name) rather than by slug collision. That is what allowed one box to be
  added twice as `nano` and `nano-245`
- Duplicate node ids are collapsed on load. Two nodes with one id silently shadow
  each other in every lookup, probe result and history series

## 0.7.0 - 2026-09-17

- **Cards lead with a name, not an identifier.** `RINCON_5CAAFD26F5E201400@Living Room`
  becomes **Living Room**, because the owner's own name for it was inside that
  string all along. Model serials (`Android_R5UE8DLF`), UUIDs and bare addresses
  stop being headlines; the identifier is kept and moves to the card detail
- Devices get a kind from what they advertise (Sonos, Android TV, Printer,
  Linux desktop, VM, Ubiquiti), so a thing with no name at least says what it is.
  A class-only name carries the host octet, since two boxes both called
  "Ubiquiti" cannot be told apart
- Privacy (locally-administered) MACs are flagged. That is why a phone keeps
  reappearing as a brand new device
- **Fixed: every sparkline in the List view was dead.** `nodeId: nodeId` bound
  the Sparkline's own property to itself, because QML resolves an unqualified
  name against the innermost object first, so the row id never reached it
- **Fixed: a machine could vanish from the dashboard entirely.** Any group of 2+
  members became a service, and `leftover_rows` only ever emits hosts and
  proxies, so a `machine` absorbed into a group appeared in neither band. A
  colliding key was enough, for instance a machine `caddy` beside the proxy
  `caddy-health`, whose `-health` suffix strips to the same key. Machines are now
  never absorbed
- **Fixed: a node with an unresolvable dns name reported `unknown` forever** even
  when a working address was stored beside it. Discovery guesses names
  (`<label>.lan`), and the guess was preferred with no fallback
- **Discovery no longer runs off your home network.** Probing touches your own
  inventory; discovery sweeps the subnet with TCP connects to 22/3389 and SSH
  attempts. That is fine at home and is port-scanning on hotel wifi, so it is
  refused away from `homeGatewayMac` even with the panel open, and skipped
  whenever the panel is closed. Closed-panel probe cycles dropped 8.4s to 1.0s
- `ss -tunH` gained `-n`. Without it `ss` reverse-resolves every peer, which on a
  busy box outruns the SSH timeout and costs the entire telemetry report
- mDNS service evidence now reaches OS detection, which it never did before, so
  an Apple box is identified as macOS rather than guessed `UNIX?` from its TTL
- Starter no longer ships the `caddy-health` node

## 0.6.0 - 2026-09-17

- **Real machines stop hiding in the LAN bucket.** A candidate was only ever
  classed `machine` if it advertised `_ssh`, `_sftp-ssh` or `_workstation` over
  mDNS. Arch and Omarchy do not publish `_ssh` by default, so a Linux laptop
  running sshd was demoted to `host` and buried in the LAN cluster. Discovery now
  asks the address directly: anything answering on 22 or 3389 is a machine,
  which is the plugin's own definition of one. Speakers and TVs answer neither,
  so they stay hosts
- **Scan gets real host names.** Three sources now, in order: the mDNS host
  field, reverse DNS, and `hostname -s` over SSH for any box whose key we already
  hold. On a test LAN that took named machines from 3 of 11 to 8 of 11. Discovery
  uses a throwaway known-hosts file so scanning a subnet never writes to
  `~/.ssh/known_hosts`
- Port verdicts and SSH names are cached per address for 15 minutes, so the
  enrichment costs nothing on repeat scans
- **The map detail pane holds information instead of an instruction.** With
  nothing selected it was a large box reading "Click a machine, the Caddy hub, a
  service, or the LAN cluster" - and still named a node removed in 0.5.0. It now
  shows the last six status transitions with relative times, and calls out any
  node that flapped 4 or more times in the past hour
- `snapshot.json` carries `events[]` and `flaps{}`. The events ring already
  recorded every flap; nothing had ever surfaced it, so a box bouncing every few
  minutes looked exactly like a healthy one

## 0.5.0 - 2026-09-17

- **Cards say what the box runs.** `MACHINE` on every card carried no information;
  the slot now reads `LINUX`, `MACOS`, `WINDOWS`, `APPLIANCE` or `ROUTER`, with a
  trailing `?` when it is inferred rather than known
- OS identification adds no probes. `uname -s` rides the SSH telemetry hop we
  already make, the ICMP TTL was already in the ping reply we already parse
  (64 unix / 128 windows / 255 appliance), and Apple mDNS services are a strong
  tell. Detail line shows the release and which source answered
- `MACHINE` is still shown when nothing supports a claim, and a TTL of 64 yields
  `UNIX?` rather than guessing between Linux and macOS
- Notifications name something you can act on: a label that is a UUID, a MAC, a
  bare address or a Sonos `RINCON_` id falls back to the node's dns name, and the
  body carries the address
- Starter inventory no longer ships a Caddy health check against
  `127.0.0.1:2019`. Caddy is usually not installed, so a fresh install showed a
  permanent `1 DOWN` and, because that node is the map hub, painted every edge
  red. A fresh install is now one node and green

## 0.4.1 - 2026-09-17

- **The map's traffic is measured, not decorative.** Packet count, speed and
  direction all come from `rates` (rx_bps / tx_bps) read off the interface
  counters. rx walks the route forwards, tx walks it back, and an edge with no
  telemetry does not move at all: a still line means "not measured", not "idle"
- Fixed the reason none of it could ever be real: the shipped starter set
  `telemetry: false` on the local box, the one node whose counters need no SSH and
  no credentials. With it enabled, `this-box` reports real throughput after two
  probes, so a fresh install has live rates out of the box
- Measured bytes still show when an endpoint's health check is down. A failing
  Caddy health URL does not mean the wire is idle; it only dims the lane
- Map cards carry a status halo: green sits still, amber breathes, red pulses, so
  health is legible without reading the dot
- The map canvas is now static geometry and repaints only when the layout,
  statuses or rates change, instead of every 50 ms

## 0.4.0 - 2026-09-17

- Bar icon carries a live readout beside the castle: down count, up/total, worst
  latency, or WAN rates. Right-click the icon to choose, or `barDisplay <mode>`
- New `IpcHandler` (`donnie.homelab-mesh`): `open`, `close`, `toggle`, `refresh`,
  `map`, `list`, `setup`, `modes`, `barDisplay`, `status`
- Setup: **+ Add all machines** / **+ Add everything** bootstrap a found lab in one
  write instead of one click per host
- Discover resolves names automatically: reverse DNS (PTR) turns bare ARP addresses
  into host names, and synthetic answers (`_gateway`, `localhost`) are rejected
- Discover: an mDNS pairing id (`83DEE99F-...`) falls back to the resolved host name
  instead of becoming a node label
- Discover: a multi-homed box (wifi + ethernet) is one candidate, not two
- Collector is gated: full pace with the panel open, `batteryIntervalSec` on battery
  with it closed, and paused entirely off a configured `homeGatewayMac`
- `inventory.json` is untracked user state, seeded from `inventory.default.json`,
  so `omarchy plugin update` cannot conflict with an edited lab
- Node edit form no longer scrolls: two columns, every control on screen

## 0.3.13 — 2026-09-17

- Map edges: bottom→top Visio ports, elbows in gutters (no lines through card centres)
- Flow march on every edge with stagger; busy links full pace, quiet/no-rate at 1/10

## 0.3.12 — 2026-09-17

- Resolve plugin dir from install location (marketplace `donnie.homelab-mesh`), not a hardcoded `homelab-mesh` path
- Ship a localhost starter `inventory.json` (lab mesh moved out of the default)
- Refresh marketplace preview and README screenshots

## 0.3.11 — 2026-09-17

- Visio-style orthogonal edges attach to card borders (not through centers)
- **FLOW** / **STATIC** toggle (`a`) for animated traffic; animation actually moves again

## 0.3.10 — 2026-09-17

- Calm traffic: one shared slow pulse, modest width from real link rates only (no aggregate bleed / yellow overlays)

## 0.3.9 — 2026-09-17

- Drop LAN / PROXIES / ALL (ISSUES) toggles — leftovers and demoted cards always show in List; map shows everything except Move-to-LAN demotions

## 0.3.8 — 2026-09-17

- Map traffic as a slow Minard-style march: width from volume, soft under-glow, long pulse (not frantic dashes)

## 0.3.7 — 2026-09-17

- **Move to LAN** demotes a map card into the LAN bucket (cluster + List → LAN); **Show** brings it back
- Removed the separate HIDDEN drawer — LAN is the only hide/show bucket

## 0.3.6 — 2026-09-17

- Map edges hub on the **reverse proxy** (Caddy), not the UniFi router; WAN lines still cross the router bar
- Card colour = status only (fill + rim match) — drop orange “hot RTT” wash that fought green borders
- Hub card labelled `reverse proxy`; no extra dns role needed for overlays

## 0.3.5 — 2026-09-17

- ISSUES off always persists: inventory writes send `settings` even when empty (no stale `mapQuietUp` merge)
- Map hub placement: redUltra on the router bar without also drawing Caddy as a left gateway

## 0.3.4 — 2026-09-17

- **HIDDEN** drawer: restore cards one-by-one or Show all (replaces unhide-all chip)
- Stronger map card fill vs border (status wash vs hard rim)
- Zone labels coloured (INTERNAL green / EXTERNAL accent)
- Degraded (yellow) only when a member is actually **down** — up+unknown stays green

## 0.3.3 — 2026-09-17

- Map proportions: ~2⁄3 INTERNAL · router bar · ~1⁄3 EXTERNAL
- Per-service **Hide on map** (`mapHidden`, still probed)
- **ISSUES** quiet mode: auto-hide healthy LAN services on the map while tracking continues (`q`)

## 0.3.2 — 2026-09-17

- Map: three columns — INTERNAL | ROUTER bar | EXTERNAL
- Router bar (redUltra) shows live aggregate LAN ↓/↑ traffic; edges bend through it
- External/cloud boxes with `httpReachable` for 401/404 edges
- Packaging: plugin root is the git repo root (marketplace `omarchy plugin add` layout)

## 0.3.1 — 2026-09-17

- Stop grey↔LIVE flicker: keep applying snapshot while the panel is closed (bar chip)
- Don't flash PROBING on refresh when glance data already exists
- Wider STALE window; boot daemon without opening the panel; ignore flock exit-0 restarts

## 0.3.0 — 2026-09-16

- Theme-aware map/list status colours from Omarchy `colors.toml`
- Stronger borders on map cards, pills, and setup rows
- Scrollable Setup / form
- **Search network** (Find hosts): UniFi wired machines + mDNS + ARP
- UniFi OS `macAddress` / `ipAddress` projection; machine vs IoT noise filter
- Reverse-proxy hosts no longer steal the Caddy box MAC in history
- README rewritten to match Omarchy plugin develop guide + Pulse-style docs
- Panel-only screenshots under `docs/screenshots/`

## 0.2.0 — 2026-09-16

- P0–P3 stack: inventory write safety, discover, sparklines, speedtest, talkers, bar health ramp, unknown-neighbor notify
- UniFi collector + castle-socket bar mark

## 0.1.0

- Initial Homelab Mesh / Lanarchy glance panel
