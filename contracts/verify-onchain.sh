#!/usr/bin/env bash
# Audits the live Lucid deployment on Somnia Shannon (chain 50312) against every public claim,
# using nothing but ordinary RPC reads.
#
# Read-only by construction: it holds no key, signs nothing and calls no state-changing method,
# so a reviewer can point it at the deployment with an empty wallet and no trust in us. Whatever
# it prints was observed on chain during the run, and every line carries the observed value —
# a bare PASS proves nothing a reader can re-derive. A claim the chain cannot answer is reported
# SKIP or FAIL with the reason, never assumed true: a green line for something nobody looked at
# is strictly worse than a red one.
#
# Usage:  ./verify-onchain.sh          (RPC= and DESK= may be overridden from the environment)
# Exit:   0 if every claim passed, 1 if any failed or was skipped.

set -uo pipefail
cd "$(dirname "$0")"

RPC=${RPC:-https://api.infra.testnet.somnia.network}

# The demo desk is a factory clone created at runtime, not a deployment artifact, which is why it
# is not in deployed.json and has to be named here.
DESK=${DESK:-0x4EEDABCC63448b11Bd689EEA4021E7e5B2B314f5}

# DreamDEX's binary-market module — the venue the router subscribes to.
VENUE_MODULE=0x3ecC694Cef705358864a646142ac17A90E29e388

# The venue's settlement collateral. Six decimals, not eighteen.
TUSDC=0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E

# SomniaExtensions.SUBSCRIPTION_OWNER_MINIMUM_BALANCE. The precompile re-checks this against the
# subscription owner on every subscribe, including the one-shot the router creates per settlement,
# so it is a floor the router must stay above for as long as the protocol runs — not a deposit.
SUBSCRIPTION_FLOOR_WEI=32000000000000000000

# LucidBrain.PER_AGENT_COST: the platform's reward per validator, on top of its own deposit floor.
AGENT_REWARD_WEI=70000000000000000

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

ROUTER=$(py -c "import json;print(json.load(open('deployed.json'))['router'])")
BRAIN=$(py -c "import json;print(json.load(open('deployed.json'))['brain'])")

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
echo "  desk       $DESK"

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
section "2. the router stays above the reactivity subscription floor"
ROUTER_BAL=$(num "$(cast balance "$ROUTER" --rpc-url "$RPC" 2>/dev/null)")
if [ -z "$ROUTER_BAL" ]; then
  bad "could not read the router balance from $RPC"
else
  VERDICT=$(py - "$ROUTER_BAL" "$SUBSCRIPTION_FLOOR_WEI" <<'PY'
import sys
bal, floor = int(sys.argv[1]), int(sys.argv[2])
print("%s %.6f SOMI held, floor is %.0f SOMI (%+.6f)" %
      ("OK" if bal >= floor else "LOW", bal / 1e18, floor / 1e18, (bal - floor) / 1e18))
PY
)
  case "$VERDICT" in
    OK*) ok  "router balance — ${VERDICT#OK }" ;;
    *)   bad "router balance — ${VERDICT#LOW }" ;;
  esac
fi

# -- 3 ----------------------------------------------------------------------------------------
section "3. the router owns a live reactivity subscription on the DreamDEX venue"
SUBS_RAW=$(rpc somnia_reactivityGetSubscriptions "[\"$ROUTER\"]")
SUB_IDS=$(SUBS="$SUBS_RAW" py - <<'PY'
import json, os
try:
    print("\n".join(json.loads(os.environ["SUBS"]).get("result") or []))
except Exception:
    pass
PY
)
if [ -z "$SUB_IDS" ]; then
  bad "somnia_reactivityGetSubscriptions($ROUTER) returned no subscriptions — raw: $SUBS_RAW"
  skip "subscription fields (emitter / topic / handler / gas limit) — no subscription to inspect"
else
  SUB_COUNT=$(printf '%s\n' "$SUB_IDS" | grep -c .)
  ok "somnia_reactivityGetSubscriptions($ROUTER) — $SUB_COUNT subscription id(s): $(printf '%s ' $SUB_IDS)"

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
for fn in factory keeper relay brain; do
  want=$(py -c "import json;print(json.load(open('deployed.json'))['$fn'])")
  got=$(ccall "$ROUTER" "${fn}()(address)")
  if [ -n "$got" ] && [ "$(lower "$got")" = "$(lower "$want")" ]; then
    ok "router.${fn}() = $got"
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
section "9. the brain's quote is the platform deposit plus the committee reward"
QUOTE=$(num "$(ccall "$BRAIN" 'quote()(uint256)')")
SIZE=$(num "$(ccall "$BRAIN" 'committeeSize()(uint8)')")
PLATFORM=$(ccall "$BRAIN" 'PLATFORM()(address)')
if [ -z "$QUOTE" ] || [ -z "$SIZE" ] || [ -z "$PLATFORM" ]; then
  skip "brain.quote() — could not read quote/committeeSize/PLATFORM from the brain"
else
  DEPOSIT=$(num "$(ccall "$PLATFORM" 'getAdvancedRequestDeposit(uint256)(uint256)' "$SIZE")")
  if [ -z "$DEPOSIT" ]; then
    skip "brain.quote() — platform $PLATFORM did not answer getAdvancedRequestDeposit($SIZE)"
  else
    LINE=$(py - "$QUOTE" "$DEPOSIT" "$SIZE" "$AGENT_REWARD_WEI" <<'PY'
import sys
quote, deposit, size, reward = (int(a) for a in sys.argv[1:5])
expect = deposit + reward * size
print("%s quote=%s wei (%.4f SOMI) vs deposit %.4f + %d x %.2f = %.4f SOMI" %
      ("OK" if quote == expect else "MISMATCH", quote, quote / 1e18,
       deposit / 1e18, size, reward / 1e18, expect / 1e18))
PY
)
    case "$LINE" in
      OK*) ok  "committee of $SIZE on platform $PLATFORM — ${LINE#OK }" ;;
      *)   bad "committee of $SIZE on platform $PLATFORM — ${LINE#MISMATCH }" ;;
    esac
  fi
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
