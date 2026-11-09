// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {SSVClustersHarness} from "../../contracts/test/harness/SSVClustersHarness.sol";
import {ISSVNetworkCore} from "../../contracts/interfaces/ISSVNetworkCore.sol";
import {BPS_DENOMINATOR} from "../../contracts/libraries/SSVCoreTypes.sol";

/// @notice Module-level proof: a reactivation overwrites the operator's stored EB deviation, and the
///         next liquidation of the other cluster then reverts on underflow.
contract LiquidationRevertsAfterOverwriteTest is Test {
    SSVClustersHarness h;
    uint64[] ids;
    uint32 constant N = 4;
    uint64 constant BASELINE = N * BPS_DENOMINATOR; // 40_000 vUnits at 10_000 bps per validator

    address constant OWNER = address(0xA11CE);

    function setUp() public {
        h = new SSVClustersHarness();

        for (uint64 i = 1; i <= N; ++i) {
            h.mockOperator(abi.encodePacked(bytes32(uint256(i))), address(this), 1_000_000_000, false);
            h.mockSetOperatorFee(i, 1_000_000_000);
            ids.push(i);
        }
        h.mockValidatorsPerOperatorLimit(1000);
        h.mockEthNetworkFee(0);
        h.mockMinimumBlocksBeforeLiquidation(1);
        h.mockMinimumLiquidationCollateral(0);
        h.mockSetEBRoot(0, bytes32(0));
        h.mockSetMinBlocksBetweenUpdates(0);
    }

    function _cluster(uint32 vc, bool active) internal pure returns (ISSVNetworkCore.Cluster memory c) {
        c.validatorCount = vc;
        c.active = active;
    }

    /// Cluster X: the one that will be liquidated second, deviation +5_000
    function _clusterX() internal pure returns (ISSVNetworkCore.Cluster memory) {
        return _cluster(N, true);   // live cluster, to be liquidated second
    }

    /// Cluster Y: the one that gets reactivated, deviation +3_000
    function _clusterY() internal pure returns (ISSVNetworkCore.Cluster memory) {
        return _cluster(N, false);  // already liquidated, to be reactivated
    }

    function _hash(address o) internal pure returns (bytes32) {
        uint64[] memory idc = new uint64[](4);
        idc[0] = 1;
        idc[1] = 2;
        idc[2] = 3;
        idc[3] = 4;
        return keccak256(abi.encodePacked(o, idc));
    }

    function test_liquidation_reverts_after_overwrite() public {
        // two distinct clusters on the same four operators
        h.mockSetEthCluster(OWNER, ids, _clusterX());
        h.mockSetEthCluster(address(0xB0B), ids, _clusterY());

        // both clusters carry deviation above baseline
        h.mockSetClusterVUnits(_hash(OWNER), BASELINE + 5_000);
        h.mockSetClusterVUnits(_hash(address(0xB0B)), BASELINE + 3_000);

        // operators currently hold X's deviation only
        for (uint64 i = 1; i <= N; ++i) {
            h.mockSetOperatorEthVUnits(i, 5_000);
        }

        // DAO totals exactly at baseline => hasDeviation == false
        h.mockSetDaoTotalEthVUnits(0); // ethDaoValidatorCount is 0, so 0 == baseline

        // reactivate Y: overwrites the stored 5_000 with 3_000
        vm.deal(address(0xB0B), 10 ether);
        vm.prank(address(0xB0B));
        h.reactivate{value: 1 ether}(ids, _clusterY());
        assertEq(h.getOperatorEthVUnits(1), 3_000, "deviation overwritten by reactivation");

        // now liquidate X, whose deviation (5_000) exceeds what is stored (3_000)
        vm.expectRevert(stdError.arithmeticError); // Panic(0x11): underflow, not a business revert
        h.liquidate(OWNER, ids, _clusterX());
    }
}
