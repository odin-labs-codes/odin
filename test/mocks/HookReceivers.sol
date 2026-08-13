// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITransferHookReceiver} from "../../src/interfaces/IERC20TransferHook.sol";

/// @dev Accepts everything and records the last call, so tests can assert what the hook actually saw.
contract RecordingHook is ITransferHookReceiver {
    address public lastToken;
    address public lastFrom;
    address public lastTo;
    uint256 public lastValue;
    uint256 public callCount;

    function onTransfer(address token, address from, address to, uint256 value) external returns (bytes4) {
        lastToken = token;
        lastFrom = from;
        lastTo = to;
        lastValue = value;
        callCount++;
        return ITransferHookReceiver.onTransfer.selector;
    }
}

/// @dev Rejects every transfer. Proves a hook can veto and that the veto reaches the caller.
contract RejectingHook is ITransferHookReceiver {
    error HookRejected();

    function onTransfer(address, address, address, uint256) external pure returns (bytes4) {
        revert HookRejected();
    }
}

/// @dev Returns a value that is not the acknowledgement selector.
contract WrongSelectorHook is ITransferHookReceiver {
    function onTransfer(address, address, address, uint256) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

/// @dev Returns nothing at all, the way a contract that never meant to be a hook would.
contract EmptyReturnHook {
    fallback() external {}
}

/// @dev Burns gas until the stipend runs out, to check the limit is real and the failure is contained.
contract GasBurningHook is ITransferHookReceiver {
    uint256 public sink;

    function onTransfer(address, address, address, uint256) external returns (bytes4) {
        for (uint256 i = 0; i < 100_000; i++) {
            sink = i;
        }
        return ITransferHookReceiver.onTransfer.selector;
    }
}

/**
 * @dev Returns an enormous buffer instead of an acknowledgement.
 *
 *      A high-level `hook.call(...)` assigns return data into `bytes memory`, and that copy is paid by the
 *      *token*, after the hook's gas budget has already been released. This hook spends its own stipend
 *      expanding memory so that copying the result back would cost the caller a comparable amount again —
 *      the returndata bomb. With the copy bounded, the token pays a constant instead.
 */
contract ReturnDataBombHook {
    uint256 public immutable returnedBytes;

    constructor(uint256 returnedBytes_) {
        returnedBytes = returnedBytes_;
    }

    fallback() external {
        uint256 size = returnedBytes;
        assembly {
            // Touch the far end so the buffer is genuinely allocated, then hand all of it back.
            mstore(add(size, 0x20), 0)
            return(0x20, size)
        }
    }
}

/// @dev The same bomb, but reverting, so the truncation of the revert reason is exercised too.
contract RevertBombHook {
    uint256 public immutable revertBytes;

    constructor(uint256 revertBytes_) {
        revertBytes = revertBytes_;
    }

    fallback() external {
        uint256 size = revertBytes;
        assembly {
            mstore(add(size, 0x20), 0)
            revert(0x20, size)
        }
    }
}

/// @dev Tries to move tokens from inside the hook. The token's reentrancy guard must stop it.
contract ReentrantHook is ITransferHookReceiver {
    address public victim;
    bool public attempted;

    constructor(address victim_) {
        victim = victim_;
    }

    function onTransfer(address token, address, address to, uint256) external returns (bytes4) {
        attempted = true;
        IERC20(token).transfer(to, 1);
        return ITransferHookReceiver.onTransfer.selector;
    }
}

/// @dev Tries to re-enter via `transferFrom` instead, in case the guard only covered the direct path.
contract ReentrantPullHook is ITransferHookReceiver {
    function onTransfer(address token, address from, address to, uint256) external returns (bytes4) {
        IERC20(token).transferFrom(from, to, 1);
        return ITransferHookReceiver.onTransfer.selector;
    }
}

/**
 * @dev Asserts, from inside the hook, that the pipeline already finished the parts that must precede it:
 *      the recipient has been credited and the fee vault has been paid. This is how the ordering test
 *      observes phase order from the one vantage point that can see it.
 */
contract OrderAssertingHook is ITransferHookReceiver {
    address public immutable feeVault;

    uint256 public observedRecipientBalance;
    uint256 public observedVaultBalance;
    uint256 public observedValue;

    constructor(address feeVault_) {
        feeVault = feeVault_;
    }

    function onTransfer(address token, address, address to, uint256 value) external returns (bytes4) {
        observedRecipientBalance = IERC20(token).balanceOf(to);
        observedVaultBalance = IERC20(token).balanceOf(feeVault);
        observedValue = value;
        return ITransferHookReceiver.onTransfer.selector;
    }
}
