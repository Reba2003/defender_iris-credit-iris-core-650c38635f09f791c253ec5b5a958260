// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./IrisInvariantTest.t.sol";

/// @dev Checks the BOND LIQUIDATION claim in the Iris.sol header: on bond liquidation the solver forfeits the
/// surplus, which "stays in the venue for the borrower, compensating the borrower for being forced to variable
/// rate". The compensation is the venue collateral left above the borrower's tracked collateral once the bond is
/// liquidated, i.e. the collateral yield accrued while the loan was fixed-rate.
/// @dev MorphoBlueAdapter pins the collateral index to 1e27, so a Morpho pod never accrues surplus and its
/// borrower is never compensated. invariantBondLiquidationCompensatesBorrower is expected to fail as soon as a
/// Morpho pod is bond-liquidated after MIN_FIXED_RATE_LIFE. It can also fail on Aave when the collateral reserve
/// earns ~no supply yield, which is the same gap in a weaker form.
contract BondLiquidationCompensationInvariantTest is IrisInvariantTest {
    using MathLib for uint256;
    using SafeTransferLib for address;

    /// @dev Below this, zero collateral yield is plausible on any venue and is not reported.
    uint256 internal constant MIN_FIXED_RATE_LIFE = 1 days;

    struct BondLiquidation {
        uint8 venueId;
        uint256 fixedRateLife;
        uint256 forfeitedSurplus;
        uint256 compensation;
    }

    address internal immutable whale = makeAddr("MorphoWhale");

    mapping(address pod => uint256) internal _takenAt;
    mapping(address pod => BondLiquidation) internal _bondLiquidation;
    address[] internal _bondLiquidatedPods;

    function setUp() public virtual override {
        _weightSelector(this.liquidateBondTracked.selector, 60);
        _weightSelector(this.raiseMorphoUtilization.selector, 40);

        super.setUp();
    }

    /* Snapshots */

    /// @dev A pod is first seen on the handler call after its take. Only `mine` (which does not touch Iris) can
    /// run in between, so lastUpdate is still the take timestamp.
    function _beforeCall() internal override {
        super._beforeCall();
        for (uint256 i; i < pods.length; ++i) {
            if (_takenAt[pods[i]] == 0) _takenAt[pods[i]] = iris.getPosition(pods[i]).lastUpdate;
        }
    }

    /* Handlers */

    /// @dev Same as liquidateBond, recording the surplus forfeited and the collateral left for the borrower.
    function liquidateBondTracked(uint256 podSeed, uint256 receiverSeed) external logCall("liquidateBondTracked") {
        address pod = _randomBondLiquidatablePod(podSeed);
        if (pod == address(0)) return;

        (address receiver,) = _randomUser(receiverSeed);
        (,,,, uint256 forfeitedSurplus) = iris.accrueLegsView(pod);

        vm.prank(msg.sender);
        iris.liquidateBond(pod, receiver);

        Loan memory loan = iris.getLoan(pod);
        Position memory pos = iris.getPosition(pod);
        (uint256 venueCollateral,) = IVenueAdapter(iris.venueAdapter(pos.venueId))
            .positionAssets(pod, loan.collateralToken, loan.debtToken, pos.data);

        _bondLiquidation[pod] = BondLiquidation({
            venueId: pos.venueId,
            fixedRateLife: block.timestamp - _takenAt[pod],
            forfeitedSurplus: forfeitedSurplus,
            compensation: venueCollateral.zeroFloorSub(pos.collateral)
        });
        _bondLiquidatedPods.push(pod);
    }

    /// @dev A third party borrows on a Morpho market up to targetMorphoUtilization. The Adaptive Curve IRM then
    /// ramps the borrow rate above the quotes' fixed rates, so Morpho pods reach bond liquidation through real
    /// venue interest instead of storage writes.
    function raiseMorphoUtilization(uint256 marketSeed, uint256 amountSeed) external logCall("raiseMorphoUtilization") {
        MarketParams memory marketParams =
            MorphoBlueUtils.randomMarketParams(morphoBlue, marketSeed, config.morphoMarketIdList);
        bytes memory data = abi.encode(marketParams);

        uint256 available = MorphoBlueUtils.maxBorrowCapacity(morphoBlue, data, targetMorphoUtilization);
        if (available < MIN_TEST_AMOUNT) return;

        uint256 amount = bound(amountSeed, MIN_TEST_AMOUNT, MathLib.min(available, MAX_TEST_AMOUNT));
        // 2x the minimum so the whale stays healthy while rates ramp.
        uint256 collateral = MorphoBlueUtils.minCollateralAmount(amount, morphoBlue, data) * 2;

        deal(marketParams.collateralToken, whale, collateral);

        vm.startPrank(whale);
        marketParams.collateralToken.safeApproveWithRetry(morphoBlue, collateral);
        IMorpho(morphoBlue).supplyCollateral(marketParams, collateral, whale, "");
        IMorpho(morphoBlue).borrow(marketParams, amount, 0, whale, whale);
        vm.stopPrank();
    }

    /* Invariants */

    function invariantBondLiquidationCompensatesBorrower() public view {
        for (uint256 i; i < _bondLiquidatedPods.length; ++i) {
            BondLiquidation memory liquidation = _bondLiquidation[_bondLiquidatedPods[i]];
            if (liquidation.fixedRateLife < MIN_FIXED_RATE_LIFE) continue;

            assertGt(
                liquidation.compensation,
                0,
                string.concat(
                    "borrower forced to variable rate without compensation (venueId ",
                    vm.toString(uint256(liquidation.venueId)),
                    ", fixed-rate life ",
                    vm.toString(liquidation.fixedRateLife),
                    "s)"
                )
            );
        }
    }

    function afterInvariant() public view {
        uint256[2] memory liquidated;
        uint256[2] memory uncompensated;

        for (uint256 i; i < _bondLiquidatedPods.length; ++i) {
            BondLiquidation memory liquidation = _bondLiquidation[_bondLiquidatedPods[i]];
            if (liquidation.fixedRateLife < MIN_FIXED_RATE_LIFE) continue;

            ++liquidated[liquidation.venueId];
            if (liquidation.compensation == 0) ++uncompensated[liquidation.venueId];
        }

        console.log("bond liquidations (Aave / Morpho):", liquidated[0], liquidated[1]);
        console.log("uncompensated     (Aave / Morpho):", uncompensated[0], uncompensated[1]);
    }
}
