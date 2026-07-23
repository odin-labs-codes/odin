// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITransferHookReceiver} from "../../src/interfaces/IERC20TransferHook.sol";

/// @dev Records what the token told it, so a test can assert the hook saw the settled transfer.
contract RecordingHook is ITransferHookReceiver {
    address public lastToken;
    address public lastFrom;
    address public lastTo;
    uint256 public lastValue;
    uint256 public callCount;
    uint256 public recipientBalanceAtCall;

    function onTransfer(address token, address from, address to, uint256 value) external returns (bytes4) {
        lastToken = token;
        lastFrom = from;
        lastTo = to;
        lastValue = value;
        callCount += 1;
        recipientBalanceAtCall = IERC20(token).balanceOf(to);
        return ITransferHookReceiver.onTransfer.selector;
    }
}

/// @dev Rejects every transfer, with a reason short enough to survive truncation intact.
contract RejectingHook is ITransferHookReceiver {
    error HookSaysNo();

    function onTransfer(address, address, address, uint256) external pure returns (bytes4) {
        revert HookSaysNo();
    }
}

/// @dev Returns a selector that is not the acknowledgement, which must still reject the transfer.
contract WrongSelectorHook is ITransferHookReceiver {
    function onTransfer(address, address, address, uint256) external pure returns (bytes4) {
        return bytes4(0xdeadbeef);
    }
}

/// @dev Returns no data at all, which is what an EOA or a fallback-only contract would do.
contract EmptyReturnHook {
    fallback() external {}
}

/// @dev Spins until its gas budget is gone, to prove the budget is the bound the token advertises.
contract GasBurningHook is ITransferHookReceiver {
    uint256 private _sink;

    function onTransfer(address, address, address, uint256) external returns (bytes4) {
        while (true) {
            _sink += 1;
        }
        return ITransferHookReceiver.onTransfer.selector;
    }
}

/// @dev Returns several hundred kilobytes, to prove the token does not copy it back at the caller's expense.
contract ReturnDataBombHook {
    fallback(bytes calldata) external returns (bytes memory) {
        return new bytes(200_000);
    }
}

/// @dev Reverts with a reason far longer than the token is willing to carry.
contract RevertBombHook {
    fallback() external {
        bytes memory big = new bytes(100_000);
        assembly {
            revert(add(big, 0x20), mload(big))
        }
    }
}

/// @dev Calls straight back into the token's transfer path, which the guard must reject.
contract ReentrantHook is ITransferHookReceiver {
    function onTransfer(address token, address, address to, uint256 value) external returns (bytes4) {
        IERC20(token).transfer(to, value);
        return ITransferHookReceiver.onTransfer.selector;
    }
}

/// @dev Re-enters through `transferFrom` instead, in case the guard only covered the direct path.
contract ReentrantPullHook is ITransferHookReceiver {
    function onTransfer(address token, address from, address to, uint256 value) external returns (bytes4) {
        IERC20(token).transferFrom(from, to, value);
        return ITransferHookReceiver.onTransfer.selector;
    }
}
