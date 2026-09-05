// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {LucidTypes} from "../types/LucidTypes.sol";

/// @title PromptLib
/// @notice Turns one Event Contracts window into the text a validator committee is asked to score.
/// @dev Every input is on-chain state, and the function is pure, so two validators reading the same
/// block build byte-identical prompts. That is what makes the committee's scores comparable at all:
/// if the evidence could vary per node, disagreement would say nothing about the market.
library PromptLib {
    /// @dev Older windows stop being evidence quickly; five is enough to show a streak and short
    /// enough to keep the prompt inside a single inference budget.
    uint256 internal constant MAX_OUTCOMES = 5;

    /// @notice Build the committee's prompt for one window.
    /// @param m The market being considered.
    /// @param pBookBps The book-implied UP probability, in bps of probability (10000 = certain).
    /// @param recentOutcomes Past window results, oldest first; any non-zero entry means UP.
    /// @param nowTs The timestamp to measure the remaining window against.
    /// @return The prompt text.
    function build(LucidTypes.MarketInfo memory m, uint256 pBookBps, uint16[] memory recentOutcomes, uint256 nowTs)
        internal
        pure
        returns (string memory)
    {
        uint256 secondsLeft = m.expiry > nowTs ? m.expiry - nowTs : 0;
        // A mid above 100% means the book was misread upstream; clamping keeps that from reaching
        // the committee as an impossible fact it would then reason from.
        uint256 book = pBookBps > LucidTypes.BPS ? LucidTypes.BPS : pBookBps;

        return string.concat(
            "Asset: ",
            assetSymbol(m.assetKey),
            ". Strike: ",
            formatTwoDecimals(m.strike),
            ". Seconds to expiry: ",
            Strings.toString(secondsLeft),
            ". Book-implied UP probability: ",
            formatTwoDecimals(book),
            "%. Recent outcomes: ",
            _outcomes(recentOutcomes),
            "."
        );
    }

    /// @notice Resolve a venue asset hash to its ticker.
    /// @dev An unrecognised asset is named, not hidden: the committee should see that the desk does
    /// not know what it is looking at rather than silently score a market it cannot reason about.
    function assetSymbol(bytes32 assetKey) internal pure returns (string memory) {
        if (assetKey == LucidTypes.ASSET_BTC) return "BTC";
        if (assetKey == LucidTypes.ASSET_ETH) return "ETH";
        return "UNKNOWN";
    }

    /// @notice Render a hundredths-scaled integer as a decimal, e.g. 7988185 becomes "79881.85".
    /// @dev The venue's oracle publishes strikes at two decimal places, and probabilities in bps
    /// carry the same two places once expressed as a percentage, so one formatter serves both.
    function formatTwoDecimals(uint256 value) internal pure returns (string memory) {
        uint256 whole = value / 100;
        uint256 frac = value % 100;
        string memory fracStr = Strings.toString(frac);
        if (frac < 10) fracStr = string.concat("0", fracStr);
        return string.concat(Strings.toString(whole), ".", fracStr);
    }

    /// @dev Renders the tail of the history, oldest first, as UP/DOWN.
    function _outcomes(uint16[] memory recentOutcomes) private pure returns (string memory out) {
        uint256 n = recentOutcomes.length;
        if (n == 0) return "none";

        uint256 start = n > MAX_OUTCOMES ? n - MAX_OUTCOMES : 0;
        for (uint256 i = start; i < n; ++i) {
            if (recentOutcomes[i] == 0) {
                out = string.concat(out, "DOWN");
            } else {
                out = string.concat(out, "UP");
            }
            if (i + 1 < n) out = string.concat(out, ",");
        }
    }
}
