// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MockCollateral
/// @notice Stands in for Shannon's tUSDC at 0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E.
/// @dev Six decimals, not eighteen: the desk sizes every order in raw collateral units, so a
/// mock with the wrong scale would hide off-by-1e12 errors that the live venue would not.
/// It also counts approvals per caller, because "approve the pool exactly once, ever" is a
/// behaviour the desk suite asserts rather than assumes.
contract MockCollateral {
    /// @notice Faucet call above the live cap of 10 000 tUSDC.
    error FaucetCapExceeded();
    error BalanceTooLow();
    error AllowanceTooLow();

    string public constant name = "Mock tUSDC";
    string public constant symbol = "tUSDC";
    uint8 public constant decimals = 6;

    /// @dev The live faucet reverts above this per call.
    uint256 public constant FAUCET_CAP = 10_000e6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice How many times each account has called `approve`.
    mapping(address => uint256) public approvalsBy;

    /// @notice Testnet faucet, callable by contracts, which is what lets a desk fund itself.
    function faucet(uint256 amount) external {
        if (amount > FAUCET_CAP) revert FaucetCapExceeded();
        _mint(msg.sender, amount);
    }

    /// @notice Test-only shortcut for seeding a balance without the faucet cap.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        approvalsBy[msg.sender] += 1;
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert AllowanceTooLow();
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _mint(address to, uint256 amount) private {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 bal = balanceOf[from];
        if (bal < amount) revert BalanceTooLow();
        balanceOf[from] = bal - amount;
        balanceOf[to] += amount;
    }
}
