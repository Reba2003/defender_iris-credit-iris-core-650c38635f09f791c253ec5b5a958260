// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../ForkTest.t.sol";

import {IMorpho} from "@morpho-blue/interfaces/IMorpho.sol";

import {StorageUtils} from "../unit/helpers/StorageUtils.sol";

/// @dev The Iris.sol header says the surplus a solver forfeits on bond liquidation compensates the borrower for
/// being forced to variable rate. Same loan, same 30 days at fixed rate, bond liquidated on each venue: Aave leaves
/// the accrued collateral yield to the borrower, Morpho (collateral index pinned to 1e27) leaves nothing.
contract BondLiquidationCompensationForkTest is ForkTest {
    using MathLib for uint256;
    using SafeTransferLib for address;

    uint256 internal constant DURATION = 60 days;
    uint256 internal constant FIXED_RATE_LIFE = 30 days;
    /// @dev Whole debt-token units, large enough that a non-zero collateral APY yields > 1 wei in 30 days.
    uint256 internal constant MIN_DEBT_UNITS = 10_000;

    function testMorphoBondLiquidationLeavesNoCompensation(uint256 collateral, uint256 debt, uint256 seed) public {
        (uint256 compensation, uint256 forfeitedSurplus) =
            _bondLiquidationCompensation(collateral, debt, seed, uint256(VenueId.MORPHO_BLUE));

        assertEq(forfeitedSurplus, 0, "Morpho surplus never accrues");
        assertEq(compensation, 0, "Morpho borrower is not compensated");
    }

    function testAaveBondLiquidationLeavesCompensation(uint256 collateral, uint256 debt, uint256 seed) public {
        (uint256 compensation, uint256 forfeitedSurplus) =
            _bondLiquidationCompensation(collateral, debt, seed, uint256(VenueId.AAVE_V3));

        assertGt(compensation, 0, "Aave borrower keeps the collateral yield");
        assertApproxEqAbs(compensation, forfeitedSurplus, 2);
    }

    /// @dev Returns the collateral left in the venue above the borrower's tracked collateral after bond liquidation,
    /// and the surplus the solver forfeited.
    function _bondLiquidationCompensation(uint256 collateral, uint256 debt, uint256 seed, uint256 venueId)
        internal
        returns (uint256 compensation, uint256 forfeitedSurplus)
    {
        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        uint256 minDebt = MIN_DEBT_UNITS * 10 ** ERC20(debtToken).decimals();
        uint256 maxBorrow = _maxBorrowable(collateralToken, debtToken, venueId, data);
        vm.assume(maxBorrow >= minDebt);
        debt = bound(debt, minDebt, maxBorrow);

        // 25% headroom so 30 days of venue interest does not make the pod liquidatable on the venue.
        uint256 minCollateral = _minCollateralAmount(debt, collateralToken, debtToken, venueId, data).mulDivUp(5, 4);
        uint256 maxCollateral = _maxSuppliable(collateralToken, venueId, data);
        vm.assume(minCollateral <= maxCollateral);
        collateral = bound(collateral, minCollateral, maxCollateral);

        address pod = _openLoan(_buildQuote(collateralToken, debtToken, collateral, debt, venueId, data));

        _forward(FIXED_RATE_LIFE / BLOCK_TIME);
        if (venueId == uint256(VenueId.MORPHO_BLUE)) {
            IMorpho(morphoBlue).accrueInterest(abi.decode(data, (MarketParams)));
        }

        // Book the fixed-rate period: legs, and on Aave the collateral yield as surplus.
        iris.rebase(pod);

        Position memory pos = iris.getPosition(pod);
        forfeitedSurplus = pos.surplus;

        // Pin tracked collateral to the venue balance (absorbs <=1 wei aToken rounding) so the rebase inside
        // liquidateBond sees no venue liquidation, then push the drawdown past bondLltv. Same block, so no accrual.
        (uint256 venueCollateral,) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        StorageUtils.setPositionCollateral(address(iris), pod, uint128(venueCollateral - pos.surplus));
        StorageUtils.setPositionFloatingLeg(
            address(iris), pod, uint128(uint256(pos.fixedLeg) + uint256(pos.bond).mulDivUp(bondLltv + 0.02e18, WAD))
        );

        iris.liquidateBond(pod, receiver);

        pos = iris.getPosition(pod);
        assertEq(pos.bondRequirement, 0);
        assertEq(pos.surplus, 0);

        (venueCollateral,) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        compensation = venueCollateral.zeroFloorSub(pos.collateral);

        console.log("venueId", venueId);
        console.log("forfeited surplus", forfeitedSurplus);
        console.log("borrower compensation", compensation);
    }

    function _buildQuote(
        address collateralToken,
        address debtToken,
        uint256 collateral,
        uint256 debt,
        uint256 venueId,
        bytes memory data
    ) internal view returns (Quote memory quote) {
        quote.borrower = borrower;
        quote.solver = solver;
        quote.receiver = receiver;
        quote.blm = address(blm);
        quote.collateralToken = collateralToken;
        quote.debtToken = debtToken;
        quote.collateral = collateral;
        quote.debt = debt;
        quote.fixedRate = 0.05e18;
        quote.duration = DURATION;
        quote.overdueRate = 0.1e18;
        quote.overduePeriod = 0;
        quote.bondLltv = bondLltv;
        quote.venueBitmap = 3; // bit0 Aave | bit1 Morpho
        quote.venueId = venueId;
        quote.deadline = block.timestamp;
        quote.nonce = 0;
        quote.data = data;
        quote.bond = blm.bondRequirement(quote);
    }
}
