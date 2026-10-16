// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title State Encryption (STATE)
/// @notice A fixed-supply ERC-20 token. The whole supply of 1,000,000 STATE (18 decimals) is minted
///         once, in the constructor, to the deployer (`msg.sender`). There is no owner, no minter,
///         no pause, no blocklist and no fee: after deployment the contract has no privileged party
///         and the supply can never grow.
/// @dev Self-contained ERC-20 (EIP-20) implementation with no external dependencies. The contract
///      name is `StateToken`; the token's metadata is returned by `name()` and `symbol()`.
contract StateToken {
    // ---------------------------------------------------------------------------------------------
    // Token constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Number of decimals, fixed at 18.
    uint8 public constant DECIMALS = 18;

    /// @notice Whole-token supply before scaling by decimals.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000;

    /// @notice Total supply in minor units: 1,000,000 * 10^18. Minted once, never again.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** uint256(DECIMALS);

    // ---------------------------------------------------------------------------------------------
    // Events (EIP-20)
    // ---------------------------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @notice Transfers to and approvals of the zero address are refused so tokens cannot be lost
    ///         by accident and allowances cannot be granted to nobody.
    error ZeroAddress();
    /// @notice The sender holds less than the amount it tried to move.
    error InsufficientBalance(address from, uint256 balance, uint256 needed);
    /// @notice The spender's allowance from the owner is less than the amount it tried to move.
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    mapping(address account => uint256) private _balances;
    mapping(address owner => mapping(address spender => uint256)) private _allowances;

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @notice Mints the entire fixed supply to the deployer. This is the only mint that ever happens.
    /// @dev Takes no arguments and calls no other contract, so it deploys on an empty chain.
    constructor() {
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata
    // ---------------------------------------------------------------------------------------------

    /// @notice The token's name.
    function name() public pure returns (string memory) {
        return "State Encryption";
    }

    /// @notice The token's symbol.
    function symbol() public pure returns (string memory) {
        return "STATE";
    }

    /// @notice The token's decimals.
    function decimals() public pure returns (uint8) {
        return DECIMALS;
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The total supply. Constant for the life of the contract: nothing mints or burns.
    function totalSupply() public pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @notice The balance held by `account`.
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    /// @notice The amount `spender` may still move on behalf of `owner`.
    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers and approvals
    // ---------------------------------------------------------------------------------------------

    /// @notice Moves `amount` from the caller to `to`.
    /// @return Always true; failures revert.
    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to exactly `amount`.
    /// @dev Setting a new non-zero allowance over an existing one carries the well-known EIP-20
    ///      front-running caveat; use `increaseAllowance`/`decreaseAllowance` to adjust safely.
    /// @return Always true; failures revert.
    function approve(address spender, uint256 amount) public returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Raises the caller's allowance for `spender` by `added`.
    /// @return Always true; failures revert.
    function increaseAllowance(address spender, uint256 added) public returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender] + added);
        return true;
    }

    /// @notice Lowers the caller's allowance for `spender` by `subtracted`.
    /// @dev Reverts with `InsufficientAllowance` when the current allowance is below `subtracted`.
    /// @return Always true; failures revert.
    function decreaseAllowance(address spender, uint256 subtracted) public returns (bool) {
        uint256 current = _allowances[msg.sender][spender];
        if (current < subtracted) revert InsufficientAllowance(spender, current, subtracted);
        unchecked {
            _approve(msg.sender, spender, current - subtracted);
        }
        return true;
    }

    /// @notice Moves `amount` from `from` to `to` using the caller's allowance from `from`.
    /// @dev An allowance of `type(uint256).max` is treated as unlimited and is not decremented.
    /// @return Always true; failures revert.
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            // Cannot underflow: checked above. Cannot overflow: the sum of all balances is TOTAL_SUPPLY.
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (spender == address(0)) revert ZeroAddress();
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 current = _allowances[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance(spender, current, amount);
        unchecked {
            _allowances[owner][spender] = current - amount;
        }
        emit Approval(owner, spender, current - amount);
    }
}
