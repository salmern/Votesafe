// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockQuadraticVoting {
    struct Proposal {
        string title;
        string description;
        string[] options;
        uint256 endTime;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => uint256) public winningOptions;
    mapping(uint256 => uint256) public voteCounts;
    uint256 public nextId;

    function createProposal(string memory title, string memory description, string[] memory options, uint256 duration)
        external
        returns (uint256)
    {
        uint256 id = ++nextId;
        proposals[id] = Proposal(title, description, options, block.timestamp + duration);
        return id;
    }

    function getProposal(uint256 id)
        external
        view
        returns (
            uint256,
            string memory,
            string memory,
            address,
            uint256,
            uint256,
            uint256,
            uint256,
            string[] memory,
            uint256[] memory,
            bool
        )
    {
        uint256[] memory votes = new uint256[](proposals[id].options.length);
        return (
            id,
            proposals[id].title,
            proposals[id].description,
            address(0),
            block.timestamp,
            proposals[id].endTime,
            0,
            0,
            proposals[id].options,
            votes,
            false
        );
    }

    function getWinningOption(uint256 id) external view returns (uint256, uint256) {
        return (winningOptions[id], voteCounts[id]);
    }

    function mockSetWinningOption(uint256 id, uint256 option, uint256 votes) external {
        winningOptions[id] = option;
        voteCounts[id] = votes;
    }
}
