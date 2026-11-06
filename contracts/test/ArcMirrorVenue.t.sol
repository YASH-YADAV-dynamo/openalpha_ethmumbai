// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAssetRegistry, IVenue} from "../IArcTreasury.sol";
import {MirrorVenue} from "../MirrorVenue.sol";
import {MirrorToken} from "../MirrorToken.sol";
import {ArcBase} from "./helpers/ArcBase.sol";

contract ArcMirrorVenueTest is ArcBase {
    event Swapped(address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    function setUp() public override {
        super.setUp();
        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(mvenue), type(uint256).max);
    }

    // independent re-implementation of the spec formulas
    function _buyOut(uint256 usdcIn, uint256 price, uint256 dec) internal pure returns (uint256) {
        return usdcIn * 1e8 * (10 ** dec) / (price * 1e6) * 9970 / 10000;
    }

    function _sellOut(uint256 amt, uint256 price, uint256 dec) internal pure returns (uint256) {
        return amt * price * 1e6 / (1e8 * (10 ** dec)) * 9970 / 10000;
    }

    function _buy(MirrorToken t, uint256 amt) internal returns (uint256) {
        vm.prank(alice);
        return mvenue.swap(address(usdc), address(t), amt, 0, alice);
    }

    function _sell(MirrorToken t, uint256 amt) internal returns (uint256) {
        vm.startPrank(alice);
        t.approve(address(mvenue), amt);
        uint256 out = mvenue.swap(address(t), address(usdc), amt, 0, alice);
        vm.stopPrank();
        return out;
    }

    // ---------- metadata ----------
    function test_Metadata() public view {
        assertEq(mvenue.name(), "Mirror (testnet)");
        assertEq(mvenue.spreadBps(), 30);
        assertEq(mvenue.maxTradeUsdc(), 5_000e6);
        assertEq(mvenue.usdc(), USDC_ADDR);
        assertEq(address(mvenue.registry()), address(registry));
        assertEq(mBTC.decimals(), 8);
        assertEq(mETH.decimals(), 18);
        assertEq(mXAU.decimals(), 6);
        assertEq(mBTC.venue(), address(mvenue));
        assertEq(mBTC.symbol(), "cirBTC.m");
    }

    function test_Constructor_ZeroAddressesRevert() public {
        vm.expectRevert(MirrorVenue.InvalidAddress.selector);
        new MirrorVenue(IAssetRegistry(address(0)), USDC_ADDR);
        vm.expectRevert(MirrorVenue.InvalidAddress.selector);
        new MirrorVenue(IAssetRegistry(address(registry)), address(0));
        vm.expectRevert(MirrorToken.InvalidVenue.selector);
        new MirrorToken("a", "b", 6, address(0));
    }

    // ---------- buy math ----------
    function test_Buy_ExactMath_AllDecimals() public {
        uint256 amt = 1_000e6;
        uint256 expBtc = _buyOut(amt, pBTC, 8);
        uint256 expEth = _buyOut(amt, pETH, 18);
        uint256 expXau = _buyOut(amt, pXAU, 6);
        assertEq(_buy(mBTC, amt), expBtc);
        assertEq(_buy(mETH, amt), expEth);
        assertEq(_buy(mXAU, amt), expXau);
        assertEq(mBTC.balanceOf(alice), expBtc);
        assertEq(mETH.balanceOf(alice), expEth);
        assertEq(mXAU.balanceOf(alice), expXau);
        assertEq(expXau, 498_500); // 1000/2000 = 0.5 XAU less 0.30%
        assertEq(expBtc, 1_661_666); // 1_666_666 sat less 0.30%
        assertEq(expEth, uint256(333_333_333_333_333_333) * 9970 / 10000);
    }

    function test_Buy_EmitsAndMovesFunds() public {
        uint256 resBefore = usdc.balanceOf(address(mvenue));
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 exp = _buyOut(1_000e6, pXAU, 6);
        vm.expectEmit(true, true, true, true, address(mvenue));
        emit Swapped(alice, USDC_ADDR, address(mXAU), 1_000e6, exp);
        _buy(mXAU, 1_000e6);
        assertEq(usdc.balanceOf(address(mvenue)), resBefore + 1_000e6);
        assertEq(usdc.balanceOf(alice), aliceBefore - 1_000e6);
        assertEq(mXAU.totalSupply(), exp);
    }

    function test_Buy_ToDifferentRecipient() public {
        vm.prank(alice);
        uint256 out = mvenue.swap(address(usdc), address(mXAU), 100e6, 0, bob);
        assertEq(mXAU.balanceOf(bob), out);
        assertEq(mXAU.balanceOf(alice), 0);
    }

    function test_Quote_MatchesSwap() public {
        uint256 q = mvenue.quote(address(usdc), address(mETH), 777e6);
        assertEq(q, _buyOut(777e6, pETH, 18));
        assertEq(_buy(mETH, 777e6), q);
        uint256 qs = mvenue.quote(address(mETH), address(usdc), q / 2);
        assertEq(qs, _sellOut(q / 2, pETH, 18));
    }

    // ---------- sell math ----------
    function test_Sell_ExactMath_AllDecimals() public {
        _buy(mBTC, 1_000e6);
        _buy(mETH, 1_000e6);
        _buy(mXAU, 1_000e6);
        uint256[3] memory bals = [mBTC.balanceOf(alice), mETH.balanceOf(alice), mXAU.balanceOf(alice)];
        uint256 before = usdc.balanceOf(alice);
        uint256 sBtc = _sell(mBTC, bals[0]);
        uint256 sEth = _sell(mETH, bals[1]);
        uint256 sXau = _sell(mXAU, bals[2]);
        assertEq(sBtc, _sellOut(bals[0], pBTC, 8));
        assertEq(sEth, _sellOut(bals[1], pETH, 18));
        assertEq(sXau, _sellOut(bals[2], pXAU, 6));
        assertEq(sXau, 994_009_000); // 498_500 XAU * 2000 = 997 USDC, less 0.30%
        assertEq(usdc.balanceOf(alice), before + sBtc + sEth + sXau);
        assertEq(mBTC.totalSupply(), 0); // sold tokens are burned
        assertEq(mETH.totalSupply(), 0);
        assertEq(mXAU.totalSupply(), 0);
        assertEq(mXAU.balanceOf(address(mvenue)), 0);
    }

    function test_Sell_Emits() public {
        _buy(mXAU, 1_000e6);
        uint256 amt = mXAU.balanceOf(alice);
        uint256 exp = _sellOut(amt, pXAU, 6);
        vm.startPrank(alice);
        mXAU.approve(address(mvenue), amt);
        vm.expectEmit(true, true, true, true, address(mvenue));
        emit Swapped(alice, address(mXAU), USDC_ADDR, amt, exp);
        mvenue.swap(address(mXAU), USDC_ADDR, amt, exp, alice);
        vm.stopPrank();
    }

    function test_RoundTrip_LosesRoughlyTwiceSpread() public {
        MirrorToken[3] memory ts = [mBTC, mETH, mXAU];
        for (uint256 i; i < 3; ++i) {
            uint256 start = usdc.balanceOf(alice);
            uint256 bought = _buy(ts[i], 2_000e6);
            _sell(ts[i], bought);
            uint256 lost = start - usdc.balanceOf(alice);
            // 1 - 0.997^2 = 0.599% of 2000 = 11.98 USDC; allow rounding slack
            assertApproxEqAbs(lost, 11_982_000, 20_000);
            assertGt(lost, 0);
        }
    }

    function testFuzz_RoundTripNeverProfitable(uint256 amt, uint8 which) public {
        amt = bound(amt, 100e6, 5_000e6);
        MirrorToken t = which % 3 == 0 ? mBTC : (which % 3 == 1 ? mETH : mXAU);
        uint256 start = usdc.balanceOf(alice);
        uint256 reserve = usdc.balanceOf(address(mvenue));
        uint256 got = _buy(t, amt);
        uint256 back = _sell(t, got);
        assertLe(back, amt * 9970 / 10000 * 9970 / 10000 + 1);
        assertGe(back, amt * 993 / 1000); // 0.6% spread + rounding tolerance
        assertEq(usdc.balanceOf(alice), start - amt + back);
        assertEq(usdc.balanceOf(address(mvenue)), reserve + amt - back); // venue keeps the spread
    }

    // ---------- reverts ----------
    function test_Sell_InsufficientReserve() public {
        _buy(mXAU, 1_000e6);
        uint256 amt = mXAU.balanceOf(alice);
        uint256 need = _sellOut(amt, pXAU, 6);
        deal(address(usdc), address(mvenue), 10e6);
        vm.startPrank(alice);
        mXAU.approve(address(mvenue), amt);
        vm.expectRevert(abi.encodeWithSelector(MirrorVenue.InsufficientReserve.selector, 10e6, need));
        mvenue.swap(address(mXAU), USDC_ADDR, amt, 0, alice);
        vm.stopPrank();
    }

    function test_RiskBlocksBuysButNotSells() public {
        _buy(mXAU, 1_000e6);
        uint256 amt = mXAU.balanceOf(alice) / 2;
        _setRisk(address(mXAU), 1); // watch: still tradable
        _buy(mXAU, 10e6);
        for (uint8 lvl = 2; lvl <= 3; ++lvl) {
            _setRisk(address(mXAU), lvl);
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(MirrorVenue.RiskBlocked.selector, address(mXAU), lvl));
            mvenue.swap(address(usdc), address(mXAU), 10e6, 0, alice);
            vm.expectRevert(abi.encodeWithSelector(MirrorVenue.RiskBlocked.selector, address(mXAU), lvl));
            mvenue.quote(address(usdc), address(mXAU), 10e6);
            uint256 before = usdc.balanceOf(alice);
            uint256 out = _sell(mXAU, amt / 2);
            assertEq(usdc.balanceOf(alice), before + out);
            assertGt(out, 0);
        }
    }

    function test_StalePrice_RevertsAll() public {
        _buy(mXAU, 100e6);
        vm.warp(block.timestamp + 3601);
        bytes memory stale = abi.encodeWithSelector(IAssetRegistry.StalePrice.selector, address(mXAU));
        vm.prank(alice);
        vm.expectRevert(stale);
        mvenue.swap(address(usdc), address(mXAU), 10e6, 0, alice);
        vm.startPrank(alice);
        mXAU.approve(address(mvenue), 1000);
        vm.expectRevert(stale);
        mvenue.swap(address(mXAU), USDC_ADDR, 1000, 0, alice);
        vm.stopPrank();
        vm.expectRevert(stale);
        mvenue.quote(address(usdc), address(mXAU), 1e6);
        _feedAll(); // refresh and trade works again
        _buy(mXAU, 10e6);
    }

    function test_TradeTooLarge_Buy() public {
        _buy(mBTC, 5_000e6); // exactly at the cap is fine
        uint256 over = 5_000e6 + 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MirrorVenue.TradeTooLarge.selector, over, 5_000e6));
        mvenue.swap(address(usdc), address(mBTC), over, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(MirrorVenue.TradeTooLarge.selector, over, 5_000e6));
        mvenue.quote(address(usdc), address(mBTC), over);
    }

    function test_TradeTooLarge_Sell() public {
        _buy(mXAU, 5_000e6);
        _buy(mXAU, 5_000e6);
        uint256 okAmt = 2_507_000; // out = 4998.958 USDC
        uint256 badAmt = 2_508_000; // out = 5000.952 USDC > cap
        uint256 badOut = _sellOut(badAmt, pXAU, 6);
        assertGt(badOut, 5_000e6);
        vm.startPrank(alice);
        mXAU.approve(address(mvenue), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(MirrorVenue.TradeTooLarge.selector, badOut, 5_000e6));
        mvenue.swap(address(mXAU), USDC_ADDR, badAmt, 0, alice);
        uint256 out = mvenue.swap(address(mXAU), USDC_ADDR, okAmt, 0, alice);
        vm.stopPrank();
        assertEq(out, _sellOut(okAmt, pXAU, 6));
    }

    function test_MinOut_BuyAndSell() public {
        uint256 exp = _buyOut(100e6, pBTC, 8);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVenue.MinOut.selector, exp, exp + 1));
        mvenue.swap(address(usdc), address(mBTC), 100e6, exp + 1, alice);
        uint256 out = mvenue.swap(address(usdc), address(mBTC), 100e6, exp, alice);
        assertEq(out, exp);
        uint256 sExp = _sellOut(out, pBTC, 8);
        mBTC.approve(address(mvenue), out);
        vm.expectRevert(abi.encodeWithSelector(IVenue.MinOut.selector, sExp, sExp + 1));
        mvenue.swap(address(mBTC), USDC_ADDR, out, sExp + 1, alice);
        assertEq(mvenue.swap(address(mBTC), USDC_ADDR, out, sExp, alice), sExp);
        vm.stopPrank();
    }

    function test_Unsupported_Pairs() public {
        bytes memory e;
        vm.startPrank(alice);
        e = abi.encodeWithSelector(IVenue.Unsupported.selector, USDC_ADDR, USDC_ADDR);
        vm.expectRevert(e);
        mvenue.swap(USDC_ADDR, USDC_ADDR, 1e6, 0, alice);
        e = abi.encodeWithSelector(IVenue.Unsupported.selector, address(mBTC), address(mETH));
        vm.expectRevert(e);
        mvenue.swap(address(mBTC), address(mETH), 1, 0, alice);
        // EURC is listed but belongs to the Uniswap venue, not this one
        e = abi.encodeWithSelector(IVenue.Unsupported.selector, USDC_ADDR, address(eurc));
        vm.expectRevert(e);
        mvenue.swap(USDC_ADDR, address(eurc), 1e6, 0, alice);
        e = abi.encodeWithSelector(IVenue.Unsupported.selector, address(eurc), USDC_ADDR);
        vm.expectRevert(e);
        mvenue.quote(address(eurc), USDC_ADDR, 1e6);
        // unlisted token bubbles UnknownAsset
        address x = makeAddr("x");
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.UnknownAsset.selector, x));
        mvenue.swap(USDC_ADDR, x, 1e6, 0, alice);
        vm.stopPrank();
    }

    function test_Swap_ZeroRecipientReverts() public {
        vm.prank(alice);
        vm.expectRevert(MirrorVenue.InvalidAddress.selector);
        mvenue.swap(USDC_ADDR, address(mXAU), 1e6, 0, address(0));
    }

    function test_Sell_WithoutAllowanceReverts() public {
        _buy(mXAU, 100e6);
        vm.prank(alice);
        vm.expectRevert();
        mvenue.swap(address(mXAU), USDC_ADDR, 1000, 0, alice);
    }

    function test_Buy_WithoutAllowanceReverts() public {
        vm.prank(bob);
        vm.expectRevert();
        mvenue.swap(USDC_ADDR, address(mXAU), 1e6, 0, bob);
    }

    // ---------- MirrorToken access ----------
    function test_OnlyVenueCanMintAndBurn() public {
        vm.startPrank(alice);
        vm.expectRevert(MirrorToken.NotVenue.selector);
        mBTC.mint(alice, 1);
        vm.expectRevert(MirrorToken.NotVenue.selector);
        mBTC.burn(alice, 1);
        vm.stopPrank();
        vm.prank(owner);
        vm.expectRevert(MirrorToken.NotVenue.selector);
        mBTC.mint(owner, 1);
        vm.prank(address(mvenue));
        mBTC.mint(alice, 5);
        assertEq(mBTC.balanceOf(alice), 5);
        vm.prank(address(mvenue));
        mBTC.burn(alice, 2);
        assertEq(mBTC.balanceOf(alice), 3);
    }
}
