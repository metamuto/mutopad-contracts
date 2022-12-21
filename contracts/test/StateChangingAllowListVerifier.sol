// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "../interfaces/AllowListVerifier.sol";

contract StateChangingAllowListVerifier {
    bytes32 public test = bytes32(0);

    function isAllowed(
        address user,
        uint256 auctionId,
        bytes calldata callData
    ) external returns (bytes4) {
        test = keccak256(abi.encode(user, auctionId, callData));
        return AllowListVerifierHelper.MAGICVALUE;
    }
}
