// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract VoteSafeTimelockController is TimelockController, ReentrancyGuard {
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    uint256 public constant MIN_DELAY_BOUND = 1 hours;
    uint256 public constant MAX_DELAY_BOUND = 30 days;
    uint256 public constant EMERGENCY_PAUSE_DURATION = 72 hours;
    uint256 public constant MAX_BATCH_SIZE = 100;

    bool public emergencyPaused;
    uint256 public emergencyPauseTimestamp;
    uint256 private _customMinDelay;

    event EmergencyPaused(address indexed admin, uint256 timestamp);
    event EmergencyUnpaused(address indexed admin, uint256 timestamp);
    event DelayUpdated(uint256 oldDelay, uint256 newDelay);
    event BatchOperationScheduled(bytes32 indexed batchId, uint256 operationCount);
    event BatchOperationExecuted(bytes32 indexed batchId, uint256 operationCount);

    error EmergencyPauseActive();
    error NotPaused();
    error InvalidDelay();
    error BatchTooLarge();
    error BatchEmpty();
    error EmergencyPauseNotExpired();
    error ArrayLengthMismatch();

    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {
        if (minDelay < MIN_DELAY_BOUND || minDelay > MAX_DELAY_BOUND) {
            revert InvalidDelay();
        }

        _customMinDelay = minDelay;

        _grantRole(TIMELOCK_ADMIN_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);

        _setRoleAdmin(EMERGENCY_ROLE, TIMELOCK_ADMIN_ROLE);
        _setRoleAdmin(TIMELOCK_ADMIN_ROLE, TIMELOCK_ADMIN_ROLE);
    }

    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        if (emergencyPaused) revert EmergencyPauseActive();
        emergencyPaused = true;
        emergencyPauseTimestamp = block.timestamp;
        emit EmergencyPaused(msg.sender, block.timestamp);
    }

    function emergencyUnpause() external onlyRole(EMERGENCY_ROLE) {
        if (!emergencyPaused) revert NotPaused();
        emergencyPaused = false;
        emergencyPauseTimestamp = 0;
        emit EmergencyUnpaused(msg.sender, block.timestamp);
    }

    function autoUnpause() external {
        if (!emergencyPaused) revert NotPaused();
        if (block.timestamp < emergencyPauseTimestamp + EMERGENCY_PAUSE_DURATION) {
            revert EmergencyPauseNotExpired();
        }
        emergencyPaused = false;
        emergencyPauseTimestamp = 0;
        emit EmergencyUnpaused(msg.sender, block.timestamp);
    }

    function updateDelay(uint256 newDelay)
        external
        override
        onlyRole(TIMELOCK_ADMIN_ROLE)
    {
        if (newDelay < MIN_DELAY_BOUND || newDelay > MAX_DELAY_BOUND) {
            revert InvalidDelay();
        }

        uint256 oldDelay = _customMinDelay;

        bytes memory data = abi.encodeWithSelector(
            this._updateDelayInternal.selector,
            newDelay
        );

        this.schedule(
            address(this),
            0,
            data,
            bytes32(0),
            bytes32(0),
            getMinDelay()
        );

        emit DelayUpdated(oldDelay, newDelay);
    }

    function _updateDelayInternal(uint256 newDelay) external {
        require(msg.sender == address(this), "Only timelock can call");
        if (newDelay < MIN_DELAY_BOUND || newDelay > MAX_DELAY_BOUND) {
            revert InvalidDelay();
        }
        uint256 oldDelay = _customMinDelay;
        _customMinDelay = newDelay;
        emit DelayUpdated(oldDelay, newDelay);
    }

    function _scheduleInternal(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) internal {
        schedule(target, value, data, predecessor, salt, delay);
    }

    function getMinDelay() public view override returns (uint256) {
        return _customMinDelay;
    }

    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        uint256 delay
    ) external onlyRole(PROPOSER_ROLE) returns (bytes32 batchId) {
        uint256 length = targets.length;

        if (length == 0) revert BatchEmpty();
        if (length > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (length != values.length || length != payloads.length) {
            revert ArrayLengthMismatch();
        }

        batchId = keccak256(
            abi.encode(
                targets,
                values,
                payloads,
                predecessor,
                delay,
                block.timestamp
            )
        );

        for (uint256 i = 0; i < length; i++) {
            _scheduleInternal(
                targets[i],
                values[i],
                payloads[i],
                predecessor,
                bytes32(0),
                delay
            );
        }

        emit BatchOperationScheduled(batchId, length);
    }

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor
    ) external payable onlyRole(EXECUTOR_ROLE) nonReentrant {
        uint256 length = targets.length;

        if (emergencyPaused) revert EmergencyPauseActive();
        if (length == 0) revert BatchEmpty();
        if (length > MAX_BATCH_SIZE) revert BatchTooLarge();

        bytes32 batchId = keccak256(
            abi.encode(
                targets,
                values,
                payloads,
                predecessor,
                block.timestamp
            )
        );

        for (uint256 i = 0; i < length; i++) {
            execute(
                targets[i],
                values[i],
                payloads[i],
                predecessor,
                bytes32(0)
            );
        }

        emit BatchOperationExecuted(batchId, length);
    }

    function execute(
        address target,
        uint256 value,
        bytes calldata payload,
        bytes32 predecessor,
        bytes32 salt
    ) public payable override onlyRole(EXECUTOR_ROLE) {
        if (emergencyPaused) revert EmergencyPauseActive();
        super.execute(target, value, payload, predecessor, salt);
    }

    receive() external payable override {}

    function getEmergencyPauseStatus() external view returns (
        bool isPaused,
        uint256 pauseTimestamp,
        uint256 unpauseTime
    ) {
        isPaused = emergencyPaused;
        pauseTimestamp = emergencyPauseTimestamp;
        unpauseTime = emergencyPaused
            ? emergencyPauseTimestamp + EMERGENCY_PAUSE_DURATION
            : 0;
    }

    // function getPendingOperationsCount() external view returns (uint256) {
    //     // Optional: Add real tracking of scheduled operations here
    //     return 0;
    // }
}