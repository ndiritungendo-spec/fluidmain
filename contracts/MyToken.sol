// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

contract FluidToken is ERC20, Ownable {
    using SafeERC20 for IERC20;

    // ----- Supply -----
    uint256 public constant TOTAL_SUPPLY = 10_000_000 * 1e18;
    uint256 public constant SALE_SUPPLY = (TOTAL_SUPPLY * 40) / 100;
    uint256 public constant AIRDROP_SUPPLY = (TOTAL_SUPPLY * 30) / 100;
    uint256 public constant MARKETING_LIQUIDITY_SUPPLY = (TOTAL_SUPPLY * 10) / 100;
    uint256 public constant TEAM_SUPPLY = (TOTAL_SUPPLY * 10) / 100;
    uint256 public constant DEV_SUPPLY = (TOTAL_SUPPLY * 10) / 100;

    // ----- Wallets -----
    address public foundationWallet;
    address public relayerWallet;

    // Preset wallets for allocations
    address public marketingWallet = 0xd40c17e2076a6cab4fcb4c7ad50693c0bd87c96f;
    address public teamWallet = 0x22a978289a5864be1890dac00154a7d343273342;
    address public devWallet = 0x4ca465f7b25b630b62b4c36b64dff963f81e27c0;

    // ----- Price -----
    uint256 public fldPriceUSDT6 = 1e6;

    // ----- Chainlink feeds -----
    mapping(address => AggregatorV3Interface) public priceFeeds;
    AggregatorV3Interface public nativePriceFeed;

    // ----- Sale tracking -----
    uint256 public fldSold;

    // ----- Airdrop -----
    struct AirdropInfo {
        uint256 totalAllocated;
        uint8 claimedYears;
        uint256 startTime;
        bool completed;
    }
    mapping(address => AirdropInfo) public airdrops;
    address[] public airdropRecipients;
    uint256 public distributedAirdrops;
    uint8 public constant AIRDROP_YEARS = 5;

    // ----- Finder reward -----
    uint32 private _finderRewardPPM = 1000; // 0.1%

    // ----- Multisig -----
    address[] public signers;
    mapping(address => bool) public isSigner;
    uint256 public requiredApprovals;

    struct Proposal {
        address token;
        address to;
        uint256 amount;
        uint256 approvals;
        bool executed;
    }
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public proposalApprovedBy;
    uint256 public proposalCount;

    // ----- Events -----
    event PriceUpdated(uint256 newPriceUSDT6);
    event PriceFeedSet(address token, address feed);
    event NativeFeedSet(address feed);
    event FoundationWalletUpdated(address newWallet);
    event RelayerWalletUpdated(address newWallet);
    event SaleExecuted(address indexed buyer, address payToken, uint256 payAmount, uint256 fldAmount);
    event AirdropAllocated(address indexed user, uint256 amount);
    event AirdropClaimed(address indexed user, uint256 amount, uint8 year);
    event AirdropExpired(address indexed user, uint8 year, uint256 slice, address indexed finder, uint256 reward);
    event FinderRewardUpdated(uint32 ppm);
    event ProposalCreated(uint256 id, address token, address to, uint256 amount);
    event ProposalApproved(uint256 id, address approver);
    event ProposalExecuted(uint256 id, address executor);

    constructor(
        address _foundationWallet,
        address _relayerWallet,
        address[] memory _initialSigners,
        uint256 _requiredApprovals
    ) ERC20("Fluid Token", "FLD") {
        require(_foundationWallet != address(0), "invalid foundation wallet");
        require(_relayerWallet != address(0), "invalid relayer wallet");
        require(_initialSigners.length >= _requiredApprovals && _requiredApprovals > 0, "invalid multisig");

        foundationWallet = _foundationWallet;
        relayerWallet = _relayerWallet;

        _mint(address(this), TOTAL_SUPPLY);

        // distribute preset allocations
        _transfer(address(this), marketingWallet, MARKETING_LIQUIDITY_SUPPLY);
        _transfer(address(this), teamWallet, TEAM_SUPPLY);
        _transfer(address(this), devWallet, DEV_SUPPLY);

        // setup multisig
        for (uint i = 0; i < _initialSigners.length; i++) {
            address s = _initialSigners[i];
            require(s != address(0), "zero signer");
            require(!isSigner[s], "duplicate signer");
            isSigner[s] = true;
            signers.push(s);
        }
        requiredApprovals = _requiredApprovals;
    }

    // =========================
    // ===== Admin / Config ====
    // =========================
    function setFldPriceUSDT6(uint256 priceUSDT6) external onlyOwner {
        require(priceUSDT6 > 0, "price>0");
        fldPriceUSDT6 = priceUSDT6;
        emit PriceUpdated(priceUSDT6);
    }

    function setPriceFeed(address token, address feed) external onlyOwner {
        require(token != address(0) && feed != address(0), "zero addr");
        priceFeeds[token] = AggregatorV3Interface(feed);
        emit PriceFeedSet(token, feed);
    }

    function setNativePriceFeed(address feed) external onlyOwner {
        require(feed != address(0), "zero feed");
        nativePriceFeed = AggregatorV3Interface(feed);
        emit NativeFeedSet(feed);
    }

    function setFoundationWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "zero");
        foundationWallet = newWallet;
        emit FoundationWalletUpdated(newWallet);
    }

    function setRelayerWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "zero");
        relayerWallet = newWallet;
        emit RelayerWalletUpdated(newWallet);
    }

    function setFinderRewardPPM(uint32 ppm) external onlyOwner {
        require(ppm >= 10 && ppm <= 10000, "ppm out of range");
        _finderRewardPPM = ppm;
        emit FinderRewardUpdated(ppm);
    }

    function finderRewardPPM() external view returns (uint32) {
        return _finderRewardPPM;
    }

    // =========================
    // ====== BUYING ==========
    // =========================
    function buyWithERC20AndGas(address payToken, uint256 payAmount, uint256 gasFee) external {
        require(payAmount > gasFee, "payAmount must > gasFee");
        require(relayerWallet != address(0) && foundationWallet != address(0), "wallets not set");
        require(address(priceFeeds[payToken]) != address(0), "no feed");

        uint256 saleAmount = payAmount - gasFee;
        if(gasFee > 0) IERC20(payToken).safeTransferFrom(msg.sender, relayerWallet, gasFee);
        IERC20(payToken).safeTransferFrom(msg.sender, foundationWallet, saleAmount);

        AggregatorV3Interface feed = priceFeeds[payToken];  
        (, int256 price,,,) = feed.latestRoundData();  
        require(price > 0, "invalid feed");  
        uint8 aggDecimals = feed.decimals();  
        uint8 tokenDecimals;  
        try IERC20Metadata(payToken).decimals() returns (uint8 d) { tokenDecimals = d; } catch { tokenDecimals = 18; }  

        uint256 usd18 = (saleAmount * uint256(price) * 1e18) / ((10 ** tokenDecimals) * (10 ** aggDecimals));  
        uint256 fldAmount = (usd18 * 1e6) / fldPriceUSDT6;  
        require(balanceOf(address(this)) >= fldAmount, "contract lacks FLD");  
        require(fldSold + fldAmount <= SALE_SUPPLY, "sale supply exceeded");  

        _transfer(address(this), msg.sender, fldAmount);  
        fldSold += fldAmount;  

        uint256 airdropAlloc = (fldAmount * AIRDROP_SUPPLY) / SALE_SUPPLY;  
        if (airdropAlloc > 0) _allocateAirdrop(msg.sender, airdropAlloc);  

        emit SaleExecuted(msg.sender, payToken, payAmount, fldAmount);  
    }

    function buyWithNativeAndGas(uint256 gasFee) external payable {
        require(msg.value > gasFee, "msg.value <= gasFee");
        require(relayerWallet != address(0) && foundationWallet != address(0), "wallets not set");
        uint256 saleAmount = msg.value - gasFee;

        if(gasFee > 0) { (bool sentGas, ) = payable(relayerWallet).call{value: gasFee}(""); require(sentGas, "gas transfer failed"); }
        (bool sentSale, ) = payable(foundationWallet).call{value: saleAmount}(""); require(sentSale, "sale transfer failed");

        (, int256 answer,,,) = nativePriceFeed.latestRoundData();
        require(answer > 0, "invalid feed");
        uint8 aggDecimals = nativePriceFeed.decimals();
        uint256 usd18 = (saleAmount * uint256(answer) * 1e18) / (1e18 * (10 ** aggDecimals));
        uint256 fldAmount = (usd18 * 1e6) / fldPriceUSDT6;
        require(balanceOf(address(this)) >= fldAmount, "contract lacks FLD");
        require(fldSold + fldAmount <= SALE_SUPPLY, "sale supply exceeded");

        _transfer(address(this), msg.sender, fldAmount);
        fldSold += fldAmount;

        uint256 airdropAlloc = (fldAmount * AIRDROP_SUPPLY) / SALE_SUPPLY;
        if(airdropAlloc > 0) _allocateAirdrop(msg.sender, airdropAlloc);

        emit SaleExecuted(msg.sender, address(0), msg.value, fldAmount);
    }

    // =========================
    // ======= AIRDROPS ========
    // =========================
    function _allocateAirdrop(address user, uint256 amount) internal {
        require(user != address(0) && amount > 0, "invalid");
        require(distributedAirdrops + amount <= AIRDROP_SUPPLY, "exceeds pool");
        AirdropInfo storage info = airdrops[user];
        if(info.totalAllocated == 0) { info.startTime = block.timestamp; airdropRecipients.push(user); }
        info.totalAllocated += amount;
        distributedAirdrops += amount;
        emit AirdropAllocated(user, amount);
    }

    function claimAirdrop() external {
        AirdropInfo storage info = airdrops[msg.sender];
        require(info.totalAllocated > 0 && !info.completed, "none or done");

        uint256 yearsSince = (block.timestamp - info.startTime) / 365 days;
        require(yearsSince >= 1, "first claim not yet");

        uint8 currentYear = uint8(yearsSince);
        require(currentYear >= 1 && currentYear <= AIRDROP_YEARS, "no claimable");
        require(info.claimedYears + 1 == currentYear, "already claimed/missed");

        uint256 perYear = info.totalAllocated / AIRDROP_YEARS;
        info.claimedYears += 1;
        if(info.claimedYears == AIRDROP_YEARS) info.completed = true;

        _transfer(address(this), msg.sender, perYear);
        emit AirdropClaimed(msg.sender, perYear, currentYear);
    }

    function sweepExpired(address user) public {
        AirdropInfo storage info = airdrops[user];
        if(info.totalAllocated == 0 || info.completed) return;
        uint256 yearsSince = (block.timestamp - info.startTime) / 365 days;
        if(yearsSince == 0) return;

        uint8 processed = info.claimedYears;
        uint256 perYear = info.totalAllocated / AIRDROP_YEARS;

        while(processed < AIRDROP_YEARS && processed < yearsSince) {
            uint256 reward = (perYear * _finderRewardPPM) / 1_000_000;
            uint256 toFoundation = perYear - reward;

            if(reward > 0) _transfer(address(this), msg.sender, reward);
            _transfer(address(this), foundationWallet, toFoundation);

            processed += 1;
            info.claimedYears = processed;
            emit AirdropExpired(user, processed, perYear, msg.sender, reward);
        }
        if(info.claimedYears == AIRDROP_YEARS) info.completed = true;
    }

    // =========================
    // ===== Multisig ==========
    // =========================
    modifier onlySigner() { require(isSigner[msg.sender], "not signer"); _; }

    function createProposal(address token, address to, uint256 amount) external onlySigner returns(uint256){
        require(to!=address(0)&&amount>0,"invalid");
        proposalCount++;
        proposals[proposalCount]=Proposal(token,to,amount,0,false);
        emit ProposalCreated(proposalCount, token, to, amount);
        return proposalCount;
    }

    function approveProposal(uint256 id) external onlySigner {
        require(id>0 && id<=proposalCount, "unknown");
        Proposal storage p = proposals[id];
        require(!proposalApprovedBy[id][msg.sender], "already approved");
        require(!p.executed, "already executed");

        p.approvals++;
        proposalApprovedBy[id][msg.sender] = true;
        emit ProposalApproved(id, msg.sender);
    }

    function executeProposal(uint256 id) external onlySigner {
        Proposal storage p = proposals[id];
        require(!p.executed, "already executed");
        require(p.approvals >= requiredApprovals, "insufficient approvals");

        if(p.token == address(0)) {
            (bool sent, ) = payable(p.to).call{value: p.amount}("");
            require(sent, "transfer failed");
        } else {
            IERC20(p.token).safeTransfer(p.to, p.amount);
        }

        p.executed = true;
        emit ProposalExecuted(id, msg.sender);
    }

    receive() external payable {}
}
