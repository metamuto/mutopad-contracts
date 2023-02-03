// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;
import "./libraries/SafeCast.sol";
import "./libraries/IdToAddressBiMap.sol";
import "./libraries/IterableOrderedOrderSet.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

// Pool input data
struct InitialPoolData {
  string formHash;
  IERC20Upgradeable poolingToken;
  IERC20Upgradeable biddingToken;
  uint40 orderCancellationEndDate;
  uint40 poolStartDate;
  uint40 poolEndDate;
  uint96 pooledSellAmount;
  uint96 minBuyAmount;
  uint256 minimumBiddingAmountPerOrder;
  uint256 minFundingThreshold;
  bool isAtomicClosureAllowed;
}
// Pool data
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

contract MutoPool is OwnableUpgradeable {
  using SafeERC20Upgradeable for IERC20Upgradeable;
  using SafeMath for uint40;
  using SafeMath for uint64;
  using SafeMath for uint96;
  using SafeMath for uint256;
  using SafeCast for uint256;
  using SafeCast for uint64;
  using IterableOrderedOrderSet for bytes32;
  using IdToAddressBiMap for IdToAddressBiMap.Data;
  using IterableOrderedOrderSet for IterableOrderedOrderSet.Data;

  mapping(uint64 => PoolData) public poolData;
  mapping(uint256 => IterableOrderedOrderSet.Data) internal sellOrders;

  uint64 public numUsers;
  uint64 public poolCounter;
  IdToAddressBiMap.Data private registeredUsers;

  uint64 public feeReceiverUserId;
  uint256 public feeNumerator;
  uint256 public constant FEE_DENOMINATOR = 1000;

  // To check if pool is marked scam or deleted
  modifier scammedOrDeleted(uint64 poolId) {
    require(poolData[poolId].isScam || poolData[poolId].isDeleted, "Pool not Scammed or Deleted"); // pool should be scammed or deleted
    _;
  }

  // To check if cancelation date is reached or not
  modifier atStageOrderPlacementAndCancelation(uint64 poolId) {
    require(block.timestamp < poolData[poolId].initData.orderCancellationEndDate, "Not in order placement/cancelation phase"); // cancellation date shouldn't have passed
    _;
  }

  // To check if pool has finished
  modifier atStageFinished(uint64 poolId) {
    require(poolData[poolId].clearingPriceOrder != bytes32(0), "Pool not finished");
    _;
  }

  // To check if pool end date is reached
  modifier atStageOrderPlacement(uint64 poolId) {
    require(block.timestamp < poolData[poolId].initData.poolEndDate, "Not in order placement phase"); // pool end date must not be reached
    _;
  }

  // To check pool is not marked scam and deleted
  modifier isScammedOrDeleted(uint64 poolId) {
    require(!poolData[poolId].isScam && !poolData[poolId].isDeleted, "Deleted or Scammed"); // poll must not be marked as deleted or scammed
    _;
  }

  // To check if end date has reached and pool can be cleared
  modifier atStageSolutionSubmission(uint64 poolId) {
    require(
      poolData[poolId].initData.poolEndDate != 0 &&
        block.timestamp >= poolData[poolId].initData.poolEndDate &&
        poolData[poolId].clearingPriceOrder == bytes32(0),
      "Not in submission phase"
    ); // pool end date must have reached
    require(!poolData[poolId].isScam && !poolData[poolId].isDeleted, "Deleted or Scammed"); //pool must not be deleted or scamed
    _;
  }

  // Both NewPoolE1 and NewPoolE2 are emitted on pool initialization
  event NewPoolE1(
    uint64 indexed poolId,
    uint256 indexed userId,
    address indexed poolOwner,
    string formHash,
    IERC20Upgradeable poolingToken,
    IERC20Upgradeable biddingToken,
    uint40 orderCancellationEndDate,
    uint40 poolStartDate,
    uint40 poolEndDate,
    uint96 pooledSellAmount,
    uint96 minBuyAmount
  );

  event NewPoolE2(
    uint64 indexed poolId,
    bytes32 initialPoolOrder,
    uint256 interimsumBidAmount,
    bytes32 interimOrder,
    bytes32 clearingPriceOrder,
    uint96 volumeClearingOrder,
    bool minimumFundingThresholdReached,
    uint256 minimumBiddingAmountPerOrder,
    uint256 minFundingThreshold,
    bool isAtomicClosureAllowed,
    uint256 feeNumerator,
    bool isScam,
    bool isDeleted
  );

  event OrderClaimedByUser(uint64 indexed poolId, uint64 indexed userId, uint96 buyAmount, uint96 sellAmount);

  event PoolEdittedByUser(uint64 indexed poolId, string formHash);

  event PoolEdittedByAdmin(
    uint64 indexed poolId,
    uint256 poolStartDate,
    uint256 poolEndDate,
    uint256 orderCancellationEndDate,
    uint256 minimumBiddingAmountPerOrder,
    uint256 minFundingThreshold
  );

  event PoolCleared(uint64 indexed poolId, uint96 soldPoolingTokens, uint96 soldBiddingTokens, bytes32 clearingPriceOrder);

  event NewSellOrderPlaced(uint64 indexed poolId, uint64 indexed userId, uint96 buyAmount, uint96 sellAmount, bytes32 sellOrder);

  event SellOrderCancelled(uint64 indexed poolId, uint64 indexed userId, uint96 buyAmount, uint96 sellAmount, bytes32 sellOrder);

  event OrderRefunded(uint64 indexed poolId, uint64 indexed userId, uint96 buyAmount, uint96 sellAmount, bytes32 sellOrder);

  event NewUser(uint64 indexed userId, address indexed userAddress);

  event UserRegistration(address indexed user, uint64 userId);

  function setFeeParameters(uint256 newFeeNumerator, address newfeeReceiverAddress) external onlyOwner {
    require(newFeeNumerator <= 15); // pool fee can be maximum upto 1.5 %
    feeReceiverUserId = getUserId(newfeeReceiverAddress);
    feeNumerator = newFeeNumerator;
  }

  function CheckUserId(address userAddress) external view returns (uint64) {
    require(registeredUsers.hasAddress(userAddress), "Not Registered Yet"); // user must be registered
    return registeredUsers.getId(userAddress);
  }

  function initialize() public initializer {
    feeReceiverUserId = 1;
    feeNumerator = 15;
  }

  function initiatePool(InitialPoolData calldata _initData) external returns (uint256) {
    uint256 _ammount = _initData.pooledSellAmount.mul(FEE_DENOMINATOR.add(feeNumerator)).div(FEE_DENOMINATOR);
    require(_initData.poolingToken.balanceOf(msg.sender) >= _ammount, "Not enough balance");
    // dates must be configured carefully
    // start date < cancellation date < end date
    require(
      block.timestamp < _initData.poolStartDate &&
        _initData.poolStartDate < _initData.poolEndDate &&
        _initData.orderCancellationEndDate <= _initData.poolEndDate &&
        _initData.poolEndDate > block.timestamp,
      "Date not configured correctly"
    );
    require(
      _initData.pooledSellAmount > 0 && // ppled amount must be greater than zero
        _initData.minBuyAmount > 0 && // minimum buy amount must be greater than zero
        _initData.minimumBiddingAmountPerOrder > 0, // minimum sell amount of order must be grater than zero
      "Ammount can't be zero"
    );
    // need to approve tokens to this contract
    _initData.poolingToken.safeTransferFrom(msg.sender, address(this), _ammount);
    poolCounter = poolCounter + 1;
    sellOrders[poolCounter].initializeEmptyList();
    uint64 userId = getUserId(msg.sender);
    poolData[poolCounter] = PoolData(
      _initData,
      msg.sender,
      IterableOrderedOrderSet.encodeOrder(userId, _initData.minBuyAmount, _initData.pooledSellAmount),
      0,
      IterableOrderedOrderSet.QUEUE_START,
      bytes32(0),
      0,
      false,
      feeNumerator,
      false,
      false
    );
    emit NewPoolE1(
      poolCounter,
      userId,
      msg.sender,
      _initData.formHash,
      _initData.poolingToken,
      _initData.biddingToken,
      _initData.orderCancellationEndDate,
      _initData.poolStartDate,
      _initData.poolEndDate,
      _initData.pooledSellAmount,
      _initData.minBuyAmount
    );
    emit NewPoolE2(
      poolCounter,
      IterableOrderedOrderSet.encodeOrder(userId, _initData.minBuyAmount, _initData.pooledSellAmount),
      0,
      IterableOrderedOrderSet.QUEUE_START,
      bytes32(0),
      0,
      false,
      _initData.minimumBiddingAmountPerOrder,
      _initData.minFundingThreshold,
      _initData.isAtomicClosureAllowed,
      feeNumerator,
      false,
      false
    );
    return poolCounter;
  }

  function getFormHash(uint64 pool_id) external view returns (string memory) {
    // pool must exist
    require(pool_id <= poolCounter, "Invali pool ID");
    return poolData[pool_id].initData.formHash;
  }

  function updatePoolAdmin(
    uint64 poolId,
    uint40 _startTime,
    uint40 _endTime,
    uint40 _cancelTime,
    uint256 _fundingThreshold,
    uint256 _minBid
  ) external onlyOwner {
    poolData[poolId].initData.poolStartDate = _startTime;
    poolData[poolId].initData.poolEndDate = _endTime;
    poolData[poolId].initData.orderCancellationEndDate = _cancelTime;
    poolData[poolId].initData.minFundingThreshold = _fundingThreshold;
    poolData[poolId].initData.minimumBiddingAmountPerOrder = _minBid;
    emit PoolEdittedByAdmin(poolId, _startTime, _endTime, _cancelTime, _minBid, _fundingThreshold);
  }

  function updatePoolUser(uint64 poolId, string memory _formHash) external {
    require(msg.sender == poolData[poolId].poolOwner, "Can be updated by pool owner only");
    poolData[poolId].initData.formHash = _formHash;
    emit PoolEdittedByUser(poolId, _formHash);
  }

  // To fetch the latest bid buy & sell amount
  function getCurrentPoolPrice(uint256 _poolId) external view returns (uint96 buyAmount, uint96 sellAmount) {
    bytes32 current = sellOrders[_poolId].getCurrent();
    (, buyAmount, sellAmount) = current.decodeOrder();
  }

  function markSpam(uint64 poolId) external onlyOwner {
    poolData[poolId].isScam = true;
    // returns the funds to pooler
    poolData[poolId].initData.poolingToken.safeTransfer(poolData[poolId].poolOwner, poolData[poolId].initData.pooledSellAmount);
  }

  function deletPool(uint64 poolId) external onlyOwner {
    poolData[poolId].isDeleted = true;
    //returns the funds to pooler
    poolData[poolId].initData.poolingToken.safeTransfer(poolData[poolId].poolOwner, poolData[poolId].initData.pooledSellAmount);
  }

  function getEncodedOrder(
    uint64 userId,
    uint96 buyAmount,
    uint96 sellAmount
  ) external pure returns (bytes32) {
    return bytes32((uint256(userId) << 192) + (uint256(buyAmount) << 96) + uint256(sellAmount));
  }

  function placeSellOrders(
    uint64 poolId,
    uint96[] memory _minBuyAmounts,
    uint96[] memory _sellAmounts,
    bytes32[] memory _prevSellOrders
  ) external atStageOrderPlacement(poolId) isScammedOrDeleted(poolId) returns (uint64 userId) {
    return _placeSellOrders(poolId, _minBuyAmounts, _sellAmounts, _prevSellOrders, msg.sender);
  }

  function placeSellOrdersOnBehalf(
    uint64 poolId,
    uint96[] memory _minBuyAmounts,
    uint96[] memory _sellAmounts,
    bytes32[] memory _prevSellOrders,
    address orderSubmitter
  ) external atStageOrderPlacement(poolId) isScammedOrDeleted(poolId) returns (uint64 userId) {
    return _placeSellOrders(poolId, _minBuyAmounts, _sellAmounts, _prevSellOrders, orderSubmitter);
  }

  function cancelSellOrders(uint64 poolId, bytes32[] memory _sellOrders)
    external
    atStageOrderPlacementAndCancelation(poolId)
    isScammedOrDeleted(poolId)
  {
    uint64 userId = getUserId(msg.sender);
    uint256 claimableAmount = 0;
    for (uint256 i = 0; i < _sellOrders.length; i++) {
      bool success = sellOrders[poolId].removeKeepHistory(_sellOrders[i]);
      if (success) {
        (uint64 userIdOfIter, uint96 buyAmountOfIter, uint96 sellAmountOfIter) = _sellOrders[i].decodeOrder();
        // User must be order placer
        require(userIdOfIter == userId, "Only order placer can cancel");
        claimableAmount = claimableAmount.add(sellAmountOfIter);
        emit SellOrderCancelled(poolId, userId, buyAmountOfIter, sellAmountOfIter, _sellOrders[i]);
      }
    }
    poolData[poolId].initData.biddingToken.safeTransfer(msg.sender, claimableAmount);
  }

  function refundOrder(uint64 poolId, bytes32 order) external scammedOrDeleted(poolId) {
    // check if order exists
    require(sellOrders[poolId].remove(order), "Order not refundable");
    uint64 userId = getUserId(msg.sender);
    (uint64 userIdOrder, uint96 buyAmount, uint96 sellAmount) = order.decodeOrder();
    // check if user is order placer
    require(userIdOrder == userId, "Not Order Placer");
    poolData[poolId].initData.biddingToken.safeTransfer(msg.sender, sellAmount);
    emit OrderRefunded(poolId, userId, buyAmount, sellAmount, order);
  }

  function claimFromParticipantOrder(uint64 poolId, bytes32[] memory orders)
    external
    atStageFinished(poolId)
    isScammedOrDeleted(poolId)
    returns (uint256 sumPoolingTokenAmount, uint256 sumBiddingTokenAmount)
  {
    for (uint256 i = 0; i < orders.length; i++) {
      require(sellOrders[poolId].remove(orders[i]), "Order not claimable");
    }
    PoolData memory pool = poolData[poolId];
    (, uint96 priceNumerator, uint96 priceDenominator) = pool.clearingPriceOrder.decodeOrder();
    (uint64 userId, , ) = orders[0].decodeOrder();
    bool minFundingThresholdNotReached = poolData[poolId].minFundingThresholdNotReached;
    for (uint256 i = 0; i < orders.length; i++) {
      (uint64 userIdOrder, uint96 buyAmount, uint96 sellAmount) = orders[i].decodeOrder();
      require(userIdOrder == userId, "Claimable by user only");
      if (minFundingThresholdNotReached) {
        sumBiddingTokenAmount = sumBiddingTokenAmount.add(sellAmount);
      } else {
        if (orders[i] == pool.clearingPriceOrder) {
          sumPoolingTokenAmount = sumPoolingTokenAmount.add(pool.volumeClearingPriceOrder.mul(priceNumerator).div(priceDenominator));
          sumBiddingTokenAmount = sumBiddingTokenAmount.add(sellAmount.sub(pool.volumeClearingPriceOrder));
        } else {
          if (orders[i].smallerThan(pool.clearingPriceOrder)) {
            sumPoolingTokenAmount = sumPoolingTokenAmount.add(sellAmount.mul(priceNumerator).div(priceDenominator));
          } else {
            sumBiddingTokenAmount = sumBiddingTokenAmount.add(sellAmount);
          }
        }
      }
      emit OrderClaimedByUser(poolId, userId, buyAmount, sellAmount);
    }
    sendOutTokens(poolId, sumPoolingTokenAmount, sumBiddingTokenAmount, userId);
  }

  function settlePoolAtomically(
    uint64 poolId,
    uint96[] memory _minBuyAmount,
    uint96[] memory _sellAmount,
    bytes32[] memory _prevSellOrder
  ) external atStageSolutionSubmission(poolId) {
    require(poolData[poolId].initData.isAtomicClosureAllowed, "Not autosettle allowed");
    require(_minBuyAmount.length == 1 && _sellAmount.length == 1);
    uint64 userId = getUserId(msg.sender);
    require(poolData[poolId].interimOrder.smallerThan(IterableOrderedOrderSet.encodeOrder(userId, _minBuyAmount[0], _sellAmount[0])));
    _placeSellOrders(poolId, _minBuyAmount, _sellAmount, _prevSellOrder, msg.sender);
    settlePool(poolId);
  }

  function registerUser(address user) public returns (uint64 userId) {
    numUsers = numUsers.add(1).toUint64();
    // check if user already registered
    require(registeredUsers.insert(numUsers, user), "User already exists");
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

  function getSecondsRemainingInBatch(uint64 poolId) public view returns (uint256) {
    if (poolData[poolId].initData.poolEndDate < block.timestamp) {
      return 0;
    }
    return poolData[poolId].initData.poolEndDate.sub(block.timestamp);
  }

  function containsOrder(uint64 poolId, bytes32 order) public view returns (bool) {
    return sellOrders[poolId].contains(order);
  }

  function settlePool(uint64 poolId) public atStageSolutionSubmission(poolId) returns (bytes32 clearingOrder) {
    (uint64 poolerId, uint96 minPooledBuyAmount, uint96 fullPooledAmount) = poolData[poolId].initialPoolOrder.decodeOrder();
    uint256 currentBidSum = poolData[poolId].interimSumBidAmount;
    bytes32 currentOrder = poolData[poolId].interimOrder;
    uint256 buyAmountOfIter;
    uint256 sellAmountOfIter;
    uint96 fillVolumeOfPoolerOrder = fullPooledAmount;
    do {
      bytes32 nextOrder = sellOrders[poolId].next(currentOrder);
      if (nextOrder == IterableOrderedOrderSet.QUEUE_END) {
        break;
      }
      currentOrder = nextOrder;
      (, buyAmountOfIter, sellAmountOfIter) = currentOrder.decodeOrder();
      currentBidSum = currentBidSum.add(sellAmountOfIter);
    } while (currentBidSum.mul(buyAmountOfIter) < fullPooledAmount.mul(sellAmountOfIter));

    if (currentBidSum > 0 && currentBidSum.mul(buyAmountOfIter) >= fullPooledAmount.mul(sellAmountOfIter)) {
      uint256 uncoveredBids = currentBidSum.sub(fullPooledAmount.mul(sellAmountOfIter).div(buyAmountOfIter));

      if (sellAmountOfIter >= uncoveredBids) {
        uint256 sellAmountClearingOrder = sellAmountOfIter.sub(uncoveredBids);
        poolData[poolId].volumeClearingPriceOrder = sellAmountClearingOrder.toUint96();
        currentBidSum = currentBidSum.sub(uncoveredBids);
        clearingOrder = currentOrder;
      } else {
        currentBidSum = currentBidSum.sub(sellAmountOfIter);
        clearingOrder = IterableOrderedOrderSet.encodeOrder(0, fullPooledAmount, uint96(currentBidSum));
      }
    } else {
      if (currentBidSum > minPooledBuyAmount) {
        clearingOrder = IterableOrderedOrderSet.encodeOrder(0, fullPooledAmount, currentBidSum.toUint96());
      } else {
        clearingOrder = IterableOrderedOrderSet.encodeOrder(0, fullPooledAmount, minPooledBuyAmount);
        fillVolumeOfPoolerOrder = currentBidSum.mul(fullPooledAmount).div(minPooledBuyAmount).toUint96();
      }
    }
    poolData[poolId].clearingPriceOrder = clearingOrder;

    if (poolData[poolId].initData.minFundingThreshold > currentBidSum) {
      poolData[poolId].minFundingThresholdNotReached = true;
    }
    processFeesAndPoolerFunds(poolId, fillVolumeOfPoolerOrder, poolerId, fullPooledAmount);
    emit PoolCleared(poolId, fillVolumeOfPoolerOrder, uint96(currentBidSum), clearingOrder);

    poolData[poolId].initialPoolOrder = bytes32(0);
    poolData[poolId].interimOrder = bytes32(0);
    poolData[poolId].interimSumBidAmount = uint256(0);
    poolData[poolId].initData.minimumBiddingAmountPerOrder = uint256(0);
  }

  function precalculateSellAmountSum(uint64 poolId, uint256 iterationSteps) public atStageSolutionSubmission(poolId) {
    (, , uint96 poolerSellAmount) = poolData[poolId].initialPoolOrder.decodeOrder();
    uint256 sumBidAmount = poolData[poolId].interimSumBidAmount;
    bytes32 iterOrder = poolData[poolId].interimOrder;

    for (uint256 i = 0; i < iterationSteps; i++) {
      iterOrder = sellOrders[poolId].next(iterOrder);
      (, , uint96 sellAmountOfIter) = iterOrder.decodeOrder();
      sumBidAmount = sumBidAmount.add(sellAmountOfIter);
    }

    // current iteration order is not the end of order que
    require(iterOrder != IterableOrderedOrderSet.QUEUE_END, "Reached end");
    (, uint96 buyAmountOfIter, uint96 selAmountOfIter) = iterOrder.decodeOrder();
    require(sumBidAmount.mul(buyAmountOfIter) < poolerSellAmount.mul(selAmountOfIter), "Too many orders");

    poolData[poolId].interimSumBidAmount = sumBidAmount;
    poolData[poolId].interimOrder = iterOrder;
  }

  function _placeSellOrders(
    uint64 poolId,
    uint96[] memory _minBuyAmounts,
    uint96[] memory _sellAmounts,
    bytes32[] memory _prevSellOrders,
    address orderSubmitter
  ) internal returns (uint64 userId) {
    uint256 sumOfSellAmounts = 0;
    userId = getUserId(orderSubmitter);
    uint256 minimumBiddingAmountPerOrder = poolData[poolId].initData.minimumBiddingAmountPerOrder;
    for (uint256 i = 0; i < _minBuyAmounts.length; i++) {
      require(_minBuyAmounts[i] > 0, "buyAmounts must be > 0");
      require(_sellAmounts[i] > minimumBiddingAmountPerOrder, "order too small");
      if (sellOrders[poolId].insert(IterableOrderedOrderSet.encodeOrder(userId, _minBuyAmounts[i], _sellAmounts[i]), _prevSellOrders[i])) {
        sumOfSellAmounts = sumOfSellAmounts.add(_sellAmounts[i]);
        emit NewSellOrderPlaced(
          poolId,
          userId,
          _minBuyAmounts[i],
          _sellAmounts[i],
          IterableOrderedOrderSet.encodeOrder(userId, _minBuyAmounts[i], _sellAmounts[i])
        );
      }
    }

    // transfer the sum of sell amounts to this contract
    poolData[poolId].initData.biddingToken.safeTransferFrom(msg.sender, address(this), sumOfSellAmounts);
  }

  function sendOutTokens(
    uint64 poolId,
    uint256 poolingTokenAmount,
    uint256 biddingTokenAmount,
    uint64 userId
  ) internal {
    address userAddress = registeredUsers.getAddressAt(userId);
    if (poolingTokenAmount > 0) {
      poolData[poolId].initData.poolingToken.safeTransfer(userAddress, poolingTokenAmount);
    }
    if (biddingTokenAmount > 0) {
      poolData[poolId].initData.biddingToken.safeTransfer(userAddress, biddingTokenAmount);
    }
  }

  function processFeesAndPoolerFunds(
    uint64 poolId,
    uint256 fillVolumeOfPoolerOrder,
    uint64 poolerId,
    uint96 fullPooledAmount
  ) internal {
    uint256 feeAmount = fullPooledAmount.mul(poolData[poolId].feeNumerator).div(FEE_DENOMINATOR);
    if (poolData[poolId].minFundingThresholdNotReached) {
      sendOutTokens(poolId, fullPooledAmount.add(feeAmount), 0, poolerId); //[4]
    } else {
      (, uint96 priceNumerator, uint96 priceDenominator) = poolData[poolId].clearingPriceOrder.decodeOrder();
      uint256 unsettledPoolTokens = fullPooledAmount.sub(fillVolumeOfPoolerOrder);
      uint256 poolingTokenAmount = unsettledPoolTokens.add(feeAmount.mul(unsettledPoolTokens).div(fullPooledAmount));
      uint256 biddingTokenAmount = fillVolumeOfPoolerOrder.mul(priceDenominator).div(priceNumerator);
      sendOutTokens(poolId, poolingTokenAmount, biddingTokenAmount, poolerId);
      sendOutTokens(poolId, feeAmount.mul(fillVolumeOfPoolerOrder).div(fullPooledAmount), 0, feeReceiverUserId);
    }
  }
}
