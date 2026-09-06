// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title LucidTypes
/// @notice Shared enums, structs and protocol constants. No logic lives here.
library LucidTypes {
    /// @notice Why a desk declined to trade. `None` is the only value that permits execution.
    /// @dev New reasons are APPENDED, never inserted. The deployed contracts and the front end
    /// already speak the numbers below, and a renumbering would silently retitle every refusal in
    /// every log line ever emitted — the one change that cannot be noticed from the outside.
    enum Refusal {
        None,
        NotArmed,
        AssetNotAllowed,
        CadenceNotAllowed,
        WindowTooShort,
        CapExceeded,
        DailyBudgetExceeded,
        MaxOpenReached,
        RiskHalt,
        AiUnavailable,
        AiMalformed,
        LowEdge,
        VenueRejected,
        NoCredit,
        InsufficientFunds,
        NoBook
    }

    /// @dev What a book-probability field carries when there was no book to read.
    ///
    /// A probability is a number between 0 and `BPS`, so every value in that range is a claim about
    /// what the market quoted. An empty book is not a claim; it is the absence of one, and rendering
    /// it as `BPS / 2` would put a price nobody quoted into the log next to prices somebody did.
    /// This sentinel sits outside the probability range on purpose: a reader that does not know
    /// about it sees an obviously impossible number rather than a plausible lie, and a reader that
    /// does can tell "no book" apart from "book at 0%".
    uint16 internal constant BOOK_UNOBSERVED = type(uint16).max;

    /// @notice Which execution style a desk runs.
    /// AiEdge takes liquidity when the committee disagrees with the book.
    /// Maker mints a complete set and rests both legs, which needs no counterparty at all.
    enum Strategy {
        AiEdge,
        Maker
    }

    /// @notice The rules a desk owner sets once and the contract enforces forever.
    struct Policy {
        uint64 maxStakePerWindow;
        uint64 dailyBudget;
        uint16 maxOpenMarkets;
        uint16 maxDrawdownBps;
        uint8 maxConsecutiveLosses;
        uint16 minEdgeBps;
        uint32 allowedAssets;
        uint32 allowedCadences;
        uint8 strategy;
        bool armed;
    }

    /// @notice Mutable per-desk risk accounting.
    struct DeskState {
        uint64 dayKey;
        uint64 spentToday;
        uint64 highWaterMark;
        uint16 openMarkets;
        uint8 consecutiveLosses;
    }

    /// @notice Everything about one Event Contracts window that a desk needs.
    struct MarketInfo {
        bytes32 marketId;
        address market;
        address pool;
        uint32 operatorId;
        bytes32 venueId;
        uint256 yesId;
        uint256 noId;
        uint64 tradingStart;
        uint64 expiry;
        uint64 nonce;
        uint256 strike;
        bytes32 assetKey;
        uint32 intervalSec;
    }

    /// @notice The agent committee's answer, reduced to a probability plus how it was reached.
    struct Verdict {
        uint16 probUpBps;
        uint8 responded;
        uint8 agreed;
        bool ok;
        uint256 requestId;
    }

    /// @notice Non-indexed body of BinaryMarketsModule.MarketCreated, in exact field order.
    struct MarketCreatedData {
        uint256 oracleQuestionId;
        uint32 operatorId;
        bytes32 venueId;
        address creator;
        address collateral;
        uint256 yesId;
        uint256 noId;
        uint64 nonce;
        uint8 outcomeSlotCount;
        uint8 marketType;
        uint64 tradingStart;
        uint64 expiry;
        uint8 voidPolicy;
        string asset;
        uint256 strike;
        string question;
        bytes context;
    }

    /// @dev One contract, in raw collateral units (tUSDC has 6 decimals).
    uint256 internal constant ONE = 1e6;
    /// @dev Probability scale used everywhere in this codebase.
    uint16 internal constant BPS = 10_000;
    /// @dev A market must have at least this long left before a desk will touch it.
    /// The public indexer lags, and a stale row makes placeBinaryOrder revert OrderAlreadyExpired.
    uint64 internal constant MIN_WINDOW_SLACK = 90;

    bytes32 internal constant ASSET_BTC = keccak256("BTC");
    bytes32 internal constant ASSET_ETH = keccak256("ETH");

    /// @dev BinaryMarketsModule.MarketCreated
    bytes32 internal constant TOPIC_MARKET_CREATED = keccak256(
        "MarketCreated(bytes32,address,address,uint256,uint32,bytes32,address,address,uint256,uint256,uint64,uint8,uint8,uint64,uint64,uint8,string,uint256,string,bytes)"
    );
    /// @dev ISomniaReactivityPrecompile.Schedule
    bytes32 internal constant TOPIC_SCHEDULE = keccak256("Schedule(uint256)");

    // ── DreamDEX Event Contracts, Somnia Shannon testnet 50312 ────────────────
    address internal constant MODULE = 0x3ecC694Cef705358864a646142ac17A90E29e388;
    address internal constant SETTLEMENT = 0xbF4a49e0Dfd092e5FBE8E5761064C49533e6Ed23;
    address internal constant OUTCOME_TOKEN = 0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9;
    address internal constant MARKETS_CORE = 0x2802504314685D89bF6C992CA5a8e7cC78bc0294;
    address internal constant ORACLE_HUB = 0xe40db387cC98601Dd11bd634fF2f3AD5686dE32b;
    address internal constant COLLATERAL = 0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E;

    // ── placeBinaryOrder enums ────────────────────────────────────────────────
    uint8 internal constant BUY_YES = 0;
    uint8 internal constant SELL_YES = 1;
    uint8 internal constant BUY_NO = 2;
    uint8 internal constant SELL_NO = 3;

    uint8 internal constant ORDER_LIMIT = 0;
    uint8 internal constant ORDER_FOK = 1;
    uint8 internal constant ORDER_MARKET = 2;
    uint8 internal constant ORDER_POST_ONLY = 3;
}
