#!/usr/bin/env bash
# Audits the live Lucid deployment on Somnia Shannon (chain 50312) against every public claim,
# using nothing but ordinary RPC reads and one query against DreamDEX's public market indexer.
#
# Read-only by construction: it holds no key, signs nothing and calls no state-changing method,
# so a reviewer can point it at the deployment with an empty wallet and no trust in us. Whatever
# it prints was observed on chain during the run, and every line carries the observed value —
# a bare PASS proves nothing a reader can re-derive. A claim the chain cannot answer is reported
# SKIP or FAIL with the reason, never assumed true: a green line for something nobody looked at
# is strictly worse than a red one.
#
# Usage:  ./verify-onchain.sh   (RPC=, INDEXER= and DESK= may be overridden from the environment)
# Exit:   0 if every claim passed, 1 if any failed or was skipped.

set -uo pipefail
cd "$(dirname "$0")"

RPC=${RPC:-https://api.infra.testnet.somnia.network}

# DreamDEX's public market indexer. Hasura, no auth, no rate limit. It is the only thing in this
# script that is not an RPC read, and it is here for one claim the chain alone cannot settle:
# whether the venue's oracle actually answers a series that an ordinary account registered.
INDEXER=${INDEXER:-https://dev.smk.somnia.host/v1/graphql}

# The indexer's terminal market status. It is "Finalized". It is never "Resolved" — that value does
# not exist in the schema, and a filter written against it returns an empty set forever, which
# reads on screen as "our venue never settles" rather than as the typo it is.
TERMINAL_STATUS=Finalized

# DreamDEX's binary-market module — the venue the router subscribes to.
VENUE_MODULE=0x3ecC694Cef705358864a646142ac17A90E29e388

# The venue's settlement collateral. Six decimals, not eighteen.
TUSDC=0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E

# SomniaExtensions.SUBSCRIPTION_OWNER_MINIMUM_BALANCE. The precompile re-checks this against the
# subscription owner on every subscribe, including the one-shot the router creates per settlement,
# so it is a floor the router must stay above for as long as the protocol runs — not a deposit.
SUBSCRIPTION_FLOOR_WEI=32000000000000000000

# LucidBrain's two per-validator rewards, paid on top of the platform's own deposit floor. The
# brain asks two separate committees per window — a cheap one for the price feed, a dearer one for
# the verdict — so a single "the quote is the deposit plus the reward" line would be checking half
# the bill. LucidBrain.FEED_PER_AGENT_COST and LucidBrain.LLM_PER_AGENT_COST.
FEED_AGENT_REWARD_WEI=30000000000000000
LLM_AGENT_REWARD_WEI=70000000000000000

# LucidSeries.Mode, in declaration order. Failover is the only mode this deployment should be in:
# Off spends nothing but also covers nothing, and Continuous rolls a window every interval whether
# or not the venue needs it, which is roughly 34 SOMI an hour.
SERIES_MODE_NAMES="Off Failover Continuous"
SERIES_MODE_EXPECTED=1

# The series our own MarketCreator has registered, and the cadence LucidSeries watches for it.
# Both are set by `setSeries` at deploy time; this is the pair the script asserts is still in force.
EXPECTED_SERIES_ID=1
EXPECTED_INTERVAL_SEC=300

# Below this a handler is not worth arming: one reactive call fans out to every armed desk and
# then runs the venue's own upkeep, so a thin gas limit turns into a silent no-op on chain.
MIN_HANDLER_GAS=5000000

TOPIC_MARKET_CREATED=0xb5ec75cdb7dbcd28a5f50d152d8833334525a902ef5332ebc19bcf5c0011f8cd
TOPIC_MARKET_SEEN=0x0e727b29d5a92ce6b52d5d648180ad787d9ffb30e4dd9c6a77ef224d965c06bf
TOPIC_SETTLEMENT_SCHEDULED=0xb84ae5069bee26c51d534481a562e19425aefa69c416643dc1e32ee80d8f518c

# Shannon caps eth_getLogs at 1000 blocks per call and mints a block roughly every 100ms, so one
# wide range is rejected outright and even a legal one covers about a minute and a half of chain.
# Walk backwards in windows and stop as soon as both events have been seen.
LOG_WINDOW=950
LOG_WINDOWS_MAX=6

PASSED=0; FAILED=0; SKIPPED=0
ok()      { printf '  PASS  %s\n' "$1"; PASSED=$((PASSED+1)); }
bad()     { printf '  FAIL  %s\n' "$1"; FAILED=$((FAILED+1)); }
skip()    { printf '  SKIP  %s\n' "$1"; SKIPPED=$((SKIPPED+1)); }
section() { printf '\n%s\n' "$1"; }

for tool in cast curl; do
  command -v "$tool" >/dev/null || { echo "$tool is required and is not on PATH" >&2; exit 2; }
done
PY=$(command -v python3 || command -v python) || { echo "python is required and is not on PATH" >&2; exit 2; }

# Python on Windows opens stdout in text mode and turns every newline into CRLF. The stray CR
# then rides along inside addresses and subscription ids and makes cast reject them as malformed,
# which reads on screen as "no code at this address" — a false FAIL that looks exactly like a
# broken deployment. It also defaults to the console codepage, which mangles anything outside
# Latin-1. Normalise both once here rather than at every call site.
py() { PYTHONIOENCODING=utf-8 "$PY" "$@" | tr -d '\r'; }

post() { # raw json body
  curl -sS --max-time 30 -X POST "$RPC" -H 'content-type: application/json' --data "$1"
}
rpc() { # method, params-as-json-array
  post "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"
}

# cast annotates large integers with a human-readable suffix ("32000... [3.2e19]"); keep the value.
num()   { printf '%s' "${1%% *}"; }
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
ccall() { cast call "$@" --rpc-url "$RPC" 2>/dev/null; }

[ -f deployed.json ] || { echo "deployed.json not found next to this script" >&2; exit 2; }

jkey() { py -c "import json,sys;print(json.load(open('deployed.json')).get(sys.argv[1],''))" "$1"; }

ROUTER=$(jkey router)
# The venue watch. It owns the `MarketCreated` subscription and names the router as its
# handler, so the loop starts on its bond rather than on the router's. Older records predate
# it and carry no `watch` key; the checks below then fall back to the router owning its own
# subscription, which is what those deployments actually do.
WATCH=$(jkey watch)
BRAIN=$(jkey brain)
SERIES=$(jkey series)
MARKET_CREATOR=$(jkey marketCreator)
OWN_VENUE=$(jkey ownVenueId)

# The demo desk is a factory clone created at runtime rather than a `forge create` artifact, but the
# deploy records the one it makes, so it is read from deployed.json like everything else. DESK=
# still overrides it, to point this script at any other desk the factory has produced.
# Seed desks are named per strategy now; older records named a single demoDesk. Take whichever
# this deployment actually carries so the bare command works without an environment override.
DESK=${DESK:-$(jkey deskAiEdge)}
[ -n "$DESK" ] || DESK=$(jkey deskMaker)
[ -n "$DESK" ] || DESK=$(jkey demoDesk)
if [ -z "$DESK" ]; then
  echo "deployed.json names no desk and DESK= was not set — nothing to audit for the desk" >&2
  exit 2
fi

CHAIN_ID=$(cast chain-id --rpc-url "$RPC" 2>/dev/null)
TIP=$(cast block-number --rpc-url "$RPC" 2>/dev/null)
if [ -z "${TIP:-}" ]; then
  echo "cannot reach $RPC — nothing below can be observed, so nothing below is reported" >&2
  exit 2
fi

echo "Lucid on-chain verification"
echo "  rpc        $RPC"
echo "  chain id   ${CHAIN_ID:-unknown}"
echo "  head block $TIP"
echo "  router     $ROUTER"
echo "  series     $SERIES"
echo "  desk       $DESK"
echo "  indexer    $INDEXER"

# Reported alongside the head block so every "seconds ago" below is chain time, not this machine's.
NOW=$(num "$(cast block latest --field timestamp --rpc-url "$RPC" 2>/dev/null)")
echo "  head time  ${NOW:-unknown}"

# -- 1 ----------------------------------------------------------------------------------------
section "1. every address in deployed.json carries deployed code"
# Runtime bytecode is by far the largest payload this script pulls, and one round trip per address
# was most of its wall clock. Ask for all of them in a single batched JSON-RPC call instead.
CODE_REQ=$(py - <<'PY'
import json, re
addrs = [v for v in json.load(open("deployed.json")).values()
         if isinstance(v, str) and re.fullmatch(r"0x[0-9a-fA-F]{40}", v)]
print(json.dumps([{"jsonrpc": "2.0", "id": i, "method": "eth_getCode", "params": [a, "latest"]}
                  for i, a in enumerate(addrs)]))
PY
)
CODE_REPORT=$(RES="$(post "$CODE_REQ")" py - <<'PY'
import json, os, re
named = [(k, v) for k, v in json.load(open("deployed.json")).items()
         if isinstance(v, str) and re.fullmatch(r"0x[0-9a-fA-F]{40}", v)]
raw = os.environ["RES"]
try:
    resp = json.loads(raw)
except Exception:
    resp = None
if not isinstance(resp, list):
    # Reporting "no code" here would look exactly like a wiped deployment; say what really happened.
    print("FAIL\tbatched eth_getCode returned no batch — %s" % raw[:200])
else:
    by_id = {r.get("id"): r for r in resp}
    for i, (name, addr) in enumerate(named):
        code = by_id.get(i, {}).get("result") or "0x"
        size = (len(code) - 2) // 2
        print("%s\t%-18s %s — %s" % (
            "PASS" if size else "FAIL", name, addr,
            "%d bytes of runtime code" % size if size else "no code at this address"))
PY
)
while IFS=$'\t' read -r verdict line; do
  [ -n "$verdict" ] || continue
  if [ "$verdict" = "PASS" ]; then ok "$line"; else bad "$line"; fi
done <<< "$CODE_REPORT"

# -- 2 ----------------------------------------------------------------------------------------
section "2. every contract that owns a subscription stays above the reactivity floor"
# The floor is checked against whichever contract calls `subscribe`, so it binds on each of
# them separately. The watch pays for delivering markets; the router pays for the wake-ups and
# the committee. Either one falling through the floor stops its own half and nothing else,
# which is the entire reason they are two contracts and not one.
floor_check() { # label, address
  local label=$1 addr=$2 bal verdict
  [ -n "$addr" ] || { skip "$label balance — deployed.json names no address for it"; return; }
  bal=$(num "$(cast balance "$addr" --rpc-url "$RPC" 2>/dev/null)")
  if [ -z "$bal" ]; then
    bad "could not read the $label balance from $RPC"
    return
  fi
  verdict=$(py - "$bal" "$SUBSCRIPTION_FLOOR_WEI" <<'PY'
import sys
bal, floor = int(sys.argv[1]), int(sys.argv[2])
print("%s %.6f SOMI held, floor is %.0f SOMI (%+.6f)" %
      ("OK" if bal >= floor else "LOW", bal / 1e18, floor / 1e18, (bal - floor) / 1e18))
PY
)
  case "$verdict" in
    OK*) ok  "$label balance — ${verdict#OK }" ;;
    *)   bad "$label balance — ${verdict#LOW }" ;;
  esac
}
floor_check router "$ROUTER"

# The watch is a standby on a fresh deployment: deployed, cold, holding nothing. The floor
# binds on it only once it actually owns the venue subscription, and reporting a cold standby
# as underfunded would be reporting a deployment that is working exactly as designed as broken.
if [ -n "$WATCH" ]; then
  WATCH_ARMED=$(ccall "$WATCH" "armed()(bool)")
  case "$WATCH_ARMED" in
    true)  floor_check watch "$WATCH" ;;
    false) ok "watch is a cold standby — holds no subscription, so the floor does not bind on it" ;;
    *)     bad "watch.armed() did not answer — got '${WATCH_ARMED:-<nothing>}'" ;;
  esac
fi

# -- 3 ----------------------------------------------------------------------------------------
section "3. a live reactivity subscription on the DreamDEX venue delivers to the router"
# Ownership of that subscription is not the claim; delivery to the router is. Both owners are
# asked, because a deployment whose router still holds it and one whose watch holds it are
# equally live, and a check written against only one of them would report the other as dead.
SUB_IDS=""; SUB_SOURCES=""
for holder in "$ROUTER" "$WATCH"; do
  [ -n "$holder" ] || continue
  HOLDER_RAW=$(rpc somnia_reactivityGetSubscriptions "[\"$holder\"]")
  HOLDER_IDS=$(SUBS="$HOLDER_RAW" py - <<'PY'
import json, os
try:
    print("\n".join(json.loads(os.environ["SUBS"]).get("result") or []))
except Exception:
    pass
PY
)
  N=$(printf '%s' "$HOLDER_IDS" | grep -c . || true)
  SUB_SOURCES="$SUB_SOURCES$holder -> ${N:-0} id(s) $(printf '%s ' $HOLDER_IDS); "
  if [ -n "$HOLDER_IDS" ]; then SUB_IDS="$SUB_IDS $HOLDER_IDS"; fi
done
if [ -z "$(printf '%s' "$SUB_IDS" | tr -d '[:space:]')" ]; then
  bad "no subscription is owned by the router or the watch — $SUB_SOURCES"
  skip "subscription fields (emitter / topic / handler / gas limit) — no subscription to inspect"
else
  SUB_COUNT=$(printf '%s\n' $SUB_IDS | grep -c .)
  ok "somnia_reactivityGetSubscriptions — $SUB_COUNT id(s) across owners: $SUB_SOURCES"

  MATCH_ID=""; MATCH_DETAIL=""; LAST_DETAIL=""
  for id in $SUB_IDS; do
    INFO=$(rpc somnia_reactivityGetSubscriptionInfo "[\"$id\"]")
    REPORT=$(INFO="$INFO" py - "$VENUE_MODULE" "$TOPIC_MARKET_CREATED" "$ROUTER" "$MIN_HANDLER_GAS" <<'PY'
import json, os, sys
module, topic, router, mingas = sys.argv[1].lower(), sys.argv[2].lower(), sys.argv[3].lower(), int(sys.argv[4])
try:
    res = json.loads(os.environ["INFO"]).get("result") or []
except Exception:
    res = []
if not res:
    # A one-shot settlement subscription the precompile has already fired and dropped.
    print("EMPTY|no info returned")
    raise SystemExit
s = res[0]
gas = int(str(s.get("gas_limit", "0x0")), 16)
top = (s.get("topics") or [""])[0]
checks = [
    ("emitter", s.get("emitter", "").lower() == module, s.get("emitter")),
    ("topics[0]", top.lower() == topic, top),
    ("handler_contract_address", s.get("handler_contract_address", "").lower() == router,
     s.get("handler_contract_address")),
    ("gas_limit", gas >= mingas, "%d (min %d)" % (gas, mingas)),
]
print(("MATCH" if all(c[1] for c in checks) else "MISMATCH") + "|" +
      "; ".join("%s=%s%s" % (n, v, "" if good else "  <-- WRONG") for n, good, v in checks))
PY
)
    case "${REPORT%%|*}" in
      MATCH)    MATCH_ID="$id"; MATCH_DETAIL="${REPORT#*|}"; break ;;
      MISMATCH) LAST_DETAIL="$id -> ${REPORT#*|}" ;;
    esac
  done

  if [ -n "$MATCH_ID" ]; then
    ok "subscription $MATCH_ID — $MATCH_DETAIL"
  elif [ -n "$LAST_DETAIL" ]; then
    bad "no subscription matches the venue: $LAST_DETAIL"
  else
    bad "every subscription id returned empty info — none is a live venue subscription"
  fi
fi

# -- 4 and 5 ----------------------------------------------------------------------------------
section "4/5. the router is reacting to the live venue right now (no process of ours running)"
SEEN_TOTAL=0; SEEN_LAST=0
SCHED_TOTAL=0; SCHED_LAST=0
SCAN_LOW=$TIP; SCAN_ERR=""; WINDOWS_DONE=0
for i in $(seq 0 $((LOG_WINDOWS_MAX - 1))); do
  to=$((TIP - i * LOG_WINDOW))
  from=$((to - LOG_WINDOW + 1))
  [ "$from" -lt 0 ] && from=0
  RES=$(rpc eth_getLogs "[{\"address\":\"$ROUTER\",\"fromBlock\":\"$(printf '0x%x' $from)\",\"toBlock\":\"$(printf '0x%x' $to)\"}]")
  LINE=$(LOGS="$RES" py - "$TOPIC_MARKET_SEEN" "$TOPIC_SETTLEMENT_SCHEDULED" <<'PY'
import json, os, sys
try:
    d = json.loads(os.environ["LOGS"])
except Exception as e:
    print("ERR unparseable response: %s" % e)
    raise SystemExit
if "result" not in d:
    print("ERR %s" % json.dumps(d.get("error")))
    raise SystemExit
def pick(t):
    hits = [l for l in d["result"] if (l.get("topics") or [""])[0].lower() == t]
    return len(hits), (max(int(l["blockNumber"], 16) for l in hits) if hits else 0)
a, b = pick(sys.argv[1].lower()), pick(sys.argv[2].lower())
print("OK %d %d %d %d" % (a[0], a[1], b[0], b[1]))
PY
)
  if [ "${LINE%% *}" = "ERR" ]; then SCAN_ERR="${LINE#ERR }"; break; fi
  read -r _ w_seen w_seen_last w_sched w_sched_last <<< "$LINE"
  SEEN_TOTAL=$((SEEN_TOTAL + w_seen))
  SCHED_TOTAL=$((SCHED_TOTAL + w_sched))
  [ "$w_seen_last" -gt "$SEEN_LAST" ] && SEEN_LAST=$w_seen_last
  [ "$w_sched_last" -gt "$SCHED_LAST" ] && SCHED_LAST=$w_sched_last
  SCAN_LOW=$from
  WINDOWS_DONE=$((WINDOWS_DONE + 1))
  if [ "$SEEN_TOTAL" -gt 0 ] && [ "$SCHED_TOTAL" -gt 0 ]; then break; fi
done

SCANNED=$((TIP - SCAN_LOW + 1))
if [ -n "$SCAN_ERR" ]; then
  skip "MarketSeen — eth_getLogs refused the scan: $SCAN_ERR"
  skip "SettlementScheduled — eth_getLogs refused the scan: $SCAN_ERR"
else
  echo "        scanned $WINDOWS_DONE window(s), blocks $SCAN_LOW..$TIP ($SCANNED blocks, ~$((SCANNED / 10))s of chain)"
  if [ "$SEEN_TOTAL" -gt 0 ]; then
    ok "MarketSeen — $SEEN_TOTAL log(s), newest at block $SEEN_LAST ($((TIP - SEEN_LAST)) blocks ago)"
  else
    bad "MarketSeen — 0 logs in the last $SCANNED blocks; the router is not reacting to the venue"
  fi
  if [ "$SCHED_TOTAL" -gt 0 ]; then
    ok "SettlementScheduled — $SCHED_TOTAL log(s), newest at block $SCHED_LAST ($((TIP - SCHED_LAST)) blocks ago)"
  else
    bad "SettlementScheduled — 0 logs in the last $SCANNED blocks"
  fi
fi

# -- 6 ----------------------------------------------------------------------------------------
section "6. the router's wiring matches deployed.json"
for fn in factory keeper relay brain series; do
  want=$(py -c "import json;print(json.load(open('deployed.json'))['$fn'])")
  got=$(ccall "$ROUTER" "${fn}()(address)")
  if [ -n "$got" ] && [ "$(lower "$got")" = "$(lower "$want")" ]; then
    ok "router.${fn}() = $got"
  elif [ "$got" = "0x0000000000000000000000000000000000000000" ]; then
    # Not the same failure as a wrong address: every one of these setters takes zero as "detach",
    # so a zero here is a deliberate operator action rather than a mis-wired deployment. It is still
    # a divergence from the deployment this file records, and it still changes what the router does
    # — with no keeper attached the router schedules a settlement only for markets its own desks
    # asked about, and runs no venue-wide upkeep at all.
    bad "router.${fn}() = zero — the $fn is detached, though deployed.json ships one at $want"
  else
    bad "router.${fn}() = ${got:-<call failed>}, deployed.json says $want"
  fi
done

# -- 7 ----------------------------------------------------------------------------------------
section "7. the demo desk is registered and armed"
IS_DESK=$(ccall "$ROUTER" 'isDesk(address)(bool)' "$DESK")
ARMED=$(ccall "$ROUTER" 'deskArmed(address)(bool)' "$DESK")
ARMED_LIST=$(ccall "$ROUTER" 'armedDesks()(address[])')
if [ "$IS_DESK" = "true" ]; then ok "router.isDesk($DESK) = true"
else bad "router.isDesk($DESK) = ${IS_DESK:-<call failed>}"; fi
if [ "$ARMED" = "true" ]; then ok "router.deskArmed($DESK) = true"
else bad "router.deskArmed($DESK) = ${ARMED:-<call failed>}"; fi
if printf '%s' "$(lower "$ARMED_LIST")" | grep -qF "$(lower "$DESK")"; then
  ok "router.armedDesks() contains the desk — $ARMED_LIST"
else
  bad "router.armedDesks() does not contain the desk — ${ARMED_LIST:-<call failed>}"
fi

# -- 8 ----------------------------------------------------------------------------------------
section "8. the demo desk holds real collateral"
TUSDC_BAL=$(num "$(ccall "$TUSDC" 'balanceOf(address)(uint256)' "$DESK")")
SYMBOL=$(ccall "$TUSDC" 'symbol()(string)' | tr -d '"')
if [ -z "$TUSDC_BAL" ]; then
  bad "balanceOf($DESK) on $TUSDC — the call failed, balance unobserved"
elif [ "$TUSDC_BAL" = "0" ]; then
  bad "desk holds 0 ${SYMBOL:-tUSDC}"
else
  ok "desk holds $(py -c "print('%.6f' % (int('$TUSDC_BAL') / 1e6))") ${SYMBOL:-tUSDC} (raw $TUSDC_BAL, 6 decimals)"
fi

# -- 9 ----------------------------------------------------------------------------------------
section "9. the mandate the desk contract is enforcing, in human terms"
# A reviewer should not have to decode two bitmasks and a strategy enum out of a raw tuple to see
# what this desk is allowed to do with its money. Everything below is read from the desk itself,
# not from whatever was passed to the factory at creation time.
POLICY_RAW=$(ccall "$DESK" 'policy()((uint64,uint64,uint16,uint16,uint8,uint16,uint32,uint32,uint8,bool))')
if [ -z "$POLICY_RAW" ]; then
  skip "desk policy — $DESK did not answer policy(); the mandate went unread"
else
  POLICY_REPORT=$(P="$POLICY_RAW" py - <<'PY'
import os, re
raw = os.environ["P"].strip()
# cast prints the struct as a tuple and annotates wide integers ("200000000 [2e8]"); keep the value.
fields = [re.sub(r"\s*\[[^]]*\]", "", f).strip() for f in raw.strip().strip("()").split(",")]
if len(fields) != 10:
    print("FAIL\tdesk policy — policy() returned %d fields, expected 10: %s" % (len(fields), raw))
    raise SystemExit
cap, budget, max_open, dd_bps, max_losses, edge_bps, assets, cadences, strategy, armed = fields
cap, budget = int(cap), int(budget)
assets, cadences, strategy = int(assets), int(cadences), int(strategy)
armed = armed.lower() == "true"

# PolicyLib.assetBit / PolicyLib.cadenceBit, in the order the masks are defined.
names = lambda mask, table: [n for bit, n in table if mask & bit]
asset_names = names(assets, ((1, "BTC"), (2, "ETH")))
cadence_names = names(cadences, ((1, "1m"), (2, "5m"), (4, "15m"), (8, "1h")))
strategy_name = {0: "AiEdge — takes the book when the committee disagrees with it",
                 1: "Maker — mints a complete set and rests both legs"}.get(
                     strategy, "unrecognised strategy id %d" % strategy)

# Collateral is tUSDC: six decimals, not eighteen.
print("%s\tspend limits — %.6f tUSDC per window, %.6f tUSDC per UTC day (%s at the cap)" % (
    "PASS" if cap and budget else "FAIL", cap / 1e6, budget / 1e6,
    ("%d windows" % (budget // cap)) if cap else "no cap set, nothing may trade"))
print("%s\tmandate — assets %s (mask %d); cadences %s (mask %d)" % (
    "PASS" if asset_names and cadence_names else "FAIL",
    ", ".join(asset_names) or "none — no asset may be traded", assets,
    ", ".join(cadence_names) or "none — no window length may be traded", cadences))
print("%s\tstrategy %s; armed=%s; at most %s open markets; halts on a %.2f%% drawdown or %s "
      "consecutive losses; needs %.2f%% of edge over the book" % (
    "PASS" if armed else "FAIL", strategy_name, str(armed).lower(), max_open,
    int(dd_bps) / 100, max_losses, int(edge_bps) / 100))
PY
)
  while IFS=$'\t' read -r verdict line; do
    [ -n "$verdict" ] || continue
    if [ "$verdict" = "PASS" ]; then ok "$line"; else bad "$line"; fi
  done <<< "$POLICY_REPORT"
fi

# -- 10 ---------------------------------------------------------------------------------------
section "10. the brain's quote is stage 1 plus stage 2, each its own committee's deposit and reward"
# The brain asks two committees per window — a cheap one for the price feed and a dearer one for the
# verdict — so both sizes are reported and both stages are re-derived from the platform's own
# deposit function rather than taken on the brain's word.
QUOTE=$(num "$(ccall "$BRAIN" 'quote()(uint256)')")
Q1=$(num "$(ccall "$BRAIN" 'quoteStage1()(uint256)')")
Q2=$(num "$(ccall "$BRAIN" 'quoteStage2()(uint256)')")
FEED_SIZE=$(num "$(ccall "$BRAIN" 'feedCommitteeSize()(uint8)')")
SIZE=$(num "$(ccall "$BRAIN" 'committeeSize()(uint8)')")
PLATFORM=$(ccall "$BRAIN" 'PLATFORM()(address)')
if [ -z "$QUOTE" ] || [ -z "$Q1" ] || [ -z "$Q2" ] || [ -z "$SIZE" ] || [ -z "$FEED_SIZE" ] || [ -z "$PLATFORM" ]; then
  skip "brain.quote() — could not read quote/quoteStage1/quoteStage2/committee sizes/PLATFORM from $BRAIN"
else
  FEED_DEPOSIT=$(num "$(ccall "$PLATFORM" 'getAdvancedRequestDeposit(uint256)(uint256)' "$FEED_SIZE")")
  LLM_DEPOSIT=$(num "$(ccall "$PLATFORM" 'getAdvancedRequestDeposit(uint256)(uint256)' "$SIZE")")
  if [ -z "$FEED_DEPOSIT" ] || [ -z "$LLM_DEPOSIT" ]; then
    skip "brain.quote() — platform $PLATFORM did not answer getAdvancedRequestDeposit($FEED_SIZE / $SIZE)"
  else
    QUOTE_REPORT=$(py - "$QUOTE" "$Q1" "$Q2" "$FEED_SIZE" "$FEED_DEPOSIT" "$FEED_AGENT_REWARD_WEI" \
                          "$SIZE" "$LLM_DEPOSIT" "$LLM_AGENT_REWARD_WEI" <<'PY'
import sys
quote, q1, q2, fsize, fdep, frew, size, ldep, lrew = (int(a) for a in sys.argv[1:10])
somi = lambda w: "%.4f SOMI" % (w / 1e18)
for label, got, dep, n, rew in (("stage 1 (price feed)", q1, fdep, fsize, frew),
                                ("stage 2 (verdict)", q2, ldep, size, lrew)):
    want = dep + rew * n
    print("%s\t%s — committee of %d, %s = platform deposit %s + %d x %s" % (
        "PASS" if got == want else "FAIL", label, n, somi(got), somi(dep), n, somi(rew)))
    if got != want:
        print("FAIL\t%s — contract says %s wei, the platform's own numbers give %s wei" % (label, got, want))
print("%s\tquote() = %s = stage 1 %s + stage 2 %s" % (
    "PASS" if quote == q1 + q2 else "FAIL", somi(quote), somi(q1), somi(q2)))
PY
)
    echo "        platform $PLATFORM"
    while IFS=$'\t' read -r verdict line; do
      [ -n "$verdict" ] || continue
      if [ "$verdict" = "PASS" ]; then ok "$line"; else bad "$line"; fi
    done <<< "$QUOTE_REPORT"
  fi
fi

# -- 11 ---------------------------------------------------------------------------------------
section "11. the failover watcher's live status"
STATUS_RAW=$(ccall "$SERIES" 'status()(uint8,bool,uint64,uint64,uint32,uint256)')
STALENESS=$(num "$(ccall "$SERIES" 'stalenessSeconds()(uint32)')")
MAX_ROLLS=$(num "$(ccall "$SERIES" 'maxRollsPerDay()(uint256)')")
MIN_FLOAT=$(num "$(ccall "$SERIES" 'minCreatorFloat()(uint256)')")
if [ -z "$STATUS_RAW" ] || [ -z "$NOW" ]; then
  skip "series.status() — $SERIES did not answer status(), or the chain's head timestamp was unreadable"
else
  STATUS_REPORT=$(S="$STATUS_RAW" py - "$NOW" "${STALENESS:-0}" "${MAX_ROLLS:-0}" "${MIN_FLOAT:-0}" \
                                       "$SERIES_MODE_EXPECTED" "$SERIES_MODE_NAMES" <<'PY'
import os, re, sys
vals = [re.sub(r"\s*\[[^]]*\]", "", v).strip()
        for v in os.environ["S"].strip().splitlines() if v.strip()]
if len(vals) != 6:
    print("FAIL\tseries.status() — returned %d values, expected 6: %r" % (len(vals), vals))
    raise SystemExit
mode = int(vals[0]); healthy = vals[1].lower() == "true"
last_market, last_roll, rolls_today, float_wei = (int(v) for v in vals[2:6])
now, staleness, max_rolls, min_float, expected_mode = (int(a) for a in sys.argv[1:6])
mode_names = sys.argv[6].split()
name = mode_names[mode] if mode < len(mode_names) else "unrecognised(%d)" % mode

print("%s\tseries.mode = %d (%s)%s" % (
    "PASS" if mode == expected_mode else "FAIL", mode, name,
    "" if mode == expected_mode else " — expected %d (%s)" % (
        expected_mode, mode_names[expected_mode])))

age = now - last_market
print("PASS\tvenue considered healthy = %s — last venue market of the watched cadence at %d, "
      "%ds ago, against a %ds staleness threshold" % (str(healthy).lower(), last_market, age, staleness))
print("PASS\trolls today = %d of %d allowed; last roll %s" % (
    rolls_today, max_rolls,
    ("at %d, %ds ago" % (last_roll, now - last_roll)) if last_roll else
    "never — the venue has not yet needed standing in for"))
print("PASS\tcreator native float = %.6f SOMI, against a %.6f SOMI roll floor" % (
    float_wei / 1e18, min_float / 1e18))
if float_wei < min_float:
    print("NOTE\tthe float is under the floor: were the venue to go stale right now, _maybeRoll "
          "would emit RollSkipped(LOW_FLOAT) and roll nothing until the creator is topped up")
PY
)
  while IFS=$'\t' read -r verdict line; do
    [ -n "$verdict" ] || continue
    case "$verdict" in
      PASS) ok "$line" ;;
      NOTE) printf '        %s\n' "$line" ;;
      *)    bad "$line" ;;
    esac
  done <<< "$STATUS_REPORT"
fi

# -- 12 ---------------------------------------------------------------------------------------
section "12. the failover is pointed at our own MarketCreator, not at somebody else's"
SER_CREATOR=$(ccall "$SERIES" 'creator()(address)')
SER_ID=$(num "$(ccall "$SERIES" 'seriesId()(uint32)')")
SER_INTERVAL=$(num "$(ccall "$SERIES" 'intervalSec()(uint32)')")
if [ -n "$SER_CREATOR" ] && [ "$(lower "$SER_CREATOR")" = "$(lower "$MARKET_CREATOR")" ]; then
  ok "series.creator() = $SER_CREATOR, which is the marketCreator in deployed.json"
else
  bad "series.creator() = ${SER_CREATOR:-<call failed>}, deployed.json says $MARKET_CREATOR"
fi
if [ "$SER_ID" = "$EXPECTED_SERIES_ID" ]; then
  ok "series.seriesId() = $SER_ID"
else
  bad "series.seriesId() = ${SER_ID:-<call failed>}, expected $EXPECTED_SERIES_ID"
fi
if [ "$SER_INTERVAL" = "$EXPECTED_INTERVAL_SEC" ]; then
  ok "series.intervalSec() = ${SER_INTERVAL}s — the window it rolls and the venue cadence it watches"
else
  bad "series.intervalSec() = ${SER_INTERVAL:-<call failed>}, expected $EXPECTED_INTERVAL_SEC"
fi
# _maybeRoll refuses a creator with no code, so a creator that is an EOA is a dead failover.
CREATOR_CODE=$(cast code "$MARKET_CREATOR" --rpc-url "$RPC" 2>/dev/null)
CREATOR_SIZE=$(( (${#CREATOR_CODE} - 2) / 2 ))
if [ "${CREATOR_CODE:-0x}" != "0x" ] && [ "$CREATOR_SIZE" -gt 0 ]; then
  ok "marketCreator $MARKET_CREATOR carries $CREATOR_SIZE bytes of runtime code"
else
  bad "marketCreator $MARKET_CREATOR has no code — _maybeRoll would refuse it with NO_SERIES"
fi

# -- 13 ---------------------------------------------------------------------------------------
section "13. our own venue really resolves — a series an ordinary account registered gets answered"
# The point of this one. Anybody can register a venue, a creator and a series on DreamDEX; the
# question a reviewer should ask is whether the venue's oracle then actually settles the windows
# that come out of it, or whether permissionless registration produces markets nobody resolves.
# The public indexer is the only place that answer lives, so this is the one non-RPC read here.
gql() { # query, variables-json
  BODY=$(Q="$1" V="$2" py - <<'PY'
import json, os
print(json.dumps({"query": os.environ["Q"], "variables": json.loads(os.environ["V"])}))
PY
)
  curl -sS --max-time 30 -X POST "$INDEXER" -H 'content-type: application/json' --data "$BODY"
}
if [ -z "$OWN_VENUE" ]; then
  skip "own venue — deployed.json carries no ownVenueId, so there is nothing to look up"
else
  # `clobStatus` is a Hasura enum column, not text: declaring $terminal as String! is rejected at
  # validation, which reads as "the indexer is down" if the error is not printed.
  VENUE_RES=$(gql 'query LucidOwnVenue($v: String!, $terminal: clobmarketstatus!) {
  Market(limit: 5, order_by: {resolvedAtTimestamp: desc},
         where: {venueId: {_eq: $v}, clobStatus: {_eq: $terminal}}) {
    marketId asset intervalSec clobStatus winningOutcome finalized voided expiry resolvedAtTimestamp
  }
}' "{\"v\":\"$OWN_VENUE\",\"terminal\":\"$TERMINAL_STATUS\"}")
  VENUE_REPORT=$(RES="$VENUE_RES" py - "$TERMINAL_STATUS" <<'PY'
import json, os, sys
terminal = sys.argv[1]
raw = os.environ["RES"]
try:
    d = json.loads(raw)
except Exception:
    print("SKIP\tthe indexer returned something that is not JSON: %s" % raw[:200])
    raise SystemExit
if d.get("errors"):
    print("SKIP\tthe indexer rejected the query: %s" % json.dumps(d["errors"])[:300])
    raise SystemExit
rows = (d.get("data") or {}).get("Market")
if rows is None:
    print("SKIP\tthe indexer returned no Market set: %s" % raw[:200])
    raise SystemExit
# winningOutcome 0 is a real outcome, so this has to be a null test and not a truth test.
settled = [r for r in rows if r.get("clobStatus") == terminal and r.get("winningOutcome") is not None]
if not settled:
    print("FAIL\tno %s market with a winning outcome on our venue — %d row(s) came back: %s" % (
        terminal, len(rows), json.dumps(rows)[:300]))
    raise SystemExit
r = settled[0]
print("PASS\t%d market(s) on our own venue reached %s with a winning outcome" % (len(settled), terminal))
print("PASS\tnewest — market %s, %s %ss, clobStatus=%s, winningOutcome=%s, voided=%s, expiry %s, "
      "resolved at %s" % (r["marketId"], r.get("asset"), r.get("intervalSec"), r.get("clobStatus"),
                          r.get("winningOutcome"), json.dumps(r.get("voided")), r.get("expiry"),
                          r.get("resolvedAtTimestamp")))
PY
)
  while IFS=$'\t' read -r verdict line; do
    [ -n "$verdict" ] || continue
    case "$verdict" in
      PASS) ok "$line" ;;
      SKIP) skip "$line" ;;
      *)    bad "$line" ;;
    esac
  done <<< "$VENUE_REPORT"
fi

# -- summary ----------------------------------------------------------------------------------
TOTAL=$((PASSED + FAILED + SKIPPED))
printf '\n%s\n' "$TOTAL checks: $PASSED passed, $FAILED failed, $SKIPPED skipped"
# A skip is not a pass: it means the claim went unobserved, which the exit code has to reflect.
if [ "$FAILED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]; then
  echo "OK — every claim was checked against the chain and held."
  exit 0
fi
echo "NOT OK — see the FAIL/SKIP lines above."
exit 1
