// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ExtensionIds
 * @notice Stable identifiers for the extensions this framework defines.
 *
 * @dev These are deliberately **not** `type(IExtension).interfaceId`. An interface ID is a hash over the
 *      function selectors, so adding a single view function to an interface silently changes the ID and
 *      breaks every integrator who cached it. An extension ID has to outlive interface revisions, so it is
 *      derived from a name instead:
 *
 *          id = bytes4(keccak256("erc20.extension.<camelCaseName>"))
 *
 *      The names describe what the extension does. They contain no draft ERC number, because a draft
 *      number is a placeholder that changes on the way to Final and would take every deployed token's
 *      identifiers with it.
 */
library ExtensionIds {
    /// @notice Enumerable on-chain key/value metadata, with an ERC-1046 `tokenURI` as a secondary source.
    bytes4 internal constant ONCHAIN_METADATA = bytes4(keccak256("erc20.extension.onchainMetadata"));

    /// @notice A pre-computable, capped fee withheld from every transfer.
    bytes4 internal constant TRANSFER_FEE = bytes4(keccak256("erc20.extension.transferFee"));

    /// @notice ERC-1404 style transfer restrictions: pause and per-account freeze.
    bytes4 internal constant TRANSFER_RESTRICTION = bytes4(keccak256("erc20.extension.transferRestriction"));

    /// @notice Transfers between non-zero addresses always revert.
    bytes4 internal constant NON_TRANSFERABLE = bytes4(keccak256("erc20.extension.nonTransferable"));

    /// @notice A gas-bounded call into a policy contract after every transfer.
    bytes4 internal constant TRANSFER_HOOK = bytes4(keccak256("erc20.extension.transferHook"));
}
