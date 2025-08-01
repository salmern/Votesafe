// SPDX-License-Identifier: LICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "src/core/VoteSafeGovernor.sol";
import "src/core/VoteSafeTimelockController.sol";
import "src/voting/QuadraticVotingHandler.sol";
import "src/voting/QuadraticVoting.sol";
import "src/mocks/MockERC20Votes.sol";
import "src/mocks/MockQuadraticVotingHandler.sol";

contract VoteSafeTest is Test {
    VoteSafeGovernor public governor;
    VoteSafeTimelockController public timelock;
    MockERC20Votes public token;
    MockQuadraticVotingHandler public handler;

    address public admin = address(0xA11CE);
    address public proposer = address(0xB0B);
    address public voter = address(0xCAF3);
    address[] public proposers;
    address[] public executors;

    function setUp() public {
        // Deploy token first
        token = new MockERC20Votes("MockToken", "MTK");

        // Mint tokens to voter
        vm.prank(voter);
        token.mint(voter, 1000 ether);

        // Delegate voting power
        vm.prank(voter);
        token.delegate(voter);

        // Set up proposers and executors
        proposers = new address[](1);
        executors = new address[](1);
        proposers[0] = address(this);
        executors[0] = address(this);

        // Deploy timelock
        timelock = new VoteSafeTimelockController(2 days, proposers, executors, admin);

        // Deploy governor first with placeholder handler
        vm.startPrank(admin);
        governor = new VoteSafeGovernor(
            IVotes(address(token)),
            timelock,
            address(0), // Placeholder, will be updated
            1000,
            500
        );
        vm.stopPrank();

        // Deploy handler with correct governor address
        handler = new MockQuadraticVotingHandler(address(governor));

        // Update governor's handler (you might need to add a setter function)
        // For now, we'll work with the constructor approach

        // Alternative: Redeploy governor with correct handler
        vm.startPrank(admin);
        governor = new VoteSafeGovernor(IVotes(address(token)), timelock, address(handler), 1000, 500);
        vm.stopPrank();

        // Grant roles
        vm.startPrank(admin);
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));

        governor.grantRole(governor.EMERGENCY_ROLE(), admin);
        governor.grantRole(governor.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();

        // Make sure voting power is delegated and move forward a block
        vm.prank(voter);
        token.delegate(voter);
        vm.roll(block.number + 1);
    }

    function testProposeWithQuadraticVoting() public {
        // Move to next block to ensure voting power is available
        vm.roll(block.number + 1);

        vm.startPrank(voter);

        // Prepare proposal parameters
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        // Set up a simple call
        targets[0] = address(token);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature("transfer(address,uint256)", voter, 1);

        string[] memory options = new string[](2);
        options[0] = "Yes";
        options[1] = "No";

        string memory description = "Should we enable feature X?";

        // Check voter has enough voting power
        uint256 voterPower = governor.getVotes(voter, block.number - 1);
        uint256 requiredThreshold = governor.proposalThreshold();

        console.log("Voter power:", voterPower);
        console.log("Required threshold:", requiredThreshold);

        assertTrue(voterPower >= requiredThreshold, "Voter doesn't have enough voting power");

        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            description,
            options,
            true // useQuadraticVoting
        );

        assertTrue(proposalId > 0);

        vm.stopPrank();
    }

    function testProposeWithoutQuadraticVoting() public {
        vm.roll(block.number + 1);

        vm.startPrank(voter);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = address(token);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature("transfer(address,uint256)", voter, 1);

        string[] memory options = new string[](0); // Empty options for non-QV
        string memory description = "Regular proposal without quadratic voting";

        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            description,
            options,
            false // useQuadraticVoting = false
        );

        assertTrue(proposalId > 0);

        vm.stopPrank();
    }

    function testEmergencyPauseAndUnpause() public {
        vm.startPrank(admin);

        governor.emergencyPause();
        assertTrue(governor.paused());

        governor.emergencyUnpause();
        assertFalse(governor.paused());

        vm.stopPrank();
    }

    function testUpdateThresholds() public {
        vm.prank(admin);
        governor.updateProposalThresholds(2000, 1000);

        assertEq(governor.proposalThresholdBPS(), 2000);
        assertEq(governor.emergencyProposalThresholdBPS(), 1000);
    }

    function testInsufficientVotingPower() public {
        // Create a new voter with insufficient tokens
        address poorVoter = address(0xA21CE);

        vm.startPrank(poorVoter);
        token.mint(poorVoter, 1 ether); // Very small amount
        token.delegate(poorVoter);
        vm.stopPrank();

        vm.roll(block.number + 1);

        vm.startPrank(poorVoter);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        string[] memory options = new string[](2);
        options[0] = "Yes";
        options[1] = "No";

        string memory description = "Should fail due to insufficient voting power";

        // This should revert with InsufficientProposalThreshold
        vm.expectRevert(abi.encodeWithSignature("InsufficientProposalThreshold()"));
        governor.propose(targets, values, calldatas, description, options, true);

        vm.stopPrank();
    }
}
