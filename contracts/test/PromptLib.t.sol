// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PromptLib} from "../src/lib/PromptLib.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";

/// @notice The prompt is the only thing the committee ever sees. If it drifts, the scores drift
/// with it and nothing on-chain would notice, so its exact shape is pinned here.
contract PromptLibTest is Test {
    uint64 internal constant EXPIRY = 1_700_000_300;

    function test_prompt_contains_strike_and_seconds_left() public pure {
        uint16[] memory outcomes = new uint16[](2);
        outcomes[0] = 1;
        outcomes[1] = 0;

        string memory p = PromptLib.build(_market(LucidTypes.ASSET_BTC, 7_988_185), 5123, outcomes, EXPIRY - 247);

        assertTrue(_contains(p, "BTC"), "asset");
        assertTrue(_contains(p, "79881.85"), "strike");
        assertTrue(_contains(p, "247"), "seconds left");
        assertTrue(_contains(p, "51.23%"), "book probability");
        assertTrue(_contains(p, "UP,DOWN"), "outcome history");
    }

    function test_prompt_formats_strike_with_two_decimals() public pure {
        // The venue's oracle reports two decimal places: 7988185 is $79,881.85.
        assertEq(PromptLib.formatTwoDecimals(7_988_185), "79881.85");
        assertEq(PromptLib.formatTwoDecimals(7_988_105), "79881.05");
        assertEq(PromptLib.formatTwoDecimals(100), "1.00");
        assertEq(PromptLib.formatTwoDecimals(5), "0.05");
        assertEq(PromptLib.formatTwoDecimals(0), "0.00");
    }

    function test_asset_symbol_for_btc_eth_and_unknown() public pure {
        assertEq(PromptLib.assetSymbol(LucidTypes.ASSET_BTC), "BTC");
        assertEq(PromptLib.assetSymbol(LucidTypes.ASSET_ETH), "ETH");
        assertEq(PromptLib.assetSymbol(keccak256("SOL")), "UNKNOWN");
        assertEq(PromptLib.assetSymbol(bytes32(0)), "UNKNOWN");
    }

    function test_prompt_keeps_only_the_last_five_outcomes() public pure {
        uint16[] memory outcomes = new uint16[](7);
        for (uint256 i; i < 7; ++i) {
            outcomes[i] = uint16(i % 2); // 0,1,0,1,0,1,0 -> tail of five is 0,1,0,1,0
        }

        string memory p = PromptLib.build(_market(LucidTypes.ASSET_ETH, 300_000), 5000, outcomes, EXPIRY - 60);

        assertTrue(_contains(p, "DOWN,UP,DOWN,UP,DOWN"), "tail of five");
        assertFalse(_contains(p, "DOWN,UP,DOWN,UP,DOWN,UP"), "no sixth entry");
    }

    function test_prompt_reports_an_empty_history_explicitly() public pure {
        string memory p = PromptLib.build(_market(LucidTypes.ASSET_BTC, 1), 5000, new uint16[](0), EXPIRY - 60);
        assertTrue(_contains(p, "none"), "empty history is stated, not omitted");
    }

    function test_seconds_left_is_zero_once_the_window_has_expired() public pure {
        string memory p = PromptLib.build(_market(LucidTypes.ASSET_BTC, 1), 5000, new uint16[](0), EXPIRY + 10);
        assertTrue(_contains(p, "Seconds to expiry: 0"), "no underflow past expiry");
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _market(bytes32 assetKey, uint256 strike) internal pure returns (LucidTypes.MarketInfo memory m) {
        m.marketId = bytes32(uint256(1));
        m.assetKey = assetKey;
        m.strike = strike;
        m.tradingStart = EXPIRY - 300;
        m.expiry = EXPIRY;
        m.intervalSec = 300;
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            uint256 j;
            while (j < n.length && h[i + j] == n[j]) {
                ++j;
            }
            if (j == n.length) return true;
        }
        return false;
    }
}
