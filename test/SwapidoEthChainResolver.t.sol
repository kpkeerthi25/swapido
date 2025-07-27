// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {SwapidoEthChainResolver} from "../src/SwapidoEthChainResolver.sol";

import {IOrderMixin} from "limit-order-protocol/interfaces/IOrderMixin.sol";
import {TakerTraits} from "limit-order-protocol/libraries/TakerTraitsLib.sol";
import {MakerTraits} from "limit-order-protocol/libraries/MakerTraitsLib.sol";
import {IEscrowFactory} from "cross-chain-swap/interfaces/IEscrowFactory.sol";
import {IBaseEscrow} from "cross-chain-swap/interfaces/IBaseEscrow.sol";
import {IEscrow} from "cross-chain-swap/interfaces/IEscrow.sol";
import {TimelocksLib, Timelocks} from "cross-chain-swap/libraries/TimelocksLib.sol";
import {Address, AddressLib} from "solidity-utils/contracts/libraries/AddressLib.sol";

contract SwapidoEthChainResolverTest is Test {
    using AddressLib for Address;
    using TimelocksLib for Timelocks;

    SwapidoEthChainResolver public resolver;
    
    // Mock contracts
    address public mockFactory = makeAddr("mockFactory");
    address public mockLOP = makeAddr("mockLOP");
    address public owner = makeAddr("owner");
    address public user = makeAddr("user");

    // Test constants
    bytes32 constant TEST_HASHLOCK = keccak256("test_secret");
    string constant TEST_SUI_RECIPIENT = "0x123456789abcdef";
    string constant TEST_SUI_TOKEN_TYPE = "0x2::sui::SUI";
    uint256 constant TEST_EXPECTED_AMOUNT = 1000e9; // 1000 SUI

    function setUp() public {
        vm.prank(owner);
        resolver = new SwapidoEthChainResolver(
            IEscrowFactory(mockFactory),
            IOrderMixin(mockLOP),
            owner
        );
    }

    function test_Constructor() public {
        assertEq(resolver.owner(), owner);
        assertEq(resolver.escrowFactory(), mockFactory);
        assertEq(resolver.limitOrderProtocol(), mockLOP);
    }

    function test_InitiateSuiSwap_RevertsWithInvalidSuiRecipient() public {
        IBaseEscrow.Immutables memory immutables = _createTestImmutables();
        IOrderMixin.Order memory order = _createTestOrder();
        
        vm.prank(owner);
        vm.expectRevert(SwapidoEthChainResolver.InvalidSuiRecipient.selector);
        resolver.initiateSuiSwap(
            immutables,
            order,
            bytes32(0),
            bytes32(0),
            100,
            TakerTraits.wrap(0),
            "",
            "", // Empty recipient
            TEST_SUI_TOKEN_TYPE,
            TEST_EXPECTED_AMOUNT
        );
    }

    function test_InitiateSuiSwap_RevertsWithInvalidHashLock() public {
        IBaseEscrow.Immutables memory immutables = _createTestImmutables();
        immutables.hashlock = bytes32(0); // Invalid hashlock
        IOrderMixin.Order memory order = _createTestOrder();
        
        vm.prank(owner);
        vm.expectRevert(SwapidoEthChainResolver.InvalidHashLock.selector);
        resolver.initiateSuiSwap(
            immutables,
            order,
            bytes32(0),
            bytes32(0),
            100,
            TakerTraits.wrap(0),
            "",
            TEST_SUI_RECIPIENT,
            TEST_SUI_TOKEN_TYPE,
            TEST_EXPECTED_AMOUNT
        );
    }

    function test_InitiateSuiSwap_RevertsWithNonOwner() public {
        IBaseEscrow.Immutables memory immutables = _createTestImmutables();
        IOrderMixin.Order memory order = _createTestOrder();
        
        vm.prank(user);
        vm.expectRevert();
        resolver.initiateSuiSwap(
            immutables,
            order,
            bytes32(0),
            bytes32(0),
            100,
            TakerTraits.wrap(0),
            "",
            TEST_SUI_RECIPIENT,
            TEST_SUI_TOKEN_TYPE,
            TEST_EXPECTED_AMOUNT
        );
    }

    function test_GetSuiSwap_EmptyForNonExistentSwap() public {
        bytes32 nonExistentSwapId = keccak256("non_existent");
        
        (
            address escrowSrc,
            string memory suiRecipient,
            string memory suiTokenType,
            uint256 expectedSuiAmount,
            bool completed
        ) = resolver.getSuiSwap(nonExistentSwapId);
        
        assertEq(escrowSrc, address(0));
        assertEq(bytes(suiRecipient).length, 0);
        assertEq(bytes(suiTokenType).length, 0);
        assertEq(expectedSuiAmount, 0);
        assertFalse(completed);
    }

    function test_CompleteSuiSwap_RevertsWithSwapNotFound() public {
        bytes32 nonExistentSwapId = keccak256("non_existent");
        IEscrow mockEscrow = IEscrow(makeAddr("mockEscrow"));
        IBaseEscrow.Immutables memory immutables = _createTestImmutables();
        
        vm.expectRevert(SwapidoEthChainResolver.SwapNotFound.selector);
        resolver.completeSuiSwap(
            nonExistentSwapId,
            mockEscrow,
            keccak256("secret"),
            immutables
        );
    }

    function test_CancelSuiSwap_RevertsWithSwapNotFound() public {
        bytes32 nonExistentSwapId = keccak256("non_existent");
        IEscrow mockEscrow = IEscrow(makeAddr("mockEscrow"));
        IBaseEscrow.Immutables memory immutables = _createTestImmutables();
        
        vm.expectRevert(SwapidoEthChainResolver.SwapNotFound.selector);
        resolver.cancelSuiSwap(
            nonExistentSwapId,
            mockEscrow,
            immutables
        );
    }

    function test_ArbitraryCalls_RevertsWithLengthMismatch() public {
        address[] memory targets = new address[](2);
        bytes[] memory arguments = new bytes[](1);
        
        targets[0] = makeAddr("target1");
        targets[1] = makeAddr("target2");
        arguments[0] = "";
        
        vm.prank(owner);
        vm.expectRevert(SwapidoEthChainResolver.LengthMismatch.selector);
        resolver.arbitraryCalls(targets, arguments);
    }

    function test_ArbitraryCalls_RevertsWithNonOwner() public {
        address[] memory targets = new address[](1);
        bytes[] memory arguments = new bytes[](1);
        
        targets[0] = makeAddr("target");
        arguments[0] = "";
        
        vm.prank(user);
        vm.expectRevert();
        resolver.arbitraryCalls(targets, arguments);
    }

    function test_ReceiveEther() public {
        uint256 amount = 1 ether;
        vm.deal(user, amount);
        
        vm.prank(user);
        (bool success,) = address(resolver).call{value: amount}("");
        
        assertTrue(success);
        assertEq(address(resolver).balance, amount);
    }

    // Helper functions
    function _createTestImmutables() internal returns (IBaseEscrow.Immutables memory) {
        return IBaseEscrow.Immutables({
            orderHash: keccak256("test_order"),
            hashlock: TEST_HASHLOCK,
            maker: Address.wrap(uint160(makeAddr("maker"))),
            taker: Address.wrap(uint160(makeAddr("taker"))),
            token: Address.wrap(uint160(makeAddr("token"))),
            amount: 1000,
            safetyDeposit: 0.01 ether,
            timelocks: Timelocks.wrap(0)
        });
    }

    function _createTestOrder() internal returns (IOrderMixin.Order memory) {
        return IOrderMixin.Order({
            salt: 12345,
            maker: Address.wrap(uint160(makeAddr("maker"))),
            receiver: Address.wrap(uint160(address(0))),
            makerAsset: Address.wrap(uint160(makeAddr("makerAsset"))),
            takerAsset: Address.wrap(uint160(makeAddr("takerAsset"))),
            makingAmount: 1000,
            takingAmount: 1000,
            makerTraits: MakerTraits.wrap(0)
        });
    }
}