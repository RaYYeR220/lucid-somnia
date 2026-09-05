// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LucidTypes} from "../src/types/LucidTypes.sol";

contract TypesTest is Test {
    /// The router filters the venue's log stream on this exact topic, so a wrong constant
    /// means the desk never wakes up at all.
    function test_marketCreatedTopicMatchesTheLiveVenue() public pure {
        assertEq(LucidTypes.TOPIC_MARKET_CREATED, 0xb5ec75cdb7dbcd28a5f50d152d8833334525a902ef5332ebc19bcf5c0011f8cd);
    }

    function test_scheduleTopicMatchesThePrecompile() public pure {
        assertEq(LucidTypes.TOPIC_SCHEDULE, 0x67aa3d752967d87d8944b9c7adf73172518777fa4703f336edee81f0736d8987);
    }

    function test_assetKeysHashTheVenuesOwnSymbols() public pure {
        assertEq(LucidTypes.ASSET_BTC, keccak256(bytes("BTC")));
        assertEq(LucidTypes.ASSET_ETH, keccak256(bytes("ETH")));
        assertTrue(LucidTypes.ASSET_BTC != LucidTypes.ASSET_ETH);
    }

    function test_oneContractIsSixDecimals() public pure {
        assertEq(LucidTypes.ONE, 1e6);
    }
}
