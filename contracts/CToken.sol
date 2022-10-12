// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./ComptrollerInterface.sol";
import "./CTokenInterfaces.sol";
import "./ErrorReporter.sol";
import "./EIP20Interface.sol";
import "./InterestRateModel.sol";
import "./ExponentialNoError.sol";

/**
 * @title Compound's CToken Contract
 * @notice Abstract base for CTokens
 * @author Compound
 */
abstract contract CToken is CTokenInterface, ExponentialNoError, TokenErrorReporter {
    /**
     * @notice Initialize the money market
     * 启动货币市场
     * @param comptroller_ The address of the Comptroller
     * Comptroller合约地址
     * @param interestRateModel_ The address of the interest rate model
     * 利率模型合约地址
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * 初始汇率，乘以1e18
     * @param name_ EIP-20 name of this token
     * @param symbol_ EIP-20 symbol of this token
     * @param decimals_ EIP-20 decimal precision of this token
     */
    function initialize(ComptrollerInterface comptroller_,
                        InterestRateModel interestRateModel_,
                        uint initialExchangeRateMantissa_,
                        string memory name_,
                        string memory symbol_,
                        uint8 decimals_) public {
        // 只有admin能够初始化货币市场
        require(msg.sender == admin, "only admin may initialize the market");
        require(accrualBlockNumber == 0 && borrowIndex == 0, "market may only be initialized once");

        // Set initial exchange rate
        // 设置初始汇率
        initialExchangeRateMantissa = initialExchangeRateMantissa_;
        require(initialExchangeRateMantissa > 0, "initial exchange rate must be greater than zero.");

        // Set the comptroller
        uint err = _setComptroller(comptroller_);
        require(err == NO_ERROR, "setting comptroller failed");

        // Initialize block number and borrow index (block number mocks depend on comptroller being set)
        // 初始化区块号和borrow index
        accrualBlockNumber = getBlockNumber();
        // borrowIndex初始化为mantissaOne，mantissaOne是1e18，写死的，即1
        borrowIndex = mantissaOne;

        // Set the interest rate model (depends on block number / borrow index)
        err = _setInterestRateModelFresh(interestRateModel_);//TODO
        require(err == NO_ERROR, "setting interest rate model failed");

        name = name_;
        symbol = symbol_;
        decimals = decimals_;

        // The counter starts true to prevent changing it from zero to non-zero (i.e. smaller cost/refund)
        // _notEntered开始变为true，以防止将其从零更改为非零(即更小的成本/退款)
        // _notEntered在调用initialize之前默认值是false，意味着对整个合约加了可重入锁了，此处设置为true，就是解锁。也就是说只有在调用了initialize之后才能调用其他方法。
        _notEntered = true;
    }

    /**
     * @notice Transfer `tokens` tokens from `src` to `dst` by `spender`
     * @dev Called by both `transfer` and `transferFrom` internally
     * @param spender The address of the account performing the transfer
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param tokens The number of tokens to transfer
     * @return 0 if the transfer succeeded, else revert
     */
    function transferTokens(address spender, address src, address dst, uint tokens) internal returns (uint) {
        /* Fail if transfer not allowed */
        uint allowed = comptroller.transferAllowed(address(this), src, dst, tokens);
        if (allowed != 0) {
            revert TransferComptrollerRejection(allowed);
        }

        /* Do not allow self-transfers */
        if (src == dst) {
            revert TransferNotAllowed();
        }

        /* Get the allowance, infinite for the account owner */
        uint startingAllowance = 0;
        if (spender == src) {
            startingAllowance = type(uint).max;
        } else {
            startingAllowance = transferAllowances[src][spender];
        }

        /* Do the calculations, checking for {under,over}flow */
        uint allowanceNew = startingAllowance - tokens;
        uint srcTokensNew = accountTokens[src] - tokens;
        uint dstTokensNew = accountTokens[dst] + tokens;

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        accountTokens[src] = srcTokensNew;
        accountTokens[dst] = dstTokensNew;

        /* Eat some of the allowance (if necessary) */
        if (startingAllowance != type(uint).max) {
            transferAllowances[src][spender] = allowanceNew;
        }

        /* We emit a Transfer event */
        emit Transfer(src, dst, tokens);

        // unused function
        // comptroller.transferVerify(address(this), src, dst, tokens);

        return NO_ERROR;
    }

    /**
     * @notice Transfer `amount` tokens from `msg.sender` to `dst`
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transfer(address dst, uint256 amount) override external nonReentrant returns (bool) {
        return transferTokens(msg.sender, msg.sender, dst, amount) == NO_ERROR;
    }

    /**
     * @notice Transfer `amount` tokens from `src` to `dst`
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferFrom(address src, address dst, uint256 amount) override external nonReentrant returns (bool) {
        return transferTokens(msg.sender, src, dst, amount) == NO_ERROR;
    }

    /**
     * @notice Approve `spender` to transfer up to `amount` from `src`
     * @dev This will overwrite the approval amount for `spender`
     *  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
     * @param spender The address of the account which may transfer tokens
     * @param amount The number of tokens that are approved (uint256.max means infinite)
     * @return Whether or not the approval succeeded
     */
    function approve(address spender, uint256 amount) override external returns (bool) {
        address src = msg.sender;
        transferAllowances[src][spender] = amount;
        emit Approval(src, spender, amount);
        return true;
    }

    /**
     * @notice Get the current allowance from `owner` for `spender`
     * @param owner The address of the account which owns the tokens to be spent
     * @param spender The address of the account which may transfer tokens
     * @return The number of tokens allowed to be spent (-1 means infinite)
     */
    function allowance(address owner, address spender) override external view returns (uint256) {
        return transferAllowances[owner][spender];
    }

    /**
     * @notice Get the token balance of the `owner`
     * @param owner The address of the account to query
     * @return The number of tokens owned by `owner`
     */
    function balanceOf(address owner) override external view returns (uint256) {
        return accountTokens[owner];
    }

    /**
     * @notice Get the underlying balance of the `owner`
     * @dev This also accrues interest in a transaction
     * @param owner The address of the account to query
     * @return The amount of underlying owned by `owner`
     */
    function balanceOfUnderlying(address owner) override external returns (uint) {
        Exp memory exchangeRate = Exp({mantissa: exchangeRateCurrent()});
        return mul_ScalarTruncate(exchangeRate, accountTokens[owner]);
    }

    /**
     * @notice Get a snapshot of the account's balances, and the cached exchange rate
     * 获取帐户的CToken余额，借款余额（underlying），汇率（一个CToken值多少underlying）
     * @dev This is used by comptroller to more efficiently perform liquidity checks.
     * 这被审计合约用来更有效地执行流动性检查。
     * @param account Address of the account to snapshot
     * @return (possible error, token balance, borrow balance, exchange rate mantissa)
     */
    function getAccountSnapshot(address account) override external view returns (uint, uint, uint, uint) {
        return (
            NO_ERROR,
            accountTokens[account], // CToken余额
            borrowBalanceStoredInternal(account), // 根据存储的数据返回账户借款余额
            exchangeRateStoredInternal() // 计算从underlying到CToken的汇率，即一个CToken值多少underlying
        );
    }

    /**
     * @dev Function to simply retrieve block number
     * 用来检索当前区块号
     *  This exists mainly for inheriting test contracts to stub this result.
     × 这主要是为了继承测试合约来存根此结果，即打桩。
     */
    function getBlockNumber() virtual internal view returns (uint) {
        return block.number;
    }

    /**
     * @notice Returns the current per-block borrow interest rate for this cToken
     * @return The borrow interest rate per block, scaled by 1e18
     */
    function borrowRatePerBlock() override external view returns (uint) {
        return interestRateModel.getBorrowRate(getCashPrior(), totalBorrows, totalReserves);
    }

    /**
     * @notice Returns the current per-block supply interest rate for this cToken
     * @return The supply interest rate per block, scaled by 1e18
     */
    function supplyRatePerBlock() override external view returns (uint) {
        return interestRateModel.getSupplyRate(getCashPrior(), totalBorrows, totalReserves, reserveFactorMantissa);
    }

    /**
     * @notice Returns the current total borrows plus accrued interest
     * @return The total borrows with interest
     */
    function totalBorrowsCurrent() override external nonReentrant returns (uint) {
        accrueInterest();
        return totalBorrows;
    }

    /**
     * @notice Accrue interest to updated borrowIndex and then calculate account's borrow balance using the updated borrowIndex
     * @param account The address whose balance should be calculated after updating borrowIndex
     * @return The calculated balance
     */
    function borrowBalanceCurrent(address account) override external nonReentrant returns (uint) {
        accrueInterest();
        return borrowBalanceStored(account);
    }

    /**
     * @notice Return the borrow balance of account based on stored data
     * 根据已存储数据返回账户借款余额，需要基于状态变量现计算
     * @param account The address whose balance should be calculated
     * 需要计算余额的地址
     * @return The calculated balance
     * 计算的借款余额
     */
    function borrowBalanceStored(address account) override public view returns (uint) {
        return borrowBalanceStoredInternal(account);
    }

    /**
     * @notice Return the borrow balance of account based on stored data
     * 根据存储的数据返回账户借款余额
     * @param account The address whose balance should be calculated
     * @return (error code, the calculated balance or 0 if error code is non-zero)
     */
    function borrowBalanceStoredInternal(address account) internal view returns (uint) {
        /* Get borrowBalance and borrowIndex */
        // accountBorrows是帐户地址到未偿还借款余额的映射
        BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

        /* If borrowBalance = 0 then borrowIndex is likely also 0.
         * Rather than failing the calculation with a division by 0, we immediately return 0 in this case.
         */
        // principal代表应用最近的余额变更操作后的总余额(包括应计利息)
        // 如果borrowBalance = 0，那么borrowIndex也可能为0。在这种情况下，我们不会因为除以0而导致计算失败，而是立即返回0。
        if (borrowSnapshot.principal == 0) {
            return 0;
        }

        /* Calculate new borrow balance using the interest index:
         * 使用利率指数计算新借款余额:
         *  recentBorrowBalance = borrower.borrowBalance * market.borrowIndex / borrower.borrowIndex
         * market.borrowIndex是对于market全局的，borrower.borrowBalance和borrower.borrowIndex是针对这个借款人的
         */
        uint principalTimesIndex = borrowSnapshot.principal * borrowIndex;
        return principalTimesIndex / borrowSnapshot.interestIndex;
    }

    /**
     * @notice Accrue interest then return the up-to-date exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateCurrent() override public nonReentrant returns (uint) {
        accrueInterest();
        return exchangeRateStored();
    }

    /**
     * @notice Calculates the exchange rate from the underlying to the CToken
     * @dev This function does not accrue interest before calculating the exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateStored() override public view returns (uint) {
        return exchangeRateStoredInternal();
    }

    /**
     * @notice Calculates the exchange rate from the underlying to the CToken
     * 计算从underlying到CToken的汇率
     * @dev This function does not accrue interest before calculating the exchange rate
     * 该函数在计算汇率之前不累积/计算利息
     * @return calculated exchange rate scaled by 1e18
     */
    function exchangeRateStoredInternal() virtual internal view returns (uint) {
        // CToken的总供应量
        uint _totalSupply = totalSupply;
        if (_totalSupply == 0) { // 说明还没有铸造过CToken，使用初始汇率
            /*
             * If there are no tokens minted:
             *  exchangeRate = initialExchangeRate
             */
            return initialExchangeRateMantissa; // 初始汇率
        } else { // 说明已经铸造过CToken
            /*
             * Otherwise:
             *  exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
             */
            uint totalCash = getCashPrior(); // CToken合约拥有的标的资产的数量
            uint cashPlusBorrowsMinusReserves = totalCash + totalBorrows - totalReserves;
            // 计算CToken的价格，即一个CToken可以换多少标的资产。cashPlusBorrowsMinusReserves是标的资产，_totalSupply是CToken
            // expScale是固定的，1e18
            uint exchangeRate = cashPlusBorrowsMinusReserves * expScale / _totalSupply;

            return exchangeRate;
        }
    }

    /**
     * @notice Get cash balance of this cToken in the underlying asset
     * @return The quantity of underlying asset owned by this contract
     */
    function getCash() override external view returns (uint) {
        return getCashPrior();
    }

    /**
     * @notice Applies accrued interest to total borrows and reserves
     * 将应计利息应用于总借款和准备金
     * @dev This calculates interest accrued from the last checkpointed block
     *   up to the current block and writes new checkpoint to storage.
     * 这将计算从最后一个检查点区块到当前区块的累积利息，并将新的检查点写入存储。
     */
    function accrueInterest() virtual override public returns (uint) {
        /* Remember the initial block number */
        uint currentBlockNumber = getBlockNumber();
        uint accrualBlockNumberPrior = accrualBlockNumber;

        /* Short-circuit accumulating 0 interest */
        // 当前区块已经计算过利息了，不再重复计算
        if (accrualBlockNumberPrior == currentBlockNumber) {
            return NO_ERROR;
        }

        /* Read the previous values out of storage */
        // 读取状态变量到本地变量
        uint cashPrior = getCashPrior(); // 获取此合约拥有的标的资产的余额
        uint borrowsPrior = totalBorrows;
        uint reservesPrior = totalReserves;
        uint borrowIndexPrior = borrowIndex;

        /* Calculate the current borrow interest rate */
        // 计算每个区块的当前借款利率
        uint borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
        // 利率不能过高。.0005%/区块是写死的。
        require(borrowRateMantissa <= borrowRateMaxMantissa, "borrow rate is absurdly high");

        /* Calculate the number of blocks elapsed since the last accrual */
        uint blockDelta = currentBlockNumber - accrualBlockNumberPrior;

        /*
         * Calculate the interest accumulated into borrows and reserves and the new index:
         * 计算借款和准备金的利息积累和新index
         *  simpleInterestFactor = borrowRate * blockDelta
         *  interestAccumulated = simpleInterestFactor * totalBorrows
         *  totalBorrowsNew = interestAccumulated + totalBorrows
         *  totalReservesNew = interestAccumulated * reserveFactor + totalReserves
         *  borrowIndexNew = simpleInterestFactor * borrowIndex + borrowIndex
         */

        // blockDelta数量的区块对应的利率，计算方式很简单，区块利率*区块数
        Exp memory simpleInterestFactor = mul_(Exp({mantissa: borrowRateMantissa}), blockDelta);
        // 计算blockDelta个区块产生的利息，注意，是复利，因为利息计算之后会被算到借款额即totalBorrows中去
        // simpleInterestFactor = borrowRate * blockDelta
        // interestAccumulated = simpleInterestFactor * borrowsPrior
        uint interestAccumulated = mul_ScalarTruncate(simpleInterestFactor, borrowsPrior);
        // 利息+之前的借款额。所以是复利。
        // totalBorrowsNew = interestAccumulated + totalBorrows
        uint totalBorrowsNew = interestAccumulated + borrowsPrior;
        // totalReservesNew = interestAccumulated * reserveFactor + totalReserves
        // totalReserves就是累积利息中需要分给准备金的部分，具体分多少由百分比reserveFactorMantissa决定
        uint totalReservesNew = mul_ScalarTruncateAddUInt(Exp({mantissa: reserveFactorMantissa}), interestAccumulated, reservesPrior);
        // borrowIndexNew = simpleInterestFactor * borrowIndex + borrowIndex
        // borrowIndex表示累积的区块利率，初始值是1e18，即1。比如，第一次调用accrueInterest的话，那么
        // borrowIndexNew = simpleInterestFactor * 1e18 + 1e18
        uint borrowIndexNew = mul_ScalarTruncateAddUInt(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)
        // 超过这个点就没有安全故障了

        /* We write the previously calculated values into storage */
        // 更新状态变量
        accrualBlockNumber = currentBlockNumber;
        borrowIndex = borrowIndexNew;
        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;

        /* We emit an AccrueInterest event */
        emit AccrueInterest(cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew);

        return NO_ERROR;
    }

    /**
     * @notice Sender supplies assets into the market and receives cTokens in exchange
     * Sender向市场提供资产，并接收cTokens作为交换
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * 无论操作是否成功，均应计算利息，除非回滚
     * @param mintAmount The amount of the underlying asset to supply
     * 要提供的标的资产的数量
     */
    function mintInternal(uint mintAmount) internal nonReentrant {
        // 将应计利息应用于总借款和准备金，并更新相关状态变量
        accrueInterest();
        // mintFresh emits the actual Mint event if successful and logs on errors, so we don't need to
        // mintFresh如果成功就会发出实际的Mint事件并记录错误，所以我们不需要这样做
        // 用户向市场提供资产并接收cTokens作为交换，干了如下几件事：
        // 1.mint前置检查 2.计算当前汇率 3.minter转标的资产到CToken合约 4.根据当前汇率计算应该给minter铸造的cTokens数量 5.给minter铸造cTokens 6.发出相应事件
        mintFresh(msg.sender, mintAmount);
    }

    /**
     * @notice User supplies assets into the market and receives cTokens in exchange
     * 用户向市场提供资产并接收cTokens作为交换，干了如下几件事：
     * 1.mint前置检查 2.计算当前汇率 3.minter转标的资产到CToken合约 4.根据当前汇率计算应该给minter铸造的cTokens数量 5.给minter铸造cTokens 6.发出相应事件
     * @dev Assumes interest has already been accrued up to the current block
     * 假设利息已经累积到当前区块
     * @param minter The address of the account which is supplying the assets
     * 提供资产的帐户地址
     * @param mintAmount The amount of the underlying asset to supply
     * 要提供的标的资产的数量
     */
    function mintFresh(address minter, uint mintAmount) internal {
        /* Fail if mint not allowed */
        // 检查帐户是否应该被允许在给定的市场上铸造代币
        uint allowed = comptroller.mintAllowed(address(this), minter, mintAmount);
        if (allowed != 0) {
            revert MintComptrollerRejection(allowed);
        }

        /* Verify market's block number equals current block number */
        // 判断当前区块必须已经计算过利息了
        if (accrualBlockNumber != getBlockNumber()) {
            revert MintFreshnessCheck();
        }

        // exchangeRateStoredInternal计算从underlying到CToken的汇率，即CToken的价格，一个CToken可以换多少标的资产
        Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal()});

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         *  We call `doTransferIn` for the minter and the mintAmount.
         *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
         *  `doTransferIn` reverts if anything goes wrong, since we can't be sure if
         *  side-effects occurred. The function returns the amount actually transferred,
         *  in case of a fee. On success, the cToken holds an additional `actualMintAmount`
         *  of cash.
         */
        // 我们为minter和mintAmount调用`doTransferIn`。
        // 注意:cToken必须处理ERC-20 underlying和ETH underlying的差异。
        // `doTransferIn`会在出现任何问题时回滚，因为我们不能确定是否副作用发生了。函数返回实际转移的金额。成功后，cToken合约持有额外的`actualMintAmount`标的资产。
        // 类似于EIP20传输，除了它处理来自transferFrom的False结果并在那种情况下回滚。这将由于余额不足或allowance不足而回滚。
        // 此函数返回实际收到的金额，如果transfer附加了fee，则实际收到的金额可能小于amount。
        // 这个包装器可以安全地处理不返回值的非标准ERC-20 tokens。
        // 执行转账，失败时回滚。返回实际转移到协议的金额。可能由于余额不足或allowance不足而回滚。
        // doTransferIn的具体实现有两种，在CErc20和CEther中
        uint actualMintAmount = doTransferIn(minter, mintAmount);

        /*
         * We get the current exchange rate and calculate the number of cTokens to be minted:
         * 我们得到当前的汇率并计算要铸造的cTokens的数量:
         *  mintTokens = actualMintAmount / exchangeRate
         */

        uint mintTokens = div_(actualMintAmount, exchangeRate);

        /*
         * We calculate the new total supply of cTokens and minter token balance, checking for overflow:
         * 我们计算新的cTokens总供应量和minter token余额，检查溢出:
         *  totalSupplyNew = totalSupply + mintTokens
         *  accountTokensNew = accountTokens[minter] + mintTokens
         * And write them into storage
         */
        totalSupply = totalSupply + mintTokens; // cTokens总供应量增加
        accountTokens[minter] = accountTokens[minter] + mintTokens; // minter的cTokens余额增加

        /* We emit a Mint event, and a Transfer event */
        emit Mint(minter, actualMintAmount, mintTokens); // minter地址，minter转给CToken合约的标的资产数量，铸造的cTokens数量
        emit Transfer(address(this), minter, mintTokens); // EIP20标准的Transfer事件

        /* We call the defense hook */
        // unused function
        // comptroller.mintVerify(address(this), minter, actualMintAmount, mintTokens);
    }

    /**
     * @notice Sender redeems cTokens in exchange for the underlying asset
     * Sender赎回cTokens以换取标的资产
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * 无论操作是否成功，均应计算累积利息
     * @param redeemTokens The number of cTokens to redeem into underlying
     */
    function redeemInternal(uint redeemTokens) internal nonReentrant {
        // 将应计利息应用于总借款和准备金。这将计算从最后一个检查点区块到当前区块的累积利息，并将新的检查点写入存储。
        accrueInterest();
        // redeemFresh emits redeem-specific logs on errors, so we don't need to
        redeemFresh(payable(msg.sender), redeemTokens, 0);
    }

    /**
     * @notice Sender redeems cTokens in exchange for a specified amount of underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemAmount The amount of underlying to receive from redeeming cTokens
     */
    function redeemUnderlyingInternal(uint redeemAmount) internal nonReentrant {
        accrueInterest();
        // redeemFresh emits redeem-specific logs on errors, so we don't need to
        redeemFresh(payable(msg.sender), 0, redeemAmount);
    }

    /**
     * @notice User redeems cTokens in exchange for the underlying asset
     * 用户赎回cTokens以换取标的资产
     * @dev Assumes interest has already been accrued up to the current block
     * 假设利息已经累积到当前区块
     * @param redeemer The address of the account which is redeeming the tokens
     * 赎回代币的账户地址
     * @param redeemTokensIn The number of cTokens to redeem into underlying (only one of redeemTokensIn or redeemAmountIn may be non-zero)
     * 赎回到标的资产的cTokens的数量(redeemTokensIn或redeemAmountIn中只有一个可能是非零的)
     * @param redeemAmountIn The number of underlying tokens to receive from redeeming cTokens (only one of redeemTokensIn or redeemAmountIn may be non-zero)
     * 从赎回的cTokens中接收的标的资产的数量(redeemTokensIn或redeemAmountIn中只有一个可能非零)
     */
    function redeemFresh(address payable redeemer, uint redeemTokensIn, uint redeemAmountIn) internal {
        require(redeemTokensIn == 0 || redeemAmountIn == 0, "one of redeemTokensIn or redeemAmountIn must be zero");

        /* exchangeRate = invoke Exchange Rate Stored() */
        // exchangeRateStoredInternal计算从underlying到CToken的汇率
        Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal() });

        uint redeemTokens;
        uint redeemAmount;
        /* If redeemTokensIn > 0: */
        if (redeemTokensIn > 0) {
            /*
             * We calculate the exchange rate and the amount of underlying to be redeemed:
             * 我们计算汇率和可赎回的标的资产金额:
             *  redeemTokens = redeemTokensIn
             *  redeemAmount = redeemTokensIn x exchangeRateCurrent
             */
            redeemTokens = redeemTokensIn;
            redeemAmount = mul_ScalarTruncate(exchangeRate, redeemTokensIn);
        } else {
            /*
             * We get the current exchange rate and calculate the amount to be redeemed:
             * 我们得到当前汇率，并计算要赎回的cTokens数量:
             *  redeemTokens = redeemAmountIn / exchangeRate
             *  redeemAmount = redeemAmountIn
             */
            redeemTokens = div_(redeemAmountIn, exchangeRate);
            redeemAmount = redeemAmountIn;
        }

        /* Fail if redeem not allowed */
        // 注意：传入的参数是要赎回的cTokens数量，而不是标的资产数量
        // 注意redeemAllowed的返回值，返回值为0,表示allow；为非0,表示不allow。不会用回滚来表示不allow。
        // 这一步很重要，安全性检查就在里面。
        uint allowed = comptroller.redeemAllowed(address(this), redeemer, redeemTokens);
        if (allowed != 0) {
            revert RedeemComptrollerRejection(allowed); // 回滚
        }

        /* Verify market's block number equals current block number */
        // 判断当前区块必须已经计算过利息了
        if (accrualBlockNumber != getBlockNumber()) {
            revert RedeemFreshnessCheck(); // 回滚
        }

        /* Fail gracefully if protocol has insufficient cash */
        // 如果协议拥有的标的资产不足，则优雅地失败
        if (getCashPrior() < redeemAmount) {
            revert RedeemTransferOutNotPossible(); // 回滚
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)


        /*
         * We write the previously calculated values into storage.
         *  Note: Avoid token reentrancy attacks by writing reduced supply before external transfer.
         */
        // 我们将上面计算的值写入存储。注意:通过在外部transfer之前写入减少的供应来避免token可重入攻击。
        totalSupply = totalSupply - redeemTokens; // cToken总供应量减少
        accountTokens[redeemer] = accountTokens[redeemer] - redeemTokens; // 赎回者的cToken余额减少

        /*
         * We invoke doTransferOut for the redeemer and the redeemAmount.
         *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
         *  On success, the cToken has redeemAmount less of cash.
         *  doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
         */
        // 我们为redeemer和redeemAmount调用doTransferOut。
        // 注意:cToken必须处理ERC-20和ETH之间的差异。成功时，cToken合约拥有的标的资产减少redeemAmount。
        // 如果出现任何错误，doTransferOut将回滚，因为我们不能确定是否发生了副作用。
        doTransferOut(redeemer, redeemAmount);

        /* We emit a Transfer event, and a Redeem event */
        emit Transfer(redeemer, address(this), redeemTokens); // 赎回者发送cTokens给cTokens合约
        emit Redeem(redeemer, redeemAmount, redeemTokens); // 赎回者赎回的cTokens数量和标的资产金额

        /* We call the defense hook */
        // 验证赎回操作并在拒绝时回滚。可能发出日志。
        comptroller.redeemVerify(address(this), redeemer, redeemAmount, redeemTokens);
    }

    /**
      * @notice Sender borrows assets from the protocol to their own address
      * sender从协议中借资产到自己的地址
      * @param borrowAmount The amount of the underlying asset to borrow
      * 要借的标的资产的数额
      */
    function borrowInternal(uint borrowAmount) internal nonReentrant {
        // 将应计利息应用于总借款和准备金。这将计算从最后一个检查点区块到当前区块的累积利息，并将新的检查点写入存储。
        accrueInterest();
        // borrowFresh emits borrow-specific logs on errors, so we don't need to
        borrowFresh(payable(msg.sender), borrowAmount);
    }

    /**
      * @notice Users borrow assets from the protocol to their own address
      * 用户从协议中借资产到自己的地址
      * @param borrowAmount The amount of the underlying asset to borrow
      * 要借的标的资产的数额
      */
    function borrowFresh(address payable borrower, uint borrowAmount) internal {
        /* Fail if borrow not allowed */
        uint allowed = comptroller.borrowAllowed(address(this), borrower, borrowAmount);
        if (allowed != 0) {
            revert BorrowComptrollerRejection(allowed);
        }

        /* Verify market's block number equals current block number */
        // 判断当前区块必须已经计算过利息了
        if (accrualBlockNumber != getBlockNumber()) {
            revert BorrowFreshnessCheck();
        }

        /* Fail gracefully if protocol has insufficient underlying cash */
        // 如果协议的underlying资金不足，则优雅失败
        if (getCashPrior() < borrowAmount) {
            revert BorrowCashNotAvailable();
        }

        /*
         * We calculate the new borrower and total borrow balances, failing on overflow:
         * 计算该借款人的借款余额和总借款余额，在溢出时失败:
         *  accountBorrowNew = accountBorrow + borrowAmount
         *  totalBorrowsNew = totalBorrows + borrowAmount
         */
        uint accountBorrowsPrev = borrowBalanceStoredInternal(borrower); // 根据存储的数据返回账户借款余额，这是现计算出来的
        uint accountBorrowsNew = accountBorrowsPrev + borrowAmount;
        uint totalBorrowsNew = totalBorrows + borrowAmount;

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         * We write the previously calculated values into storage.
         *  Note: Avoid token reentrancy attacks by writing increased borrow before external transfer.
        `*/
        // 将上面计算的值写入存储
        // 通过在external transfer之前写入增加的借款来避免token重入攻击。
        accountBorrows[borrower].principal = accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = totalBorrowsNew;

        /*
         * We invoke doTransferOut for the borrower and the borrowAmount.
         *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
         *  On success, the cToken borrowAmount less of cash.
         *  doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
         */
        // 我们为借款人和borrowAmount调用doTransferOut。
        // 注意:cToken必须处理ERC-20和ETH之间的差异。
        // 成功后，cToken的资金减少。如果出现任何错误，doTransferOut将回滚，因为我们不能确定是否发生了副作用。
        doTransferOut(borrower, borrowAmount);

        /* We emit a Borrow event */
        emit Borrow(borrower, borrowAmount, accountBorrowsNew, totalBorrowsNew);
    }

    /**
     * @notice Sender repays their own borrow
     * sender偿还他们自己的借款
     * @param repayAmount The amount to repay, or -1 for the full outstanding amount
     * 偿还金额，或-1表示全部未偿还金额
     */
    function repayBorrowInternal(uint repayAmount) internal nonReentrant {
        // 将应计利息应用于总借款和准备金，这将计算从最后一个检查点区块到当前区块的累积利息，并将新的检查点写入存储。
        accrueInterest();
        // repayBorrowFresh emits repay-borrow-specific logs on errors, so we don't need to
        // 借款由另一个用户(可能是借款人自己)偿还。
        repayBorrowFresh(msg.sender, msg.sender, repayAmount);
    }

    /**
     * @notice Sender repays a borrow belonging to borrower
     * @param borrower the account with the debt being payed off
     * @param repayAmount The amount to repay, or -1 for the full outstanding amount
     */
    function repayBorrowBehalfInternal(address borrower, uint repayAmount) internal nonReentrant {
        accrueInterest();
        // repayBorrowFresh emits repay-borrow-specific logs on errors, so we don't need to
        repayBorrowFresh(msg.sender, borrower, repayAmount);
    }

    /**
     * @notice Borrows are repaid by another user (possibly the borrower).
     * 借款由另一个用户(可能是借款人自己)偿还。
     * @param payer the account paying off the borrow
     * 偿还借款的帐户
     * @param borrower the account with the debt being payed off
     * 需要偿还债务的账户，payer和borrower可以是同一个地址
     * @param repayAmount the amount of underlying tokens being returned, or -1 for the full outstanding amount
     * @return (uint) the actual repayment amount.
     * 实际还款金额
     */
    function repayBorrowFresh(address payer, address borrower, uint repayAmount) internal returns (uint) {
        /* Fail if repayBorrow not allowed */
        uint allowed = comptroller.repayBorrowAllowed(address(this), payer, borrower, repayAmount);
        if (allowed != 0) {
            revert RepayBorrowComptrollerRejection(allowed);
        }

        /* Verify market's block number equals current block number */
        // 判断当前区块必须已经计算过利息了
        if (accrualBlockNumber != getBlockNumber()) {
            revert RepayBorrowFreshnessCheck();
        }

        /* We fetch the amount the borrower owes, with accumulated interest */
        // 获取借款人所欠的金额，包括累计利息
        // borrowBalanceStoredInternal根据存储的数据返回账户借款余额
        uint accountBorrowsPrev = borrowBalanceStoredInternal(borrower);

        /* If repayAmount == -1, repayAmount = accountBorrows */
        // 确定要还款的金额
        uint repayAmountFinal = repayAmount == type(uint).max ? accountBorrowsPrev : repayAmount;

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         * We call doTransferIn for the payer and the repayAmount
         *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
         *  On success, the cToken holds an additional repayAmount of cash.
         *  doTransferIn reverts if anything goes wrong, since we can't be sure if side effects occurred.
         *   it returns the amount actually transferred, in case of a fee.
         */
        // 我们为付款人和repayAmount调用doTransferIn。
        // 注意:cToken必须处理ERC-20和ETH之间的差异。如果成功，cToken持有额外的偿还金额标的资产。
        // 如果出现任何问题，doTransferIn会回滚，因为我们不能确定是否出现了副作用。
        // 它返回实际转移的金额，以防发生费用。这个很重要，所以actualRepayAmount并不一定等于repayAmountFinal，有可能要少一些。
        uint actualRepayAmount = doTransferIn(payer, repayAmountFinal);

        /*
         * We calculate the new borrower and total borrow balances, failing on underflow:
         * 我们计算新的借款人借款余额和总借款余额，如果underflow就失败:
         *  accountBorrowsNew = accountBorrows - actualRepayAmount
         *  totalBorrowsNew = totalBorrows - actualRepayAmount
         */
        uint accountBorrowsNew = accountBorrowsPrev - actualRepayAmount;
        uint totalBorrowsNew = totalBorrows - actualRepayAmount;

        /* We write the previously calculated values into storage */
        // 写进storage
        accountBorrows[borrower].principal = accountBorrowsNew; // 更新借款人借款总额
        accountBorrows[borrower].interestIndex = borrowIndex; // 更新借款人的interestIndex为最新的borrowIndex，borrowIndex是状态变量，全局的
        totalBorrows = totalBorrowsNew; // 更新cToken的总借款额

        /* We emit a RepayBorrow event */
        emit RepayBorrow(payer, borrower, actualRepayAmount, accountBorrowsNew, totalBorrowsNew);

        return actualRepayAmount; // 返回的是实际还款额，即cToken实际收到的标的资产的金额
    }

    /**
     * @notice The sender liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * 发送方清算借款人抵押品。
     * 扣押的抵押品转移给清盘人。
     * @param borrower The borrower of this cToken to be liquidated
     * 要清算的cToken的借款人
     * @param cTokenCollateral The market in which to seize collateral from the borrower
     * 从借款人手中夺取抵押品的市场
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * 需要偿还的标的借款资产的金额
     */
    function liquidateBorrowInternal(address borrower, uint repayAmount, CTokenInterface cTokenCollateral) internal nonReentrant {
        // 对于当前CToken, 将应计利息应用于总借款和准备金。这将计算从最后一个检查点区块到当前区块的累积利息，并将新的检查点写入存储。
        accrueInterest();

        // 对于抵押品CToken, 将应计利息应用于总借款和准备金。这将计算从最后一个检查点区块到当前区块的累积利息，并将新的检查点写入存储。
        uint error = cTokenCollateral.accrueInterest();
        if (error != NO_ERROR) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted liquidation failed
            // accrueInterest发出关于错误的日志，但是我们仍然希望记录试图清算失败的事实
            revert LiquidateAccrueCollateralInterestFailed(error);
        }

        // liquidateBorrowFresh emits borrow-specific logs on errors, so we don't need to
        // msg.sender是清算人，borrower是借款人
        // 清算人清算借款人的抵押品。查封的抵押品转移给清算人。
        liquidateBorrowFresh(msg.sender, borrower, repayAmount, cTokenCollateral);
    }

    /**
     * @notice The liquidator liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * 清算人清算借款人的抵押品。
     * 扣押的抵押品转移给清算人。
     * @param borrower The borrower of this cToken to be liquidated
     * 要清算的cToken的借款人
     * @param liquidator The address repaying the borrow and seizing collateral
     * 偿还借款和得到抵押品的清算人地址
     * @param cTokenCollateral The market in which to seize collateral from the borrower
     * 从借款人手中夺取抵押品的市场
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * 需要偿还的标的借款资产的金额
     */
    // 注意，这个方法的安全校验有两个地方：一是调用liquidateBorrowAllowed判断是否允许清算借款，一是调用seizeAllowed判断是否允许查封抵押物
    function liquidateBorrowFresh(address liquidator, address borrower, uint repayAmount, CTokenInterface cTokenCollateral) internal {
        /* Fail if liquidate not allowed */
        // 检查清算是否被允许发生
        uint allowed = comptroller.liquidateBorrowAllowed(address(this), address(cTokenCollateral), liquidator, borrower, repayAmount);
        if (allowed != 0) {
            revert LiquidateComptrollerRejection(allowed);
        }

        /* Verify market's block number equals current block number */
        // 判断借款CToken的当前区块必须已经计算过利息了
        if (accrualBlockNumber != getBlockNumber()) {
            revert LiquidateFreshnessCheck();
        }

        /* Verify cTokenCollateral market's block number equals current block number */
        // 判断抵押物CToken的当前区块必须已经计算过利息了
        if (cTokenCollateral.accrualBlockNumber() != getBlockNumber()) {
            revert LiquidateCollateralFreshnessCheck();
        }

        /* Fail if borrower = liquidator */
        // 清算人不能是借款人本人
        if (borrower == liquidator) {
            revert LiquidateLiquidatorIsBorrower();
        }

        /* Fail if repayAmount = 0 */
        // 偿还的借款不能为0
        if (repayAmount == 0) {
            revert LiquidateCloseAmountIsZero();
        }

        /* Fail if repayAmount = -1 */
        // 偿还的借款不能为uint256的最大值
        if (repayAmount == type(uint).max) {
            revert LiquidateCloseAmountIsUintMax();
        }

        /* Fail if repayBorrow fails */
        // 借款由另一个用户(可能是借款人自己)偿还。
        // repayBorrowFresh被用在三种场景中：1.借款人自己偿还借款 2.帮别人偿还借款 3.清算人清算
        uint actualRepayAmount = repayBorrowFresh(liquidator, borrower, repayAmount); // 清算人实际还款金额

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /* We calculate the number of collateral tokens that will be seized */
        // 计算将被查封的抵押品代币的数量
        // 返回错误码，清算中要查封的cTokenCollateral tokens的数量，应该归清算人所有，这个数量包含了对清算人的激励。注意：seizeTokens中有一小部分要划拨到抵押物cToken的准备金中去。
        (uint amountSeizeError, uint seizeTokens) = comptroller.liquidateCalculateSeizeTokens(address(this), address(cTokenCollateral), actualRepayAmount);
        require(amountSeizeError == NO_ERROR, "LIQUIDATE_COMPTROLLER_CALCULATE_AMOUNT_SEIZE_FAILED");

        /* Revert if borrower collateral token balance < seizeTokens */
        // 借款人在抵押物CToken拥有的cTokens余额必须大于要转给清算人的数量，这样才够。
        require(cTokenCollateral.balanceOf(borrower) >= seizeTokens, "LIQUIDATE_SEIZE_TOO_MUCH");

        // If this is also the collateral, run seizeInternal to avoid re-entrancy, otherwise make an external call
        // 如果本借款CToken合约也是抵押品CToken合约，运行seizeInternal以避免重入。
        // 进一步解释：不能调用seize，只能调用seizeInternal。因为liquidateBorrowFresh的外层调用方法liquidateBorrowInternal已经加了锁，而seize方法也加了锁，如果调seize方法就会发生重入失败。所以只能调没有加锁的seizeInternal以避免重入。
        // 这是一种特殊场景，即借款人在同一个CToken中既有cTokens，代表借款人是储户，赚取利息，同时借款人又从这个CToken中借了标的资产。借款人同时在一个CToken中是储户和借款人。
        // 这种场景，清算者有可能就把抵押物CToken设置为借款的CToken
        if (address(cTokenCollateral) == address(this)) {
            // 将抵押品代币(该市场)转移到清算人。借款人抵押物cTokens减少，清算人抵押物cTokens增加，抵押物cTokens总供应量减少，本市场所持有的标的准备金总额增加。
            // 注意：此处调的是本CToken的查封方法，本CToken同时是借款CToken和抵押物CToken
            seizeInternal(address(this), liquidator, borrower, seizeTokens);
        } else {
            // 将抵押品代币(该市场)转移到清算人。借款人抵押物cTokens减少，清算人抵押物cTokens增加，抵押物cTokens总供应量减少，本市场所持有的标的准备金总额增加。
            require(cTokenCollateral.seize(liquidator, borrower, seizeTokens) == NO_ERROR, "token seizure failed");
        }

        /* We emit a LiquidateBorrow event */
        // actualRepayAmount表示清算人实际还款金额
        // seizeTokens表示清算中要查封的cTokenCollateral tokens的数量，应该归清算人所有，这个数量包含了对清算人的激励。注意：seizeTokens中有一小部分要划拨到抵押物cToken的准备金中去。
        emit LiquidateBorrow(liquidator, borrower, actualRepayAmount, address(cTokenCollateral), seizeTokens);
    }

    /**
     * @notice Transfers collateral tokens (this market) to the liquidator.
     * 将抵押品代币(该市场)转移到清算人。借款人抵押物cTokens减少，清算人抵押物cTokens增加，抵押物cTokens总供应量减少，本市场所持有的标的准备金总额增加。
     * 注意：针对本CToken是抵押物CToken的场景
     * @dev Will fail unless called by another cToken during the process of liquidation.
     *  Its absolutely critical to use msg.sender as the borrowed cToken and not a parameter.
     * 将失败，除非在清算过程中被另一个cToken调用，即调用者是另一个CToken合约。使用msg.sender而非一个参数作为seizer cToken是绝对关键的。
     * @param liquidator The account receiving seized collateral
     * 接收查封抵押物的账户
     * @param borrower The account having collateral seized
     * 抵押物被查封的账户
     * @param seizeTokens The number of cTokens to seize
     * 要查封的cTokens数量
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function seize(address liquidator, address borrower, uint seizeTokens) override external nonReentrant returns (uint) {
        // 注意此处用了msg.sender，代表正在执行清算操作的其他CToken。msg.sender作为参数传到seizeInternal中，然后作为comptroller.seizeAllowed的第二个参数，代表借款的CToken合约
        seizeInternal(msg.sender, liquidator, borrower, seizeTokens);

        return NO_ERROR;
    }

    /**
     * @notice Transfers collateral tokens (this market) to the liquidator.
     * 将抵押品代币(该市场)转移到清算人。借款人抵押物cTokens减少，清算人抵押物cTokens增加，抵押物cTokens总供应量减少，本市场所持有的标的准备金总额增加。
     * 注意：针对本CToken是抵押物CToken的场景
     * @dev Called only during an in-kind liquidation, or by liquidateBorrow during the liquidation of another CToken.
     *  Its absolutely critical to use msg.sender as the seizer cToken and not a parameter. TODO：这一段注释是copy的seize函数的注释，并不适用于本函数，可以删掉
     * 只在内部清算期间调用，或者在另一个CToken清算期间由liquidateBorrow调用。使用msg.sender而非一个参数作为seizer cToken是绝对关键的。
     * @param seizerToken The contract seizing the collateral (i.e. borrowed cToken)
     * 查封抵押物的合约(比如，借款的cToken)。
     * @param liquidator The account receiving seized collateral
     * 接收查封抵押物的账户
     * @param borrower The account having collateral seized
     * 抵押物被查封的账户
     * @param seizeTokens The number of cTokens to seize
     * 要查封的cTokens数量
     */
    function seizeInternal(address seizerToken, address liquidator, address borrower, uint seizeTokens) internal {
        /* Fail if seize not allowed */
        // 检查是否允许查封资产
        // 注意：第一个参数写死为address(this)，表示本CToken合约此时是抵押物合约；第二个参数seizerToken视情况而定，有可能是其他合约，也有可能是本合约
        uint allowed = comptroller.seizeAllowed(address(this), seizerToken, liquidator, borrower, seizeTokens);
        if (allowed != 0) {
            revert LiquidateSeizeComptrollerRejection(allowed);
        }

        /* Fail if borrower = liquidator */
        // 清算人不能是借款人
        if (borrower == liquidator) {
            revert LiquidateSeizeLiquidatorIsBorrower();
        }

        /*
         * We calculate the new borrower and liquidator token balances, failing on underflow/overflow:
         * 计算新的借款人和清算人在本cToken的cTokens代币余额，在下溢/上溢时失败:
         *  borrowerTokensNew = accountTokens[borrower] - seizeTokens
         *  liquidatorTokensNew = accountTokens[liquidator] + seizeTokens
         */

        // protocolSeizeShareMantissa是清算人查封的抵押物被加入准备金的比例
        uint protocolSeizeTokens = mul_(seizeTokens, Exp({mantissa: protocolSeizeShareMantissa})); // 需要加入准备金的抵押物cTokens数量
        uint liquidatorSeizeTokens = seizeTokens - protocolSeizeTokens; // 扣除了需要加入准备金的抵押物cTokens数量后，清算人应该净得的抵押物cTokens数量
        Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal()}); // 借款CToken的汇率
        uint protocolSeizeAmount = mul_ScalarTruncate(exchangeRate, protocolSeizeTokens); // 需要加入准备金的抵押物cTokens数量对应的标的资产数量
        uint totalReservesNew = totalReserves + protocolSeizeAmount; // 准备金增加了，注意：准备金是以标的资产计算的，而不是以cTokens计算的


        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /* We write the calculated values into storage */
        // 将计算值写入storage持久化
        totalReserves = totalReservesNew; // 更新本市场所持有的标的准备金总额
        totalSupply = totalSupply - protocolSeizeTokens; // 更新流通中的CToken代币总数，减去需要加入准备金的抵押物cTokens数量。即cTokens减少，准备金标的资产增加。
        accountTokens[borrower] = accountTokens[borrower] - seizeTokens; // 借款人应该失去seizeTokens数量的cTokens
        accountTokens[liquidator] = accountTokens[liquidator] + liquidatorSeizeTokens; // 清算人应该得到liquidatorSeizeTokens cTokens数量

        /* Emit a Transfer event */
        emit Transfer(borrower, liquidator, liquidatorSeizeTokens); // 代表借款人给了清算人抵押物cTokens
        emit Transfer(borrower, address(this), protocolSeizeTokens); // 代表借款人给了CToken合约需要加入准备金的抵押物cTokens数量
        emit ReservesAdded(address(this), protocolSeizeAmount, totalReservesNew); // 代表在查封过程中准备金增加了
    }


    /*** Admin Functions ***/

    /**
      * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
      * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
      * @param newPendingAdmin New pending admin.
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setPendingAdmin(address payable newPendingAdmin) override external returns (uint) {
        // Check caller = admin
        if (msg.sender != admin) {
            revert SetPendingAdminOwnerCheck();
        }

        // Save current value, if any, for inclusion in log
        address oldPendingAdmin = pendingAdmin;

        // Store pendingAdmin with value newPendingAdmin
        pendingAdmin = newPendingAdmin;

        // Emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin)
        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);

        return NO_ERROR;
    }

    /**
      * @notice Accepts transfer of admin rights. msg.sender must be pendingAdmin
      * @dev Admin function for pending admin to accept role and update admin
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _acceptAdmin() override external returns (uint) {
        // Check caller is pendingAdmin and pendingAdmin ≠ address(0)
        if (msg.sender != pendingAdmin || msg.sender == address(0)) {
            revert AcceptAdminPendingAdminCheck();
        }

        // Save current values for inclusion in log
        address oldAdmin = admin;
        address oldPendingAdmin = pendingAdmin;

        // Store admin with value pendingAdmin
        admin = pendingAdmin;

        // Clear the pending value
        pendingAdmin = payable(address(0));

        emit NewAdmin(oldAdmin, admin);
        emit NewPendingAdmin(oldPendingAdmin, pendingAdmin);

        return NO_ERROR;
    }

    /**
      * @notice Sets a new comptroller for the market
      * 为市场设置一个新的审计员
      * @dev Admin function to set a new comptroller
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      * 返回0表示成功
      */
    function _setComptroller(ComptrollerInterface newComptroller) override public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            revert SetComptrollerOwnerCheck();
        }

        ComptrollerInterface oldComptroller = comptroller;
        // Ensure invoke comptroller.isComptroller() returns true
        require(newComptroller.isComptroller(), "marker method returned false");

        // Set market's comptroller to newComptroller
        comptroller = newComptroller;

        // Emit NewComptroller(oldComptroller, newComptroller)
        emit NewComptroller(oldComptroller, newComptroller);

        return NO_ERROR; // 常量0
    }

    /**
      * @notice accrues interest and sets a new reserve factor for the protocol using _setReserveFactorFresh
      * @dev Admin function to accrue interest and set a new reserve factor
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setReserveFactor(uint newReserveFactorMantissa) override external nonReentrant returns (uint) {
        accrueInterest();
        // _setReserveFactorFresh emits reserve-factor-specific logs on errors, so we don't need to.
        return _setReserveFactorFresh(newReserveFactorMantissa);
    }

    /**
      * @notice Sets a new reserve factor for the protocol (*requires fresh interest accrual)
      * @dev Admin function to set a new reserve factor
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setReserveFactorFresh(uint newReserveFactorMantissa) internal returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            revert SetReserveFactorAdminCheck();
        }

        // Verify market's block number equals current block number
        if (accrualBlockNumber != getBlockNumber()) {
            revert SetReserveFactorFreshCheck();
        }

        // Check newReserveFactor ≤ maxReserveFactor
        if (newReserveFactorMantissa > reserveFactorMaxMantissa) {
            revert SetReserveFactorBoundsCheck();
        }

        uint oldReserveFactorMantissa = reserveFactorMantissa;
        reserveFactorMantissa = newReserveFactorMantissa;

        emit NewReserveFactor(oldReserveFactorMantissa, newReserveFactorMantissa);

        return NO_ERROR;
    }

    /**
     * @notice Accrues interest and reduces reserves by transferring from msg.sender
     * @param addAmount Amount of addition to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _addReservesInternal(uint addAmount) internal nonReentrant returns (uint) {
        accrueInterest();

        // _addReservesFresh emits reserve-addition-specific logs on errors, so we don't need to.
        _addReservesFresh(addAmount);
        return NO_ERROR;
    }

    /**
     * @notice Add reserves by transferring from caller
     * @dev Requires fresh interest accrual
     * @param addAmount Amount of addition to reserves
     * @return (uint, uint) An error code (0=success, otherwise a failure (see ErrorReporter.sol for details)) and the actual amount added, net token fees
     */
    function _addReservesFresh(uint addAmount) internal returns (uint, uint) {
        // totalReserves + actualAddAmount
        uint totalReservesNew;
        uint actualAddAmount;

        // We fail gracefully unless market's block number equals current block number
        if (accrualBlockNumber != getBlockNumber()) {
            revert AddReservesFactorFreshCheck(actualAddAmount);
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         * We call doTransferIn for the caller and the addAmount
         *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
         *  On success, the cToken holds an additional addAmount of cash.
         *  doTransferIn reverts if anything goes wrong, since we can't be sure if side effects occurred.
         *  it returns the amount actually transferred, in case of a fee.
         */

        actualAddAmount = doTransferIn(msg.sender, addAmount);

        totalReservesNew = totalReserves + actualAddAmount;

        // Store reserves[n+1] = reserves[n] + actualAddAmount
        totalReserves = totalReservesNew;

        /* Emit NewReserves(admin, actualAddAmount, reserves[n+1]) */
        emit ReservesAdded(msg.sender, actualAddAmount, totalReservesNew);

        /* Return (NO_ERROR, actualAddAmount) */
        return (NO_ERROR, actualAddAmount);
    }


    /**
     * @notice Accrues interest and reduces reserves by transferring to admin
     * @param reduceAmount Amount of reduction to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _reduceReserves(uint reduceAmount) override external nonReentrant returns (uint) {
        accrueInterest();
        // _reduceReservesFresh emits reserve-reduction-specific logs on errors, so we don't need to.
        return _reduceReservesFresh(reduceAmount);
    }

    /**
     * @notice Reduces reserves by transferring to admin
     * @dev Requires fresh interest accrual
     * @param reduceAmount Amount of reduction to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _reduceReservesFresh(uint reduceAmount) internal returns (uint) {
        // totalReserves - reduceAmount
        uint totalReservesNew;

        // Check caller is admin
        if (msg.sender != admin) {
            revert ReduceReservesAdminCheck();
        }

        // We fail gracefully unless market's block number equals current block number
        if (accrualBlockNumber != getBlockNumber()) {
            revert ReduceReservesFreshCheck();
        }

        // Fail gracefully if protocol has insufficient underlying cash
        if (getCashPrior() < reduceAmount) {
            revert ReduceReservesCashNotAvailable();
        }

        // Check reduceAmount ≤ reserves[n] (totalReserves)
        if (reduceAmount > totalReserves) {
            revert ReduceReservesCashValidation();
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        totalReservesNew = totalReserves - reduceAmount;

        // Store reserves[n+1] = reserves[n] - reduceAmount
        totalReserves = totalReservesNew;

        // doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
        doTransferOut(admin, reduceAmount);

        emit ReservesReduced(admin, reduceAmount, totalReservesNew);

        return NO_ERROR;
    }

    /**
     * @notice accrues interest and updates the interest rate model using _setInterestRateModelFresh
     * @dev Admin function to accrue interest and update the interest rate model
     * @param newInterestRateModel the new interest rate model to use
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setInterestRateModel(InterestRateModel newInterestRateModel) override public returns (uint) {
        accrueInterest();
        // _setInterestRateModelFresh emits interest-rate-model-update-specific logs on errors, so we don't need to.
        return _setInterestRateModelFresh(newInterestRateModel);
    }

    /**
     * @notice updates the interest rate model (*requires fresh interest accrual)
     * @dev Admin function to update the interest rate model
     * @param newInterestRateModel the new interest rate model to use
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setInterestRateModelFresh(InterestRateModel newInterestRateModel) internal returns (uint) {

        // Used to store old model for use in the event that is emitted on success
        InterestRateModel oldInterestRateModel;

        // Check caller is admin
        if (msg.sender != admin) {
            revert SetInterestRateModelOwnerCheck();
        }

        // We fail gracefully unless market's block number equals current block number
        if (accrualBlockNumber != getBlockNumber()) {
            revert SetInterestRateModelFreshCheck();
        }

        // Track the market's current interest rate model
        oldInterestRateModel = interestRateModel;

        // Ensure invoke newInterestRateModel.isInterestRateModel() returns true
        require(newInterestRateModel.isInterestRateModel(), "marker method returned false");

        // Set the interest rate model to newInterestRateModel
        interestRateModel = newInterestRateModel;

        // Emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel)
        emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel);

        return NO_ERROR;
    }

    /*** Safe Token ***/

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * 获取此合约拥有的标的资产的余额
     * @dev This excludes the value of the current message, if any
     * 这排除了当前消息的值(如果有的话)
     * @return The quantity of underlying owned by this contract
     * 本合约所拥有的标的资产数量
     */
    // 此处只是声明，并没有实现，要子合约来实现，比如CErc20, CEther, CDaiDelegate
    function getCashPrior() virtual internal view returns (uint);

    /**
     * @dev Performs a transfer in, reverting upon failure. Returns the amount actually transferred to the protocol, in case of a fee.
     *  This may revert due to insufficient balance or insufficient allowance.
     * 执行转账，失败时回滚。返回实际转移到协议的金额。可能由于余额不足或allowance不足而回滚。
     */
    function doTransferIn(address from, uint amount) virtual internal returns (uint);

    /**
     * @dev Performs a transfer out, ideally returning an explanatory error code upon failure rather than reverting.
     *  If caller has not called checked protocol's balance, may revert due to insufficient cash held in the contract.
     *  If caller has checked protocol's balance, and verified it is >= amount, this should not revert in normal conditions.
     */
    function doTransferOut(address payable to, uint amount) virtual internal;


    /*** Reentrancy Guard ***/
    // 可重入保护

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * 防止合约直接或间接调用自身。
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered"); // _notEntered为true代表没有进入
        _notEntered = false; // 已经进入
        _; // 执行方法
        _notEntered = true; // get a gas-refund post-Istanbul 方法执行完后设置为没有进入
    }
}
