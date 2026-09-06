// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LucidTypes} from "../../src/types/LucidTypes.sol";

/// @dev The one router entry point a desk uses while it is being driven. Declared locally so the
/// mock stays independent of the router's own compilation unit.
interface IRouterTradeSink {
    function reportTrade(bytes32 marketId, uint8 kind, uint256 stake) external;
}

/// @title MockDeskForRouter
/// @notice A desk that records how the router drove it, and can be told to misbehave.
/// @dev The misbehaviour modes are the interesting part. The router's central promise is that one
/// broken desk cannot take down the fan-out for everybody else, and there are two distinct ways to
/// break: reverting (cheap, caught by `try`) and running away with the gas (expensive, only bounded
/// by a stipend). Both are reproduced here so the promise is tested rather than asserted.
contract MockDeskForRouter {
    /// @notice Deliberate failure used by the revert modes.
    error DeskIsDown();

    address public owner;
    address public router;

    // ── behaviour switches ────────────────────────────────────────────────────
    bool public wants = true;
    bool public revertOnPreCheck;
    bool public revertOnVerdict;
    bool public revertOnSettlement;
    bool public revertOnLeaderTrade;
    /// @dev When set, the desk burns storage until it runs out of the gas the router gave it.
    bool public gasBombOnVerdict;
    bool public gasBombOnSettlement;

    /// @dev When set, the desk tells the router what it traded, which is what makes copy-trading work.
    bool public reportsTrade;
    uint8 public tradeKind;
    uint256 public tradeStake;

    // ── observations ──────────────────────────────────────────────────────────
    uint256 public verdictCalls;
    uint256 public settlementCalls;
    uint256 public leaderTradeCalls;

    bytes32 public lastVerdictMarketId;
    uint256 public lastPBookBps;
    /// @dev Recorded separately from the value, because the whole point of the flag is that a book
    /// value alone cannot say whether anybody quoted it.
    bool public lastBookObserved;
    uint16 public lastProbUpBps;

    bytes32 public lastSettledMarketId;

    bytes32 public lastLeaderMarketId;
    uint8 public lastLeaderKind;
    uint256 public lastLeaderStake;

    /// @dev Only ever written by the gas bombs; never read.
    mapping(uint256 => uint256) private _ballast;

    constructor(address owner_, address router_) {
        owner = owner_;
        router = router_;
    }

    function setWants(bool on) external {
        wants = on;
    }

    function setRevertModes(bool preCheck_, bool verdict_, bool settlement_, bool leaderTrade_) external {
        revertOnPreCheck = preCheck_;
        revertOnVerdict = verdict_;
        revertOnSettlement = settlement_;
        revertOnLeaderTrade = leaderTrade_;
    }

    function setGasBombs(bool verdict_, bool settlement_) external {
        gasBombOnVerdict = verdict_;
        gasBombOnSettlement = settlement_;
    }

    function setTradeReport(bool on, uint8 kind, uint256 stake) external {
        reportsTrade = on;
        tradeKind = kind;
        tradeStake = stake;
    }

    // ── ILucidDesk surface the router drives ─────────────────────────────────

    function preCheck(LucidTypes.MarketInfo calldata) external view returns (bool) {
        if (revertOnPreCheck) revert DeskIsDown();
        return wants;
    }

    function onVerdict(
        LucidTypes.MarketInfo calldata m,
        LucidTypes.Verdict calldata v,
        uint256 pBookBps,
        bool bookObserved
    ) external {
        if (revertOnVerdict) revert DeskIsDown();
        if (gasBombOnVerdict) _burnGas();

        verdictCalls++;
        lastVerdictMarketId = m.marketId;
        lastPBookBps = pBookBps;
        lastBookObserved = bookObserved;
        lastProbUpBps = v.probUpBps;

        if (reportsTrade) IRouterTradeSink(router).reportTrade(m.marketId, tradeKind, tradeStake);
    }

    function onSettlement(LucidTypes.MarketInfo calldata m) external {
        if (revertOnSettlement) revert DeskIsDown();
        if (gasBombOnSettlement) _burnGas();

        settlementCalls++;
        lastSettledMarketId = m.marketId;
    }

    function onLeaderTrade(LucidTypes.MarketInfo calldata m, uint8 kind, uint256 stake) external {
        if (revertOnLeaderTrade) revert DeskIsDown();

        leaderTradeCalls++;
        lastLeaderMarketId = m.marketId;
        lastLeaderKind = kind;
        lastLeaderStake = stake;
    }

    /// @dev Cold storage writes are the cheapest way to spend a large gas budget deterministically.
    function _burnGas() private {
        for (uint256 i = 1;; ++i) {
            _ballast[i] = i;
        }
    }
}
