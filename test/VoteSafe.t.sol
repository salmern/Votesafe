// SPDX-License-Identifier: LICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/VoteSafeGovernor.sol";
import "../src/VoteSafeTimelockController.sol";
import "../src/MockERC20Votes.sol";
import "../src/MockQuadraticVoting.sol";

contract VoteSafeTest is Test {
    VoteSafeGovernor public governor;
    VoteSafeTimelockController public timelock;
    MockERC20Votes public token;
    MockQuadraticVoting public quadraticVoting;

    address public admin = address(0xA11CE);
    address public proposer = address(0xB0B);
    address public voter = address(0xCAF3);
    address[] public proposers;
    address[] public executors;

    function setUp() public {
        token = new MockERC20Votes("MockToken", "MTK");
        token.mint(voter, 1000 ether);

        proposers = new address[](1);
        executors = new address[](1);
        proposers[0] = address(this);
        executors[0] = address(this);

        timelock = new VoteSafeTimelockController(2 days, proposers, executors, admin);
        quadraticVoting = new MockQuadraticVoting();

        governor = new VoteSafeGovernor(
            IVotes(address(token)),
            timelock,
            IQuadraticVoting(address(quadraticVoting)),
            1000, // 10%
            500 // 5%
        );

        vm.startPrank(admin);
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        vm.stopPrank();

        token.delegate(voter);
    }

    function testProposeWithQuadraticVoting() public {
        vm.prank(voter);
        address[] memory targets = new address[](1);
        targets[0] = address(0);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        string[] memory options = new string[](2);
        options[0] = "Yes";
        options[1] = "No";

        string memory description = "Should we enable feature X?";

        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            description,
            options,
            true // useQuadraticVoting
        );

        assertTrue(proposalId > 0);
        assertEq(governor.getProposalOptions(proposalId).length, 2);
    }

    function testEmergencyPauseAndUnpause() public {
        vm.startPrank(admin);

        // Pause
        timelock.emergencyPause();
        (bool paused,,) = timelock.getEmergencyPauseStatus();
        assertTrue(paused);

        // Unpause
        timelock.emergencyUnpause();
        (paused,,) = timelock.getEmergencyPauseStatus();
        assertFalse(paused);

        vm.stopPrank();
    }

    function testProcessQuadraticResult() public {
        vm.prank(voter);
        address[] memory targets = new address[](1);
        targets[0] = address(0);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        string[] memory options = new string[](2);
        options[0] = "Option A";
        options[1] = "Option B";

        string memory description = "Vote for the better option";

        uint256 proposalId = governor.propose(targets, values, calldatas, description, options, true);
        uint256 quadraticId = governor.proposalToQuadraticId(proposalId);
        quadraticVoting.mockSetWinningOption(quadraticId, 1, 90);

        // Fast forward past endTime
        vm.warp(block.timestamp + 8 days);

        governor.processQuadraticResults(proposalId);
        VoteSafeGovernor.QuadraticResult memory result = governor.getQuadraticResult(proposalId);

        assertEq(result.processed, true);
        assertEq(result.winningOption, 1);
        assertEq(result.totalVotes, 90);
    }
}
