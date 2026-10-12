// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract Precog {
    uint256 public constant FEE_BPS = 30;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_INITIAL_LIQUIDITY = 0.01 ether;

    enum Result {
        Open,
        Yes,
        No,
        Invalid
    }

    struct Market {
        address creator;
        string question;
        uint64 closesAt;
        uint64 resolvedAt;
        Result result;
        uint256 yesReserve;
        uint256 noReserve;
        uint256 collateral;
    }

    address public owner;
    uint256 public nextMarketId;
    mapping(uint256 => Market) private markets;
    mapping(uint256 => mapping(address => uint256)) public yesShares;
    mapping(uint256 => mapping(address => uint256)) public noShares;
    mapping(address => uint256) public gameRoundsStarted;
    uint256 private lockState = 1;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event MarketCreated(uint256 indexed marketId, address indexed creator, string question, uint64 closesAt, uint256 initialLiquidity);
    event SharesBought(uint256 indexed marketId, address indexed buyer, bool indexed yesOutcome, uint256 collateralIn, uint256 sharesOut);
    event MarketResolved(uint256 indexed marketId, Result result, uint64 resolvedAt);
    event WinningsClaimed(uint256 indexed marketId, address indexed account, uint256 amount);
    event LiquidityClaimed(uint256 indexed marketId, address indexed creator, uint256 amount);
    event GameRoundStarted(address indexed player, uint256 indexed roundNumber, uint256 blockNumber);

    error Unauthorized();
    error InvalidAddress();
    error InvalidQuestion();
    error InvalidCloseTime();
    error MarketNotFound();
    error MarketClosed();
    error MarketStillOpen();
    error MarketAlreadyResolved();
    error InvalidResolution();
    error InsufficientLiquidity();
    error InvalidAmount();
    error SlippageExceeded();
    error NothingToClaim();
    error TransferFailed();
    error ReentrantCall();
    error DirectPaymentDisabled();

    modifier nonReentrant() {
        if (lockState != 1) revert ReentrantCall();
        lockState = 2;
        _;
        lockState = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function createMarket(string calldata question, uint64 closesAt) external payable returns (uint256 marketId) {
        if (bytes(question).length == 0 || bytes(question).length > 280) revert InvalidQuestion();
        if (closesAt <= block.timestamp) revert InvalidCloseTime();
        if (msg.value < MIN_INITIAL_LIQUIDITY) revert InsufficientLiquidity();

        marketId = nextMarketId++;
        markets[marketId] = Market({
            creator: msg.sender,
            question: question,
            closesAt: closesAt,
            resolvedAt: 0,
            result: Result.Open,
            yesReserve: msg.value,
            noReserve: msg.value,
            collateral: msg.value
        });

        emit MarketCreated(marketId, msg.sender, question, closesAt, msg.value);
    }

    function getMarket(uint256 marketId) external view returns (Market memory) {
        return _market(marketId);
    }

    function quoteBuy(uint256 marketId, bool yesOutcome, uint256 collateralIn)
        public
        view
        returns (uint256 sharesOut, uint256 swapOut)
    {
        Market storage current = _market(marketId);
        if (collateralIn == 0) revert InvalidAmount();

        uint256 netInput = collateralIn * (BPS_DENOMINATOR - FEE_BPS) / BPS_DENOMINATOR;
        uint256 inputReserve = yesOutcome ? current.noReserve : current.yesReserve;
        uint256 outputReserve = yesOutcome ? current.yesReserve : current.noReserve;
        swapOut = outputReserve * netInput / (inputReserve + netInput);
        sharesOut = collateralIn + swapOut;
    }

    function buy(uint256 marketId, bool yesOutcome, uint256 minSharesOut)
        external
        payable
        returns (uint256 sharesOut)
    {
        Market storage current = _market(marketId);
        if (current.result != Result.Open || block.timestamp >= current.closesAt) revert MarketClosed();
        if (msg.value == 0) revert InvalidAmount();

        uint256 swapOut;
        (sharesOut, swapOut) = quoteBuy(marketId, yesOutcome, msg.value);
        if (sharesOut < minSharesOut) revert SlippageExceeded();

        current.collateral += msg.value;
        if (yesOutcome) {
            current.noReserve += msg.value;
            current.yesReserve -= swapOut;
            yesShares[marketId][msg.sender] += sharesOut;
        } else {
            current.yesReserve += msg.value;
            current.noReserve -= swapOut;
            noShares[marketId][msg.sender] += sharesOut;
        }

        emit SharesBought(marketId, msg.sender, yesOutcome, msg.value, sharesOut);
    }

    function resolveMarket(uint256 marketId, Result result) external {
        Market storage current = _market(marketId);
        if (msg.sender != current.creator) revert Unauthorized();
        if (current.result != Result.Open) revert MarketAlreadyResolved();
        if (block.timestamp < current.closesAt) revert MarketStillOpen();
        if (result == Result.Open) revert InvalidResolution();

        current.result = result;
        current.resolvedAt = uint64(block.timestamp);
        emit MarketResolved(marketId, result, current.resolvedAt);
    }

    function claim(uint256 marketId) external nonReentrant returns (uint256 payout) {
        Market storage current = _market(marketId);
        Result result = current.result;
        if (result == Result.Open) revert MarketStillOpen();

        uint256 userYes = yesShares[marketId][msg.sender];
        uint256 userNo = noShares[marketId][msg.sender];
        yesShares[marketId][msg.sender] = 0;
        noShares[marketId][msg.sender] = 0;

        if (result == Result.Yes) payout = userYes;
        else if (result == Result.No) payout = userNo;
        else payout = (userYes + userNo) / 2;
        if (payout == 0) revert NothingToClaim();

        current.collateral -= payout;
        _sendValue(msg.sender, payout);
        emit WinningsClaimed(marketId, msg.sender, payout);
    }

    function claimLiquidity(uint256 marketId) external nonReentrant returns (uint256 payout) {
        Market storage current = _market(marketId);
        if (msg.sender != current.creator) revert Unauthorized();
        Result result = current.result;
        if (result == Result.Open) revert MarketStillOpen();

        uint256 poolYes = current.yesReserve;
        uint256 poolNo = current.noReserve;
        current.yesReserve = 0;
        current.noReserve = 0;

        if (result == Result.Yes) payout = poolYes;
        else if (result == Result.No) payout = poolNo;
        else payout = (poolYes + poolNo) / 2;
        if (payout == 0) revert NothingToClaim();

        current.collateral -= payout;
        _sendValue(msg.sender, payout);
        emit LiquidityClaimed(marketId, msg.sender, payout);
    }

    function startGameRound() external {
        uint256 roundNumber = ++gameRoundsStarted[msg.sender];
        emit GameRoundStarted(msg.sender, roundNumber, block.number);
    }

    function _market(uint256 marketId) private view returns (Market storage current) {
        if (marketId >= nextMarketId) revert MarketNotFound();
        return markets[marketId];
    }

    function _sendValue(address recipient, uint256 amount) private {
        (bool success,) = payable(recipient).call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    receive() external payable {
        revert DirectPaymentDisabled();
    }
}