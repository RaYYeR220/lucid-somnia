// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LucidTypes} from "../types/LucidTypes.sol";

/// @title MarketDecoder
/// @notice Turns a raw `BinaryMarketsModule.MarketCreated` log into a `LucidTypes.MarketInfo`.
/// @dev The Somnia Reactivity precompile hands a subscriber the log split into its raw parts
/// (`topics` + `data`) rather than ABI-decoded arguments, so this is the only seam where the
/// venue's event layout is interpreted. Keeping it in one pure library means the layout can be
/// pinned against real captured logs in tests instead of trusted at runtime.
library MarketDecoder {
    /// @notice A `MarketCreated` log always carries exactly four topics: the signature plus
    /// three indexed fields.
    /// @param got The number of topics that were supplied.
    error TopicCountMismatch(uint256 got);

    /// @notice `topics[0]` did not match `MarketCreated`.
    /// @param topic0 The event signature that was supplied.
    error UnexpectedEvent(bytes32 topic0);

    /// @notice Decode one `MarketCreated` log.
    /// @dev Reverts rather than returning a zeroed struct on a foreign log: a router that
    /// silently accepted the wrong event would key desk state by a meaningless `marketId`.
    /// @param topics The log's topic array: `[signature, marketId, market, pool]`.
    /// @param data The log's non-indexed body, ABI-encoded as `LucidTypes.MarketCreatedData`.
    /// @return m The window described by the log, with `assetKey` and `intervalSec` derived.
    function decode(bytes32[] calldata topics, bytes calldata data)
        internal
        pure
        returns (LucidTypes.MarketInfo memory m)
    {
        if (topics.length != 4) revert TopicCountMismatch(topics.length);
        if (topics[0] != LucidTypes.TOPIC_MARKET_CREATED) revert UnexpectedEvent(topics[0]);

        // The body has 17 fields, three of them dynamic; decoding into named locals overflows
        // the stack, so it goes straight into the struct.
        //
        // The prefix word is load-bearing. `abi.decode(x, (T))` reads `x` as the encoding of the
        // one-element tuple `(T)`, and because `MarketCreatedData` is dynamic (it holds two
        // strings and a bytes) that encoding starts with an offset to the struct. Log data is the
        // bare tuple of non-indexed arguments with no such offset, so the decoder has to be handed
        // one. Without it every real log reverts.
        LucidTypes.MarketCreatedData memory d =
            abi.decode(bytes.concat(bytes32(uint256(0x20)), data), (LucidTypes.MarketCreatedData));

        m.marketId = topics[1];
        m.market = address(uint160(uint256(topics[2])));
        m.pool = address(uint160(uint256(topics[3])));

        m.operatorId = d.operatorId;
        m.venueId = d.venueId;
        m.yesId = d.yesId;
        m.noId = d.noId;
        m.tradingStart = d.tradingStart;
        m.expiry = d.expiry;
        m.nonce = d.nonce;
        m.strike = d.strike;

        // The asset arrives as a string ("BTC", "ETH"). Hashing it once here lets every
        // downstream comparison be a single word check against LucidTypes.ASSET_*.
        m.assetKey = keccak256(bytes(d.asset));

        // The venue never emits expiry <= tradingStart; if it ever did, the subtraction
        // underflowing is the correct outcome — a zero-or-negative window is not tradeable.
        m.intervalSec = uint32(d.expiry - d.tradingStart);
    }
}
