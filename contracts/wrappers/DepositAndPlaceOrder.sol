// SPDX-License-Identifier: MIT
pragma solidity >=0.6.8;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../MutoPool.sol";
import "../interfaces/IWETH.sol";

contract DepositAndPlaceOrder {
    MutoPool public immutable mutoPool;
    IWETH public immutable nativeTokenWrapper;

    constructor(address mutoPoolAddress, address _nativeTokenWrapper)
    {
        nativeTokenWrapper = IWETH(_nativeTokenWrapper);
        mutoPool = MutoPool(mutoPoolAddress);
        IERC20(_nativeTokenWrapper).approve(mutoPoolAddress, uint256(int(-1)));
    }

    function depositAndPlaceOrder(
        uint256 auctionId,
        uint96[] memory _minBuyAmounts,
        bytes32[] memory _prevSellOrders
    ) external payable returns (uint64 userId) {
        uint96[] memory sellAmounts = new uint96[](1);
        require(msg.value < 2**96, "too much value sent");
        nativeTokenWrapper.deposit{value: msg.value}();
        sellAmounts[0] = uint96(msg.value);
        return
            mutoPool.placeSellOrdersOnBehalf(
                auctionId,
                _minBuyAmounts,
                sellAmounts,
                _prevSellOrders,
                msg.sender
            );
    }
}
