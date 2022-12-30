// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./libraries/SafeCast.sol";
import "./libraries/IdToAddressBiMap.sol";
import "./libraries/IterableOrderedOrderSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

struct InitialAuctionData{
    string formHash;
    IERC20 auctioningToken;
    IERC20 biddingToken;
    uint40 orderCancellationEndDate;
    uint40 auctionStartDate;
    uint40 auctionEndDate;
    uint96 auctionedSellAmount;
    uint96 minBuyAmount;
    uint256 minimumBiddingAmountPerOrder;
    uint256 minFundingThreshold;
    bool isAtomicClosureAllowed;
}
    
struct AuctionData {
    InitialAuctionData initData;
    address poolOwner;
    bytes32 initialAuctionOrder;
    uint256 interimSumBidAmount;
    bytes32 interimOrder;
    bytes32 clearingPriceOrder;
    uint96 volumeClearingPriceOrder;
    bool minFundingThresholdNotReached;
    uint256 feeNumerator;
    bool isScam;
    bool isDeleted;    
}

contract MutoPool is Ownable {
    
    using SafeERC20 for IERC20;
    using SafeMath for uint40;
    using SafeMath for uint64;
    using SafeMath for uint96;
    using SafeMath for uint256;
    using SafeCast for uint256;
    //using SafeCast for uint64;

    using IterableOrderedOrderSet for bytes32;
    using IdToAddressBiMap for IdToAddressBiMap.Data;
    using IterableOrderedOrderSet for IterableOrderedOrderSet.Data;

    mapping(uint256 => AuctionData) public auctionData;
    mapping(uint256 => IterableOrderedOrderSet.Data) internal sellOrders;

    uint64 public numUsers;
    uint256 public auctionCounter;
    IdToAddressBiMap.Data private registeredUsers;

    constructor()  Ownable() {}

    uint64 public feeReceiverUserId = 1;
    uint256 public feeNumerator = 0;
    uint256 public constant FEE_DENOMINATOR = 1000;

    function iscancellledorDeleted(uint256 auctioId) internal view{
        require(!auctionData[auctioId].isScam);
        require(!auctionData[auctioId].isDeleted);
    }

    modifier atStageOrderPlacementAndCancelation(uint256 auctionId) {
        require(
            block.timestamp < auctionData[auctionId].initData.orderCancellationEndDate,
            "not in  placement/cancelation phase"
        );
        _;
    }
    
    modifier atStageFinished(uint256 auctionId) {
        require(
            auctionData[auctionId].clearingPriceOrder != bytes32(0),
            "auction not finished"
        );
        _;
    }
    
    modifier atStageOrderPlacement(uint256 auctionId) {
        orderplace(auctionId);
        _;
    }

    modifier atStageSolutionSubmission(uint256 auctionId) {
        solutionSubmission(auctionId);
        iscancellledorDeleted(auctionId);   

        _;
    }

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

    event ClaimedFromOrder(
        uint256 indexed auctionId,
        uint64 indexed userId,
        uint96 buyAmount,
        uint96 sellAmount
    );

    event AuctionCleared(
        uint256 indexed auctionId,
        uint96 soldAuctioningTokens,
        uint96 soldBiddingTokens,
        bytes32 clearingPriceOrder
    );    

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

    event NewUser(
        uint64 indexed userId, 
        address indexed userAddress
    );

    event UserRegistration(
        address indexed user, 
        uint64 userId
    );
    

    function getCurrentAuctionPrice(uint256 _auctionId) external view returns(uint){
        bytes32 current = sellOrders[_auctionId].getCurrent();
        (, uint96 buyAmount, uint96 sellAmount) =
                    current.decodeOrder();
        return sellAmount.div(buyAmount);
    }
    
    function initiateAuction(
            string memory _formHash,
            IERC20 _auctioningToken,
            IERC20 _biddingToken,
            uint40 _orderCancellationEndDate,  
            uint40 _auctionStartDate,
            uint40 _auctionEndDate,
            uint96 _auctionedSellAmount,
            uint96 _minBuyAmount,
            uint256 _minimumBiddingAmountPerOrder,
            uint256 _minFundingThreshold,
            bool _isAtomicClosureAllowed
        ) public returns (uint256) {
            uint256 _ammount = _auctionedSellAmount.mul(FEE_DENOMINATOR.add(feeNumerator)).div(
                    FEE_DENOMINATOR);
            require(_auctioningToken.balanceOf(msg.sender)>=_ammount);
            require(block.timestamp<_auctionStartDate && _auctionStartDate<_auctionEndDate);
            require(_auctionedSellAmount > 0);
            require(_minBuyAmount > 0);
            require(_minimumBiddingAmountPerOrder > 0);
            require(_orderCancellationEndDate <= _auctionEndDate);
            require(_auctionEndDate > block.timestamp);
            _auctioningToken.safeTransferFrom(
                msg.sender,
                address(this),
                _ammount
            );
            InitialAuctionData memory  data = InitialAuctionData(
                    _formHash,
                    _auctioningToken,
                    _biddingToken,
                    _orderCancellationEndDate,
                    _auctionStartDate,
                    _auctionEndDate,
                    _auctionedSellAmount,
                    _minBuyAmount,
                    _minimumBiddingAmountPerOrder,
                    _minFundingThreshold,
                    _isAtomicClosureAllowed
                );
            auctionCounter = auctionCounter.add(1);
            sellOrders[auctionCounter].initializeEmptyList();
            uint64 userId = getUserId(msg.sender);
            auctionData[auctionCounter] = AuctionData(
                data,
                msg.sender,
                IterableOrderedOrderSet.encodeOrder(
                    userId,
                    _minBuyAmount,
                    _auctionedSellAmount
                ),
                0,
                IterableOrderedOrderSet.QUEUE_START,
                bytes32(0),
                0,
                false,
                feeNumerator,
                false,
                false
            );
            emit NewAuction(
                auctionCounter,
                _auctioningToken,
                _biddingToken,
                _orderCancellationEndDate,
                _auctionEndDate,
                userId,
                _auctionedSellAmount,
                _minBuyAmount,
                _minimumBiddingAmountPerOrder,
                _minFundingThreshold
            );
            return auctionCounter;
        }

    function markSpam(uint256 auctioId) external onlyOwner{
        auctionData[auctioId].isScam = true;
    }

    function deletAuction(uint256 auctioId) external onlyOwner{
        auctionData[auctioId].isDeleted = true;
    }

    function updateAuctionAdmin(uint256 auctionId, uint40 _startTime, uint40 _endTime, uint40 _cancelTime, uint256 _fundingThreshold,uint256 _minBid ) external onlyOwner{
        auctionData[auctionId].initData.auctionStartDate = _startTime;
        auctionData[auctionId].initData.auctionEndDate = _endTime;
        auctionData[auctionId].initData.orderCancellationEndDate = _cancelTime;
        auctionData[auctionId].initData.minFundingThreshold = _fundingThreshold;
        auctionData[auctionId].initData.minimumBiddingAmountPerOrder = _minBid;
    }

    function updateAuctionUser(uint256 auctionId, uint40 _startTime, uint40 _endTime, uint40 _cancelTime, string memory _formHash) external{
        require(msg.sender==auctionData[auctionId].poolOwner);
        auctionData[auctionId].initData.auctionStartDate = _startTime;
        auctionData[auctionId].initData.auctionEndDate = _endTime;
        auctionData[auctionId].initData.orderCancellationEndDate = _cancelTime;
        auctionData[auctionId].initData.formHash = _formHash;
    }
        
    function placeSellOrders(
            uint256 auctionId,
            uint96 _minBuyAmount,
            uint96 _sellAmount,
            bytes32 _prevSellOrder
        ) external atStageOrderPlacement(auctionId) returns (uint64 userId) {
            return
                _placeSellOrders(
                    auctionId,
                    _minBuyAmount,
                    _sellAmount,
                    _prevSellOrder,
                    msg.sender
                );
        }


    function placeSellOrdersOnBehalf(
            uint256 auctionId,
            uint96 _minBuyAmount,
            uint96 _sellAmount,
            bytes32 _prevSellOrder,
            address orderSubmitter
        ) external atStageOrderPlacement(auctionId) returns (uint64 userId) {
            return
                _placeSellOrders(
                    auctionId,
                    _minBuyAmount,
                    _sellAmount,
                    _prevSellOrder,
                    orderSubmitter
                );
        }


    function _placeSellOrders(
            uint256 auctionId,
            uint96 _minBuyAmount,
            uint96 _sellAmount,
            bytes32 _prevSellOrder,
            address orderSubmitter
        ) internal returns (uint64 userId) {
            {
                (   ,
                    uint96 buyAmountOfInitialAuctionOrder,
                    uint96 sellAmountOfInitialAuctionOrder
                ) = auctionData[auctionId].initialAuctionOrder.decodeOrder();
                require(
                        _minBuyAmount.mul(buyAmountOfInitialAuctionOrder) <
                            sellAmountOfInitialAuctionOrder.mul(_sellAmount),
                        "limit price is <  min offer"
                    );
            }
            userId = getUserId(orderSubmitter);
            uint256 minimumBiddingAmountPerOrder =
                auctionData[auctionId].initData.minimumBiddingAmountPerOrder;
                require(_minBuyAmount > 0,"buyAmounts must be < 0");
                require(_sellAmount > minimumBiddingAmountPerOrder,"order too small");
                if (
                    sellOrders[auctionId].insert(
                        IterableOrderedOrderSet.encodeOrder(
                            userId,
                            _minBuyAmount,
                            _sellAmount
                        ),
                        _prevSellOrder
                    )
                ) {
                    emit NewSellOrder(
                        auctionId,
                        userId,
                        _minBuyAmount,
                        _sellAmount
                    );
                }
            auctionData[auctionId].initData.biddingToken.safeTransferFrom(
                msg.sender,
                address(this),
                _sellAmount
            );
        }
            
        
    function cancelSellOrder(uint256 auctionId, bytes32 _sellOrder)
            public
            atStageOrderPlacementAndCancelation(auctionId)
        {
            uint64 userId = getUserId(msg.sender);
            bool success = sellOrders[auctionId].removeKeepHistory(_sellOrder);
            if (success) {
                (
                    uint64 userIdOfIter,
                    uint96 buyAmountOfIter,
                    uint96 sellAmountOfIter
                ) = _sellOrder.decodeOrder();
                require(
                    userIdOfIter == userId,
                    "user can cancel"
                );
                emit CancellationSellOrder(
                    auctionId,
                    userId,
                    buyAmountOfIter,
                    sellAmountOfIter
                );
                auctionData[auctionId].initData.biddingToken.safeTransfer(
                msg.sender,
                sellAmountOfIter
            );
            }
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
        
    function claimFromParticipantOrder(
            uint256 auctionId,
            bytes32 order
        )
            public
            atStageFinished(auctionId)
            returns (
                uint256 auctioningTokenAmount,
                uint256 biddingTokenAmount
            )
        {
            require(sellOrders[auctionId].remove(order),"order not claimable");
            (, uint96 priceNumerator, uint96 priceDenominator) = auctionData[auctionId].clearingPriceOrder.decodeOrder();
            (uint64 userId, uint96 buyAmount, uint96 sellAmount) = order.decodeOrder();
            require(getUserId(msg.sender) == userId,"Claimable by user");
            if (auctionData[auctionId].minFundingThresholdNotReached)
            {
            	biddingTokenAmount = sellAmount;
            }
            else {
            	if (order == auctionData[auctionId].clearingPriceOrder) {
		        auctioningTokenAmount =
		            auctionData[auctionId]
		                .volumeClearingPriceOrder
		                .mul(priceNumerator)
		                .div(priceDenominator);
		        biddingTokenAmount = sellAmount.sub(auctionData[auctionId].volumeClearingPriceOrder);
               } else {
                        if (order.smallerThan(auctionData[auctionId].clearingPriceOrder)) {
                            auctioningTokenAmount =
                                sellAmount.mul(priceNumerator).div(priceDenominator);
                        } else {
                            biddingTokenAmount = sellAmount;
                        }
                    }
            }
            emit ClaimedFromOrder(auctionId, userId, buyAmount, sellAmount);
            sendOutTokens(
                auctionId,
                auctioningTokenAmount,
                biddingTokenAmount,
                userId
            );    
            
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
            uint96 _minBuyAmount,
            uint96 _sellAmount,
            bytes32 _prevSellOrder
        ) public atStageSolutionSubmission(auctionId) {
            require(
                auctionData[auctionId].initData.isAtomicClosureAllowed,
                "not allowed"
            );
            uint64 userId = getUserId(msg.sender);
            require(
                auctionData[auctionId].interimOrder.smallerThan(
                    IterableOrderedOrderSet.encodeOrder(
                        userId,
                        _minBuyAmount,
                        _sellAmount
                    )
                )
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
                    currentBidSum = currentBidSum.sub(sellAmountOfIter);
                    clearingOrder = IterableOrderedOrderSet.encodeOrder(
                        0,
                        fullAuctionedAmount,
                       uint96 (currentBidSum)
                    );
                }
            } else {
                if (currentBidSum > minAuctionedBuyAmount) {
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
                "reached end"
            );
            (, uint96 buyAmountOfIter, uint96 selAmountOfIter) =
                iterOrder.decodeOrder();
            require(
                sumBidAmount.mul(buyAmountOfIter) <
                    auctioneerSellAmount.mul(selAmountOfIter),
                "too many orders"
            );

            auctionData[auctionId].interimSumBidAmount = sumBidAmount;
            auctionData[auctionId].interimOrder = iterOrder;
        }
           
    function setFeeParameters(
            uint256 newFeeNumerator,
            address newfeeReceiverAddress
        ) public onlyOwner() {
            require(newFeeNumerator <= 15);
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
            require(registeredUsers.insert(numUsers, user),"User Exists");
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


    function getFormHash(uint256 auction_id) public view returns(string memory){
        require(auction_id<=auctionCounter, "Invalid Id");
        return auctionData[auction_id].initData.formHash;
    }

    function orderplace(uint256 auctionId) internal view {
        require(
            block.timestamp < auctionData[auctionId].initData.auctionEndDate,
            "Not in order placement phase"
        );
    }

    function solutionSubmission(uint256 auctionId) internal view{
            uint256 auctionEndDate = auctionData[auctionId].initData.auctionEndDate;
            require(
                auctionEndDate != 0 &&
                    block.timestamp >= auctionEndDate &&
                    auctionData[auctionId].clearingPriceOrder == bytes32(0),
                "Not in submission phase"
            );
        }
}