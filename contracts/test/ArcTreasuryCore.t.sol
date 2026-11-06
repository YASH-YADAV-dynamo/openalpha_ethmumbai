// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ArcTreasuryCore} from "../ArcTreasuryCore.sol";
import {MirrorTokenBatch} from "../MirrorTokenBatch.sol";
import {SeedRelay, IArcTreasuryCore} from "../SeedRelay.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

contract ArcTreasuryCoreTest is Test {
    uint256 signerKey = 0xA11CE;
    address signer;
    ArcTreasuryCore core;
    MockERC20 usdc;
    address newOwner = makeAddr("newOwner");

    function setUp() public {
        signer = vm.addr(signerKey);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        core = new ArcTreasuryCore(address(usdc), signer);
    }

    function _batch() internal view returns (address[] memory t, bytes[] memory d) {
        t = new address[](3);
        d = new bytes[](3);
        t[0] = address(core.registry());
        d[0] = abi.encodeWithSignature("setReporter(address,bool)", newOwner, true);
        t[1] = address(core.templates());
        d[1] = abi.encodeWithSignature("setCurator(address,bool)", newOwner, true);
        t[2] = address(core.registry());
        d[2] = abi.encodeWithSignature("transferOwnership(address)", newOwner);
    }

    function _sign(uint256 key, address[] memory t, bytes[] memory d) internal view returns (bytes memory) {
        bytes32 h = MessageHashUtils.toEthSignedMessageHash(core.digest(t, d));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, h);
        return abi.encodePacked(r, s, v);
    }

    function test_ownsRegistriesAfterConstruction() public view {
        assertEq(core.registry().owner(), address(core));
        assertEq(core.templates().owner(), address(core));
        assertEq(core.signer(), signer);
    }

    function test_relayRunsSignedBatchOnceAndClearsSigner() public {
        (address[] memory t, bytes[] memory d) = _batch();
        new SeedRelay(IArcTreasuryCore(address(core)), t, d, _sign(signerKey, t, d));
        assertTrue(core.registry().isReporter(newOwner));
        assertTrue(core.templates().isCurator(newOwner));
        assertEq(core.registry().pendingOwner(), newOwner);
        assertEq(core.signer(), address(0));
    }

    function test_secondExecReverts() public {
        (address[] memory t, bytes[] memory d) = _batch();
        bytes memory sig = _sign(signerKey, t, d);
        core.exec(t, d, sig);
        vm.expectRevert(ArcTreasuryCore.AlreadyExecuted.selector);
        core.exec(t, d, sig);
    }

    function test_wrongSignerReverts() public {
        (address[] memory t, bytes[] memory d) = _batch();
        bytes memory sig = _sign(0xBAD, t, d);
        vm.expectRevert(ArcTreasuryCore.BadSignature.selector);
        core.exec(t, d, sig);
        assertEq(core.signer(), signer); // a failed attempt does not burn the batch
    }

    function test_tamperedBatchReverts() public {
        (address[] memory t, bytes[] memory d) = _batch();
        bytes memory sig = _sign(signerKey, t, d);
        d[2] = abi.encodeWithSignature("transferOwnership(address)", address(this));
        vm.expectRevert(ArcTreasuryCore.BadSignature.selector);
        core.exec(t, d, sig);
    }

    function test_lengthMismatchReverts() public {
        (address[] memory t, bytes[] memory d) = _batch();
        bytes[] memory short = new bytes[](2);
        short[0] = d[0];
        short[1] = d[1];
        vm.expectRevert(ArcTreasuryCore.LengthMismatch.selector);
        core.exec(t, short, "");
    }

    function test_failingCallBubblesAndKeepsSigner() public {
        (address[] memory t, bytes[] memory d) = _batch();
        d[0] = abi.encodeWithSignature("setReporter(address,bool)", address(0), true);
        t[1] = address(usdc); // not a template registry: call to unknown selector reverts
        d[1] = abi.encodeWithSignature("doesNotExist()");
        bytes memory sig = _sign(signerKey, t, d);
        vm.expectRevert();
        core.exec(t, d, sig);
        assertEq(core.signer(), signer);
    }

    function test_tokenBatchBindsAllSixToVenue() public {
        MirrorTokenBatch b = new MirrorTokenBatch(address(core.mirrorVenue()));
        for (uint256 i; i < 6; ++i) {
            assertEq(b.tokens(i).venue(), address(core.mirrorVenue()));
        }
        assertEq(b.tokens(0).decimals(), 8);
        assertEq(b.tokens(1).decimals(), 18);
        assertEq(b.tokens(2).decimals(), 6);
        assertEq(b.tokens(0).symbol(), "cirBTC.m");
    }
}
