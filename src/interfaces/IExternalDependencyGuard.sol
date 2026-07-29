// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IExternalDependencyGuard {
    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event ExternalDependencyPauseUpdated(bool paused);

    function pauseGuardian() external view returns (address);
    function externalDependencyPaused() external view returns (bool);
    function setPauseGuardian(address newGuardian) external;
    function pauseExternalDependency() external;
    function unpauseExternalDependency() external;
}
