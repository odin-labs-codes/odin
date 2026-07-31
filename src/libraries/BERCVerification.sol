// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title BERCVerification
 * @notice Decides whether a token runs known code, by reading the token's bytecode. No calls, no registry.
 *
 * @dev Everything else in this framework asks the token to describe itself. `behaviorFlags()` is a claim,
 *      `extensions()` is a claim, and a token that charges a fee while reporting none is simply a token that
 *      lied. That is tolerable for discovery — a claim is still better than the silence a plain ERC-20 gives
 *      you — but it is not a foundation to put money on.
 *
 *      This library removes the token's opinion from the answer. Every canonical BERC token is an EIP-1167
 *      minimal proxy delegating to one shared runtime, and a minimal proxy has no behaviour of its own: its
 *      45 bytes are a fixed prologue, the implementation address, and a fixed epilogue. There is nowhere in
 *      those bytes to hide anything. So if the code matches the pattern and the embedded address is the
 *      canonical runtime, then the token's code *is* the runtime's code, and the claims it makes afterwards
 *      are made by the runtime the caller vetted rather than by the token's author. What this establishes
 *      is identity, not quality: it is worth exactly as much as the review behind the runtime address the
 *      caller chose to pin.
 *
 *      ## Why not a registry
 *
 *      A registry answers the same question with a `staticcall`, which means the answer is only as
 *      trustworthy as the registry's write path. Give the registry an owner and the owner can forge entries;
 *      give it none and it can never learn about a second runtime. The bytecode has no such problem: it is
 *      already on chain, it needs no governance, and it keeps working when the registry is unreachable,
 *      misconfigured, or hostile. {BERCFactoryV1} still keeps an index, but as a way to enumerate tokens,
 *      not as a thing to trust.
 *
 *      ## The answer is stable, so cache it
 *
 *      A minimal proxy contains no `SELFDESTRUCT`, and since EIP-6780 an account can only be destroyed in
 *      the transaction that created it. A token that verifies at one block therefore verifies at every later
 *      block, and integrators can resolve a token once and cache the result permanently.
 *
 *      ## What a pass does and does not mean
 *
 *      A pass means the token executes the given runtime's code. It says nothing about how that runtime is
 *      configured: a verified token can still charge the maximum fee, be paused, or have every holder
 *      frozen. Verification tells you the rules are the published ones, not that you will like them. Read
 *      `behaviorFlags()` afterwards — the point is that now you can believe it.
 */
library BERCVerification {
    /// @dev Runtime length of an EIP-1167 minimal proxy: 10-byte prologue, 20-byte address, 15-byte epilogue.
    uint256 internal constant MINIMAL_PROXY_CODE_LENGTH = 45;

    /// @dev `0x363d3d373d3d3d363d73`, the 10 bytes before the implementation address.
    uint256 private constant PROLOGUE = 0x363d3d373d3d3d363d73;

    /// @dev `0x5af43d82803e903d91602b57fd5bf3`, the 15 bytes after it.
    uint256 private constant EPILOGUE = 0x5af43d82803e903d91602b57fd5bf3;

    /**
     * @notice The implementation a minimal proxy delegates to, or `address(0)` if `account` is not one.
     * @dev Returns zero for EOAs, for contracts of any other length, and for 45-byte contracts whose bytes
     *      do not match the pattern — the caller cannot tell those apart, and does not need to, because all
     *      of them mean "not a token whose code I know".
     */
    function implementationOf(address account) internal view returns (address) {
        if (account.code.length != MINIMAL_PROXY_CODE_LENGTH) return address(0);

        bytes32 head;
        bytes32 tail;
        assembly ("memory-safe") {
            // Scratch use of the memory past the free pointer, read back before anything can allocate over
            // it. Two overlapping 32-byte words are enough to cover all 45: `head` carries the prologue and
            // the address, `tail` carries the epilogue in its low 15 bytes.
            let scratch := mload(0x40)
            extcodecopy(account, scratch, 0, MINIMAL_PROXY_CODE_LENGTH)
            head := mload(scratch)
            tail := mload(add(scratch, 13))
        }

        // Bytes 0..9 of `head`, i.e. everything above the 22 bytes that follow them.
        if (uint256(head) >> 176 != PROLOGUE) return address(0);
        // Bytes 30..44, which land in the low 15 bytes of a word read from offset 13.
        if (uint256(tail) & type(uint120).max != EPILOGUE) return address(0);

        // Bytes 10..29: drop the two epilogue bytes `head` also caught, then keep the low 20.
        return address(uint160(uint256(head) >> 16));
    }

    /**
     * @notice Whether `account` is a minimal proxy running `runtime`'s code.
     * @dev The runtime must actually have code. A zero runtime would otherwise validate every EOA and
     *      every ordinary contract, since those are what {implementationOf} reports zero for — and any
     *      other code-less address is just as bad in a subtler way: a minimal proxy pointing at one
     *      `delegatecall`s into nothing, which succeeds and returns empty for *every* selector. Such a
     *      contract would pass a naive check while behaving like no token at all.
     */
    function isClonedFrom(address account, address runtime) internal view returns (bool) {
        if (runtime.code.length == 0) return false;
        return implementationOf(account) == runtime;
    }
}
