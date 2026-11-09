// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {OperatorLib} from "../../contracts/libraries/OperatorLib.sol";
import {SSVStorage, StorageData} from "../../contracts/libraries/storage/SSVStorage.sol";
import {SSVStorageProtocol, StorageProtocol} from "../../contracts/libraries/storage/SSVStorageProtocol.sol";
import {SSVStorageEB, StorageEB} from "../../contracts/libraries/storage/SSVStorageEB.sol";
import {BPS_DENOMINATOR} from "../../contracts/libraries/SSVCoreTypes.sol";
import {PackedETHLib} from "../../contracts/libraries/SSVPackedLib.sol";

/// @notice Does a reactivation overwrite an operator's existing EB deviation when the
///         global DAO flag says there is none?
contract ReactivationOverwriteTest is Test {
    uint64[] ids;

    function _s() internal pure returns (StorageData storage) {
        return SSVStorage.load();
    }

    function _sp() internal pure returns (StorageProtocol storage) {
        return SSVStorageProtocol.load();
    }

    function _seb() internal pure returns (StorageEB storage) {
        return SSVStorageEB.load();
    }

    function setUp() public {
        StorageData storage s = _s();
        StorageProtocol storage sp = _sp();
        StorageEB storage seb = _seb();

        for (uint64 i = 1; i <= 4; ++i) {
            s.operators[i].owner = address(this);
            s.operators[i].ethSnapshot.block = 1;
            s.operators[i].ethFee = PackedETHLib.pack(1_000_000_000);
            ids.push(i);
            // each operator already carries deviation from another cluster
            seb.operatorEthVUnits[i] = 5_000;
        }

        // DAO totals exactly at baseline => hasDeviation == false
        sp.ethDaoValidatorCount = 0;
        sp.daoTotalEthVUnits = 0;
        sp.validatorsPerOperatorLimit = 1000;

        vm.roll(block.number + 10);
    }

    function _reactivate(uint64 clusterDeviation) internal {
        OperatorLib.updateClusterOperatorsOnReactivation(ids, 0, clusterDeviation, _s(), _sp(), _seb());
    }

    /// @notice flag false => the branch assigns, so prior deviation is lost
    function test_reactivation_overwrites_existing_deviation() public {
        assertEq(_seb().operatorEthVUnits[1], 5_000, "precondition: operator already has deviation");

        _reactivate(3_000);

        emit log_named_uint("stored deviation after reactivate", _seb().operatorEthVUnits[1]);
        assertEq(_seb().operatorEthVUnits[1], 3_000, "deviation was overwritten, not accumulated");
    }

    /// @notice control: with the global flag true the branch adds and nothing is lost
    function test_control_flag_true_accumulates() public {
        _sp().ethDaoValidatorCount = 1;
        _sp().daoTotalEthVUnits = BPS_DENOMINATOR + 1; // != baseline => hasDeviation true

        _reactivate(3_000);
        assertEq(_seb().operatorEthVUnits[1], 8_000, "with the flag set the values add");
    }
}
