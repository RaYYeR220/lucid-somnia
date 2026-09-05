// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MarketDecoder} from "../src/lib/MarketDecoder.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";

/// @dev `MarketDecoder` is an internal library, so it has no callable ABI of its own.
/// Routing through a deployed contract is what forces the `calldata` slicing path that
/// production actually takes, instead of the memory path an in-test call would use.
contract DecoderHarness {
    function decode(bytes32[] calldata topics, bytes calldata data)
        external
        pure
        returns (LucidTypes.MarketInfo memory)
    {
        return MarketDecoder.decode(topics, data);
    }
}

/// @title MarketDecoderTest
/// @notice Every fixture below is a verbatim `MarketCreated` log lifted off Somnia Shannon
/// testnet (chain 50312), not a hand-rolled encoding, so a silent field-order drift in
/// `BinaryMarketsModule` shows up here as a failing assertion rather than in production.
///
/// Fixture provenance — both logs come from one transaction, so the venue emitted them
/// for the same 60-second window:
///   block    480739596
///   tx       0x5d1cf9cea46cdaaf4231c5c41235d616f0dfe91ffc67dd19fc6ca8404c8c7822
///   logIndex 91  (BTC, marketId 0x14898)
///   logIndex 113 (ETH, marketId 0x14899)
/// Re-verify with:
///   cast logs --address 0x3ecC694Cef705358864a646142ac17A90E29e388 \
///     0xb5ec75cdb7dbcd28a5f50d152d8833334525a902ef5332ebc19bcf5c0011f8cd \
///     --from-block 480739596 --to-block 480739596 \
///     --rpc-url https://api.infra.testnet.somnia.network --json
/// Cross-checked field-by-field against the public indexer at
/// https://dev.smk.somnia.host/v1/graphql (Market.marketId / poolAddress / asset /
/// operatorId / venueId / yesTokenId / noTokenId / tradingStart / expiry / nonce / strike).
contract MarketDecoderTest is Test {
    DecoderHarness internal harness;

    // ── BTC window, marketId 0x14898 ──────────────────────────────────────────
    bytes32 internal constant BTC_MARKET_ID = bytes32(uint256(0x14898));
    address internal constant BTC_MARKET = 0xc7B7f71513EAF972B9Ff6C0DDb6144E322bA63B0;
    address internal constant BTC_POOL = 0xcc2c4f74C8c3Dd5684EE2e18B1eb8fB1952fb308;
    uint256 internal constant BTC_YES_ID = 5504495547312190195319177961967947372303061094964355023905059567085312;
    uint256 internal constant BTC_NO_ID = 5504495547312190195319177961967947372303061094964355023905059567085313;

    // ── ETH window, marketId 0x14899 ──────────────────────────────────────────
    bytes32 internal constant ETH_MARKET_ID = bytes32(uint256(0x14899));
    address internal constant ETH_MARKET = 0xe7a6118ebCd087f41B9308abff545F0cdC6Bac7c;
    address internal constant ETH_POOL = 0x56154C18cf0e7E601919b13c7478747398AA5057;
    uint256 internal constant ETH_YES_ID = 2320798275952812330975716786824727824296094161206346751391597045435392;
    uint256 internal constant ETH_NO_ID = 2320798275952812330975716786824727824296094161206346751391597045435393;

    // Shared across both fixtures: same venue, same window boundaries.
    bytes32 internal constant VENUE_ID = 0x1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f;
    uint64 internal constant TRADING_START = 1_788_647_100;
    uint64 internal constant EXPIRY = 1_788_647_160;

    function setUp() public {
        harness = new DecoderHarness();
    }

    function test_decodes_real_btc_log() public view {
        LucidTypes.MarketInfo memory m = harness.decode(_btcTopics(), _btcData());

        assertEq(m.marketId, BTC_MARKET_ID, "marketId");
        assertEq(m.market, BTC_MARKET, "market");
        assertEq(m.pool, BTC_POOL, "pool");
        assertEq(m.operatorId, 4, "operatorId");
        assertEq(m.venueId, VENUE_ID, "venueId");
        assertEq(m.yesId, BTC_YES_ID, "yesId");
        assertEq(m.noId, BTC_NO_ID, "noId");
        assertEq(m.tradingStart, TRADING_START, "tradingStart");
        assertEq(m.expiry, EXPIRY, "expiry");
        assertEq(m.nonce, 167, "nonce");
        assertEq(m.strike, 7_986_975, "strike");
        assertEq(m.assetKey, LucidTypes.ASSET_BTC, "assetKey");
        assertEq(m.intervalSec, uint32(EXPIRY - TRADING_START), "intervalSec");
        assertEq(m.intervalSec, 60, "the venue's shortest cadence");
    }

    function test_decodes_real_eth_log() public view {
        LucidTypes.MarketInfo memory m = harness.decode(_ethTopics(), _ethData());

        assertEq(m.marketId, ETH_MARKET_ID, "marketId");
        assertEq(m.market, ETH_MARKET, "market");
        assertEq(m.pool, ETH_POOL, "pool");
        assertEq(m.operatorId, 4, "operatorId");
        assertEq(m.venueId, VENUE_ID, "venueId");
        assertEq(m.yesId, ETH_YES_ID, "yesId");
        assertEq(m.noId, ETH_NO_ID, "noId");
        assertEq(m.tradingStart, TRADING_START, "tradingStart");
        assertEq(m.expiry, EXPIRY, "expiry");
        assertEq(m.nonce, 844, "nonce");
        assertEq(m.strike, 248_404, "strike");
        assertEq(m.assetKey, LucidTypes.ASSET_ETH, "assetKey");
        assertEq(m.intervalSec, uint32(EXPIRY - TRADING_START), "intervalSec");
        assertEq(m.intervalSec, 60, "the venue's shortest cadence");
    }

    /// @dev The two assets differ in every identity field, so a decoder that accidentally
    /// read a constant offset would pass one fixture and fail the other.
    function test_btc_and_eth_decode_to_distinct_markets() public view {
        LucidTypes.MarketInfo memory btc = harness.decode(_btcTopics(), _btcData());
        LucidTypes.MarketInfo memory eth = harness.decode(_ethTopics(), _ethData());

        assertTrue(btc.marketId != eth.marketId, "marketId");
        assertTrue(btc.pool != eth.pool, "pool");
        assertTrue(btc.yesId != eth.yesId, "yesId");
        assertTrue(btc.assetKey != eth.assetKey, "assetKey");
        assertEq(btc.venueId, eth.venueId, "same venue");
    }

    function test_rejects_too_few_topics() public {
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = LucidTypes.TOPIC_MARKET_CREATED;

        vm.expectRevert(abi.encodeWithSelector(MarketDecoder.TopicCountMismatch.selector, uint256(3)));
        harness.decode(topics, _btcData());
    }

    function test_rejects_too_many_topics() public {
        bytes32[] memory topics = new bytes32[](5);
        topics[0] = LucidTypes.TOPIC_MARKET_CREATED;

        vm.expectRevert(abi.encodeWithSelector(MarketDecoder.TopicCountMismatch.selector, uint256(5)));
        harness.decode(topics, _btcData());
    }

    function test_rejects_foreign_event_signature() public {
        bytes32[] memory topics = _btcTopics();
        topics[0] = LucidTypes.TOPIC_SCHEDULE;

        vm.expectRevert(abi.encodeWithSelector(MarketDecoder.UnexpectedEvent.selector, LucidTypes.TOPIC_SCHEDULE));
        harness.decode(topics, _btcData());
    }

    /// @dev topic0 is checked before the body is touched, so garbage data must not mask
    /// the signature error with a decode panic.
    function test_signature_is_checked_before_the_body() public {
        bytes32[] memory topics = _btcTopics();
        topics[0] = bytes32(0);

        vm.expectRevert(abi.encodeWithSelector(MarketDecoder.UnexpectedEvent.selector, bytes32(0)));
        harness.decode(topics, hex"deadbeef");
    }

    // ── fixtures ──────────────────────────────────────────────────────────────

    function _btcTopics() internal pure returns (bytes32[] memory topics) {
        topics = new bytes32[](4);
        topics[0] = LucidTypes.TOPIC_MARKET_CREATED;
        topics[1] = 0x0000000000000000000000000000000000000000000000000000000000014898;
        topics[2] = 0x000000000000000000000000c7b7f71513eaf972b9ff6c0ddb6144e322ba63b0;
        topics[3] = 0x000000000000000000000000cc2c4f74c8c3dd5684ee2e18b1eb8fb1952fb308;
    }

    function _ethTopics() internal pure returns (bytes32[] memory topics) {
        topics = new bytes32[](4);
        topics[0] = LucidTypes.TOPIC_MARKET_CREATED;
        topics[1] = 0x0000000000000000000000000000000000000000000000000000000000014899;
        topics[2] = 0x000000000000000000000000e7a6118ebcd087f41b9308abff545f0cdc6bac7c;
        topics[3] = 0x00000000000000000000000056154c18cf0e7e601919b13c7478747398aa5057;
    }

    function _btcData() internal pure returns (bytes memory) {
        return hex"95cc7af87c01e66a3bfa3feb6f3f39812bc4923d655d1524bcf534abf6d84b04"
            hex"0000000000000000000000000000000000000000000000000000000000000004"
            hex"1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f"
            hex"000000000000000000000000ee3aff92812a2cb7bf801b500687bc97b55cab34"
            hex"00000000000000000000000070a86d8842fb63c4ad2b7cdddf530ebf1bb25d8e"
            hex"000000cc2c4f74c8c3dd5684ee2e18b1eb8fb1952fb30800000000000000a700"
            hex"000000cc2c4f74c8c3dd5684ee2e18b1eb8fb1952fb30800000000000000a701"
            hex"00000000000000000000000000000000000000000000000000000000000000a7"
            hex"0000000000000000000000000000000000000000000000000000000000000002"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"000000000000000000000000000000000000000000000000000000006a9c96bc"
            hex"000000000000000000000000000000000000000000000000000000006a9c96f8"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000220"
            hex"000000000000000000000000000000000000000000000000000000000079df1f"
            hex"0000000000000000000000000000000000000000000000000000000000000260"
            hex"00000000000000000000000000000000000000000000000000000000000002e0"
            hex"0000000000000000000000000000000000000000000000000000000000000003"
            hex"4254430000000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000056"
            hex"50726963656665656420746573743a2077696c6c204254432f55534443277320"
            hex"7072696365206265206174206f722061626f76652037393836392e3735206174"
            hex"20756e69782074696d6520313738383634373136303f00000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000000";
    }

    function _ethData() internal pure returns (bytes memory) {
        return hex"830641a37e0be8d9dd46ce6ff2bb8327e913b603966c14190a9cadbba7e00352"
            hex"0000000000000000000000000000000000000000000000000000000000000004"
            hex"1a1e6821cde7d0159c0d293177871e09677b4e42307c7db3ba94f8648a5a050f"
            hex"000000000000000000000000ee3aff92812a2cb7bf801b500687bc97b55cab34"
            hex"00000000000000000000000070a86d8842fb63c4ad2b7cdddf530ebf1bb25d8e"
            hex"00000056154c18cf0e7e601919b13c7478747398aa5057000000000000034c00"
            hex"00000056154c18cf0e7e601919b13c7478747398aa5057000000000000034c01"
            hex"000000000000000000000000000000000000000000000000000000000000034c"
            hex"0000000000000000000000000000000000000000000000000000000000000002"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"000000000000000000000000000000000000000000000000000000006a9c96bc"
            hex"000000000000000000000000000000000000000000000000000000006a9c96f8"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000220"
            hex"000000000000000000000000000000000000000000000000000000000003ca54"
            hex"0000000000000000000000000000000000000000000000000000000000000260"
            hex"00000000000000000000000000000000000000000000000000000000000002e0"
            hex"0000000000000000000000000000000000000000000000000000000000000003"
            hex"4554480000000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000055"
            hex"50726963656665656420746573743a2077696c6c204554482f55534443277320"
            hex"7072696365206265206174206f722061626f766520323438342e303420617420"
            hex"756e69782074696d6520313738383634373136303f0000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000000";
    }
}
