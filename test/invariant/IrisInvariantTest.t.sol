// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../InvariantTest.t.sol";

contract IrisInvariantTest is InvariantTest {
    using MathLib for uint256;

    struct PodIndices {
        bytes32 marketKey;
        uint256 collateralIndex;
        uint256 debtIndex;
    }

    mapping(address pod => uint256 fixedLeg) internal _lastFixedLeg;
    mapping(address pod => PodIndices indices) internal _lastPodIndices;

    function setUp() public virtual override {
        _weightSelector(this.mineToMaturity.selector, 35);
        _weightSelector(this.mineToLiquidation.selector, 35);

        _weightSelector(this.take.selector, 240);
        _weightSelector(this.supplyCollateral.selector, 80);
        _weightSelector(this.withdrawCollateral.selector, 55);
        _weightSelector(this.supplyBond.selector, 70);
        _weightSelector(this.withdrawBond.selector, 45);
        _weightSelector(this.repayEarly.selector, 30);
        _weightSelector(this.repayMatured.selector, 35);
        _weightSelector(this.liquidate.selector, 35);
        _weightSelector(this.liquidateBond.selector, 25);
        _weightSelector(this.rebase.selector, 15);
        _weightSelector(this.refinance.selector, 25);
        _weightSelector(this.escape.selector, 15);
        _weightSelector(this.claim.selector, 25);

        super.setUp();
    }

    /* Modifiers */

    modifier authorized(address onBehalf) {
        if (onBehalf != msg.sender && !iris.isAuthorized(onBehalf, msg.sender)) {
            vm.prank(onBehalf);
            iris.setAuthorization(msg.sender, true);
        }

        _;

        if (iris.isAuthorized(onBehalf, msg.sender)) {
            vm.prank(onBehalf);
            iris.setAuthorization(msg.sender, false);
        }
    }

    /* Snapshots */

    function _beforeCall() internal virtual override {
        for (uint256 i; i < pods.length; ++i) {
            (,, uint256 fixedLeg,,) = iris.accrueLegsView(pods[i]);
            _lastFixedLeg[pods[i]] = fixedLeg;
        }
    }

    /* Handlers */

    function mineToMaturity(uint256 podSeed, uint256 elapsedSeed) external logCall("mineToMaturity") {
        address pod = _randomOpenPod(podSeed);
        if (pod == address(0)) return;

        Loan memory loan = iris.getLoan(pod);
        uint256 elapsed = loan.overduePeriod == 0 ? 0 : elapsedSeed % (uint256(loan.overduePeriod) + 1);
        uint256 target = uint256(loan.maturity) + elapsed;
        if (target > block.timestamp) _forward(target - block.timestamp);
    }

    function mineToLiquidation(uint256 podSeed, uint256 elapsedSeed) external logCall("mineToLiquidation") {
        address pod = _randomOpenPod(podSeed);
        if (pod == address(0)) return;

        Loan memory loan = iris.getLoan(pod);
        uint256 elapsed = elapsedSeed % (TIME_TO_MAX_LIF + 1);
        uint256 target = uint256(loan.maturity) + uint256(loan.overduePeriod) + 1 + elapsed;
        if (target > block.timestamp) _forward(target - block.timestamp);
    }

    function take(uint256 marketSeed, uint256 solverSeed, uint256 collateral, uint256 debt, uint256 quoteSeed)
        external
        logCall("take")
    {
        (address collateralToken_, address debtToken_, bytes memory data_, uint256 venueId_) = _randomMarket(marketSeed);
        (address solver, uint256 solverKey) = _randomUser(solverSeed);

        // Do not use ForkTest._boundHealthyPosition here: it relies on vm.assume, while this handler is
        // intended to run with fail_on_revert=true. Return when the current venue state cannot fit a position.
        uint256 maxBorrow = _maxBorrowable(collateralToken_, debtToken_, venueId_, data_);
        uint256 maxCollateral = _maxSuppliable(collateralToken_, venueId_, data_);
        if (maxBorrow < MIN_TEST_AMOUNT || maxCollateral < MIN_TEST_AMOUNT) return;

        debt = bound(debt, MIN_TEST_AMOUNT, maxBorrow);
        uint256 minCollateral = _minCollateralAmount(debt, collateralToken_, debtToken_, venueId_, data_);
        if (minCollateral > maxCollateral) return;
        collateral = bound(collateral, minCollateral, maxCollateral);

        Quote memory quote;
        quote.borrower = msg.sender;
        quote.solver = solver;
        quote.receiver = msg.sender;
        quote.blm = address(blm);
        quote.collateralToken = collateralToken_;
        quote.debtToken = debtToken_;
        quote.collateral = collateral;
        quote.debt = debt;
        quote.fixedRate = bound(quoteSeed, 0, MAX_FIXED_RATE / BP) * BP;
        quote.duration = bound(quoteSeed, MIN_DURATION, MAX_DURATION);
        quote.overdueRate = bound(quoteSeed, 0, MAX_OVERDUE_RATE / BP) * BP;
        quote.overduePeriod = bound(quoteSeed, 0, MAX_OVERDUE_PERIOD);
        quote.bondLltv = bondLltv;
        quote.venueBitmap = 3;
        quote.venueId = venueId_;
        quote.deadline = block.timestamp;
        quote.nonce = userNonce[solver];
        quote.data = data_;

        uint256 bondRequirement = blm.bondRequirement(quote);
        if (bondRequirement == 0) return;
        quote.bond = bound(quoteSeed, bondRequirement, MAX_TEST_AMOUNT);

        deal(collateralToken_, msg.sender, collateral);
        deal(debtToken_, solver, quote.bond);
        _approveIris(collateralToken_, msg.sender, collateral);
        _approveIris(debtToken_, solver, quote.bond);

        bytes memory signature = _signQuote(solverKey, quote);

        vm.prank(msg.sender);
        address pod = iris.take(quote, signature);
        pods.push(pod);
        ++userNonce[solver];
    }

    function supplyCollateral(uint256 podSeed, uint256 amount) external logCall("supplyCollateral") {
        address pod = _randomOpenPod(podSeed);
        if (pod == address(0)) return;

        Loan memory loan = iris.getLoan(pod);
        Position memory pos = iris.getPosition(pod);

        uint256 maxCollateral = _maxSuppliable(loan.collateralToken, pos.venueId, pos.data);
        if (maxCollateral < MIN_TEST_AMOUNT) return;

        amount = bound(amount, MIN_TEST_AMOUNT, maxCollateral);

        deal(loan.collateralToken, msg.sender, amount);
        _approveIris(loan.collateralToken, msg.sender, amount);

        vm.prank(msg.sender);
        iris.supplyCollateral(pod, amount);
    }

    function withdrawCollateral(uint256 podSeed, uint256 amountSeed, uint256 receiverSeed)
        external
        logCall("withdrawCollateral")
    {
        address pod = _randomOpenPod(podSeed);
        if (pod == address(0)) return;

        Loan memory loan = iris.getLoan(pod);
        if (block.timestamp > loan.maturity + loan.overduePeriod) return;

        (address receiver,) = _randomUser(receiverSeed);

        uint256 maxWithdraw = _maxWithdrawCollateral(pod);
        if (maxWithdraw < MIN_TEST_AMOUNT) return;

        uint256 amount = bound(amountSeed, MIN_TEST_AMOUNT, MathLib.min(maxWithdraw, MAX_TEST_AMOUNT));

        _withdrawCollateral(pod, amount, receiver);
    }

    function supplyBond(uint256 podSeed, uint256 amount) external logCall("supplyBond") {
        address pod = _randomOpenPod(podSeed);
        if (pod == address(0)) return;

        Loan memory loan = iris.getLoan(pod);
        Position memory pos = iris.getPosition(pod);

        uint256 maxAmount = MathLib.min(uint256(type(uint128).max) - pos.bond, MAX_TEST_AMOUNT);
        if (maxAmount < MIN_TEST_AMOUNT) return;

        amount = bound(amount, MIN_TEST_AMOUNT, maxAmount);

        deal(loan.debtToken, msg.sender, amount);
        _approveIris(loan.debtToken, msg.sender, amount);

        vm.prank(msg.sender);
        iris.supplyBond(pod, amount);
    }

    function withdrawBond(uint256 podSeed, uint256 amountSeed, uint256 receiverSeed) external logCall("withdrawBond") {
        address pod = _randomOpenPod(podSeed);
        if (pod == address(0)) return;

        (address receiver,) = _randomUser(receiverSeed);

        uint256 maxWithdraw = _maxWithdrawBond(pod);
        if (maxWithdraw < MIN_TEST_AMOUNT) return;

        uint256 amount = bound(amountSeed, MIN_TEST_AMOUNT, MathLib.min(maxWithdraw, MAX_TEST_AMOUNT));

        _withdrawBond(pod, amount, receiver);
    }

    function repayEarly(uint256 podSeed) external logCall("repayEarly") {
        address pod = _randomEarlyRepayablePod(podSeed);
        if (pod == address(0)) return;

        _repay(pod);
    }

    function repayMatured(uint256 podSeed) external logCall("repayMatured") {
        address pod = _randomMaturedRepayablePod(podSeed);
        if (pod == address(0)) return;

        _repay(pod);
    }

    function liquidate(uint256 podSeed, uint256 receiverSeed) external logCall("liquidate") {
        address pod = _randomLiquidatablePod(podSeed);
        if (pod == address(0)) return;

        (address receiver,) = _randomUser(receiverSeed);

        Loan memory loan = iris.getLoan(pod);

        uint256 amount = _repayAmount(pod);
        deal(loan.debtToken, msg.sender, amount);
        _approveIris(loan.debtToken, msg.sender, amount);

        // LiquidateForkTest:40
        // Stand in for the pooled balance a live Iris always holds: it absorbs the <=2 wei round-up gap a bad-bond
        // overdue close leaves (liquidation is funded to the exact tracked debt). Without it that close reverts.
        deal(loan.debtToken, address(iris), ERC20(loan.debtToken).balanceOf(address(iris)) + 2);
        deal(loan.collateralToken, address(iris), ERC20(loan.collateralToken).balanceOf(address(iris)) + 2);

        vm.prank(msg.sender);
        iris.liquidate(pod, receiver);
    }

    function liquidateBond(uint256 podSeed, uint256 receiverSeed) external logCall("liquidateBond") {
        address pod = _randomBondLiquidatablePod(podSeed);
        if (pod == address(0)) return;

        (address receiver,) = _randomUser(receiverSeed);

        vm.prank(msg.sender);
        iris.liquidateBond(pod, receiver);
    }

    function rebase(uint256 podSeed) external logCall("rebase") {
        address pod = _randomOpenPod(podSeed);
        if (pod == address(0)) return;

        vm.prank(msg.sender);
        iris.rebase(pod);
    }

    function refinance(uint256 podSeed, uint256 receiverSeed) external logCall("refinance") {
        address pod = _randomOpenPod(podSeed);
        if (pod == address(0)) return;

        (address receiver,) = _randomUser(receiverSeed);

        Loan memory loan = iris.getLoan(pod);
        Position memory pos = iris.getPosition(pod);

        if (block.timestamp > loan.maturity + loan.overduePeriod) return;

        (uint256 newVenueId, bytes memory data) = _refinanceTarget(pod);

        (uint256 venueCollateral, uint256 venueDebt) = IVenueAdapter(iris.venueAdapter(pos.venueId))
            .positionAssets(pod, loan.collateralToken, loan.debtToken, pos.data);

        uint256 maxBorrow = _maxBorrowable(loan.collateralToken, loan.debtToken, newVenueId, data);
        uint256 maxCollateral = _maxSuppliable(loan.collateralToken, newVenueId, data);
        if (maxBorrow < MIN_TEST_AMOUNT || maxCollateral < MIN_TEST_AMOUNT) return;
        if (venueDebt > maxBorrow || venueCollateral > maxCollateral) return;
        if (venueCollateral < _minCollateralAmount(venueDebt, loan.collateralToken, loan.debtToken, newVenueId, data)) {
            return;
        }

        deal(loan.debtToken, msg.sender, venueDebt);
        _approveIris(loan.debtToken, msg.sender, venueDebt);

        _refinance(pod, receiver, newVenueId, data);
    }

    function escape(uint256 podSeed, uint256 receiverSeed) external logCall("escape") {
        address pod = _randomResolvedPod(podSeed);
        if (pod == address(0)) return;

        (address receiver,) = _randomUser(receiverSeed);

        Loan memory loan = iris.getLoan(pod);
        Position memory pos = iris.getPosition(pod);

        address adapter = iris.venueAdapter(pos.venueId);
        (, uint256 venueDebt) =
            IVenueAdapter(adapter).positionAssets(pod, loan.collateralToken, loan.debtToken, pos.data);
        deal(loan.debtToken, msg.sender, venueDebt);
        _approveIris(loan.debtToken, msg.sender, venueDebt);

        _escape(pod, receiver);
    }

    function claim(uint256 claimableSeed, uint256 receiverSeed) external logCall("claim") {
        (address token, address onBehalf) = _randomClaimable(claimableSeed);
        if (onBehalf == address(0)) return;

        (address receiver,) = _randomUser(receiverSeed);

        // Iris.sol:530
        // seized + surplus can exceed the venue balance by <=1 wei.
        uint256 claimable = (iris.claimable(token, onBehalf)).zeroFloorSub(1);
        if (claimable == 0) return;

        _claim(token, claimable, onBehalf, receiver);
    }

    /* Internal Functions */

    function _withdrawCollateral(address pod, uint256 amount, address receiver)
        internal
        authorized(iris.getLoan(pod).borrower)
    {
        vm.prank(msg.sender);
        iris.withdrawCollateral(pod, amount, receiver);
    }

    function _withdrawBond(address pod, uint256 amount, address receiver)
        internal
        authorized(iris.getLoan(pod).solver)
    {
        vm.prank(msg.sender);
        iris.withdrawBond(pod, amount, receiver);
    }

    function _refinance(address pod, address receiver, uint256 venueId, bytes memory data)
        internal
        authorized(iris.getLoan(pod).solver)
    {
        vm.prank(msg.sender);
        iris.refinance(pod, receiver, venueId, data);
    }

    function _escape(address pod, address receiver) internal authorized(iris.getLoan(pod).borrower) {
        vm.prank(msg.sender);
        iris.escape(pod, receiver);
    }

    function _claim(address token, uint256 amount, address onBehalf, address receiver) internal authorized(onBehalf) {
        vm.prank(msg.sender);
        iris.claim(token, amount, onBehalf, receiver);
    }

    function _repay(address pod) internal {
        Loan memory loan = iris.getLoan(pod);

        uint256 amount = _repayAmount(pod);
        deal(loan.debtToken, msg.sender, amount);
        _approveIris(loan.debtToken, msg.sender, amount);

        // RepayForkTest:39
        // Stand in for the pooled balance a live Iris always holds: it absorbs the <=2 wei round-up gap a bad-bond
        // overdue close leaves (repay is funded to the exact tracked debt). Without it that close reverts.
        deal(loan.debtToken, address(iris), ERC20(loan.debtToken).balanceOf(address(iris)) + 2);

        vm.prank(msg.sender);
        iris.repay(pod);
    }

    /* Invariants */

    function invariantBondRequirement() public view {
        for (uint256 i; i < pods.length; ++i) {
            Position memory pos = iris.getPosition(pods[i]);
            if (pos.bondRequirement != 0) assertGt(pos.bond, 0);
        }
    }

    function invariantSolvency() public view {
        address[] memory users = targetSenders();

        for (uint256 i; i < config.morphoMarketIdList.length; ++i) {
            MarketParams memory market = MorphoBlueUtils.idToMarketParams(morphoBlue, config.morphoMarketIdList[i]);
            address[2] memory pair = [market.collateralToken, market.loanToken];

            for (uint256 j; j < 2; ++j) {
                address token = pair[j];

                uint256 liabilities = iris.claimable(token, feeRecipient);
                for (uint256 k; k < users.length; ++k) {
                    liabilities += iris.claimable(token, users[k]);
                }
                for (uint256 l; l < pods.length; ++l) {
                    if (iris.getLoan(pods[l]).debtToken == token) liabilities += iris.getPosition(pods[l]).bond;
                }

                assertGe(ERC20(token).balanceOf(address(iris)) + MIN_TEST_AMOUNT, liabilities);
            }
        }
    }

    function invariantFixedLeg() public view {
        for (uint256 i; i < pods.length; ++i) {
            address pod = pods[i];
            Position memory pos = iris.getPosition(pod);
            if (pos.debt == 0 && pos.fixedLeg == 0) continue;

            (,, uint256 fixedLeg,,) = iris.accrueLegsView(pod);
            if (pos.debt != 0) assertGe(fixedLeg, _lastFixedLeg[pod]);
            else assertLe(fixedLeg, _lastFixedLeg[pod]);
        }
    }

    function invariantPodIndicesNeverDecrease() public {
        for (uint256 i; i < pods.length; ++i) {
            address pod = pods[i];
            Position memory pos = iris.getPosition(pod);
            bytes32 marketKey = keccak256(abi.encode(pos.venueId, pos.data));
            PodIndices storage last = _lastPodIndices[pod];

            if (last.marketKey == marketKey) {
                assertGe(pos.collateralIndex, last.collateralIndex);
                assertGe(pos.debtIndex, last.debtIndex);
            }

            last.marketKey = marketKey;
            last.collateralIndex = pos.collateralIndex;
            last.debtIndex = pos.debtIndex;
        }
    }
}
