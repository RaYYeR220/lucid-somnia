// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PromptLib} from "../src/lib/PromptLib.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";

/// @notice The prompt is the only thing the committee ever sees. If it drifts, the scores drift
/// with it and nothing on-chain would notice, so its exact shape is pinned here.
contract PromptLibTest is Test {
    uint64 internal constant EXPIRY = 1_700_000_300;

    /// @dev 79912.40, a touch above the 79881.85 strike the other fixtures use.
    uint256 internal constant SPOT = 7_991_240;

    function test_prompt_contains_strike_and_seconds_left() public pure {
        uint16[] memory outcomes = new uint16[](2);
        outcomes[0] = 1;
        outcomes[1] = 0;

        string memory p = PromptLib.build(_market(LucidTypes.ASSET_BTC, 7_988_185), 5123, outcomes, EXPIRY - 247, SPOT);

        assertTrue(_contains(p, "BTC"), "asset");
        assertTrue(_contains(p, "79881.85"), "strike");
        assertTrue(_contains(p, "247"), "seconds left");
        assertTrue(_contains(p, "51.23%"), "book probability");
        assertTrue(_contains(p, "UP,DOWN"), "outcome history");
        assertTrue(_contains(p, "79912.40"), "spot");
    }

    // ── the spot and the distance it makes computable ─────────────────────────
    //
    // These windows settle against the price they opened at, so the strike is the opening price.
    // Without a spot the committee is asked whether the close will beat the open with no idea where
    // the price is now, and the only honest answer is 50 — which is exactly what the live
    // committee returned, three times out of three. The distance is the whole point of the prompt.

    function test_prompt_states_the_distance_so_the_model_never_divides() public pure {
        string memory p =
            PromptLib.build(_market(LucidTypes.ASSET_BTC, 7_988_185), 5000, new uint16[](0), EXPIRY - 60, SPOT);

        // (7991240 - 7988185) * 10000 / 7988185 = 3.82 bps, truncated toward zero.
        assertTrue(_contains(p, "Distance to strike: +3 bps (+0.03%)"), "signed distance, both units");
    }

    function test_distance_is_signed_and_symmetric_about_the_strike() public pure {
        assertEq(PromptLib.distanceBps(10_100, 10_000), 100, "one percent above is a hundred bps");
        assertEq(PromptLib.distanceBps(9_900, 10_000), -100, "and a hundred below");
        assertEq(PromptLib.distanceBps(10_000, 10_000), 0, "at the money");
        assertEq(PromptLib.distanceBps(7_991_240, 7_988_185), 3, "truncates toward zero");
        assertEq(PromptLib.distanceBps(7_985_130, 7_988_185), -3, "and truncates the same way below");
    }

    function test_a_price_below_the_strike_reads_as_negative() public pure {
        string memory p =
            PromptLib.build(_market(LucidTypes.ASSET_BTC, 10_000), 5000, new uint16[](0), EXPIRY - 60, 9_900);

        assertTrue(_contains(p, "Spot: 99.00"), "spot");
        assertTrue(_contains(p, "Distance to strike: -100 bps (-1.00%)"), "sign carries to both readings");
    }

    function test_a_broken_strike_is_named_rather_than_divided_by() public pure {
        // A zero strike is a malformed market, not an infinitely distant one. Reporting it as
        // unknown is what stops the committee reasoning from a fabricated number.
        string memory p =
            PromptLib.build(_market(LucidTypes.ASSET_BTC, 0), 5000, new uint16[](0), EXPIRY - 60, 7_991_240);

        assertTrue(_contains(p, "Distance to strike: unknown"), "no division by a zero strike");
        assertEq(PromptLib.distanceBps(7_991_240, 0), 0, "and the helper answers zero rather than reverting");
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

        string memory p = PromptLib.build(_market(LucidTypes.ASSET_ETH, 300_000), 5000, outcomes, EXPIRY - 60, 300_000);

        assertTrue(_contains(p, "DOWN,UP,DOWN,UP,DOWN"), "tail of five");
        assertFalse(_contains(p, "DOWN,UP,DOWN,UP,DOWN,UP"), "no sixth entry");
    }

    function test_prompt_reports_an_empty_history_explicitly() public pure {
        string memory p = PromptLib.build(_market(LucidTypes.ASSET_BTC, 1), 5000, new uint16[](0), EXPIRY - 60, 1);
        assertTrue(_contains(p, "none"), "empty history is stated, not omitted");
    }

    function test_seconds_left_is_zero_once_the_window_has_expired() public pure {
        string memory p = PromptLib.build(_market(LucidTypes.ASSET_BTC, 1), 5000, new uint16[](0), EXPIRY + 10, 1);
        assertTrue(_contains(p, "Seconds to expiry: 0"), "no underflow past expiry");
    }

    // ── the book sentence, and its absence ────────────────────────────────────
    //
    // Measured on the live three-validator committee with everything else held identical: a window
    // +776 bps through the strike with eight seconds left scored a median of 50 while
    // "Book-implied UP probability: 50.00%" was in the prompt, and 95 with that one sentence
    // deleted; the mirror-image bearish window scored 0. The substituted midpoint was not a neutral
    // default, it was the answer. So an empty book now costs the sentence entirely, and the tests
    // below are what stop a helpful placeholder growing back.

    function test_an_observed_book_is_stated_in_full() public pure {
        string memory p =
            PromptLib.build(_market(LucidTypes.ASSET_BTC, 7_988_185), 5123, new uint16[](0), EXPIRY - 60, SPOT);

        assertTrue(
            _contains(p, ". Book-implied UP probability: 51.23%. Recent outcomes:"),
            "a real quote is real evidence and the committee keeps it"
        );
    }

    function test_a_book_quoted_at_zero_is_still_a_quote() public pure {
        // Zero is a claim about the market. The sentinel is the absence of one, and the prompt has
        // to be able to tell them apart or the distinction in `LucidTypes` buys nothing.
        string memory p =
            PromptLib.build(_market(LucidTypes.ASSET_BTC, 7_988_185), 0, new uint16[](0), EXPIRY - 60, SPOT);

        assertTrue(_contains(p, ". Book-implied UP probability: 0.00%"), "somebody quoted zero, so say zero");
    }

    function test_an_unobserved_book_omits_the_sentence_entirely() public pure {
        string memory p = PromptLib.build(
            _market(LucidTypes.ASSET_BTC, 7_988_185), LucidTypes.BOOK_UNOBSERVED, new uint16[](0), EXPIRY - 60, SPOT
        );

        assertFalse(_contains(p, "Book"), "not a sentence, not a label, nothing");
        assertFalse(_contains(p, "50.00%"), "and no midpoint smuggled back in under another name");
        assertFalse(_contains(p, "100.00%"), "the sentinel is never clamped into a plausible percentage");
        assertTrue(_contains(p, "Seconds to expiry: 60. Recent outcomes: none."), "the seam closes cleanly");
    }

    function test_the_two_prompts_differ_by_exactly_the_book_sentence() public pure {
        LucidTypes.MarketInfo memory m = _market(LucidTypes.ASSET_BTC, 7_988_185);
        uint16[] memory outcomes = new uint16[](2);
        outcomes[0] = 1;
        outcomes[1] = 0;

        string memory observed = PromptLib.build(m, 5123, outcomes, EXPIRY - 247, SPOT);
        string memory unobserved = PromptLib.build(m, LucidTypes.BOOK_UNOBSERVED, outcomes, EXPIRY - 247, SPOT);

        // Byte-identical once the one sentence is cut out. The measurement above only means
        // anything if nothing else moved with it.
        assertEq(
            _removeFirst(observed, ". Book-implied UP probability: 51.23%"),
            unobserved,
            "one sentence removed, every other byte unchanged"
        );
    }

    function test_a_value_just_below_the_sentinel_is_still_a_book_reading() public pure {
        // 65534 bps is not "no book", it is a book misread upstream. It is clamped and stated,
        // because the clamp exists for impossible quotes and the omission exists for absent ones,
        // and only one value on the whole number line means absent.
        string memory p = PromptLib.build(
            _market(LucidTypes.ASSET_BTC, 7_988_185),
            uint256(LucidTypes.BOOK_UNOBSERVED) - 1,
            new uint16[](0),
            EXPIRY - 60,
            SPOT
        );

        assertTrue(_contains(p, ". Book-implied UP probability: 100.00%"), "clamped to certainty, not omitted");
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

    /// @dev The haystack with the first occurrence of `needle` cut out, so a test can assert that
    /// two prompts differ by exactly one sentence rather than by "something around there".
    function _removeFirst(string memory haystack, string memory needle) internal pure returns (string memory) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        require(n.length != 0 && n.length <= h.length, "needle does not fit");

        for (uint256 i; i <= h.length - n.length; ++i) {
            uint256 j;
            while (j < n.length && h[i + j] == n[j]) {
                ++j;
            }
            if (j != n.length) continue;

            bytes memory out = new bytes(h.length - n.length);
            for (uint256 k; k < i; ++k) {
                out[k] = h[k];
            }
            for (uint256 k = i + n.length; k < h.length; ++k) {
                out[k - n.length] = h[k];
            }
            return string(out);
        }
        revert("needle not present");
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
