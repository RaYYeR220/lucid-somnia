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

send() { cast send "$@" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null; }

echo "wiring..."
send "$BRAIN"  "setRouter(address)"  "$ROUTER"
send "$ROUTER" "setFactory(address)" "$FACTORY"
send "$ROUTER" "setKeeper(address)"  "$KEEPER"
send "$ROUTER" "setRelay(address)"   "$RELAY"

echo "funding..."
send "$ROUTER" --value "$ROUTER_FUNDING"
send "$BRAIN"  --value "$BRAIN_FUNDING"

echo "arming the venue subscription..."
send "$ROUTER" "armVenue(address,bytes32)" "$MODULE" "$VENUE"

cat > deployed.json <<JSON
{
  "chainId": 50312,
  "deskImplementation": "$DESK_IMPL",
  "brain": "$BRAIN",
  "router": "$ROUTER",
  "factory": "$FACTORY",
  "keeper": "$KEEPER",
  "relay": "$RELAY",
  "venueId": "$VENUE"
}
JSON
echo
cat deployed.json
