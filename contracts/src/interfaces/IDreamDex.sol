// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The DreamDEX Event Contracts surface a third-party contract needs.
/// Signatures verified against Shannon testnet 50312; selectors noted per function.

/// @dev The per-window central limit order book. Pools are recycled, so never cache one:
/// resolve the pool from the market id every time.
interface IBinaryPool {
    /// @dev 0x54657dd2. Pulls `amount` collateral from msg.sender and mints `amount` of BOTH legs.
    /// Needs no counterparty, which is what makes it usable on an empty book.
    function mintSet(address yesTo, address noTo, uint256 amount) external;

    /// @dev 0x55664dbd. Burns one of each leg back into collateral. Requires setOperator(pool, true).
    function burnSet(uint256 amount) external;

    /// @dev 0x718c2d4d. `price` is ALWAYS the YES-side price, tick-aligned, 0 < price < oneCollateral.
    /// `expireTimestampNs` is mandatory, in nanoseconds, and must not exceed the market expiry.
    /// Returns success=false WITHOUT reverting on a silent rejection — always check it.
    function placeBinaryOrder(
        uint8 kind,
        uint256 price,
        uint256 quantity,
        uint64 expireTimestampNs,
        uint8 orderType,
        uint8 selfMatchingOption,
        address builder,
        uint96 builderFeeBpsTimes1k,
        uint64 userData
    ) external payable returns (bool success, uint128 id);

    /// @dev 0xdbc91396
    function cancelOrder(uint128 orderId) external;

    /// @dev 0x33407b60. Keeps price-time priority.
    function reduceOrder(uint128 orderId, uint256 newQuantityRemaining) external;

    /// @dev 0x0765910c. Live values on Shannon are (1000, 1000, 1000).
    function getOrderBookParameters()
        external
        view
        returns (uint256 tickSize, uint256 minQuantity, uint256 lotSize);

    /// @dev 0x4f1ce9a7
    function getBookLevels(bool isBid, uint64 numLevels)
        external
        view
        returns (Level[] memory levels);

    /// @dev 0xcaa855b3. Starts at 1, increments on every pool recycle.
    function marketNonce() external view returns (uint64);

    struct Level {
        uint256 price;
        uint256 quantity;
    }
}

/// @dev BinaryMarketsModule — the routed entry point and the only creation event carrying
/// (operatorId, venueId).
interface IBinaryModule {
    /// @dev 0x7564912b. The canonical read: everything about a market from its id.
    function markets(bytes32 marketId)
        external
        view
        returns (
            uint256 oracleQuestionId,
            uint8 outcomeSlotCount,
            uint8 voidPolicy,
            address collateral,
            uint32 originOperatorId,
            bytes32 originVenueId,
            address oracleAdapter,
            address creator,
            address market,
            address pool,
            uint256 yesId,
            uint256 noId,
            uint64 tradingStart,
            uint64 expiry
        );

    /// @dev 0x5b1ffcf2. Redeeming a losing leg succeeds and pays zero; it does not revert.
    function redeem(uint32 operatorId, bytes32 venueId, bytes32 marketId, uint8 outcomeIdx, uint256 amount)
        external;

    /// @dev 0x88cb9474
    function redeemMany(
        uint32 operatorId,
        bytes32 venueId,
        bytes32[] calldata marketIds,
        uint8[] calldata outcomeIdxs,
        uint256[] calldata amounts
    ) external;

    /// @dev 0x84f093c0. The only signed struct in the whole surface. Anyone may relay.
    function redeemFor(
        address owner,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig,
        uint32 operatorId,
        bytes32 venueId,
        bytes32 marketId,
        uint8 outcomeIdx,
        uint256 amount
    ) external;

    // ── permissionless upkeep: anyone may call these, and today almost nobody does ──
    /// @dev 0x626cb257
    function finalizeMarket(bytes32 marketId) external;
    /// @dev 0xda8a1461
    function releasePool(bytes32 marketId) external;
    /// @dev 0x687d0a78
    function syncSettlement(bytes32 marketId) external;
    /// @dev 0xbddb5def
    function pokeOracle(uint256 oracleQuestionId) external;
}

/// @dev The per-window market contract.
interface IBinaryMarket {
    /// @dev 0x24427007. Winner is the argmax; winningOutcome() was removed and now reverts.
    function payoutNumerators() external view returns (uint256[] memory);
    /// @dev 0xdbb3f537
    function isResolved() external view returns (bool);
    /// @dev 0x8db3db12
    function isVoided() external view returns (bool);
    /// @dev 0x200d2ed2. 0 Listed · 1 Trading · 2 Locked · 3 Settling · 4 Resolved · 5 Voided
    function status() external view returns (uint8);
    /// @dev 0xe184c9be
    function expiry() external view returns (uint64);
    /// @dev 0xb4a7bdf9
    function settlementWindow() external view returns (uint64);
    /// @dev 0x9f5b5dde. Permissionless once expiry + settlementWindow has passed.
    function voidExpired() external;
}

/// @dev OutcomeToken6909. Approval is per-operator, not per-id: one grant covers every market.
interface IERC6909Min {
    /// @dev 0x558a7297
    function setOperator(address spender, bool approved) external returns (bool);
    /// @dev 0xb6363cf2
    function isOperator(address owner, address spender) external view returns (bool);
    /// @dev 0x00fdd58e
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    /// @dev 0x095bcdb6
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
}

/// @dev tUSDC on Shannon: 6 decimals, and its faucet is callable by contracts.
interface IERC20Faucet {
    /// @dev 0x57915897. Reverts FaucetCapExceeded above 10_000 tUSDC per call.
    function faucet(uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}
