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
 *          id = bytes4(keccak256("erc721.extension.<camelCaseName>"))
 *
 *      The names describe what the extension does. They contain no draft ERC number, because a draft
 *      number is a placeholder that changes on the way to Final and would take every deployed token's
 *      identifiers with it.
 *
 *      The token type is part of the name, so `nonTransferable` on an ERC-20 and on an ERC-721 are
 *      different identifiers. They have to be: the modules take different arguments, hold different
 *      storage, and an integrator resolving an ID against the wrong token type would read a configuration
 *      that does not exist. The shared vocabulary is {BehaviorFlags}, which describes *behaviour*; these
 *      identify *code*, and code does not cross token types.
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

    // -----------------------------------------------------------------------------------------------
    // ERC-721
    // -----------------------------------------------------------------------------------------------

    /// @notice A transfer made by an operator is screened against a policy naming that operator.
    bytes4 internal constant NFT_OPERATOR_RESTRICTION = bytes4(keccak256("erc721.extension.operatorRestriction"));

    /// @notice Transfers between non-zero addresses always revert; only mint and burn move a token.
    bytes4 internal constant NFT_NON_TRANSFERABLE = bytes4(keccak256("erc721.extension.nonTransferable"));

    /// @notice ERC-1404 style transfer restrictions: pause and per-account freeze.
    bytes4 internal constant NFT_TRANSFER_RESTRICTION = bytes4(keccak256("erc721.extension.transferRestriction"));

    /// @notice A `tokenURI` an authority can rewrite, until it freezes the collection permanently.
    bytes4 internal constant NFT_MUTABLE_METADATA = bytes4(keccak256("erc721.extension.mutableMetadata"));
}
