#!/usr/bin/env bash
# Deploys Lucid to Somnia Shannon and wires it together.
#
# The router is funded before it is armed: the reactivity precompile checks the 32 SOMI floor
# against whichever contract calls `subscribe`, and it re-checks it for every subscription the
# router later creates — including the one-shot per settlement. That balance is a floor to stay
# above for as long as the protocol runs, not a one-time deposit.
set -euo pipefail
cd "$(dirname "$0")"

RPC=${RPC:-https://api.infra.testnet.somnia.network}
AGENT_PLATFORM=0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776
MODULE=0x3ecC694Cef705358864a646142ac17A90E29e388
VENUE=0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f
# Our own venue and creator, registered permissionlessly. Used only when the venue above
# stops rolling short-cadence windows; see LucidSeries.Mode.
MARKET_CREATOR=${MARKET_CREATOR:-0x7Fa6Ac2a61C0b5A0FcC7E1d9b05a0F6AD84763b2}
OWN_VENUE=0x7b41ffa006bd7ef1b8a539217694d4db48a2b07784690decbf6b0bc9d61e8581
ROUTER_FUNDING=${ROUTER_FUNDING:-33ether}
BRAIN_FUNDING=${BRAIN_FUNDING:-3ether}

set -a; . ./.env; set +a
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
echo "deployer $ME  ($(cast balance "$ME" --rpc-url "$RPC" --ether) STT)"

deploy() { # name, constructor args...
  local name=$1; shift
  local addr
  addr=$(forge create "src/$name.sol:$name" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast \
         ${1+--constructor-args "$@"} 2>&1 | awk '/Deployed to:/{print $3}')
  [ -n "$addr" ] || { echo "failed to deploy $name" >&2; exit 1; }
  printf '%-14s %s\n' "$name" "$addr"
  echo "$addr"
}

DESK_IMPL=$(deploy LucidDesk | tail -1)
BRAIN=$(deploy LucidBrain "$ME" "$AGENT_PLATFORM" | tail -1)
ROUTER=$(deploy LucidRouter "$ME" "$BRAIN" | tail -1)
FACTORY=$(deploy LucidFactory "$DESK_IMPL" "$ROUTER" "$BRAIN" | tail -1)
KEEPER=$(deploy LucidKeeper "$ME" "$ROUTER" | tail -1)
RELAY=$(deploy LucidRelay | tail -1)
SERIES=$(deploy LucidSeries "$ME" "$ROUTER" | tail -1)
# The standby that takes the venue subscription over when the router can no longer re-arm
# itself. Deployed with everything else and left cold: it costs nothing until it is funded
# to the 32 SOMI floor and armed, and the day it is needed is a day nobody wants to be
# deploying a contract. See LucidWatch for what "can no longer re-arm itself" means.
WATCH=$(deploy LucidWatch "$ME" "$ROUTER" | tail -1)

send() { cast send "$@" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null; }

echo "wiring..."
send "$BRAIN"  "setRouter(address)"  "$ROUTER"
send "$ROUTER" "setFactory(address)" "$FACTORY"
send "$ROUTER" "setKeeper(address)"  "$KEEPER"
send "$ROUTER" "setRelay(address)"   "$RELAY"
send "$ROUTER" "setSeries(address)"  "$SERIES"
# The series our own MarketCreator already has registered: 300-second BTC, series id 1.
# Failover is the default mode, so this stays idle while DreamDEX's own scheduler is healthy.
send "$SERIES" "setSeries(address,uint32,uint32)" "$MARKET_CREATOR" 1 300

echo "funding..."
send "$ROUTER" --value "$ROUTER_FUNDING"
send "$BRAIN"  --value "$BRAIN_FUNDING"

# `armVenue` is also what records `venue` and `venueModule`, which the router checks the emitter
# against before it decodes anything — so it runs on a fresh deployment whether or not the router
# is the contract that ends up owning the subscription.
#
# Exactly one contract owns it at a time. Two subscriptions on the same logs would run the handler
# twice per market, and while the second pass books nothing twice, it is a second handler bill on
# every window for no added coverage. To hand over later:
#
#     cast send $WATCH --value 33ether            # the watch needs its own bond
#     cast send $WATCH 'arm(address)' $MODULE     # and the router's own subscription lapses
#
echo "arming the venue subscription..."
send "$ROUTER" "armVenue(address,bytes32)" "$MODULE" "$VENUE"

cat > deployed.json <<JSON
{
  "chainId": 50312,
  "deskImplementation": "$DESK_IMPL",
  "brain": "$BRAIN",
  "router": "$ROUTER",
  "watch": "$WATCH",
  "factory": "$FACTORY",
  "keeper": "$KEEPER",
  "relay": "$RELAY",
  "series": "$SERIES",
  "marketCreator": "$MARKET_CREATOR",
  "ownVenueId": "$OWN_VENUE",
  "venueId": "$VENUE"
}
JSON
echo
cat deployed.json
