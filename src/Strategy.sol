// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseAuctioneer} from "@periphery/Bases/Auctioneer/BaseAuctioneer.sol";
import {ERC20} from "@tokenized-strategy/BaseStrategy.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISUSDe, UserCooldown} from "./interfaces/ethena/ISUSDe.sol";

import {StrategyProxy} from "./StrategyProxy.sol";

contract Strategy is BaseAuctioneer {
    using SafeERC20 for ERC20;

    address private constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    ISUSDe private constant SUSDE =
        ISUSDe(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
    uint256 public constant MAX_STRATEGY_PROXIES = 7;

    uint16 public maxTendBasefeeGwei = 30; // 30 gwei
    uint16 public minSUSDeDiscountBps = 50; // 0.50%
    uint80 public minCooldownAmount = 1_000e18; // default minimium is 1_000e18;
    uint80 public minAuctionAmount = 1_000e18; // 1000 USDe
    uint88 public maxAuctionAmount = 100_000e18; // 100_000 USDe
    uint64 public auctionRangeSize = 5e16;
    uint256 public depositLimit;
    StrategyProxy[] public strategyProxies;

    constructor(
        string memory _name
    )
        BaseAuctioneer(
            USDE,
            _name,
            address(SUSDE), // auction want
            1 days, // auction length (1 day)
            1 days, // auction cooldown (0 seconds)
            WAD // auction starting price 1:1
        )
    {
        strategyProxies.push(new StrategyProxy(address(this)));
    }

    /*//////////////////////////////////////////////////////////////
                      External Views
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the amount of usde being cooldown
     * @return . The cooldown amount in usde
     */
    function coolingUSDe() external view returns (uint256) {
        return _coolingUSDe();
    }

    /**
     * @notice Returns the amount of asset with expect to report
     * @return . The amount of asset this strategy expects to report
     */
    function estimatedTotalAssets() external view returns (uint256) {
        return _estimatedTotalAssets();
    }

    /**
     * @notice Returns the number of strategy proxies
     * @return . The strategy proxy count
     */
    function strategyProxyCount() external view returns (uint256) {
        return strategyProxies.length;
    }

    /*//////////////////////////////////////////////////////////////
                      External Setters
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the deposit limit. Can only be called by management
     * @param _depositLimit The deposit limit
     */
    function setDepositLimit(uint256 _depositLimit) external onlyManagement {
        depositLimit = _depositLimit;
    }

    /**
     * @notice Sets the max base fee for tends. Can only be called by management
     * @param _maxTendBasefeeGwei The maximum base fee allowed in gwei
     */
    function setMaxTendBasefeeGwei(
        uint16 _maxTendBasefeeGwei
    ) external onlyManagement {
        maxTendBasefeeGwei = _maxTendBasefeeGwei;
    }

    /**
     * @notice Sets the min amount to be cooled down. Can only be called by management
     * @param _minCooldownAmount The minimum amount of sUSDe before a cooldown is triggered
     */
    function setMinCooldownAmount(
        uint80 _minCooldownAmount
    ) external onlyManagement {
        minCooldownAmount = _minCooldownAmount;
    }

    /**
     * @notice Sets the min amount to be auctioned. Can only be called by management
     * @param _minAuctionAmount The minimum amount of USDe to auction
     */
    function setMinAuctionAmount(
        uint80 _minAuctionAmount
    ) external onlyManagement {
        minAuctionAmount = _minAuctionAmount;
    }

    /**
     * @notice Sets the max amount to be auctioned. Can only be called by management
     * @param _maxAuctionAmount The maximum amount of USDe to auction
     */
    function setMaxAuctionAmount(
        uint88 _maxAuctionAmount
    ) external onlyManagement {
        maxAuctionAmount = _maxAuctionAmount;
    }

    /**
     * @notice Sets the starting price for the auction. Can only be called by management
     * @param _auctionStartingPrice The price at which to start the auction
     */
    function setAuctionStartingPrice(
        uint256 _auctionStartingPrice
    ) external onlyManagement {
        require(_auctionStartingPrice != 0, "!0"); // dev: cannot be zero
        require(_auctionStartingPrice >= auctionRangeSize); // dev: starting price less than range
        bytes32 _auctionId = getAuctionId(USDE);
        require(auctions[_auctionId].kicked + auctionLength < block.timestamp); // dev: live auction
        auctionStartingPrice = _auctionStartingPrice;
    }

    /**
     * @notice Sets the range for the auction. The auction will go from the starting price
     * to starting price minus auctionRangeSize. Can only be called by management
     * @param _auctionRangeSize The width of the range for the auction.
     */
    function setAuctionRangeSize(
        uint64 _auctionRangeSize
    ) external onlyManagement {
        require(_auctionRangeSize != 0, "!0"); // dev: cannot be zero
        require(_auctionRangeSize <= auctionStartingPrice);  // dev: range greater than starting price
        bytes32 _auctionId = getAuctionId(USDE);
        require(auctions[_auctionId].kicked + auctionLength < block.timestamp); // dev: live auction
        auctionRangeSize = _auctionRangeSize;
    }

    /**
     * @notice Sets the length of time an auction lasts. Can only be called by management
     * @param _auctionLength The length of the auction
     */
    function setAuctionLength(uint32 _auctionLength) external onlyManagement {
        require(_auctionLength != 0, "!0"); // dev: cannot be zero
        bytes32 _auctionId = getAuctionId(USDE);
        require(auctions[_auctionId].kicked + auctionLength < block.timestamp); // dev: live auction
        auctionLength = _auctionLength;
    }

    /**
     * @notice Sets the length of time between the start of auctions. Can only be called by management
     * @param _auctionCooldown The duration between auction starts
     */
    function setAuctionCooldown(uint32 _auctionCooldown) external onlyManagement {
        require(_auctionCooldown >= auctionLength, "cooldown"); // dev: must be greater than or equal to length
        auctionCooldown = _auctionCooldown;
    }

    /**
     * @notice Sets the min discount on sUSDe to accept. Can only be called by management
     * @param _minSUSDeDiscountBps The minimum discount in basis points when buying sUSDe
     */
    function setMinSUSDeDiscountBps(
        uint16 _minSUSDeDiscountBps
    ) external onlyManagement {
        minSUSDeDiscountBps = _minSUSDeDiscountBps;
    }

    /*//////////////////////////////////////////////////////////////
                      External Actions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Clone the strategy proxy and add it to the list of proxies
     * Cannot create more than the MAX_STRATEGY_PROXIES value
     */
    function addStrategyProxy() external onlyManagement {
        require(strategyProxies.length < MAX_STRATEGY_PROXIES); // dev: max proxies
        strategyProxies.push(StrategyProxy(strategyProxies[0].clone()));
    }

    /**
     * @notice Recalls the ERC20 tokens from the specified proxy
     * @param _proxy  The proxy to recall from
     * @param _token  The token to recall
     */
    function recallFromProxy(
        address _proxy,
        address _token
    ) external onlyEmergencyAuthorized {
        StrategyProxy(_proxy).recall(_token);
    }

    /**
     * @notice Recalls the ERC20 tokens from the specified proxy
     * @param _proxy  The proxy to recall from
     * @param _token  The token to recall
     * @param _amount The amount of token to recall
     */
    function recallFromProxy(
        address _proxy,
        address _token,
        uint256 _amount
    ) external onlyEmergencyAuthorized {
        StrategyProxy(_proxy).recall(_token, _amount);
    }

    /**
     * @notice Manually unstakes susde
     * @param _proxy  The proxy to use for cooling down
     */
    function manualUnstakeSUSDe(
        address _proxy
    ) external onlyEmergencyAuthorized {
        _unstakeSUSDe(StrategyProxy(_proxy));
    }

    /**
     * @notice Manually initiates cooldown of sUSDe using the provided proxy
     * @param _proxy  The proxy to use for cooling down
     * @param _amount The amount of sUSDe to cooldown
     */
    function manualCooldownSUSDe(
        address _proxy,
        uint256 _amount
    ) external onlyEmergencyAuthorized {
        bool _proxyValid;
        for (uint8 i; i < strategyProxies.length; ++i) {
            if (address(strategyProxies[i]) == _proxy) {
                _proxyValid = true;
                break;
            }
        }
        require(_proxyValid, "!valid"); // dev: proxy must be in strategyProxies list
        _cooldownSUSDe(StrategyProxy(_proxy), _amount);
    }

    /**
     * @notice Sweeps the specified token and sends it to the management address
     * @param _token  The token to sweep
     */
    function sweep(address _token) external onlyManagement {
        require(_token != address(asset), "!asset"); // dev: cannot sweep asset
        require(_token != address(SUSDE), "!susde"); // dev: cannot sweep susde
        ERC20(_token).safeTransfer(
            TokenizedStrategy.management(),
            ERC20(_token).balanceOf(address(this))
        );
    }

    /*//////////////////////////////////////////////////////////////
                     BaseStrategy Overrides 
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Can deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        // do nothing
    }

    /**
     * @dev Should attempt to free the '_amount' of 'asset'.
     *
     * NOTE: The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        uint256 _amountFreed;

        // 1. we can check if any sUSDe with redeemable/withdrawable
        if (SUSDE.cooldownDuration() == 0) {
            _amountFreed = _redeemSUSDe(_looseSUSDe());
            if (_amountFreed >= _amount) return;
        }

        for (uint8 i; i < strategyProxies.length; ++i) {
            StrategyProxy _strategyProxy = strategyProxies[i];
            UserCooldown memory _cooldown = _cooldownStatus(
                address(_strategyProxy)
            );
            if (
                _cooldown.underlyingAmount != 0 &&
                _cooldown.cooldownEnd <= block.timestamp
            ) {
                _strategyProxy.unstakeSUSDe();
                _amountFreed += _cooldown.underlyingAmount;
                if (_amountFreed >= _amount) return;
            }
        }
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        _adjustPosition();
        _totalAssets = _estimatedTotalAssets();
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies.
     *
     *   EX:
     *       return asset.balanceOf(yieldSource);
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return _withdrawLimit The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256 _withdrawLimit) {
        _withdrawLimit = asset.balanceOf(address(this));

        if (SUSDE.cooldownDuration() == 0) {
            _withdrawLimit += SUSDE.convertToAssets(
                SUSDE.balanceOf(address(this))
            );
        }

        _withdrawLimit += _cooledUSDe();

        bytes32 _auctionId = getAuctionId(address(asset));
        (, , , uint256 _amountAvailableForAuction) = auctionInfo(_auctionId);
        if (_withdrawLimit > _amountAvailableForAuction) {
            _withdrawLimit -= _amountAvailableForAuction;
        } else {
            _withdrawLimit = 0;
        }
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     *
     */
    function availableDepositLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        uint256 _totalAssets = TokenizedStrategy.totalAssets();
        return _totalAssets >= depositLimit ? 0 : depositLimit - _totalAssets;
    }

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * This will have no effect on PPS of the strategy till report() is called.
     *
     * @param . The current amount of idle funds that are available to deploy.
     *
     */
    function _tend(uint256 /*_totalIdle*/) internal override {
        _adjustPosition();
    }

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
     */
    function _tendTrigger() internal view override returns (bool) {
        if (TokenizedStrategy.totalAssets() == 0) {
            return false;
        }

        uint256 _maxTendBasefeeGwei = uint256(maxTendBasefeeGwei);
        if (
            _maxTendBasefeeGwei != 0 &&
            block.basefee >= _maxTendBasefeeGwei * 1e9
        ) {
            return false;
        }

        for (uint8 i; i < strategyProxies.length; ++i) {
            StrategyProxy _strategyProxy = strategyProxies[i];
            UserCooldown memory _cooldown = _cooldownStatus(
                address(_strategyProxy)
            );
            if (
                _cooldown.underlyingAmount != 0 &&
                _cooldown.cooldownEnd <= block.timestamp
            ) {
                return true;
            }
        }

        if (TokenizedStrategy.isShutdown()) {
            return false;
        }

        if (SUSDE.balanceOf(address(this)) >= minCooldownAmount) {
            return true;
        }

        return false;
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     *
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        _freeFunds(_amount);
    }

    /*//////////////////////////////////////////////////////////////
                     AuctionSwapper Overrides 
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _token Address of the token being auctioned off
     */
    function _auctionKicked(
        address _token
    ) internal virtual override returns (uint256 _kicked) {
        require(_token == address(asset), "!asset"); // dev: only sell usde
        _kicked = Math.min(_looseAsset() + _cooledUSDe(), maxAuctionAmount);
        require(_kicked >= minAuctionAmount, "!min"); // dev: too little
    }

    /**
     * @param _token Address of the token being taken.
     * @param _usdeTakeAmount Amount of `_token` needed.
     * @param _susdeReceiveAmount Amount of `want` that will be payed.
     */
    function _preTake(
        address _token,
        uint256 _usdeTakeAmount,
        uint256 _susdeReceiveAmount
    ) internal virtual override {
        require(_token == address(asset), "!asset");

        uint256 _receiveAmountInUSDe = SUSDE.convertToAssets(
            _susdeReceiveAmount
        );
        require(_receiveAmountInUSDe > _usdeTakeAmount, "!discount"); // dev: no discount
        uint256 _surplusBps = ((_receiveAmountInUSDe - _usdeTakeAmount) *
            MAX_BPS) / _usdeTakeAmount;
        require(_surplusBps >= minSUSDeDiscountBps, "!minDiscount"); // dev: below minDiscount

        // free funds if required
        uint256 _idleUSDe = _looseAsset();
        if (_usdeTakeAmount > _idleUSDe) {
            _freeFunds(_usdeTakeAmount - _idleUSDe);
        }
    }

    function _price(
        uint256 _kicked,
        uint256 _available,
        uint256 _timestamp
    ) internal view virtual override returns (uint256) {
        if (_available == 0) return 0;

        uint256 _secondsElapsed = _timestamp - _kicked;
        uint256 _auctionLength = uint256(auctionLength);

        if (_secondsElapsed > _auctionLength) return 0;

        return
            auctionStartingPrice -
            ((uint256(auctionRangeSize) * _secondsElapsed) / auctionLength);
    }

    /*//////////////////////////////////////////////////////////////
                     Internal Doers of Things
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adjusts the strategy's position
     */
    function _adjustPosition() internal {
        uint24 _cooldownDuration = SUSDE.cooldownDuration();

        uint256 _idleSUSDe = _looseSUSDe();

        // Check if we can directly redeem
        if (_cooldownDuration == 0 && _idleSUSDe != 0) {
            _redeemSUSDe(_looseSUSDe());
        }

        _idleSUSDe = _looseSUSDe();

        for (uint8 i; i < strategyProxies.length; ++i) {
            StrategyProxy _strategyProxy = strategyProxies[i];
            // Check if we have shares to unstake
            UserCooldown memory _cooldown = _cooldownStatus(
                address(_strategyProxy)
            );
            if (
                _cooldown.underlyingAmount != 0 &&
                _cooldown.cooldownEnd <= block.timestamp
            ) {
                _unstakeSUSDe(_strategyProxy);
                // zero the cooldown info
                _cooldown.underlyingAmount = 0;
                _cooldown.cooldownEnd = 0;
            }

            // Cooldown sUSDE if there is no funds being cooled down
            if (
                _idleSUSDe >= minCooldownAmount &&
                _cooldownDuration != 0 &&
                _cooldown.underlyingAmount == 0
            ) {
                _cooldownSUSDe(_strategyProxy, _idleSUSDe);
                _idleSUSDe = 0;
            }
        }

        // 3. kick auction?
    }

    /**
     * @notice Initiates cooldown of sUSDe using a strategy proxy
     * @param _strategyProxy The strategy proxy to use
     * @param _amount The maximum amount to try to cooldown
     * @return . Amount of asset that will be released after cooldown
     */
    function _cooldownSUSDe(
        StrategyProxy _strategyProxy,
        uint256 _amount
    ) internal returns (uint256) {
        ERC20(address(SUSDE)).safeTransfer(
            address(_strategyProxy),
            Math.min(_amount, SUSDE.maxRedeem(address(this)))
        );
        return _strategyProxy.cooldownSUSDe();
    }

    /**
     * @notice Unstakes cooldowned sUSDe using the strategy proxy
     * @param _strategyProxy The strategy proxy to use
     */
    function _unstakeSUSDe(StrategyProxy _strategyProxy) internal {
        _strategyProxy.unstakeSUSDe();
    }

    /**
     * @notice Redeeems USDe from sUSDe stakingInitiates cooldown of
     * @param _amount The maximum amount to try to redeem
     * @return . Amount of asset redeemed
     */
    function _redeemSUSDe(uint256 _amount) internal returns (uint256) {
        uint256 sharesToRedeem = Math.min(
            _amount,
            SUSDE.maxRedeem(address(this))
        );
        return SUSDE.redeem(sharesToRedeem, address(this), address(this));
    }

    /*//////////////////////////////////////////////////////////////
                          Internal Views
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns this contract's loose asset
     * @return . The asset loose in this contract
     */
    function _looseAsset() internal view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Returns this contract's loose sUSDe
     * @return . The sUSDe loose in this contract
     */
    function _looseSUSDe() internal view returns (uint256) {
        return SUSDE.balanceOf(address(this));
    }

    /**
     * @notice Returns the amount of usde being cooldown
     * @return _amountCooling The cooldown amount in usde
     */
    function _coolingUSDe() internal view returns (uint256 _amountCooling) {
        for (uint8 i = 0; i < strategyProxies.length; ++i) {
            UserCooldown memory _cooldown = _cooldownStatus(
                address(strategyProxies[i])
            );
            _amountCooling += _cooldown.underlyingAmount;
        }
    }

    /**
     * @notice Returns the amount of usde the is fully cooled but needs to be unstaked
     * @return _amountCooled The cooled USDe waiting to be unstaked
     */
    function _cooledUSDe() internal view returns (uint256 _amountCooled) {
        for (uint8 i = 0; i < strategyProxies.length; ++i) {
            UserCooldown memory _cooldown = _cooldownStatus(
                address(strategyProxies[i])
            );
            if (
                _cooldown.underlyingAmount != 0 &&
                _cooldown.cooldownEnd <= block.timestamp
            ) {
                _amountCooled += _cooldown.underlyingAmount;
            }
        }
    }

    /**
     * @notice Returns the amount of asset with expect to report
     * @return . The amount of asset this strategy expects to report
     */
    function _estimatedTotalAssets() internal view returns (uint256) {
        return
            _looseAsset() +
            _coolingUSDe() +
            SUSDE.convertToAssets(_looseSUSDe());
    }

    /**
     * @notice Returns this contract's cooldown
     * @param _owner The owner of the cooldown
     * @return . The cooldown for this contract
     */
    function _cooldownStatus(
        address _owner
    ) internal view returns (UserCooldown memory) {
        return SUSDE.cooldowns(_owner);
    }
}
