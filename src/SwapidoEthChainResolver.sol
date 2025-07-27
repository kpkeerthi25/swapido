// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

import {IOrderMixin} from "limit-order-protocol/interfaces/IOrderMixin.sol";
import {TakerTraits} from "limit-order-protocol/libraries/TakerTraitsLib.sol";

import {RevertReasonForwarder} from "solidity-utils/contracts/libraries/RevertReasonForwarder.sol";
import {Address, AddressLib} from "solidity-utils/contracts/libraries/AddressLib.sol";
import {IEscrowFactory} from "cross-chain-swap/interfaces/IEscrowFactory.sol";
import {IBaseEscrow} from "cross-chain-swap/interfaces/IBaseEscrow.sol";
import {TimelocksLib, Timelocks} from "cross-chain-swap/libraries/TimelocksLib.sol";
import {IEscrow} from "cross-chain-swap/interfaces/IEscrow.sol";
import {ImmutablesLib} from "cross-chain-swap/libraries/ImmutablesLib.sol";

/**
 * @title SwapidoEthChainResolver
 * @dev EVM side resolver for cross-chain swaps between EVM and Sui blockchain using 1inch Fusion+ escrow pattern
 * @notice This contract handles the EVM source chain side of atomic cross-chain swaps to Sui
 */
contract SwapidoEthChainResolver is Ownable {
    using ImmutablesLib for IBaseEscrow.Immutables;
    using TimelocksLib for Timelocks;
    using AddressLib for Address;

    error InvalidLength();
    error LengthMismatch();
    error InvalidSuiRecipient();
    error InvalidHashLock();
    error SwapNotFound();

    event SuiSwapInitiated(
        bytes32 indexed swapId,
        address indexed maker,
        address indexed escrowSrc,
        bytes32 hashLock,
        string suiRecipient,
        uint256 deadline
    );

    event SuiSwapCompleted(
        bytes32 indexed swapId,
        address indexed escrowSrc,
        bytes32 secret
    );

    event SuiSwapCancelled(
        bytes32 indexed swapId,
        address indexed escrowSrc
    );

    IEscrowFactory private immutable _FACTORY;
    IOrderMixin private immutable _LOP;

    // Mapping to track Sui-specific swap data
    mapping(bytes32 => SuiSwapData) public suiSwaps;

    struct SuiSwapData {
        address escrowSrc;
        string suiRecipient;
        string suiTokenType;
        uint256 expectedSuiAmount;
        bool completed;
    }

    constructor(
        IEscrowFactory factory, 
        IOrderMixin lop, 
        address initialOwner
    ) Ownable(initialOwner) {
        _FACTORY = factory;
        _LOP = lop;
    }

    receive() external payable {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Deploys source escrow and initiates cross-chain swap to Sui
     */
    function initiateSuiSwap(
        IBaseEscrow.Immutables calldata immutables,
        IOrderMixin.Order calldata order,
        bytes32 r,
        bytes32 vs,
        uint256 amount,
        TakerTraits takerTraits,
        bytes calldata args,
        string calldata suiRecipient,
        string calldata suiTokenType,
        uint256 expectedSuiAmount
    ) external payable onlyOwner {
        
        // Validate Sui-specific parameters
        if (bytes(suiRecipient).length == 0) revert InvalidSuiRecipient();
        if (bytes(suiTokenType).length == 0) revert InvalidSuiRecipient();
        if (immutables.hashlock == bytes32(0)) revert InvalidHashLock();

        // Set deployed timestamp for escrow
        IBaseEscrow.Immutables memory immutablesMem = immutables;
        immutablesMem.timelocks = TimelocksLib.setDeployedAt(immutables.timelocks, block.timestamp);
        
        // Compute escrow address
        address computedEscrow = _FACTORY.addressOfEscrowSrc(immutablesMem);

        // Send safety deposit to escrow
        (bool success,) = address(computedEscrow).call{value: immutablesMem.safetyDeposit}("");
        if (!success) revert IBaseEscrow.NativeTokenSendingFailure();

        // Fill the order on source chain (creates escrow)
        // _ARGS_HAS_TARGET = 1 << 251
        takerTraits = TakerTraits.wrap(TakerTraits.unwrap(takerTraits) | uint256(1 << 251));
        bytes memory argsMem = abi.encodePacked(computedEscrow, args);
        _LOP.fillOrderArgs(order, r, vs, amount, takerTraits, argsMem);

        // Generate swap ID from order hash and Sui recipient
        bytes32 swapId = keccak256(abi.encodePacked(
            order.salt,
            order.maker.get(),
            suiRecipient,
            immutables.hashlock
        ));

        // Store Sui swap data
        suiSwaps[swapId] = SuiSwapData({
            escrowSrc: computedEscrow,
            suiRecipient: suiRecipient,
            suiTokenType: suiTokenType,
            expectedSuiAmount: expectedSuiAmount,
            completed: false
        });

        emit SuiSwapInitiated(
            swapId,
            order.maker.get(),
            computedEscrow,
            immutables.hashlock,
            suiRecipient,
            immutablesMem.timelocks.get(TimelocksLib.Stage.SrcPublicWithdrawal)
        );
    }

    /**
     * @notice Withdraws from source escrow after successful Sui side completion
     */
    function completeSuiSwap(
        bytes32 swapId,
        IEscrow escrow,
        bytes32 secret,
        IBaseEscrow.Immutables calldata immutables
    ) external {
        SuiSwapData storage swapData = suiSwaps[swapId];
        if (swapData.escrowSrc == address(0)) revert SwapNotFound();
        if (swapData.completed) revert SwapNotFound();
        if (address(escrow) != swapData.escrowSrc) revert SwapNotFound();

        // Mark as completed
        swapData.completed = true;

        // Withdraw from source escrow using the secret
        escrow.withdraw(secret, immutables);

        emit SuiSwapCompleted(swapId, address(escrow), secret);
    }

    /**
     * @notice Cancels the swap and refunds the maker
     */
    function cancelSuiSwap(
        bytes32 swapId,
        IEscrow escrow,
        IBaseEscrow.Immutables calldata immutables
    ) external {
        SuiSwapData storage swapData = suiSwaps[swapId];
        if (swapData.escrowSrc == address(0)) revert SwapNotFound();
        if (swapData.completed) revert SwapNotFound();
        if (address(escrow) != swapData.escrowSrc) revert SwapNotFound();

        // Mark as completed (cancelled)
        swapData.completed = true;

        // Cancel the escrow (refunds maker)
        escrow.cancel(immutables);

        emit SuiSwapCancelled(swapId, address(escrow));
    }

    /**
     * @notice Gets Sui swap information
     */
    function getSuiSwap(bytes32 swapId) external view returns (
        address escrowSrc,
        string memory suiRecipient,
        string memory suiTokenType,
        uint256 expectedSuiAmount,
        bool completed
    ) {
        SuiSwapData storage swapData = suiSwaps[swapId];
        return (
            swapData.escrowSrc,
            swapData.suiRecipient,
            swapData.suiTokenType,
            swapData.expectedSuiAmount,
            swapData.completed
        );
    }

    /**
     * @notice Emergency function to make arbitrary calls (owner only)
     */
    function arbitraryCalls(address[] calldata targets, bytes[] calldata arguments) external onlyOwner {
        uint256 length = targets.length;
        if (targets.length != arguments.length) revert LengthMismatch();
        for (uint256 i = 0; i < length; ++i) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success,) = targets[i].call(arguments[i]);
            if (!success) RevertReasonForwarder.reRevert();
        }
    }

    /**
     * @notice Get the escrow factory address
     */
    function escrowFactory() external view returns (address) {
        return address(_FACTORY);
    }

    /**
     * @notice Get the limit order protocol address
     */
    function limitOrderProtocol() external view returns (address) {
        return address(_LOP);
    }
}