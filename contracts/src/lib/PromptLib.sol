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
    /// @dev Reads only `assetKey`, `strike` and `expiry` off the market. Callers that hold those
    /// three fields but not a whole `MarketInfo` may pass a struct carrying just them and get a
    /// byte-identical prompt.
    /// @param m The market being considered.
    /// @param pBookBps The book-implied UP probability, in bps of probability (10000 = certain).
    /// @param recentOutcomes Past window results, oldest first; any non-zero entry means UP.
    /// @param nowTs The timestamp to measure the remaining window against.
    /// @param spot The asset's current price, in hundredths, on the same scale as the strike.
    /// @return The prompt text.
    function build(
        LucidTypes.MarketInfo memory m,
        uint256 pBookBps,
        uint16[] memory recentOutcomes,
        uint256 nowTs,
        uint256 spot
    ) internal pure returns (string memory) {
        uint256 secondsLeft = m.expiry > nowTs ? m.expiry - nowTs : 0;
        // A mid above 100% means the book was misread upstream; clamping keeps that from reaching
        // the committee as an impossible fact it would then reason from.
        uint256 book = pBookBps > LucidTypes.BPS ? LucidTypes.BPS : pBookBps;

        return string.concat(
            "Asset: ",
            assetSymbol(m.assetKey),
            ". Spot: ",
            formatTwoDecimals(spot),
            ". Strike: ",
            formatTwoDecimals(m.strike),
            ". Distance to strike: ",
            _distance(spot, m.strike),
            ". Seconds to expiry: ",
            Strings.toString(secondsLeft),
            ". Book-implied UP probability: ",
            formatTwoDecimals(book),
            "%. Recent outcomes: ",
            _outcomes(recentOutcomes),
            "."
        );
    }

    /// @notice Signed distance from strike to spot, in basis points of the strike.
    /// @dev Basis points because that is the unit the rest of the protocol already speaks — a
    /// desk's `minEdgeBps` is compared against the same scale — so the prompt and the policy that
    /// judges the answer measure the market in the same way. Division truncates toward zero, which
    /// is symmetric about the strike and therefore introduces no directional bias.
    /// @param spot The current price, in the same scale as the strike.
    /// @param strike The window's opening price.
    /// @return The distance in bps: positive when spot is above the strike, negative below.
    function distanceBps(uint256 spot, uint256 strike) internal pure returns (int256) {
        // A zero strike is a broken market, not an infinitely distant one. The caller renders this
        // as "unknown" rather than as a real reading.
        if (strike == 0) return 0;
        int256 delta = int256(spot) - int256(strike);
        return (delta * int256(uint256(LucidTypes.BPS))) / int256(strike);
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

    /// @dev Renders the distance both ways round because the two readings answer different
    /// questions: the bps figure is what a policy threshold is compared against, and the percent is
    /// the form the number is quoted in everywhere else. Both come from the same on-chain integer,
    /// so the committee is never asked to divide anything itself — a model that does arithmetic in
    /// prose gets it wrong often enough to matter at these distances.
    function _distance(uint256 spot, uint256 strike) private pure returns (string memory) {
        if (strike == 0) return "unknown";

        int256 bps = distanceBps(spot, strike);
        uint256 magnitude = uint256(bps < 0 ? -bps : bps);
        string memory sign = bps < 0 ? "-" : "+";
        // A basis point is one hundredth of a percent, so the same hundredths formatter that
        // renders prices renders the percentage without a second rounding step.
        return string.concat(sign, Strings.toString(magnitude), " bps (", sign, formatTwoDecimals(magnitude), "%)");
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
