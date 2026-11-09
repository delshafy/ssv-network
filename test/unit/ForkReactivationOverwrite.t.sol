// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { stdError } from "forge-std/StdError.sol";
import { ISSVNetworkCore } from "../../contracts/interfaces/ISSVNetworkCore.sol";
import { ISSVClusters } from "../../contracts/interfaces/ISSVClusters.sol";
import { PackedSSV, PackedETH } from "../../contracts/libraries/SSVCoreTypes.sol";

/// @notice Reproduces the reactivation-overwrite bug against the DEPLOYED SSVNetwork proxy on a mainnet fork.
/// @dev All calls go through the real proxy and real module bytecode; only state is seeded, with vm.store at slots
///      derived exactly as Solidity derives mapping slots.
contract ForkReactivationOverwrite is Test {
    address constant SSV = 0xDD9BC35aE942eF0cFa76930954a156B3fF30a4E1;

    uint256 constant DATA = uint256(keccak256("ssv.network.storage.main")) - 1;
    uint256 constant PROT = uint256(keccak256("ssv.network.storage.protocol")) - 1;
    uint256 constant EB = uint256(keccak256("ssv.network.storage.eb")) - 1;

    uint256 constant OPERATORS = DATA + 6;
    uint256 constant ETH_CLUSTERS = DATA + 10;
    uint256 constant CLUSTER_EB = EB + 1;
    uint256 constant OP_VUNITS = EB + 2;

    address ownerX = address(0xA11CE);
    address ownerY = address(0xB0B);
    bytes32 hashX;
    bytes32 hashY;
    uint64[] opsX;
    uint64[] opsY;

    ISSVNetworkCore.Cluster clusterX;
    ISSVNetworkCore.Cluster clusterY;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Same operators, two different cluster owners: that is what makes the accumulator shared.
        opsX = new uint64[](4);
        opsY = new uint64[](4);
        for (uint256 i; i < 4; ++i) {
            opsX[i] = uint64(i + 1);
            opsY[i] = opsX[i];
        }
        hashX = keccak256(abi.encodePacked(ownerX, opsX));
        hashY = keccak256(abi.encodePacked(ownerY, opsY));

        // Operators already carry 5000 vUnits of deviation from cluster X.
        for (uint256 i; i < 4; ++i) _seedOperator(opsX[i], 5000);
        assertEq(uint256(vm.load(SSV, _slot(OP_VUNITS, opsX[0]))), 5000, "seed: operator vUnits");

        clusterX = ISSVNetworkCore.Cluster({ validatorCount: 1, networkFeeIndex: 0, index: 0, active: true, balance: 0 });
        clusterY = ISSVNetworkCore.Cluster({ validatorCount: 1, networkFeeIndex: 0, index: 0, active: false, balance: 1 ether });

        vm.store(SSV, _slot(ETH_CLUSTERS, hashX), _hashCluster(clusterX));
        vm.store(SSV, _slot(ETH_CLUSTERS, hashY), _hashCluster(clusterY));
        assertTrue(uint256(vm.load(SSV, _slot(ETH_CLUSTERS, hashX))) != 0, "seed: cluster X");

        _seedClusterEB(hashX, 15000);
        _seedClusterEB(hashY, 13000);
        assertEq(uint256(vm.load(SSV, _slot(CLUSTER_EB, hashY))), 13000, "seed: cluster EB");

        // Level the DAO totals so hasDeviation reads false: daoTotalEthVUnits == ethDaoValidatorCount * BPS.
        // ethDaoValidatorCount is field 14 (slot +2, byte 28); daoTotalEthVUnits is field 22 (slot +4, byte 24).
        uint32 ethDaoCount = uint32(uint256(vm.load(SSV, bytes32(PROT + 2))) >> 224);
        uint256 s4 = uint256(vm.load(SSV, bytes32(PROT + 4)));
        s4 = (s4 & ~(uint256(type(uint64).max) << 192)) | ((uint256(ethDaoCount) * 10_000) << 192);
        // minimumBlocksBeforeLiquidation is field 20: slot +4, byte 8.
        s4 = (s4 & ~(uint256(type(uint64).max) << 64)) | (uint256(1) << 64);
        vm.store(SSV, bytes32(PROT + 4), bytes32(s4));

        assertEq(uint256(vm.load(SSV, bytes32(PROT + 4))) >> 192, uint256(ethDaoCount) * 10_000, "seed: dao level");
        assertEq((uint256(vm.load(SSV, bytes32(PROT + 4))) >> 64) & type(uint64).max, 1, "seed: min blocks");
    }

    function test_fork_reactivation_overwrites_then_liquidation_reverts() public {
        vm.deal(ownerY, 2 ether);
        vm.prank(ownerY);
        ISSVClusters(SSV).reactivate{ value: 1 ether }(opsY, clusterY);

        uint64 storedAfter = uint64(uint256(vm.load(SSV, _slot(OP_VUNITS, opsY[0]))));
        emit log_named_uint("operator vUnits after reactivate", storedAfter);
        assertEq(storedAfter, 3000, "stored deviation was overwritten instead of accumulated");

        vm.expectRevert(stdError.arithmeticError);
        ISSVClusters(SSV).liquidate(ownerX, opsX, clusterX);
    }

    function test_debug_protocol_slots() public {
        for (uint256 i; i < 7; ++i) {
            emit log_named_uint(string(abi.encodePacked("PROT+", vm.toString(i))), uint256(vm.load(SSV, bytes32(PROT + i))));
        }
    }

    function _slot(uint256 mapSlot, bytes32 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, mapSlot));
    }

    function _slot(uint256 mapSlot, uint64 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, mapSlot));
    }

    function _hashCluster(ISSVNetworkCore.Cluster memory c) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(c.validatorCount, c.networkFeeIndex, c.index, c.balance, c.active));
    }

    function _seedClusterEB(bytes32 hash, uint64 vUnits) internal {
        vm.store(SSV, _slot(CLUSTER_EB, hash), bytes32(uint256(vUnits)));
    }

    function _seedOperator(uint64 id, uint64 vUnits) internal {
        uint256 s0 = uint256(1) | (uint256(uint160(ownerX)) << 96);
        bytes32 base = _slot(OPERATORS, id);
        vm.store(SSV, base, bytes32(s0));
        vm.store(SSV, bytes32(uint256(base) + 1), bytes32(uint256(1) << 32));
        vm.store(SSV, bytes32(uint256(base) + 2), bytes32(uint256(1) | (uint256(1) << 32) | (uint256(1) << 96)) );
        vm.store(SSV, _slot(OP_VUNITS, id), bytes32(uint256(vUnits)));
    }
}
