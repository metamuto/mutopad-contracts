// SPDX-License-Identifier: MIT
pragma solidity >=0.6.8;

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
    
    
    function initiateAuction(
            InitialAuctionData calldata _initData
        ) public returns (uint256) {
            uint256 _ammount = _initData.auctionedSellAmount.mul(FEE_DENOMINATOR.add(feeNumerator)).div(
                    FEE_DENOMINATOR);
            require(
                _initData.auctioningToken != _initData.biddingToken,
                ""
            );
            require(
                _initData.auctioningToken.balanceOf(msg.sender)>=_ammount,
                ""
            );
            require(
                block.timestamp<_initData.auctionStartDate<_initData.auctionEndDate,
                ""
            );
            require(
                _initData.auctionedSellAmount > 0,
                ""
            );
            require(
                _initData.minBuyAmount > 0,
                ""
            );
            require(
                _initData.minimumBiddingAmountPerOrder > 0,
                ""
            );
            require(
                _initData.orderCancellationEndDate <= _initData.auctionEndDate,
                ""
            );
            require(
                _initData.auctionEndDate > block.timestamp,
                ""
            );
            _auctioningToken.safeTransferFrom(
                msg.sender,
                address(this),
                _ammount
            );
            auctionCounter = auctionCounter.add(1);
            sellOrders[auctionCounter].initializeEmptyList();
            uint64 userId = getUserId(msg.sender);
            auctionData[auctionCounter] = AuctionData(
                _initData,
                msg.sender,
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
                feeNumerator,
                false,
                false
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


    function updateAuctionDetailsHash(uint256 _auctionId, string memory _detailsHash) public {
        require(auctionData[_auctionId].poolOwner == msg.sender);
        auctionData[_auctionId].initData.formHash = _detailsHash;
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
            require( newFeeNumerator <= 15);
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
            numUsers = numUsers.add(uint64(1));
            require(
                registeredUsers.insert(numUsers, user),
                "User Exists"
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