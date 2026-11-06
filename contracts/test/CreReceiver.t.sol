// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreReceiver} from "../CreReceiver.sol";

contract MockRegistry {
    bytes public lastMetadata;
    bytes public lastReport;
    address public lastSender;
    uint256 public calls;

    function onReport(bytes calldata metadata, bytes calldata report) external {
        lastMetadata = metadata;
        lastReport = report;
        lastSender = msg.sender;
        ++calls;
    }
}

contract CreReceiverTest is Test {
    event Relayed(uint8 kind, uint256 reportBytes);

    address forwarder = makeAddr("forwarder");
    MockRegistry registry;
    CreReceiver receiver;

    function setUp() public {
        registry = new MockRegistry();
        receiver = new CreReceiver(forwarder, address(registry));
    }

    function test_supportsInterface() public view {
        assertTrue(receiver.supportsInterface(0x805f2132));
        assertTrue(receiver.supportsInterface(0x01ffc9a7));
        assertFalse(receiver.supportsInterface(0xffffffff));
    }

    function test_forwarderRelaysExactBytesAndEmits() public {
        bytes memory metadata = hex"deadbeef";
        bytes memory report = abi.encode(uint8(1), bytes("x"));
        vm.expectEmit(address(receiver));
        emit Relayed(1, report.length);
        vm.prank(forwarder);
        receiver.onReport(metadata, report);
        assertEq(registry.lastMetadata(), metadata);
        assertEq(registry.lastReport(), report);
        assertEq(registry.lastSender(), address(receiver));
        assertEq(registry.calls(), 1);
    }

    function test_kindTwoIsReported() public {
        bytes memory report = abi.encode(uint8(2), bytes("risk"));
        vm.expectEmit(address(receiver));
        emit Relayed(2, report.length);
        vm.prank(forwarder);
        receiver.onReport("", report);
    }

    function test_nonForwarderReverts() public {
        vm.expectRevert(CreReceiver.NotForwarder.selector);
        receiver.onReport("", abi.encode(uint8(1), bytes("x")));
        assertEq(registry.calls(), 0);
    }

    function test_zeroArgsRevert() public {
        vm.expectRevert(CreReceiver.ZeroAddress.selector);
        new CreReceiver(address(0), address(registry));
        vm.expectRevert(CreReceiver.ZeroAddress.selector);
        new CreReceiver(forwarder, address(0));
    }
}
