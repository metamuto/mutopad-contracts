// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./libraries/SafeCast.sol";
import "./libraries/IdToAddressBiMap.sol";
import "./libraries/IterableOrderedOrderSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

struct InitialPoolData{
    string formHash;
    IERC20 poolingToken;
    IERC20 biddingToken;
    uint40 orderCancellationEndDate;
    uint40 poolStartDate;
    uint40 poolEndDate;
    uint96 pooledSellAmount;
    uint96 minBuyAmount;
    uint256 minimumBiddingAmountPerOrder;
    uint256 minFundingThreshold;
    bool isAtomicClosureAllowed;
}
    
struct PoolData {
    InitialPoolData initData;
    address poolOwner;
    bytes32 initialPoolOrder;
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

    mapping(uint256 => PoolData) public poolData;
    mapping(uint256 => IterableOrderedOrderSet.Data) internal sellOrders;

    uint64 public numUsers;
    uint256 public poolCounter;
    IdToAddressBiMap.Data private registeredUsers;

    constructor()  Ownable() {}

    uint64 public feeReceiverUserId = 1;
    uint256 public feeNumerator = 15;
    uint256 public constant FEE_DENOMINATOR = 1000;

    function iscancellledorDeleted(uint256 poolId) internal view{
        require(!poolData[poolId].isScam);
        require(!poolData[poolId].isDeleted);
    }

    modifier atStageOrderPlacementAndCancelation(uint256 poolId) {
        require(
            block.timestamp < poolData[poolId].initData.orderCancellationEndDate,
            "not in  placement/cancelation phase"
        );
        _;
    }
    
    modifier atStageFinished(uint256 poolId) {
        require(
            poolData[poolId].clearingPriceOrder != bytes32(0),
            "Pool not finished"
        );
        _;
    }
    
    modifier atStageOrderPlacement(uint256 poolId) {
        orderplace(poolId);
        _;
    }

    modifier atStageSolutionSubmission(uint256 poolId) {
        solutionSubmission(poolId);
        iscancellledorDeleted(poolId);   

        _;
    }

    event NewPool(
        uint256 indexed poolId,
        IERC20 indexed _poolingToken,
        IERC20 indexed _biddingToken,
        uint256 poolStartDate,
        uint256 orderCancellationEndDate,
        uint256 poolEndDate,
        uint64 userId,
        uint96 _pooledSellAmount,
        uint96 _minBuyAmount,
        uint256 minimumBiddingAmountPerOrder,
        uint256 minFundingThreshold
    );

    event UserEditted(
        uint256 indexed poolId,
        uint256 poolStartDate,
        uint256 poolEndDate,
        uint256 orderCancellationEndDate,
        string formHash


    );
    event AdminEditted(
        uint256 indexed poolId,
        uint256 poolStartDate,
        uint256 poolEndDate,
        uint256 orderCancellationEndDate,
        uint256 minimumBiddingAmountPerOrder,
        uint256 minFundingThreshold

    );

    event ClaimedFromOrder(
        uint256 indexed poolId,
        uint64 indexed userId,
        uint96 buyAmount,
        uint96 sellAmount
    );

    event PoolCleared(
        uint256 indexed poolId,
        uint96 soldpoolingTokens,
        uint96 soldBiddingTokens,
        bytes32 clearingPriceOrder
    );    

    event NewSellOrder(
        uint256 indexed poolId,
        uint64 indexed userId,
        uint96 buyAmount,
        uint96 sellAmount
    );

    event CancellationSellOrder(
        uint256 indexed poolId,
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
    

    function getCurrentPoolPrice(uint256 _poolId) external view returns(uint){
        bytes32 current = sellOrders[_poolId].getCurrent();
        (, uint96 buyAmount, uint96 sellAmount) =
                    current.decodeOrder();
        return sellAmount.div(buyAmount);
    }
    
    function initiatePool(
            string memory _formHash,
            IERC20 _poolingToken,
            IERC20 _biddingToken,
            uint40 _orderCancellationEndDate,  
            uint40 _poolStartDate,
            uint40 _poolEndDate,
            uint96 _pooledSellAmount,
            uint96 _minBuyAmount,
            uint256 _minimumBiddingAmountPerOrder,
            uint256 _minFundingThreshold,
            bool _isAtomicClosureAllowed
        ) public returns (uint256) {
            require(_poolingToken.balanceOf(msg.sender)>= _pooledSellAmount.mul(FEE_DENOMINATOR.add(feeNumerator)).div(
                    FEE_DENOMINATOR), "BNE");
            require(block.timestamp<_poolStartDate && 
                    _poolStartDate<_poolEndDate && 
                    _orderCancellationEndDate <= _poolEndDate &&
                    _poolEndDate > block.timestamp, "DNCC");
            require(_pooledSellAmount > 0 &&
                    _minBuyAmount > 0 &&
                    _minimumBiddingAmountPerOrder > 0,"ACBZ");
            _poolingToken.safeTransferFrom(
                msg.sender,
                address(this),
                 _pooledSellAmount.mul(FEE_DENOMINATOR.add(feeNumerator)).div(
                    FEE_DENOMINATOR)
            );
            InitialPoolData memory  data = InitialPoolData(
                    _formHash,
                    _poolingToken,
                    _biddingToken,
                    _orderCancellationEndDate,
                    _poolStartDate,
                    _poolEndDate,
                    _pooledSellAmount,
                    _minBuyAmount,
                    _minimumBiddingAmountPerOrder,
                    _minFundingThreshold,
                    _isAtomicClosureAllowed
                );
            poolCounter = poolCounter.add(1);
            sellOrders[poolCounter].initializeEmptyList();
            uint64 userId = getUserId(msg.sender);
            poolData[poolCounter] = PoolData(
                data,
                msg.sender,
                IterableOrderedOrderSet.encodeOrder(
                    userId,
                    _minBuyAmount,
                    _pooledSellAmount
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
            emit NewPool(
                poolCounter,
                _poolingToken,
                _biddingToken,
                _poolStartDate,
                _orderCancellationEndDate,
                _poolEndDate,
                userId,
                _pooledSellAmount,
                _minBuyAmount,
                _minimumBiddingAmountPerOrder,
                _minFundingThreshold
            );
            return poolCounter;
        }

    function markSpam(uint256 poolId) external onlyOwner{
        poolData[poolId].isScam = true;
        poolData[poolId].initData.poolingToken.safeTransfer(
                msg.sender,
                pooledSellAmount
            );
        
    }

    function deletPool(uint256 poolId) external onlyOwner{
        poolData[poolId].isDeleted = true;
        poolData[poolId].initData.poolingToken.safeTransfer(
                msg.sender,
                pooledSellAmount
            );
    }

    function updatePoolAdmin(uint256 poolId, uint40 _startTime, uint40 _endTime, uint40 _cancelTime, uint256 _fundingThreshold,uint256 _minBid ) external onlyOwner{
        poolData[poolId].initData.poolStartDate = _startTime;
        poolData[poolId].initData.poolEndDate = _endTime;
        poolData[poolId].initData.orderCancellationEndDate = _cancelTime;
        poolData[poolId].initData.minFundingThreshold = _fundingThreshold;
        poolData[poolId].initData.minimumBiddingAmountPerOrder = _minBid;
        emit AdminEditted(
            poolId,
            _startTime,
            _endTime,
            _cancelTime,
            _minBid,
            _fundingThreshold
        );
    }

    function updatePoolUser(uint256 poolId, uint40 _startTime, uint40 _endTime, uint40 _cancelTime, string memory _formHash) external{
        require(msg.sender==poolData[poolId].poolOwner);
        poolData[poolId].initData.poolStartDate = _startTime;
        poolData[poolId].initData.poolEndDate = _endTime;
        poolData[poolId].initData.orderCancellationEndDate = _cancelTime;
        poolData[poolId].initData.formHash = _formHash;
        emit UserEditted(
            poolId,
            _startTime,
            _endTime,
            _cancelTime,
            _formHash
        );
    }
        
    function placeSellOrders(
            uint256 poolId,
            uint96 _minBuyAmount,
            uint96 _sellAmount,
            bytes32 _prevSellOrder
        ) external atStageOrderPlacement(poolId) returns (uint64 userId) {
            return
                _placeSellOrders(
                    poolId,
                    _minBuyAmount,
                    _sellAmount,
                    _prevSellOrder,
                    msg.sender
                );
        }


    function placeSellOrdersOnBehalf(
            uint256 poolId,
            uint96 _minBuyAmount,
            uint96 _sellAmount,
            bytes32 _prevSellOrder,
            address orderSubmitter
        ) external atStageOrderPlacement(poolId) returns (uint64 userId) {
            return
                _placeSellOrders(
                    poolId,
                    _minBuyAmount,
                    _sellAmount,
                    _prevSellOrder,
                    orderSubmitter
                );
        }


    function _placeSellOrders(
            uint256 poolId,
            uint96 _minBuyAmount,
            uint96 _sellAmount,
            bytes32 _prevSellOrder,
            address orderSubmitter
        ) internal returns (uint64 userId) {
            {
                (   ,
                    uint96 buyAmountOfInitialPoolOrder,
                    uint96 sellAmountOfInitialPoolOrder
                ) = poolData[poolId].initialPoolOrder.decodeOrder();
                require(
                        _minBuyAmount.mul(buyAmountOfInitialPoolOrder) <
                            sellAmountOfInitialPoolOrder.mul(_sellAmount),
                        "limit price is <  min offer"
                    );
            }
            userId = getUserId(orderSubmitter);
            uint256 minimumBiddingAmountPerOrder =
                poolData[poolId].initData.minimumBiddingAmountPerOrder;
                require(_minBuyAmount > 0,"buyAmounts must be < 0");
                require(_sellAmount > minimumBiddingAmountPerOrder,"order too small");
                if (
                    sellOrders[poolId].insert(
                        IterableOrderedOrderSet.encodeOrder(
                            userId,
                            _minBuyAmount,
                            _sellAmount
                        ),
                        _prevSellOrder
                    )
                ) {
                    emit NewSellOrder(
                        poolId,
                        userId,
                        _minBuyAmount,
                        _sellAmount
                    );
                }
            poolData[poolId].initData.biddingToken.safeTransferFrom(
                msg.sender,
                address(this),
                _sellAmount
            );
        }
            
        
    function cancelSellOrder(uint256 poolId, bytes32 _sellOrder)
            public
            atStageOrderPlacementAndCancelation(poolId)
        {
            uint64 userId = getUserId(msg.sender);
            bool success = sellOrders[poolId].removeKeepHistory(_sellOrder);
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
                    poolId,
                    userId,
                    buyAmountOfIter,
                    sellAmountOfIter
                );
                poolData[poolId].initData.biddingToken.safeTransfer(
                msg.sender,
                sellAmountOfIter
            );
            }
        }


    function sendOutTokens(
            uint256 poolId,
            uint256 poolingTokenAmount,
            uint256 biddingTokenAmount,
            uint64 userId
        ) internal {
            address userAddress = registeredUsers.getAddressAt(userId);
            if (poolingTokenAmount > 0) {
                poolData[poolId].initData.poolingToken.safeTransfer(
                    userAddress,
                    poolingTokenAmount
                );
            }
            if (biddingTokenAmount > 0) {
                poolData[poolId].initData.biddingToken.safeTransfer(
                    userAddress,
                    biddingTokenAmount
                );
            }
        }
        
    function claimFromParticipantOrder(
            uint256 poolId,
            bytes32 order
        )
            public
            atStageFinished(poolId)
            returns (
                uint256 poolingTokenAmount,
                uint256 biddingTokenAmount
            )
        {
            require(sellOrders[poolId].remove(order),"order not claimable");
            (, uint96 priceNumerator, uint96 priceDenominator) = poolData[poolId].clearingPriceOrder.decodeOrder();
            (uint64 userId, uint96 buyAmount, uint96 sellAmount) = order.decodeOrder();
            require(getUserId(msg.sender) == userId,"Claimable by user");
            if (poolData[poolId].minFundingThresholdNotReached)
            {
            	biddingTokenAmount = sellAmount;
            }
            else {
            	if (order == poolData[poolId].clearingPriceOrder) {
		        poolingTokenAmount =
		            poolData[poolId]
		                .volumeClearingPriceOrder
		                .mul(priceNumerator)
		                .div(priceDenominator);
		        biddingTokenAmount = sellAmount.sub(poolData[poolId].volumeClearingPriceOrder);
               } else {
                        if (order.smallerThan(poolData[poolId].clearingPriceOrder)) {
                            poolingTokenAmount =
                                sellAmount.mul(priceNumerator).div(priceDenominator);
                        } else {
                            biddingTokenAmount = sellAmount;
                        }
                    }
            }
            emit ClaimedFromOrder(poolId, userId, buyAmount, sellAmount);
            sendOutTokens(
                poolId,
                poolingTokenAmount,
                biddingTokenAmount,
                userId
            );    
            
        }   
           
    function processFeesAndPoolerFunds(
            uint256 poolId,
            uint256 fillVolumeOfPoolerOrder,
            uint64 poolerId,
            uint96 fullPooledAmount
        ) internal {
            uint256 feeAmount =
                fullPooledAmount.mul(poolData[poolId].feeNumerator).div(
                    FEE_DENOMINATOR
                ); //[20]
            if (poolData[poolId].minFundingThresholdNotReached) {
                sendOutTokens(
                    poolId,
                    fullPooledAmount.add(feeAmount),
                    0,
                    poolerId
                ); //[4]
            } else {
                //[11]
                (, uint96 priceNumerator, uint96 priceDenominator) =
                    poolData[poolId].clearingPriceOrder.decodeOrder();
                uint256 unsettledPooledTokens =
                    fullPooledAmount.sub(fillVolumeOfPoolerOrder);
                uint256 poolingTokenAmount =
                    unsettledPooledTokens.add(
                        feeAmount.mul(unsettledPooledTokens).div(
                            fullPooledAmount
                        )
                    );
                uint256 biddingTokenAmount =
                    fillVolumeOfPoolerOrder.mul(priceDenominator).div(
                        priceNumerator
                    );
                sendOutTokens(
                    poolId,
                    poolingTokenAmount,
                    biddingTokenAmount,
                    poolerId
                ); //[5]
                sendOutTokens(
                    poolId,
                    feeAmount.mul(fillVolumeOfPoolerOrder).div(
                        fullPooledAmount
                    ),
                    0,
                    feeReceiverUserId
                ); //[7]
            }
        }  
        

    function settlePoolAtomically(
            uint256 poolId,
            uint96 _minBuyAmount,
            uint96 _sellAmount,
            bytes32 _prevSellOrder
        ) public atStageSolutionSubmission(poolId) {
            require(
                poolData[poolId].initData.isAtomicClosureAllowed,
                "not allowed"
            );
            uint64 userId = getUserId(msg.sender);
            require(
                poolData[poolId].interimOrder.smallerThan(
                    IterableOrderedOrderSet.encodeOrder(
                        userId,
                        _minBuyAmount,
                        _sellAmount
                    )
                )
            );
            _placeSellOrders(
                poolId,
                _minBuyAmount,
                _sellAmount,
                _prevSellOrder,
                msg.sender
            );
            settlePool(poolId);
        }


    function settlePool(uint256 poolId)
            public
            atStageSolutionSubmission(poolId)
            returns (bytes32 clearingOrder)
        {
            (
                uint64 poolerId,
                uint96 minPooledBuyAmount,
                uint96 fullPooledAmount
            ) = poolData[poolId].initialPoolOrder.decodeOrder();

            uint256 currentBidSum = poolData[poolId].interimSumBidAmount;
            bytes32 currentOrder = poolData[poolId].interimOrder;
            uint256 buyAmountOfIter;
            uint256 sellAmountOfIter;
            uint96 fillVolumeOfPoolerOrder = fullPooledAmount;
            // Sum order up, until fullPooledAmount is fully bought or queue end is reached
            do {
                bytes32 nextOrder = sellOrders[poolId].next(currentOrder);
                if (nextOrder == IterableOrderedOrderSet.QUEUE_END) {
                    break;
                }
                currentOrder = nextOrder;
                (, buyAmountOfIter, sellAmountOfIter) = currentOrder.decodeOrder();
                currentBidSum = currentBidSum.add(sellAmountOfIter);
            } while (
                currentBidSum.mul(buyAmountOfIter) <
                    fullPooledAmount.mul(sellAmountOfIter)
            );

            if (
                currentBidSum > 0 &&
                currentBidSum.mul(buyAmountOfIter) >=
                fullPooledAmount.mul(sellAmountOfIter)
            ) {
                // All considered/summed orders are sufficient to close the pool fully
                // at price between current and previous orders.
                uint256 uncoveredBids =
                    currentBidSum.sub(
                        fullPooledAmount.mul(sellAmountOfIter).div(
                            buyAmountOfIter
                        )
                    );

                if (sellAmountOfIter >= uncoveredBids) {
                    //[13]
                    // Pool fully filled via partial match of currentOrder
                    uint256 sellAmountClearingOrder =
                        sellAmountOfIter.sub(uncoveredBids);
                    poolData[poolId]
                        .volumeClearingPriceOrder = sellAmountClearingOrder
                        .toUint96();
                    currentBidSum = currentBidSum.sub(uncoveredBids);
                    clearingOrder = currentOrder;
                } else {
                    currentBidSum = currentBidSum.sub(sellAmountOfIter);
                    clearingOrder = IterableOrderedOrderSet.encodeOrder(
                        0,
                        fullPooledAmount,
                       uint96 (currentBidSum)
                    );
                }
            } else {
                if (currentBidSum > minPooledBuyAmount) {
                    clearingOrder = IterableOrderedOrderSet.encodeOrder(
                        0,
                        fullPooledAmount,
                        currentBidSum.toUint96()
                    );
                } else {
                    //[16]
                    // Even at the initial pool price, the pool is partially filled
                    clearingOrder = IterableOrderedOrderSet.encodeOrder(
                        0,
                        fullPooledAmount,
                        minPooledBuyAmount
                    );
                    fillVolumeOfPoolerOrder = currentBidSum
                        .mul(fullPooledAmount)
                        .div(minPooledBuyAmount)
                        .toUint96();
                }
            }
            poolData[poolId].clearingPriceOrder = clearingOrder;

            if (poolData[poolId].initData.minFundingThreshold > currentBidSum) {
                poolData[poolId].minFundingThresholdNotReached = true;
            }
            processFeesAndPoolerFunds(
                poolId,
                fillVolumeOfPoolerOrder,
                poolerId,
                fullPooledAmount
            );
            emit PoolCleared(
                poolId,
                fillVolumeOfPoolerOrder,
                uint96(currentBidSum),
                clearingOrder
            );

            poolData[poolId].initialPoolOrder = bytes32(0);
            poolData[poolId].interimOrder = bytes32(0);
            poolData[poolId].interimSumBidAmount = uint256(0);
            poolData[poolId].initData.minimumBiddingAmountPerOrder = uint256(0);
        }   
        
        
    function precalculateSellAmountSum(
            uint256 poolId,
            uint256 iterationSteps
        ) public atStageSolutionSubmission(poolId) {
            (, , uint96 poolerSellAmount) =
                poolData[poolId].initialPoolOrder.decodeOrder();
            uint256 sumBidAmount = poolData[poolId].interimSumBidAmount;
            bytes32 iterOrder = poolData[poolId].interimOrder;

            for (uint256 i = 0; i < iterationSteps; i++) {
                iterOrder = sellOrders[poolId].next(iterOrder);
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
                    poolerSellAmount.mul(selAmountOfIter),
                "too many orders"
            );

            poolData[poolId].interimSumBidAmount = sumBidAmount;
            poolData[poolId].interimOrder = iterOrder;
        }
           
    function setFeeParameters(
            uint256 newFeeNumerator,
            address newfeeReceiverAddress
        ) public onlyOwner() {
            require(newFeeNumerator <= 15, "Fee can't be > 1.5%");
            feeReceiverUserId = getUserId(newfeeReceiverAddress);
            feeNumerator = newFeeNumerator;
        }
        
        
    function containsOrder(uint256 poolId, bytes32 order)
            public
            view
            returns (bool)
        {
            return sellOrders[poolId].contains(order);
        }
        
        
    function getSecondsRemainingInBatch(uint256 poolId)
            public
            view
            returns (uint256)
        {
            if (poolData[poolId].initData.poolEndDate < block.timestamp) {
                return 0;
            }
            return poolData[poolId].initData.poolEndDate.sub(block.timestamp);
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


    function getFormHash(uint256 poolId) public view returns(string memory){
        require(poolId<=poolCounter, "Invalid Id");
        return poolData[poolId].initData.formHash;
    }

    function orderplace(uint256 poolId) internal view {
        require(
            block.timestamp < poolData[poolId].initData.poolEndDate,
            "Not in order placement phase"
        );
    }

    function solutionSubmission(uint256 poolId) internal view{
            uint256 poolEndDate = poolData[poolId].initData.poolEndDate;
            require(
                poolEndDate != 0 &&
                    block.timestamp >= poolEndDate &&
                    poolData[poolId].clearingPriceOrder == bytes32(0),
                "Not in submission phase"
            );
        }
}