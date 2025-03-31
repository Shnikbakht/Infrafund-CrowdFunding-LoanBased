// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title MockChainlinkOracle
 * @dev A mock implementation of Chainlink's AggregatorV3Interface for testing purposes
 * This allows setting and updating price feeds in a test environment
 */
contract MockChainlinkOracle is AggregatorV3Interface {
    // Storage variables
    string private _description;
    uint8 private _decimals;
    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;
    
    // Events
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    
    /**
     * @dev Constructor sets initial values
     * @param initialAnswer The initial price value (with 8 decimals)
     */
    constructor(int256 initialAnswer) {
        _description = "Mock Chainlink Oracle";
        _decimals = 8; // Standard for Chainlink price feeds
        _roundId = 1;
        _answer = initialAnswer;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = 1;
    }
    
    /**
     * @dev Update the price answer
     * @param newAnswer The new price value
     */
    function updateAnswer(int256 newAnswer) external {
        _roundId++;
        _answer = newAnswer;
        _updatedAt = block.timestamp;
        _answeredInRound = _roundId;
        
        emit AnswerUpdated(newAnswer, _roundId, block.timestamp);
    }
    
    /**
     * @dev Sets new round details manually (for advanced testing scenarios)
     */
    function setRoundData(
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) external {
        _roundId = roundId;
        _answer = answer;
        _startedAt = startedAt;
        _updatedAt = updatedAt;
        _answeredInRound = answeredInRound;
    }
    
    /**
     * @dev Manually set a timestamp for the last update
     */
    function setUpdateTime(uint256 timestamp) external {
        _updatedAt = timestamp;
    }
    
    /**
     * @dev Force the oracle to report stale data
     */
    function setStaleData() external {
        // Set answeredInRound to be less than roundId to simulate stale data
        _answeredInRound = _roundId - 1;
    }
    
    // AggregatorV3Interface implementation
    
    /**
     * @dev Returns the latest round data
     */
    function latestRoundData() external view override returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (
            _roundId,
            _answer,
            _startedAt,
            _updatedAt,
            _answeredInRound
        );
    }
    
    /**
     * @dev Get data from a specific round
     */
    function getRoundData(uint80 roundId) external view override returns (
        uint80 id,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        // For simplicity, we'll return the current values for any round ID
        // In a more sophisticated mock, you could store historical values
        return (
            roundId,
            _answer,
            _startedAt,
            _updatedAt,
            _answeredInRound
        );
    }
    
    /**
     * @dev Returns the description of the oracle
     */
    function description() external view override returns (string memory) {
        return _description;
    }
    
    /**
     * @dev Returns the number of decimals for the oracle's answer
     */
    function decimals() external view override returns (uint8) {
        return _decimals;
    }
    
    /**
     * @dev Returns the version of the oracle
     */
    function version() external pure override returns (uint256) {
        return 1;
    }
}