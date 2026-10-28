# HourLoom

A time bank on BOT Chain. The unit of account is an hour of somebody's work,
not a token.

Members join by posting a refundable bond. When you help someone you log the
time; **they** confirm it, and the credit moves from their account to yours.
Nothing can be fabricated, because the only person who can move credit out of
an account is its owner.

## The invariant

Every confirmation moves the same number of minutes out of one account and into
another, so **the sum of all balances is always zero**. The contract mints
nothing and holds no float beyond the bonds.

## The debt floor

Balances are signed. A member may go up to `debtFloorMinutes` into the red
(24 hours by default), which is what lets a newcomer receive help before they
have given any. The floor is the whole risk model: the debt is social, so the
floor is what stops it becoming an unbounded IOU, and the bond is what makes
walking away from it cost something.

Leaving requires a square balance. Owing time and walking off with the bond is
exactly what the bond is there to discourage.

| Call | Who | What it does |
|---|---|---|
| `join(handle)` | anyone | Pays `joinBond` (refundable) + `joinFee` (protocol) |
| `logHours(to, minutes, memo)` | members | 15 minutes to 24 hours, never against yourself |
| `confirmEntry(id)` | the recipient | The only call that moves credit. **Works while paused** |
| `declineEntry(id)` / `cancelEntry(id)` | recipient / giver | Kills a pending entry |
| `postRequest(minutes, memo)` / `closeRequest(id)` | members | A simple ask-for-help board |
| `leave()` | members | Square balance only; returns the bond. **Works while paused** |

A returning member keeps the balance and history they left with.
`withdrawFees` is bounded by `accumulatedFees` and can never reach a bond.

## Build and deploy

```bash
npm install
npx hardhat test          # 15 tests
npm run deploy:testnet    # BOT Chain testnet, chain 968
npm run deploy:mainnet    # BOT Chain mainnet, chain 677
```

Create `.env` from `.env.example` with your `PRIVATE_KEY` first. The deploy
script prints the network name **and** the chain id.

After deploying, paste the address into `CONTRACT_ADDRESS` in
`frontend/index.html`. For mainnet also swap the five network values flagged in
the comment block directly above it, and set `label` to `"MAINNET"`.

## Frontend

Single file, no build step, ethers v6 from cdnjs. **Claymorphism**: pillowy
inflatable surfaces with double inner shadows, large radii and pastel tones.
Built as a single phone-width app column with a fixed bottom tab bar —
Inbox, Loom, Asks, Give, Me — rather than a desktop dashboard. Your balance is a
two-way gauge running either side of zero, with the debt floor as the edge.

The page ends with the BOT Chain ecosystem footer, carrying links to
**botchain.ai** and the **block explorer**. The explorer href is read from the
`NETWORK` config at the top of the file, so the five-value mainnet swap updates
it too. No chain ID is printed anywhere on the page — these sites move from
testnet to mainnet, so a rendered chain ID would be wrong half the time.
