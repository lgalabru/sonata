# How Sonata works

Everything Sonata shows comes from the Solana RPC you point it at, plus a few public APIs.
Every dataset is cached under `~/Library/Caches/sonata/`, and refreshed on its own schedule.

## Where the data comes from

| Data | Source | Cache (`~/Library/Caches/sonata/`) |
|---|---|---|
| Epoch and slot | `getEpochInfo` every 30s, `getSlot` every 2s, interpolated at the slot time measured by `getRecentPerformanceSamples` (~215 ms) | not cached |
| Leader schedule | `getLeaderSchedule` (current epoch; next epoch prefetched after 90%) | `<rpc-host>/schedule-<epoch>.json`, last 3 kept |
| Gossip IPs, versions | `getClusterNodes` | `<rpc-host>/nodes.json`, 6h |
| Validator names | `getProgramAccounts` on the Config program (validator-info) | `<rpc-host>/names.json`, 24h |
| Locations | [ip-api.com](https://ip-api.com) batch endpoint (100 IPs/request) | `geo.json`, 30 days |

### Your validator

Pin an identity or vote account in Settings. Sonata then shows when it leads next, and once
each tenure is confirmed it sums the tenure's blocks (`getBlock`, accounts-level details):

| Figure | How |
|---|---|
| Blocks produced / skipped | `getBlock` per leader slot (`-32007`/`-32009` = skipped) |
| Block rewards | the leader's `Fee` reward: priority fees + 50% of base fees (5,000 lamports/signature) |
| Burned | the other 50% of base fees |
| MEV tips | balance increases on Jito's 8 tip accounts in each transaction |
| Split | tips − Jito's 3% fee → your MEV commission (from the tip distribution account) → stakers get the rest; block rewards stay with you unless you share priority fees through Jito |
| Missed | average produced slot × skipped slots |
| Epoch so far | `getBlockProduction`; MEV collected = the tip distribution account's lamports − rent (found with `getProgramAccounts` on vote account) |
| Stakers' MEV APY | last epoch's MEV from `kobe.mainnet.jito.network`, net of fee and commission, over activated stake, compounded over ~182.6 epochs/year |
| IBRL | `explorer.bam.dev/api/v1/ibrl_validators/<identity>` (ibrl.wtf); its data trails the chain by days, so the epoch it scores is shown |

Tenure reports are cached per window (`tenure-*.json`, last 50).

### Earnings

With a validator pinned, the menu bar shows the seconds to its next tenure and what it has earned
over a period you choose (last tenure, this epoch, 7 days, 30 days, this month). Earnings are
revenue kept by the validator: block rewards (after burn and any priority fees shared), MEV
commission and inflation commission; vote costs are shown apart.

| Data | Source | Cache |
|---|---|---|
| Completed epochs | [Trillium](https://trillium.so) `validator_rewards` (last 10 epochs, CC BY 4.0), refreshed every 6h | `earnings-<vote>.json`, every epoch ever seen, kept forever |
| Current epoch block rewards | each of your blocks, `getBlock` without transactions; ≈ extrapolated from a typical block until all are read | `blockrewards-<identity>-<epoch>.json`, per slot, last 3 epochs |
| Current epoch MEV | tip distribution account × (1 − 3%) × MEV commission | in `earnings-<vote>.json` |
| Inflation commission | Trillium, or `getInflationReward` for the epoch just ended | in `earnings-<vote>.json` |
| Epoch start times | `getBlockTime` / Trillium `epoch_data` | `epoch-times.json`, forever |

Calendar periods are prorated by time across the epochs they overlap. The public RPC allows 6
`getBlock` calls per 10 seconds, so the first pass over an epoch's blocks is slow (about 2,900
blocks in ~90 minutes); a private RPC (Settings → Network) makes it a matter of minutes.

Slot times are measured (`getRecentPerformanceSamples`, about 215 ms per slot) rather than assumed,
for countdowns, epoch time left and APYs.

RPC calls go through Sonata's own small JSON-RPC client (`Sources/SonataCore/JSONRPC.swift`):
no dependencies, only the read methods listed above.
The RPC URL can be changed in settings (the gear icon). Each RPC host gets its own cache
directory, so mainnet and devnet data never mix.

Because ip-api.com's free tier is HTTP only, `Info.plist` has an ATS exception for that one
domain. Locations come from a validator's gossip IP, so they show the datacenter, not the
operator.

## Code layout

- `Sources/SonataCore`: RPC, schedule storage and lookup, disk cache, geolocation, slot clock,
  map projection, and the `SonataModel` that ties them together
- `Sources/Sonata`: the status item and borderless glass panel (AppKit), and the SwiftUI cards
  and map painter
- `scripts/bundle.sh`: wraps the release binary into an ad-hoc-signed `.app`
