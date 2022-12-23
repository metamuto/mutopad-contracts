// SPDX-License-Identifier: MIT
pragma solidity >=0.6.8;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libraries/IterableOrderedOrderSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./libraries/IdToAddressBiMap.sol";
import "./libraries/SafeCast.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MutoPool is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint64;
    using SafeMath for uint96;
    using SafeMath for uint256;
    using SafeCast for uint256;
    using IterableOrderedOrderSet for IterableOrderedOrderSet.Data;
    using IterableOrderedOrderSet for bytes32;
    using IdToAddressBiMap for IdToAddressBiMap.Data;

    struct InitialAuctionData{
        bytes32 formHash;
        IERC20 auctioningToken;
        IERC20 biddingToken;
        uint256 orderCancellationEndDate;
        uint256 auctionEndDate;
        uint256 minimumBiddingAmountPerOrder;
        bool isAtomicClosureAllowed;
        uint256 minFundingThreshold;
        uint96 auctionedSellAmount;
        uint96 minBuyAmount;
    }
    
    struct AuctionData {
        InitialAuctionData initData;
        bytes32 initialAuctionOrder;
        uint256 interimSumBidAmount;
        bytes32 interimOrder;
        bytes32 clearingPriceOrder;
        uint96 volumeClearingPriceOrder;
        bool minFundingThresholdNotReached;
        uint256 feeNumerator;    
    }
    
    mapping(uint256 => IterableOrderedOrderSet.Data) internal sellOrders;
    mapping(uint256 => AuctionData) public auctionData;

    IdToAddressBiMap.Data private registeredUsers;
    uint64 public numUsers;
    uint256 public auctionCounter;

    constructor() public Ownable() {}

    uint256 public feeNumerator = 0;
    uint256 public constant FEE_DENOMINATOR = 1000;
    uint64 public feeReceiverUserId = 1;
    
    // @dev: Identifier to check weather the auction is still live
    modifier atStageOrderPlacement(uint256 auctionId) {
        require(
            block.timestamp < auctionData[auctionId].initData.auctionEndDate,
            "no longer in order placement phase"
        );
        _;
    }
    
    // @dev: Identifier to check cancelation end date at order cancelation 
    modifier atStageOrderPlacementAndCancelation(uint256 auctionId) {
        require(
            block.timestamp < auctionData[auctionId].initData.orderCancellationEndDate,
            "no longer in order placement and cancelation phase"
        );
        _;
    }
    
    // @dev: Identifier to check if auction end date has been reached
    modifier atStageSolutionSubmission(uint256 auctionId) {
        {
            uint256 auctionEndDate = auctionData[auctionId].initData.auctionEndDate;
            require(
                auctionEndDate != 0 &&
                    block.timestamp >= auctionEndDate &&
                    auctionData[auctionId].clearingPriceOrder == bytes32(0),
                "Auction not in solution submission phase"
            );
        }
        _;
    }
    
    
    modifier atStageFinished(uint256 auctionId) {
        require(
            auctionData[auctionId].clearingPriceOrder != bytes32(0),
            "Auction not yet finished"
        );
        _;
    }
    
    
    
    event NewSellOrder(
        uint256 indexed auctionId,
        uint64 indexed userId,
        uint96 buyAmount,
        uint96 sellAmount
    );
    event CancellationSellOrder(
        uint256 indexed auctionId,
        uint64 indexed userId,
        uint96 buyAmount,
        uint96 sellAmount
    );
    event ClaimedFromOrder(
        uint256 indexed auctionId,
        uint64 indexed userId,
        uint96 buyAmount,
        uint96 sellAmount
    );
    event NewUser(uint64 indexed userId, address indexed userAddress);
    event NewAuction(
        uint256 indexed auctionId,
        IERC20 indexed _auctioningToken,
        IERC20 indexed _biddingToken,
        uint256 orderCancellationEndDate,
        uint256 auctionEndDate,
        uint64 userId,
        uint96 _auctionedSellAmount,
        uint96 _minBuyAmount,
        uint256 minimumBiddingAmountPerOrder,
        uint256 minFundingThreshold
    );
    event AuctionCleared(
        uint256 indexed auctionId,
        uint96 soldAuctioningTokens,
        uint96 soldBiddingTokens,
        bytes32 clearingPriceOrder
    );
    event UserRegistration(address indexed user, uint64 userId);
    
    
    function initiateAuction(
	InitialAuctionData calldata _initData
    ) public returns (uint256) {
        _auctioningToken.safeTransferFrom(
            msg.sender,
            address(this),
            _auctionedSellAmount.mul(FEE_DENOMINATOR.add(feeNumerator)).div(
                FEE_DENOMINATOR
            ) //[0]
        );
        require(_initData.auctionedSellAmount > 0, "cannot auction zero tokens");
        require(_initData.minBuyAmount > 0, "tokens cannot be auctioned for free");
        require(
            _initData.minimumBiddingAmountPerOrder > 0,
            "minimumBiddingAmountPerOrder is not allowed to be zero"
        );
        require(
            _initData.orderCancellationEndDate <= _initData.auctionEndDate,
            "time periods are not configured correctly"
        );
        require(
            _initData.auctionEndDate > block.timestamp,
            "auction end date must be in the future"
        );
        auctionCounter = auctionCounter.add(1);
        sellOrders[auctionCounter].initializeEmptyList();
        uint64 userId = getUserId(msg.sender);
        auctionData[auctionCounter] = AuctionData(
            _initData,
            IterableOrderedOrderSet.encodeOrder(
                userId,
                _initData.minBuyAmount,
                _initData.auctionedSellAmount
            ),
            0,
            IterableOrderedOrderSet.QUEUE_START,
            bytes32(0),
            0,
            false,
            feeNumerator
        );
        emit NewAuction(
            auctionCounter,
            _initData.auctioningToken,
            _initData.biddingToken,
            _initData.orderCancellationEndDate,
            _initData.auctionEndDate,
            userId,
            _initData.auctionedSellAmount,
            _initData.minBuyAmount,
            _initData.minimumBiddingAmountPerOrder,
            _initData.minFundingThreshold
        );
        return auctionCounter;
    }
    
    
function placeSellOrders(
        uint256 auctionId,
        uint96[] memory _minBuyAmounts,
        uint96[] memory _sellAmounts,
        bytes32[] memory _prevSellOrders
    ) external atStageOrderPlacement(auctionId) returns (uint64 userId) {
        return
            _placeSellOrders(
                auctionId,
                _minBuyAmounts,
                _sellAmounts,
                _prevSellOrders,
                msg.sender
            );
    }
    
    
    
function placeSellOrdersOnBehalf(
        uint256 auctionId,
        uint96[] memory _minBuyAmounts,
        uint96[] memory _sellAmounts,
        bytes32[] memory _prevSellOrders,
        address orderSubmitter
    ) external atStageOrderPlacement(auctionId) returns (uint64 userId) {
        return
            _placeSellOrders(
                auctionId,
                _minBuyAmounts,
                _sellAmounts,
                _prevSellOrders,
                orderSubmitter
            );
    }
    
    
    
    
    
function _placeSellOrders(
        uint256 auctionId,
        uint96[] memory _minBuyAmounts,
        uint96[] memory _sellAmounts,
        bytes32[] memory _prevSellOrders,
        address orderSubmitter
    ) internal returns (uint64 userId) {
        {
            (
                ,
                uint96 buyAmountOfInitialAuctionOrder,
                uint96 sellAmountOfInitialAuctionOrder
            ) = auctionData[auctionId].initialAuctionOrder.decodeOrder();
            for (uint256 i = 0; i < _minBuyAmounts.length; i++) {
                require(
                    _minBuyAmounts[i].mul(buyAmountOfInitialAuctionOrder) <
                        sellAmountOfInitialAuctionOrder.mul(_sellAmounts[i]),
                    "limit price not better than mimimal offer"
                );
            }
        }
        uint256 sumOfSellAmounts = 0;
        userId = getUserId(orderSubmitter);
        uint256 minimumBiddingAmountPerOrder =
            auctionData[auctionId].initData.minimumBiddingAmountPerOrder;
        for (uint256 i = 0; i < _minBuyAmounts.length; i++) {
            require(
                _minBuyAmounts[i] > 0,
                "_minBuyAmounts must be greater than 0"
            );
            // orders should have a minimum bid size in order to limit the gas
            // required to compute the final price of the auction.
            require(
                _sellAmounts[i] > minimumBiddingAmountPerOrder,
                "order too small"
            );
            if (
                sellOrders[auctionId].insert(
                    IterableOrderedOrderSet.encodeOrder(
                        userId,
                        _minBuyAmounts[i],
                        _sellAmounts[i]
                    ),
                    _prevSellOrders[i]
                )
            ) {
                sumOfSellAmounts = sumOfSellAmounts.add(_sellAmounts[i]);
                emit NewSellOrder(
                    auctionId,
                    userId,
                    _minBuyAmounts[i],
                    _sellAmounts[i]
                );
            }
        }
        auctionData[auctionId].initData.biddingToken.safeTransferFrom(
            msg.sender,
            address(this),
            sumOfSellAmounts
        ); //[1]
    }
    
    
    
function cancelSellOrders(uint256 auctionId, bytes32[] memory _sellOrders)
        public
        atStageOrderPlacementAndCancelation(auctionId)
    {
        uint64 userId = getUserId(msg.sender);
        uint256 claimableAmount = 0;
        for (uint256 i = 0; i < _sellOrders.length; i++) {
            // Note: we keep the back pointer of the deleted element so that
            // it can be used as a reference point to insert a new node.
            bool success =
                sellOrders[auctionId].removeKeepHistory(_sellOrders[i]);
            if (success) {
                (
                    uint64 userIdOfIter,
                    uint96 buyAmountOfIter,
                    uint96 sellAmountOfIter
                ) = _sellOrders[i].decodeOrder();
                require(
                    userIdOfIter == userId,
                    "Only the user can cancel his orders"
                );
                claimableAmount = claimableAmount.add(sellAmountOfIter);
                emit CancellationSellOrder(
                    auctionId,
                    userId,
                    buyAmountOfIter,
                    sellAmountOfIter
                );
            }
        }
        auctionData[auctionId].initData.biddingToken.safeTransfer(
            msg.sender,
            claimableAmount
        ); //[2]
    }
    
function sendOutTokens(
        uint256 auctionId,
        uint256 auctioningTokenAmount,
        uint256 biddingTokenAmount,
        uint64 userId
    ) internal {
        address userAddress = registeredUsers.getAddressAt(userId);
        if (auctioningTokenAmount > 0) {
            auctionData[auctionId].initData.auctioningToken.safeTransfer(
                userAddress,
                auctioningTokenAmount
            );
        }
        if (biddingTokenAmount > 0) {
            auctionData[auctionId].initData.biddingToken.safeTransfer(
                userAddress,
                biddingTokenAmount
            );
        }
    }
    
    
function processFeesAndAuctioneerFunds(
        uint256 auctionId,
        uint256 fillVolumeOfAuctioneerOrder,
        uint64 auctioneerId,
        uint96 fullAuctionedAmount
    ) internal {
        uint256 feeAmount =
            fullAuctionedAmount.mul(auctionData[auctionId].feeNumerator).div(
                FEE_DENOMINATOR
            ); //[20]
        if (auctionData[auctionId].minFundingThresholdNotReached) {
            sendOutTokens(
                auctionId,
                fullAuctionedAmount.add(feeAmount),
                0,
                auctioneerId
            ); //[4]
        } else {
            //[11]
            (, uint96 priceNumerator, uint96 priceDenominator) =
                auctionData[auctionId].clearingPriceOrder.decodeOrder();
            uint256 unsettledAuctionTokens =
                fullAuctionedAmount.sub(fillVolumeOfAuctioneerOrder);
            uint256 auctioningTokenAmount =
                unsettledAuctionTokens.add(
                    feeAmount.mul(unsettledAuctionTokens).div(
                        fullAuctionedAmount
                    )
                );
            uint256 biddingTokenAmount =
                fillVolumeOfAuctioneerOrder.mul(priceDenominator).div(
                    priceNumerator
                );
            sendOutTokens(
                auctionId,
                auctioningTokenAmount,
                biddingTokenAmount,
                auctioneerId
            ); //[5]
            sendOutTokens(
                auctionId,
                feeAmount.mul(fillVolumeOfAuctioneerOrder).div(
                    fullAuctionedAmount
                ),
                0,
                feeReceiverUserId
            ); //[7]
        }
    }
    
    
    
function settleAuctionAtomically(
        uint256 auctionId,
        uint96[] memory _minBuyAmount,
        uint96[] memory _sellAmount,
        bytes32[] memory _prevSellOrder
    ) public atStageSolutionSubmission(auctionId) {
        require(
            auctionData[auctionId].initData.isAtomicClosureAllowed,
            "not allowed to settle auction atomically"
        );
        require(
            _minBuyAmount.length == 1 && _sellAmount.length == 1,
            "Only one order can be placed atomically"
        );
        uint64 userId = getUserId(msg.sender);
        require(
            auctionData[auctionId].interimOrder.smallerThan(
                IterableOrderedOrderSet.encodeOrder(
                    userId,
                    _minBuyAmount[0],
                    _sellAmount[0]
                )
            ),
            "precalculateSellAmountSum is already too advanced"
        );
        _placeSellOrders(
            auctionId,
            _minBuyAmount,
            _sellAmount,
            _prevSellOrder,
            msg.sender
        );
        settleAuction(auctionId);
    }
    
   
   
function settleAuction(uint256 auctionId)
        public
        atStageSolutionSubmission(auctionId)
        returns (bytes32 clearingOrder)
    {
        (
            uint64 auctioneerId,
            uint96 minAuctionedBuyAmount,
            uint96 fullAuctionedAmount
        ) = auctionData[auctionId].initialAuctionOrder.decodeOrder();

        uint256 currentBidSum = auctionData[auctionId].interimSumBidAmount;
        bytes32 currentOrder = auctionData[auctionId].interimOrder;
        uint256 buyAmountOfIter;
        uint256 sellAmountOfIter;
        uint96 fillVolumeOfAuctioneerOrder = fullAuctionedAmount;
        // Sum order up, until fullAuctionedAmount is fully bought or queue end is reached
        do {
            bytes32 nextOrder = sellOrders[auctionId].next(currentOrder);
            if (nextOrder == IterableOrderedOrderSet.QUEUE_END) {
                break;
            }
            currentOrder = nextOrder;
            (, buyAmountOfIter, sellAmountOfIter) = currentOrder.decodeOrder();
            currentBidSum = currentBidSum.add(sellAmountOfIter);
        } while (
            currentBidSum.mul(buyAmountOfIter) <
                fullAuctionedAmount.mul(sellAmountOfIter)
        );

        if (
            currentBidSum > 0 &&
            currentBidSum.mul(buyAmountOfIter) >=
            fullAuctionedAmount.mul(sellAmountOfIter)
        ) {
            // All considered/summed orders are sufficient to close the auction fully
            // at price between current and previous orders.
            uint256 uncoveredBids =
                currentBidSum.sub(
                    fullAuctionedAmount.mul(sellAmountOfIter).div(
                        buyAmountOfIter
                    )
                );

            if (sellAmountOfIter >= uncoveredBids) {
                //[13]
                // Auction fully filled via partial match of currentOrder
                uint256 sellAmountClearingOrder =
                    sellAmountOfIter.sub(uncoveredBids);
                auctionData[auctionId]
                    .volumeClearingPriceOrder = sellAmountClearingOrder
                    .toUint96();
                currentBidSum = currentBidSum.sub(uncoveredBids);
                clearingOrder = currentOrder;
            } else {
                //[14]
                // Auction fully filled via price strictly between currentOrder and the order
                // immediately before. For a proof, see the security-considerations.md
                currentBidSum = currentBidSum.sub(sellAmountOfIter);
                clearingOrder = IterableOrderedOrderSet.encodeOrder(
                    0,
                    fullAuctionedAmount,
                    currentBidSum.toUint96()
                );
            }
        } else {
            // All considered/summed orders are not sufficient to close the auction fully at price of last order //[18]
            // Either a higher price must be used or auction is only partially filled

            if (currentBidSum > minAuctionedBuyAmount) {
                //[15]
                // Price higher than last order would fill the auction
                clearingOrder = IterableOrderedOrderSet.encodeOrder(
                    0,
                    fullAuctionedAmount,
                    currentBidSum.toUint96()
                );
            } else {
                //[16]
                // Even at the initial auction price, the auction is partially filled
                clearingOrder = IterableOrderedOrderSet.encodeOrder(
                    0,
                    fullAuctionedAmount,
                    minAuctionedBuyAmount
                );
                fillVolumeOfAuctioneerOrder = currentBidSum
                    .mul(fullAuctionedAmount)
                    .div(minAuctionedBuyAmount)
                    .toUint96();
            }
        }
        auctionData[auctionId].clearingPriceOrder = clearingOrder;

        if (auctionData[auctionId].initData.minFundingThreshold > currentBidSum) {
            auctionData[auctionId].minFundingThresholdNotReached = true;
        }
        processFeesAndAuctioneerFunds(
            auctionId,
            fillVolumeOfAuctioneerOrder,
            auctioneerId,
            fullAuctionedAmount
        );
        emit AuctionCleared(
            auctionId,
            fillVolumeOfAuctioneerOrder,
            uint96(currentBidSum),
            clearingOrder
        );

        auctionData[auctionId].initialAuctionOrder = bytes32(0);
        auctionData[auctionId].interimOrder = bytes32(0);
        auctionData[auctionId].interimSumBidAmount = uint256(0);
        auctionData[auctionId].initData.minimumBiddingAmountPerOrder = uint256(0);
    }
    
    
    
function precalculateSellAmountSum(
        uint256 auctionId,
        uint256 iterationSteps
    ) public atStageSolutionSubmission(auctionId) {
        (, , uint96 auctioneerSellAmount) =
            auctionData[auctionId].initialAuctionOrder.decodeOrder();
        uint256 sumBidAmount = auctionData[auctionId].interimSumBidAmount;
        bytes32 iterOrder = auctionData[auctionId].interimOrder;

        for (uint256 i = 0; i < iterationSteps; i++) {
            iterOrder = sellOrders[auctionId].next(iterOrder);
            (, , uint96 sellAmountOfIter) = iterOrder.decodeOrder();
            sumBidAmount = sumBidAmount.add(sellAmountOfIter);
        }

        require(
            iterOrder != IterableOrderedOrderSet.QUEUE_END,
            "reached end of order list"
        );

        // it is checked that not too many iteration steps were taken:
        // require that the sum of SellAmounts times the price of the last order
        // is not more than initially sold amount
        (, uint96 buyAmountOfIter, uint96 sellAmountOfIter) =
            iterOrder.decodeOrder();
        require(
            sumBidAmount.mul(buyAmountOfIter) <
                auctioneerSellAmount.mul(sellAmountOfIter),
            "too many orders summed up"
        );

        auctionData[auctionId].interimSumBidAmount = sumBidAmount;
        auctionData[auctionId].interimOrder = iterOrder;
    }
    
  function claimFromParticipantOrder(
        uint256 auctionId,
        bytes32[] memory orders
    )
        public
        atStageFinished(auctionId)
        returns (
            uint256 sumAuctioningTokenAmount,
            uint256 sumBiddingTokenAmount
        )
    {
        for (uint256 i = 0; i < orders.length; i++) {
            // Note: we don't need to keep any information about the node since
            // no new elements need to be inserted.
            require(
                sellOrders[auctionId].remove(orders[i]),
                "order is no longer claimable"
            );
        }
        AuctionData memory auction = auctionData[auctionId];
        (, uint96 priceNumerator, uint96 priceDenominator) =
            auction.clearingPriceOrder.decodeOrder();
        (uint64 userId, , ) = orders[0].decodeOrder();
        bool minFundingThresholdNotReached =
            auctionData[auctionId].minFundingThresholdNotReached;
        for (uint256 i = 0; i < orders.length; i++) {
            (uint64 userIdOrder, uint96 buyAmount, uint96 sellAmount) =
                orders[i].decodeOrder();
            require(
                userIdOrder == userId,
                "only allowed to claim for same user"
            );
            if (minFundingThresholdNotReached) {
                //[10]
                sumBiddingTokenAmount = sumBiddingTokenAmount.add(sellAmount);
            } else {
                //[23]
                if (orders[i] == auction.clearingPriceOrder) {
                    //[25]
                    sumAuctioningTokenAmount = sumAuctioningTokenAmount.add(
                        auction
                            .volumeClearingPriceOrder
                            .mul(priceNumerator)
                            .div(priceDenominator)
                    );
                    sumBiddingTokenAmount = sumBiddingTokenAmount.add(
                        sellAmount.sub(auction.volumeClearingPriceOrder)
                    );
                } else {
                    if (orders[i].smallerThan(auction.clearingPriceOrder)) {
                        //[17]
                        sumAuctioningTokenAmount = sumAuctioningTokenAmount.add(
                            sellAmount.mul(priceNumerator).div(priceDenominator)
                        );
                    } else {
                        //[24]
                        sumBiddingTokenAmount = sumBiddingTokenAmount.add(
                            sellAmount
                        );
                    }
                }
            }
            emit ClaimedFromOrder(auctionId, userId, buyAmount, sellAmount);
        }
        sendOutTokens(
            auctionId,
            sumAuctioningTokenAmount,
            sumBiddingTokenAmount,
            userId
        ); //[3]
    }
    
    
    
function setFeeParameters(
        uint256 newFeeNumerator,
        address newfeeReceiverAddress
    ) public onlyOwner() {
        require(
            newFeeNumerator <= 15,
            "Fee is not allowed to be set higher than 1.5%"
        );
        // caution: for currently running auctions, the feeReceiverUserId is changing as well.
        feeReceiverUserId = getUserId(newfeeReceiverAddress);
        feeNumerator = newFeeNumerator;
    }
    
    
    
    

function containsOrder(uint256 auctionId, bytes32 order)
        public
        view
        returns (bool)
    {
        return sellOrders[auctionId].contains(order);
    }
    
    
    


function getSecondsRemainingInBatch(uint256 auctionId)
        public
        view
        returns (uint256)
    {
        if (auctionData[auctionId].initData.auctionEndDate < block.timestamp) {
            return 0;
        }
        return auctionData[auctionId].initData.auctionEndDate.sub(block.timestamp);
    }
    
    
    


function registerUser(address user) public returns (uint64 userId) {
        numUsers = numUsers.add(1).toUint64();
        require(
            registeredUsers.insert(numUsers, user),
            "User already registered"
        );
        userId = numUsers;
        emit UserRegistration(user, userId);
    }


function getUserId(address user) public returns (uint64 userId) {
        if (registeredUsers.hasAddress(user)) {
            userId = registeredUsers.getId(user);
        } else {
            userId = registerUser(user);
            emit NewUser(userId, user);
        }
    }
    
function getFormHash(uint256 auction_id) public view returns(bytes32){
    require(auction_id<=auctionCounter, "Invalid Auction Id");
    return auctionData[auction_id].initData.formHash;
} 

}