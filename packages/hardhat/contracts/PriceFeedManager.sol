// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title PriceFeedManager
 * @notice Manages Chainlink price feeds for token to USD conversions
 * @dev Used by the LoanCrowdfunding contract to get real-time price data
 */
contract PriceFeedManager is AccessControl, ReentrancyGuard {
    // Role definitions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    // Token to price feed mapping
    mapping(address => address) private _priceFeeds;
    
    // Fallback prices (denominated in USD with 8 decimals, e.g. 100000000 = $1.00)
    mapping(address => uint256) private _fallbackPrices;
    
    // Minimum update interval to prevent price manipulation
    uint256 public constant MIN_UPDATE_INTERVAL = 1 hours;
    
    // Maximum staleness period for price data
    uint256 public constant MAX_STALENESS_PERIOD = 24 hours;
    
    // Timestamp of last price feed update for each token
    mapping(address => uint256) private _lastUpdateTime;
    
    // Events
    event PriceFeedSet(address indexed token, address indexed priceFeed);
    event FallbackPriceSet(address indexed token, uint256 price);
    event PriceObtained(address indexed token, uint256 price, bool usedFallback);
    
    /**
     * @dev Constructor sets up initial roles
     */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }
    
    /**
     * @notice Sets the Chainlink price feed for a token
     * @param token The token address
     * @param priceFeed The Chainlink price feed address for this token/USD pair
     */
    function setPriceFeed(address token, address priceFeed) external onlyRole(OPERATOR_ROLE) {
        require(token != address(0), "Token address cannot be zero");
        require(priceFeed != address(0), "Price feed address cannot be zero");
        
        // Verify the price feed is valid by trying to get a price
        AggregatorV3Interface feed = AggregatorV3Interface(priceFeed);
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = feed.latestRoundData();
        
        // Validate basic Chainlink data
        require(answer > 0, "Invalid price feed - non-positive price");
        require(updatedAt > 0, "Invalid price feed - zero timestamp");
        require(answeredInRound >= roundId, "Invalid price feed - stale answer");
        
        _priceFeeds[token] = priceFeed;
        _lastUpdateTime[token] = block.timestamp;
        
        emit PriceFeedSet(token, priceFeed);
    }
    
    /**
     * @notice Sets a fallback price for a token in case the oracle is down
     * @param token The token address
     * @param price The fallback price in USD (8 decimals, e.g., 100000000 = $1.00)
     */
    function setFallbackPrice(address token, uint256 price) external onlyRole(OPERATOR_ROLE) {
        require(token != address(0), "Token address cannot be zero");
        require(price > 0, "Price must be greater than zero");
        
        _fallbackPrices[token] = price;
        emit FallbackPriceSet(token, price);
    }
    
    /**
     * @notice Gets the latest USD price of a token using Chainlink price feed
     * @param token The token address
     * @return price The token price in USD (8 decimals)
     * @return usedFallback Whether the fallback price was used
     */
    function getTokenPrice(address token) public view returns (uint256 price, bool usedFallback) {
        address feedAddress = _priceFeeds[token];
        
        // Check if we have a price feed for this token
        if (feedAddress != address(0)) {
            try AggregatorV3Interface(feedAddress).latestRoundData() returns (
                uint80 roundId,
                int256 answer,
                uint256 startedAt,
                uint256 updatedAt,
                uint80 answeredInRound
            ) {
                // Validate the oracle data
                if (answer > 0 && 
                    updatedAt > 0 && 
                    updatedAt <= block.timestamp && 
                    block.timestamp - updatedAt <= MAX_STALENESS_PERIOD &&
                    answeredInRound >= roundId) {
                    
                    return (uint256(answer), false);
                }
            } catch {
                // If oracle call fails, fall back to fallback price
            }
        }
        
        // If we reach here, either there's no price feed, the data is stale, or the call failed
        uint256 fallbackPrice = _fallbackPrices[token];
        require(fallbackPrice > 0, "No valid price feed and no fallback price");
        
        return (fallbackPrice, true);
    }
    
    /**
     * @notice Converts a USD amount to token amount using current price
     * @param usdAmount Amount in USD (2 decimal precision, e.g., 10000 = $100.00)
     * @param token Token address to convert to
     * @return tokenAmount Amount in token's native precision
     */
    function usdToToken(uint256 usdAmount, address token) external returns (uint256 tokenAmount) {
        require(usdAmount > 0, "USD amount must be greater than zero");
        require(token != address(0), "Token address cannot be zero");
        
        // Get token decimals
        uint8 tokenDecimals;
        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            tokenDecimals = decimals;
        } catch {
            // If we can't get decimals, assume 18 (most common)
            tokenDecimals = 18;
        }
        
        // Get token price in USD (8 decimals)
        (uint256 price, bool usedFallback) = getTokenPrice(token);
        
        // Convert USD amount with 2 decimals to token amount with token-specific decimals
        // Formula: (usdAmount * 10^(tokenDecimals + 8 - 2)) / price
        // This expands usdAmount to (tokenDecimals + 8) precision, then divides by price
        tokenAmount = (usdAmount * (10 ** (tokenDecimals + 6))) / price;
        
        emit PriceObtained(token, price, usedFallback);
        return tokenAmount;
    }
    
    /**
     * @notice Converts a token amount to USD using current price
     * @param tokenAmount Amount in token's native precision
     * @param token Token address
     * @return usdAmount Amount in USD (2 decimal precision, e.g., 10000 = $100.00)
     */
    function tokenToUsd(uint256 tokenAmount, address token) external returns (uint256 usdAmount) {
        require(tokenAmount > 0, "Token amount must be greater than zero");
        require(token != address(0), "Token address cannot be zero");
        
        // Get token decimals
        uint8 tokenDecimals;
        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            tokenDecimals = decimals;
        } catch {
            // If we can't get decimals, assume 18 (most common)
            tokenDecimals = 18;
        }
        
        // Get token price in USD (8 decimals)
        (uint256 price, bool usedFallback) = getTokenPrice(token);
        
        // Convert token amount to USD amount with 2 decimals
        // Formula: (tokenAmount * price) / 10^(tokenDecimals + 8 - 2)
        // This multiplies tokenAmount by price (getting tokenDecimals + 8 precision)
        // Then scales down to 2 decimal places for USD
        usdAmount = (tokenAmount * price) / (10 ** (tokenDecimals + 6));
        
       emit PriceObtained(token, price, usedFallback);
        return usdAmount;
    }
    
    /**
     * @notice Gets the last update time for a token's price feed
     * @param token The token address
     * @return The timestamp of the last update
     */
    function getLastUpdateTime(address token) external view returns (uint256) {
        return _lastUpdateTime[token];
    }
    
    /**
     * @notice Checks if a token has a valid price feed
     * @param token Token address to check
     * @return True if token has a price feed, false otherwise
     */
    function hasPriceFeed(address token) external view returns (bool) {
        return _priceFeeds[token] != address(0);
    }
    
    /**
     * @notice Gets the price feed address for a token
     * @param token Token address
     * @return Price feed address
     */
    function getPriceFeed(address token) external view returns (address) {
        return _priceFeeds[token];
    }
    
    /**
     * @notice Gets the fallback price for a token
     * @param token Token address
     * @return Fallback price in USD (8 decimals)
     */
    function getFallbackPrice(address token) external view returns (uint256) {
        return _fallbackPrices[token];
    }
}