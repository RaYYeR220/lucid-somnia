// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IBinaryPool} from "../../src/interfaces/IDreamDex.sol";

/// @title MockPool
/// @notice A binary CLOB whose top of book the test sets directly.
/// @dev Written to be `vm.etch`ed onto the pool address a real captured `MarketCreated` log points
/// at, so the router reads the book from exactly the address it derived from the log rather than
/// from one the test handed it. Freshly etched code starts with empty storage, which is the
/// empty-book case the venue actually presents most of the time: the recon showed most live
/// windows with zero trades.
contract MockPool is IBinaryPool {
    /// @notice Deliberate failure used by the revert mode.
    error PoolIsDown();

    Level[] internal _bids;
    Level[] internal _asks;
    bool public revertOnBook;

    function setRevertOnBook(bool on) external {
        revertOnBook = on;
    }

    /// @notice Replace one side of the book with a single level.
    /// @param isBid True to set the bid side, false for the ask side.
    /// @param price Raw 6-decimal YES price.
    /// @param quantity Contracts resting at that price.
    function setLevel(bool isBid, uint256 price, uint256 quantity) external {
        Level[] storage side = isBid ? _bids : _asks;
        while (side.length != 0) {
            side.pop();
        }
        side.push(Level({price: price, quantity: quantity}));
    }

    /// @notice Empty both sides.
    function clearBook() external {
        while (_bids.length != 0) {
            _bids.pop();
        }
        while (_asks.length != 0) {
            _asks.pop();
        }
    }

    function getBookLevels(bool isBid, uint64 numLevels) external view returns (Level[] memory levels) {
        if (revertOnBook) revert PoolIsDown();

        Level[] storage side = isBid ? _bids : _asks;
        uint256 n = side.length < numLevels ? side.length : numLevels;
        levels = new Level[](n);
        for (uint256 i; i < n; ++i) {
            levels[i] = side[i];
        }
    }

    // ── the rest of IBinaryPool: present so the mock is substitutable, unused by the router ──

    function mintSet(address, address, uint256) external {}

    function burnSet(uint256) external {}

    function placeBinaryOrder(uint8, uint256, uint256, uint64, uint8, uint8, address, uint96, uint64)
        external
        payable
        returns (bool, uint128)
    {
        return (true, 1);
    }

    function cancelOrder(uint128) external {}

    function reduceOrder(uint128, uint256) external {}

    function getOrderBookParameters() external pure returns (uint256, uint256, uint256) {
        return (1000, 1000, 1000);
    }

    function marketNonce() external pure returns (uint64) {
        return 1;
    }
}
