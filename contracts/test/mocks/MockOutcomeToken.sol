// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MockOutcomeToken
/// @notice Stands in for OutcomeToken6909 at 0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9.
/// @dev Only the surface a desk touches is modelled. The one property worth reproducing exactly
/// is that approval is per operator and not per id, so a single grant covers every market and
/// both legs forever; the suite uses `operatorGrantsBy` to prove the desk grants it once.
contract MockOutcomeToken {
    error BalanceTooLow();

    /// @notice ERC-6909 balances, keyed by owner then outcome id.
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    /// @notice ERC-6909 operator grants, keyed by owner then spender.
    mapping(address => mapping(address => bool)) public isOperator;

    /// @notice How many `setOperator` calls each account has made.
    mapping(address => uint256) public operatorGrantsBy;

    function setOperator(address spender, bool approved) external returns (bool) {
        operatorGrantsBy[msg.sender] += 1;
        isOperator[msg.sender][spender] = approved;
        return true;
    }

    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool) {
        uint256 bal = balanceOf[msg.sender][id];
        if (bal < amount) revert BalanceTooLow();
        balanceOf[msg.sender][id] = bal - amount;
        balanceOf[receiver][id] += amount;
        return true;
    }

    /// @notice Mint hook used by the pool mock when a buy fills or a complete set is minted.
    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    /// @notice Burn hook used by the module mock when a leg is redeemed.
    function burn(address from, uint256 id, uint256 amount) external {
        uint256 bal = balanceOf[from][id];
        if (bal < amount) revert BalanceTooLow();
        balanceOf[from][id] = bal - amount;
    }
}
