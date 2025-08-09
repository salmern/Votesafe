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
    address public voter = address(0xCAF3);

    function setUp() public {
        // 1. Deploy and setup token
        token = new MockERC20Votes("MockToken", "MTK");

        // Mint tokens to voter
        token.mint(voter, 1000 ether);
        assertEq(token.balanceOf(voter), 1000 ether, "Mint failed");

        // Delegate votes
        vm.prank(voter);
        token.delegate(voter);

        // Advance blocks to activate voting power
        vm.roll(block.number + 2);
        assertGt(token.getVotes(voter), 0, "Voting power not activated");

        // Deploy governance contracts
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(this);
        executors[0] = address(this);
        // Redeploy handler with correct governor address
        handler = new MockQuadraticVotingHandler(address(0));

        timelock = new VoteSafeTimelockController(2 days, proposers, executors, admin);

        // Deploy handler with temporary address
        // handler = new MockQuadraticVotingHandler(address(this));

        // Deploy governor
        vm.startPrank(admin);
        governor = new VoteSafeGovernor(
            IVotes(address(token)),
            timelock,
            address(handler),
            1000, // 10% threshold
            500 // 5% emergency threshold
        );
        // Re-assign handler to know about the new governor
        // handler = new MockQuadraticVotingHandler(address(governor));

        vm.stopPrank();

        // Setup roles
        vm.startPrank(admin);
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 adminRole = governor.DEFAULT_ADMIN_ROLE();
        bytes32 emergencyRole = governor.EMERGENCY_ROLE();

        timelock.grantRole(executorRole, address(governor));
        timelock.grantRole(proposerRole, address(governor));
        governor.grantRole(adminRole, admin);
        governor.grantRole(emergencyRole, admin);
        vm.stopPrank();

        // Final verification
        assertTrue(governor.hasRole(adminRole, admin), "Admin role not set");
        assertEq(address(governor.qvHandler()), address(handler), "Handler not set correctly");
    }

    function testProposeWithQuadraticVoting() public {
        // Verify voting power
        uint256 snapshotBlock = block.number - 1;
        uint256 votes = token.getPastVotes(voter, snapshotBlock);
        uint256 threshold = governor.proposalThreshold();

        console.log("Voter power:", votes);
        console.log("Required threshold:", threshold);
        assertGe(votes, threshold, "Insufficient voting power");

        // Create proposal
        vm.startPrank(voter);
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(token);
        calldatas[0] = abi.encodeWithSignature("transfer(address,uint256)", voter, 1);

        string[] memory options = new string[](2);
        options[0] = "Yes";
        options[1] = "No";

        uint256 proposalId = governor.propose(targets, values, calldatas, "QV Proposal", options, true);

        assertGt(proposalId, 0, "Proposal creation failed");
        vm.stopPrank();
    }

    function debugVotingPower() public view {
        console.log("Current block:", block.number);
        console.log("Token balance:", token.balanceOf(voter));
        console.log("Current votes:", token.getVotes(voter));
        console.log("Past votes (prev block):", token.getPastVotes(voter, block.number - 1));
        console.log("Proposal threshold:", governor.proposalThreshold());
        console.log("Handler address:", address(governor.qvHandler()));
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
