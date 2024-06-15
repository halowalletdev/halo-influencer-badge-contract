// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/EventsAndErrors.sol";
import "./interfaces/IHaloMembershipPass.sol";
import "./interfaces/IERC20WithDecimals.sol";

/// @title Influencer Badge
/// @notice An ERC1155 contract, each tokenId(poolId) corresponds to a badge pool
contract InfluencerBadge is
    ERC1155,
    ERC1155Supply,
    EventsAndErrors,
    Ownable2Step,
    ReentrancyGuard,
    Pausable
{
    struct BadgePoolConfig {
        address kol; // creator of this badge pool
        address payToken; // payment currency of this badge pool
        uint256 amountPerPayToken; // 10^token's decimal  e.g. for eth: 10^18=1000000000000000000
        uint256 tokenBalance; // updated when buying、 selling、 adding bonus
        // parameters of price curve:
        // price formula: y=(x^2+A)/B *varCoef1/varCoef2
        uint256 constA;
        uint256 constB;
        // initial value are all 1, and updated when bonus are added
        uint256 varCoef1; // update to: tokenBalance of the pool "after" adding bonus
        uint256 varCoef2; // update to: tokenBalance of the pool "before" adding bonus
        uint256 revenueSharingPercent; // [0,100] the proportion of the income earned by kol in the later period is distributed to badge holders
        bool hasFinishPremint; // if kol is in whitelist, then halo official will firstly mint before users; if kol is not in whitelist, then do not need premint
    }
    uint256 private constant SCALE_DECIMAL = 100;

    // erc1155
    string public name;
    string public symbol;
    uint256 public currentIndex; // current tokenId(poolId) of "created"

    // hmp
    IHaloMembershipPass public immutable hmp;
    bool public isCheckHMPInCreation; // whether check hmp's level in creating badge pool
    bool public isCheckHMPInBuyOrSell; // whether check hmp's level in selling or buying
    uint8 public hpmLevelThreshold; // the Halo Membership Pass's level  that user's main profile must reach
    // fees
    uint256 public protocolFeePercent; // [0,100]
    address public protocolFeeTo; // protocol fee recipient
    uint256 public kolFeePercent; // [0,100]

    uint256 public maxLimitInBuyOrSell; // the maximum limit for buying or selling at one tx
    uint256 public maxPercentInRevenueSharing; // the maximum percent when setting badge pool's revenue sharing percent

    // whitelists
    bool public isCheckCreator; // whether to enable whitelist checking
    mapping(address kol => bool isInWhitelist) public isWhitelistKOL;
    mapping(address kol => bool isInBlacklist) public isBlacklistKOL; // users in the blacklist cannot create pools
    mapping(address token => bool isInWhitelist) public isWhitelistPayToken;
    mapping(address preminer => bool isInWhitelist) public isWhitelistPreminter; // the halo address to premint, need to be a EOA
    mapping(address funder => bool) public isWhitelistFunder; // only address in this whitelist can call addBonus

    // pools' config
    mapping(uint256 poolId => BadgePoolConfig config) public badgePoolConfigs;
    bool public isCheckConstA;
    mapping(uint256 coefficient => bool) public isWhitelistConstA; // the constA in formula
    bool public isCheckConstB;
    mapping(uint256 coefficient => bool) public isWhitelistConstB; // the constB in formula, which determine the curve

    mapping(address kol => bool hasCreated) public hasCreatedPool; // whether has created badge pool

    /////////////////// modifiers ///////////////////
    modifier callerIsUser() {
        require(tx.origin == msg.sender, "Only EOA");
        _;
    }

    /////////////////// constructor ///////////////////
    constructor(
        string memory name_,
        string memory symbol_,
        string memory uri_,
        address usdt,
        address protocolFeeTo_,
        IHaloMembershipPass hmp_
    ) ERC1155(uri_) Ownable(msg.sender) {
        name = name_;
        symbol = symbol_;
        protocolFeeTo = protocolFeeTo_;

        hmp = hmp_;
        // default preminter
        isWhitelistPreminter[msg.sender] = true;

        // default payToken:usdt
        isWhitelistPayToken[usdt] = true;
        //
        isCheckCreator = true;
        isCheckConstA = true;
        isCheckConstB = true;
        isCheckHMPInCreation = false;
        isCheckHMPInBuyOrSell = false;

        // formula parameter
        isWhitelistConstA[210] = true;
        isWhitelistConstB[2100] = true;

        // default fee
        protocolFeePercent = 2;
        kolFeePercent = 3;
        // default max limit
        maxLimitInBuyOrSell = 10;
        maxPercentInRevenueSharing = 80;
    }

    /*//////////////////////////////////////////////////////////////
                        external functions
    //////////////////////////////////////////////////////////////*/

    /// Create a new badge pool (not payable)
    /// @param payToken the payment currency of the new badge pool
    /// @param constA the const of the bonding curve
    /// @param constB the const of the bonding curve
    /// @param revenueSharingPercent  profit
    /// @return poolId the id of new badge pool
    function createBadgePool(
        address payToken,
        uint256 constA,
        uint256 constB,
        uint256 revenueSharingPercent
    )
        external
        callerIsUser
        nonReentrant
        whenNotPaused
        returns (uint256 poolId)
    {
        // verify parameters
        if (isCheckCreator) {
            require(isWhitelistKOL[msg.sender], "NOT_IN_WL"); // in the  whitelist
        }
        require(!isBlacklistKOL[msg.sender], "IN_BL"); // in the blacklist

        require(!hasCreatedPool[msg.sender], "HAS_CRED"); // has created

        if (isCheckConstA) {
            require(isWhitelistConstA[constA], "INV_CONSTA");
        }
        require(constB > 0, "INV_CONSTB");
        if (isCheckConstB) {
            require(isWhitelistConstB[constB], "INV_CONSTB");
        }
        // verify hmp
        if (isCheckHMPInCreation) {
            // check level
            require(getHMPLevel(msg.sender) >= hpmLevelThreshold, "INV_LEVEL");
        }
        require(isWhitelistPayToken[payToken], "NS_TOKEN"); // not supported token

        // get amountPerPayToken which is "10^n"
        uint256 amountPerPayToken;
        if (payToken == address(0)) {
            // native token
            amountPerPayToken = 10 ** 18;
        } else {
            uint256 decimals = IERC20WithDecimals(payToken).decimals();
            amountPerPayToken = 10 ** decimals;
        }

        require(revenueSharingPercent <= maxPercentInRevenueSharing, "INV_PCT");

        //---- verify success ---//
        hasCreatedPool[msg.sender] = true;
        // save pool's config
        uint256 newPoolId = ++currentIndex;

        BadgePoolConfig storage poolConfig = badgePoolConfigs[newPoolId];
        poolConfig.kol = msg.sender;
        poolConfig.payToken = payToken;
        poolConfig.amountPerPayToken = amountPerPayToken;
        poolConfig.tokenBalance = 0;
        poolConfig.constA = constA;
        poolConfig.constB = constB;
        poolConfig.varCoef1 = 1;
        poolConfig.varCoef2 = 1;
        poolConfig.revenueSharingPercent = revenueSharingPercent;
        if (isWhitelistKOL[msg.sender]) {
            poolConfig.hasFinishPremint = false; // false: need premint
        } else {
            poolConfig.hasFinishPremint = true; // do not need premint, just mark true
        }

        emit CreateBadgePool(msg.sender, newPoolId);
        return newPoolId;
    }

    /// Buy badges from a badge pool
    /// @param poolId the badge pool's ERC1155 tokenId
    /// @param buyAmount the amount of badges
    /// @param maxPayIn the maximum amount of tokens user can accept to spend
    /// @return payInAddFee the token number actually spent
    function buyFromPool(
        uint256 poolId,
        uint256 buyAmount,
        uint256 maxPayIn
    )
        external
        payable
        callerIsUser
        nonReentrant
        whenNotPaused
        returns (uint256 payInAddFee)
    {
        // verify parameters
        BadgePoolConfig storage poolConfig = badgePoolConfigs[poolId];
        require(poolConfig.kol != address(0), "INV_ID");
        // verify msg.sender
        if (!poolConfig.hasFinishPremint) {
            require(isWhitelistPreminter[msg.sender], "NEED_PREMINT");
            poolConfig.hasFinishPremint = true;
        }

        require(
            buyAmount > 0 && maxPayIn > 0 && buyAmount <= maxLimitInBuyOrSell,
            "INV_AMT"
        );
        // verify hmp
        if (isCheckHMPInBuyOrSell) {
            // check level
            require(getHMPLevel(msg.sender) >= hpmLevelThreshold, "INV_LEVEL");
        }

        // calculate cost
        (uint256 buyPrice, uint256 protocolFee, uint256 kolFee) = getBuyPrice(
            poolId,
            buyAmount
        );
        // verify limit
        uint256 allFee = protocolFee + kolFee;
        payInAddFee = buyPrice + allFee;
        require(payInAddFee <= maxPayIn, "EX_AMT"); // exceeds max input amount

        //---- verify success ---//

        // pay: native or erc20
        address payToken = poolConfig.payToken;
        if (payToken == address(0)) {
            require(msg.value >= payInAddFee, "IF_AMT"); // insufficient payment amount
            // pay fees
            Address.sendValue(payable(protocolFeeTo), protocolFee);
            Address.sendValue(payable(poolConfig.kol), kolFee);
            // refund remaining
            uint256 refundAmount = msg.value - payInAddFee;
            if (refundAmount > 0) {
                Address.sendValue(payable(msg.sender), refundAmount);
            }
        } else {
            require(msg.value == 0, "NO_NATIVE");
            // msg.sender->this
            SafeERC20.safeTransferFrom(
                IERC20(payToken),
                msg.sender,
                address(this),
                buyPrice
            );
            // transfer fees
            // 1. msg.sender-> protocol fee recipient
            SafeERC20.safeTransferFrom(
                IERC20(payToken),
                msg.sender,
                protocolFeeTo,
                protocolFee
            );
            // 2. msg.sender-> kol
            SafeERC20.safeTransferFrom(
                IERC20(payToken),
                msg.sender,
                poolConfig.kol,
                kolFee
            );
        }
        // update pool balance
        poolConfig.tokenBalance += buyPrice;
        // // mint erc1155 to user
        _mint(msg.sender, poolId, buyAmount, "");
        emit Buy(
            poolId,
            msg.sender,
            buyAmount,
            payInAddFee,
            buyPrice,
            protocolFee,
            kolFee,
            poolConfig.tokenBalance
        );
    }

    /// Sell badges to a badge pool
    /// @param poolId the badge pool's ERC1155 tokenId
    /// @param sellAmount the badge amount to sell
    /// @param minPayOut the minimum amount of tokens user can accept to receive
    /// @return payOutSubFee the token number actually received
    function sellToPool(
        uint256 poolId,
        uint256 sellAmount,
        uint256 minPayOut
    )
        external
        callerIsUser
        nonReentrant
        whenNotPaused
        returns (uint256 payOutSubFee)
    {
        // verify parameters
        BadgePoolConfig storage poolConfig = badgePoolConfigs[poolId];
        require(poolConfig.kol != address(0), "INV_ID");
        require(sellAmount > 0 && sellAmount <= maxLimitInBuyOrSell, "INV_AMT");
        require(sellAmount <= balanceOf(msg.sender, poolId), "EX_AMT1");

        // verify hmp
        if (isCheckHMPInBuyOrSell) {
            // check level
            require(getHMPLevel(msg.sender) >= hpmLevelThreshold, "INV_LEVEL");
        }

        // calculate cost
        (uint256 sellPrice, uint256 protocolFee, uint256 kolFee) = getSellPrice(
            poolId,
            sellAmount
        );
        uint256 allFee = protocolFee + kolFee;
        payOutSubFee = sellPrice - allFee;
        require(payOutSubFee >= minPayOut, "EX_AMT2"); // exceed min output amount

        //---- verify success ---//

        // burn erc1155 from user
        _burn(msg.sender, poolId, sellAmount);

        // pay: native or erc20
        address payToken = poolConfig.payToken;
        if (payToken == address(0)) {
            Address.sendValue(payable(msg.sender), payOutSubFee);
            // transfer fees
            Address.sendValue(payable(protocolFeeTo), protocolFee);
            Address.sendValue(payable(poolConfig.kol), kolFee);
        } else {
            // this --> msg.sender
            SafeERC20.safeTransfer(IERC20(payToken), msg.sender, payOutSubFee);
            // transfer fees
            // 1. this -->protocol fee recipient
            SafeERC20.safeTransfer(
                IERC20(payToken),
                protocolFeeTo,
                protocolFee
            );
            // 2. this --> kol
            SafeERC20.safeTransfer(IERC20(payToken), poolConfig.kol, kolFee);
        }

        // update pool
        poolConfig.tokenBalance -= sellPrice;

        // event
        emit Sell(
            poolId,
            msg.sender,
            sellAmount,
            payOutSubFee,
            sellPrice,
            protocolFee,
            kolFee,
            poolConfig.tokenBalance
        );
    }

    /// Add reward funds to a badge pool, and update the pool's bunding curve
    /// @param poolId the id of badge pool
    /// @param bonusERC20Amount  bonus token amount, it is necessary when the payToken is ERC20
    function addBonus(
        uint256 poolId,
        uint256 bonusERC20Amount
    ) external payable nonReentrant {
        // only specific addresses can contribute funds (e.g. treasury contract)
        require(isWhitelistFunder[msg.sender], "NO_PERMISSION");

        BadgePoolConfig storage poolConfig = badgePoolConfigs[poolId];
        require(poolConfig.kol != address(0), "INV_ID");
        require(poolConfig.tokenBalance > 0, "CANNOT_ADD"); // because after adding bonus, varCoef2=tokenBalance, so can't be zero

        address payToken = poolConfig.payToken;
        uint256 actualBonusAmount;

        // pay token
        if (payToken == address(0)) {
            require(msg.value > 0, "INV_VAL1");
            actualBonusAmount = msg.value;
        } else {
            require(bonusERC20Amount > 0, "INV_VAL2");
            actualBonusAmount = bonusERC20Amount;
            SafeERC20.safeTransferFrom(
                IERC20(payToken),
                msg.sender,
                address(this),
                actualBonusAmount
            );
        }

        // update parameters
        poolConfig.varCoef2 = poolConfig.tokenBalance; // denominator, can not be 0
        poolConfig.varCoef1 = poolConfig.tokenBalance + actualBonusAmount; // numerator
        poolConfig.tokenBalance += actualBonusAmount;

        emit AddBonus(
            msg.sender,
            poolId,
            actualBonusAmount,
            poolConfig.tokenBalance
        );
    }

    /*//////////////////////////////////////////////////////////////
                        public view or pure functions
    //////////////////////////////////////////////////////////////*/

    /// Calculate the price of buying badges from badge pool. User actually pays= buyPrice+protocolFee+kolFee
    /// @param poolId the id of badge pool
    /// @param amount  buy amount
    /// @return buyPrice (not consider the fees, so the actual paid tokens when buying will greater than this value)
    /// @return protocolFee The portion that needs to be added to buyPrice, pay to protocol
    /// @return kolFee The portion that needs to be added from buyPrice, pay to kol
    function getBuyPrice(
        uint256 poolId,
        uint256 amount
    )
        public
        view
        returns (uint256 buyPrice, uint256 protocolFee, uint256 kolFee)
    {
        BadgePoolConfig storage poolConfig = badgePoolConfigs[poolId];
        require(poolConfig.kol != address(0), "INV_ID");
        require(amount > 0, "INV_AMT");

        uint256 supply = totalSupply(poolId);

        // the price of the i-th badge is  (i^2+A)/B*varCoef1/varCoef2 --->  (i^2+A) * (varCoef1) / ( B*varCoef2)
        // so the all price of [supply+1, supply+2,...... supply+amount] equal:
        //      (  (supply+1)^2+.... (supply+amount)^2 + amount*A ) * (varCoef1) / ( B*varCoef2)
        // in addition: 1^2+2^2+......n^2=n(n+1)(2n+1)/6   ---> Divisible, no decimals will appear

        uint256 sum1 = ((supply + amount) *
            (supply + amount + 1) *
            (2 * (supply + amount) + 1)) / 6;
        uint256 sum2 = (supply * (supply + 1) * (2 * supply + 1)) / 6;

        uint256 numerator = ((sum1 - sum2) + amount * (poolConfig.constA)) *
            poolConfig.varCoef1;

        uint256 denominator = poolConfig.constB * poolConfig.varCoef2;
        // when dividing, decimals may occur (rounding up, benefiting the pool, users paying more)）
        buyPrice = Math.mulDiv(
            numerator,
            poolConfig.amountPerPayToken, // equal 10^token decimal
            denominator,
            Math.Rounding.Ceil
        );
        // calculate fees----decimals will appear too (rounding up, benefit the kol and protocol)
        protocolFee = Math.mulDiv(
            buyPrice,
            protocolFeePercent,
            SCALE_DECIMAL,
            Math.Rounding.Ceil
        );
        kolFee = Math.mulDiv(
            buyPrice,
            kolFeePercent,
            SCALE_DECIMAL,
            Math.Rounding.Ceil
        );
    }

    /// Calculate the price of selling badges to badge pool. User actually receives= sellPrice-protocolFee-kolFee
    /// @param poolId the id of badge pool
    /// @param amount  sell amount
    /// @return sellPrice (not consider the fees, so the actual received tokens when selling will less than this value)
    /// @return protocolFee The portion that needs to be deducted from sellPrice, pay to protocol
    /// @return kolFee The portion that needs to be deducted from sellPrice, pay to kol
    function getSellPrice(
        uint256 poolId,
        uint256 amount
    )
        public
        view
        returns (uint256 sellPrice, uint256 protocolFee, uint256 kolFee)
    {
        BadgePoolConfig storage poolConfig = badgePoolConfigs[poolId];
        require(poolConfig.kol != address(0), "INV_ID");

        uint256 supply = totalSupply(poolId);
        require(amount > 0 && supply >= amount, "INV_AMT");
        // the price of the i-th badge is  (i^2+A)/B*varCoef1/varCoef2 --->  (i^2+A) * (varCoef1) / ( B*varCoef2)
        // so the all sell price of [supply-(m-1),supply-(m-2) ...... ,supply-0 ] equal:
        //      (  (supply-m+1)^2+.... (supply)^2    + m*A ) * (varCoef1) / ( B*varCoef2)
        // in addition: 1^2+2^2+......n^2=n(n+1)(2n+1)/6   ---> Divisible, no decimals will appear

        uint256 sum1 = (supply * (supply + 1) * (2 * supply + 1)) / 6;
        uint256 sum2 = ((supply - amount) *
            (supply - amount + 1) *
            (2 * (supply - amount) + 1)) / 6;

        uint256 numerator = ((sum1 - sum2) + amount * (poolConfig.constA)) *
            poolConfig.varCoef1;

        uint256 denominator = poolConfig.constB * poolConfig.varCoef2;
        // when dividing, decimals may occur (rounding down, benefiting the pool, users receive less)）
        sellPrice = Math.mulDiv(
            numerator,
            poolConfig.amountPerPayToken, // equal 10^token decimal
            denominator,
            Math.Rounding.Floor
        );
        // calculate fees----decimals will appear too (rounding up, benefit the kol and protocol)
        protocolFee = Math.mulDiv(
            sellPrice,
            protocolFeePercent,
            SCALE_DECIMAL,
            Math.Rounding.Ceil
        );
        kolFee = Math.mulDiv(
            sellPrice,
            kolFeePercent,
            SCALE_DECIMAL,
            Math.Rounding.Ceil
        );
    }

    function uri(uint256 tokenId) public view override returns (string memory) {
        // require pool has created
        require(tokenId > 0 && tokenId <= currentIndex, "INV_ID");
        string memory baseURI = super.uri(tokenId);
        return
            bytes(baseURI).length > 0
                ? string(abi.encodePacked(baseURI, Strings.toString(tokenId)))
                : "";
    }

    /// Get user's main profile hmp's level, if not bind, will revert
    /// @param user user address
    /// @return level hmp's level
    function getHMPLevel(address user) public view returns (uint8 level) {
        uint256 tokenId = hmp.userMainProfile(user);
        require(
            tokenId != 0 && hmp.ownerOf(tokenId) == user,
            "NO_MAIN_PROFILE"
        );
        return hmp.levelOfToken(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                        owner's functions
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setURI(string memory newBaseUri) external onlyOwner {
        _setURI(newBaseUri);
    }

    function setHMPLevelThreshold(uint8 newLevel) external onlyOwner {
        require(newLevel <= 6, "EX_LEVEL");
        hpmLevelThreshold = newLevel;
    }

    function setFeePercent(
        uint256 newProtocolPercent,
        uint256 newKolFeePercent
    ) external onlyOwner {
        require(newKolFeePercent + newProtocolPercent <= 20, "EX_LIM");
        protocolFeePercent = newProtocolPercent;
        kolFeePercent = newKolFeePercent;
    }

    function setProtocolFeeTo(address newReceiver) external onlyOwner {
        protocolFeeTo = newReceiver;
    }

    function setRevenueSharingPercent(
        uint256 poolId,
        uint256 newPercent
    ) external onlyOwner {
        require(newPercent <= maxPercentInRevenueSharing, "INV_PCT");
        BadgePoolConfig storage poolConfig = badgePoolConfigs[poolId];
        poolConfig.revenueSharingPercent = newPercent;
    }

    function setMaxLimitInBuyOrSell(uint256 newLimit) external onlyOwner {
        maxLimitInBuyOrSell = newLimit;
    }

    function setMaxPercentInRevenueSharing(
        uint256 newPercent
    ) external onlyOwner {
        require(newPercent <= SCALE_DECIMAL, "INV_PCT");
        maxPercentInRevenueSharing = newPercent;
    }

    function toggleIsCheckHMPInCreation() external onlyOwner {
        isCheckHMPInCreation = !isCheckHMPInCreation;
    }

    function toggleIsCheckHMPInBuyOrSell() external onlyOwner {
        isCheckHMPInBuyOrSell = !isCheckHMPInBuyOrSell;
    }

    function toggleIsCheckCreator() external onlyOwner {
        isCheckCreator = !isCheckCreator;
    }

    function toggleIsCheckConstA() external onlyOwner {
        isCheckConstA = !isCheckConstA;
    }

    function toggleIsCheckConstB() external onlyOwner {
        isCheckConstB = !isCheckConstB;
    }

    function addWhitelistKOLs(address[] calldata users) external onlyOwner {
        uint256 addLength = users.length;
        address user;
        for (uint i = 0; i < addLength; i++) {
            user = users[i];
            isWhitelistKOL[user] = true;
        }
    }

    function removeWhitelistKOLs(address[] calldata users) external onlyOwner {
        uint256 removeLength = users.length;
        address user;
        for (uint i = 0; i < removeLength; i++) {
            user = users[i];
            isWhitelistKOL[user] = false;
        }
    }

    function addBlacklistKOLs(address[] calldata users) external onlyOwner {
        uint256 addLength = users.length;
        address user;
        for (uint i = 0; i < addLength; i++) {
            user = users[i];
            isBlacklistKOL[user] = true;
        }
    }

    function removeBlacklistKOLs(address[] calldata users) external onlyOwner {
        uint256 removeLength = users.length;
        address user;
        for (uint i = 0; i < removeLength; i++) {
            user = users[i];
            isBlacklistKOL[user] = false;
        }
    }

    function addWhitelistPayTokens(
        address[] calldata tokens
    ) external onlyOwner {
        uint256 addLength = tokens.length;
        address token;
        for (uint i = 0; i < addLength; i++) {
            token = tokens[i];
            isWhitelistPayToken[token] = true;
        }
    }

    function removeWhitelistPayTokens(
        address[] calldata tokens
    ) external onlyOwner {
        uint256 removeLength = tokens.length;
        address token;
        for (uint i = 0; i < removeLength; i++) {
            token = tokens[i];
            isWhitelistPayToken[token] = false;
        }
    }

    function addWhitelistPreminer(address newMiner) external onlyOwner {
        isWhitelistPreminter[newMiner] = true;
    }

    function removeWhitelistPreminer(address removedMiner) external onlyOwner {
        isWhitelistPreminter[removedMiner] = false;
    }

    function addWhitelistConstA(uint256 constA) external onlyOwner {
        isWhitelistConstA[constA] = true;
    }

    function removeWhitelistConstA(uint256 constA) external onlyOwner {
        isWhitelistConstA[constA] = false;
    }

    function addWhitelistConstB(uint256 constB) external onlyOwner {
        require(constB > 0, "NOT_ZERO");
        isWhitelistConstB[constB] = true;
    }

    function removeWhitelistConstB(uint256 constB) external onlyOwner {
        isWhitelistConstB[constB] = false;
    }

    function addWhitelistFunder(address funder) external onlyOwner {
        isWhitelistFunder[funder] = true;
    }

    function removeWhitelistFunder(address funder) external onlyOwner {
        isWhitelistFunder[funder] = false;
    }

    ////////// internal and private functions //////////////////////////
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Supply) {
        super._update(from, to, ids, values);
    }
}
