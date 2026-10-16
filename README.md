# State Encryption (STATE)

A fixed-supply ERC-20 token for an IdentityMD custom-token launch on Ethereum.

| Parameter        | Value                                        |
|------------------|----------------------------------------------|
| Solidity contract| `StateToken` (`src/StateToken.sol`)          |
| `name()`         | `State Encryption`                           |
| `symbol()`       | `STATE`                                      |
| `decimals()`     | 18                                           |
| Total supply     | 1,000,000 STATE = `1000000000000000000000000` minor units |
| Constructor args | none                                         |
| Owner / admin    | none                                         |
| Compiler         | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"` |

## Behaviour

- The constructor mints the whole supply of 1,000,000 STATE once, to `msg.sender`, and emits the
  standard `Transfer(address(0), msg.sender, supply)` event. On the launch `msg.sender` is the
  IdentityMD ProjectFactory, which pays the supply out (swarm share, pool seed, remainder).
- `totalSupply()` is a compile-time constant. There is no `mint`, `burn`, `burnFrom`, owner,
  minter role, pause, blocklist, freeze, fee, tax, reflection, upgrade hook or `receive()`.
  Nothing can grow or shrink the supply, and no party can move or freeze a holder's balance.
- Transfers move exactly the amount requested for every caller. The factory, the pool manager and
  the Merkle distributor need no exemption because nothing is ever deducted.
- Standard EIP-20 surface: `transfer`, `approve`, `transferFrom`, `allowance`, `balanceOf`,
  plus `increaseAllowance` / `decreaseAllowance` for safe allowance adjustment. An allowance of
  `type(uint256).max` is treated as unlimited and is not decremented.
- Reverts use custom errors: `ZeroAddress()` (transfer or approve to `address(0)`),
  `InsufficientBalance(from, balance, needed)` and `InsufficientAllowance(spender, allowance, needed)`.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, and there are no
  external library calls, so the bytecode is fully linked and reproducible.

## Assumptions

- The brief asks for a plain fixed-supply token with no transfer rules, so none were added.
  Anything beyond EIP-20 (permit, votes, burn) is deliberately out of scope.
- The deployer is whoever sends the creation transaction. The constructor takes no owner argument
  because the contract has no owner to assign; `$owner` is not needed in the manifest.
- The constructor calls no other contract and requires nothing to exist on chain, so it deploys
  on an empty chain and through CREATE2 from the factory.
- The well-known EIP-20 `approve` race (changing a non-zero allowance to another non-zero value)
  is inherent to the standard; integrators should use `increaseAllowance` / `decreaseAllowance`
  or set the allowance to zero first.

## Deployment parameters

The launch is performed by IdentityMD's deployer through the ProjectFactory; this repository
does not deploy, broadcast or hold keys. Values the manifest step will use:

- Chain: Ethereum mainnet (chain id 1).
- Token contract name: `StateToken`; `constructorArgs`: `[]`; `decimals`: 18;
  `totalSupply`: `1000000000000000000000000`.
- Application contracts: none.
- Pool: paired with IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), fee 12500 (1.25%),
  tick spacing 60, initial price `79228162514264337593543950336` (provenance only; the deployer
  derives the opening price from the market cap).
- Economics (copied verbatim from the job): `poolBps` 8800, `initialMarketCapWei`
  `2500000000000000000000` (2,500 IMD), `remainderTo` `0x7fa42b3818cf074169acacfb75880531aaef3303`.

The whole supply is minted to the factory. The factory forwards 10% to the launch's
MerkleDistributor, seeds the pool with 88% single-sided, and sends the remaining 2% to
`remainderTo`. No contract in this repository is allocated any of it.

`script/DeployStateToken.s.sol` exposes `deploy()` for tests and for any manual deployment
outside the launch. Its `run()` broadcasts with whatever sender the `forge script` invocation
chooses; the script itself reads no environment variables.

## After launch

There are no owner-settable values. Nothing needs to be configured, and nobody can change the
token after deployment.

## Operational responsibilities

- Holders: the token has no recovery path. Tokens sent to a wrong address, or approvals granted
  to a malicious spender, cannot be undone by anyone. Keep approvals bounded.
- Launch deployer (IdentityMD): deploy the attested bytecode through the factory, verify the
  source on the block explorer, and distribute the supply per the manifest. These are open items
  for the deployer; this task does not perform them.
- Requester: nothing to operate. The contract has no admin and cannot be paused or upgraded.
  This is a trust assumption in the holders' favour: no privileged party exists.

## Security notes

Checked against the eth-security reference checklist for this task:

- No external calls, so no reentrancy surface.
- Checked arithmetic everywhere except two `unchecked` blocks that are guarded immediately
  above (balance and allowance subtraction after an explicit comparison).
- Zero-address transfers and approvals revert.
- No owner, no proxy, no delegatecall, no selfdestruct, no `tx.origin`, no timestamps.
- Every function returns the EIP-20 `bool`, so SafeERC20 wrappers work but are not required.

Tools run: `forge build`, `forge test` (with the verifier's fuzz seed), `forge fmt --check`.
Slither and Mythril were not available in this environment and did not run. Passing tests are not
an audit; an independent adversarial review is still recommended before relying on the contract
for third-party funds.

## Layout

```
foundry.toml                  solc 0.8.26, bytecode_hash = "none", no ffi / fs access
remappings.txt                forge-std/=lib/forge-std/src/
src/StateToken.sol            the token
script/DeployStateToken.s.sol deploy() + run()
test/StateToken.t.sol         33 unit and fuzz tests (success and failure paths)
lib/forge-std/                forge-std v1.9.7, vendored as plain files (MIT/Apache-2.0)
```

## Build and test

```
forge build
forge test
forge fmt --check
```
