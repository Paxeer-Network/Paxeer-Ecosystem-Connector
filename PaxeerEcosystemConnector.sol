// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Interfaces
interface IPaxeerWalletManager {
    function canAutoConnect(address wallet, string memory dappId) external view returns (bool);
    function connectToDapp(string memory dappId, address wallet) external returns (bool);
    function getSessionInfo(address wallet) external view returns (uint256, uint256, bool, string[] memory);
}

interface IPaxeerWalletVMFactory {
    function getUserWallet(address user) external view returns (address);
    function hasWallet(address user) external view returns (bool);
    function getNetworkStats() external view returns (uint256, uint256, uint256, uint256);
}

interface IPaxeerWalletVM {
    function getWalletInfo() external view returns (address, uint256, uint256, uint256, uint256, string[] memory);
    function executeTransaction(address target, uint256 value, bytes memory data) external returns (bool, bytes memory);
}

/**
 * @title PaxeerEcosystemConnector
 * @dev Bridges the SSO wallet manager with the new Wallet VM ecosystem
 * Provides seamless integration between traditional dApp connections and smart contract wallets
 */
contract PaxeerEcosystemConnector is Ownable, ReentrancyGuard {
    
    // Events
    event EcosystemWalletConnected(address indexed user, address indexed walletVM, string dappId);
    event CrossWalletTransaction(address indexed fromWallet, address indexed toWallet, uint256 amount);
    event DataAggregated(bytes32 indexed dataHash, uint256 contributingWallets, uint256 totalReward);

    // State variables
    address public walletManager;
    address public walletVMFactory;
    
    struct EcosystemStats {
        uint256 totalConnections;
        uint256 totalTransactions;
        uint256 totalDataContributions;
        uint256 activeUsers;
    }
    
    EcosystemStats public ecosystemStats;
    mapping(address => mapping(string => bool)) public dappConnections;
    mapping(bytes32 => uint256) public dataContributionRewards;

    constructor(address _walletManager, address _walletVMFactory) Ownable(msg.sender) {
        walletManager = _walletManager;
        walletVMFactory = _walletVMFactory;
    }

    /**
     * @dev Enhanced connection that works with both traditional wallets and wallet VMs
     */
    function connectToEcosystem(string memory dappId) external nonReentrant returns (bool) {
        address user = msg.sender;
        
        // Check if user has a Wallet VM
        bool hasWalletVM = IPaxeerWalletVMFactory(walletVMFactory).hasWallet(user);
        
        if (hasWalletVM) {
            // User has a Wallet VM - use enhanced connection
            address walletVM = IPaxeerWalletVMFactory(walletVMFactory).getUserWallet(user);
            return _connectWalletVMToDapp(user, walletVM, dappId);
        } else {
            // Traditional wallet connection through SSO manager
            return IPaxeerWalletManager(walletManager).connectToDapp(dappId, user);
        }
    }

    /**
     * @dev Auto-connect functionality that detects wallet type
     */
    function autoConnect(string memory dappId) external view returns (bool canConnect, bool isWalletVM, address walletAddress) {
        address user = msg.sender;
        
        // Check for Wallet VM first
        if (IPaxeerWalletVMFactory(walletVMFactory).hasWallet(user)) {
            walletAddress = IPaxeerWalletVMFactory(walletVMFactory).getUserWallet(user);
            return (true, true, walletAddress);
        }
        
        // Check traditional SSO connection
        bool canConnectSSO = IPaxeerWalletManager(walletManager).canAutoConnect(user, dappId);
        return (canConnectSSO, false, user);
    }

    /**
     * @dev Execute transaction through the appropriate wallet type
     */
    function executeEcosystemTransaction(
        address target,
        uint256 value,
        bytes memory data,
        string memory dappId
    ) external nonReentrant returns (bool success, bytes memory result) {
        address user = msg.sender;
        
        // Verify dApp connection
        require(dappConnections[user][dappId], "Not connected to dApp");
        
        // Check if user has Wallet VM
        if (IPaxeerWalletVMFactory(walletVMFactory).hasWallet(user)) {
            address walletVM = IPaxeerWalletVMFactory(walletVMFactory).getUserWallet(user);
            (success, result) = IPaxeerWalletVM(walletVM).executeTransaction(target, value, data);
        } else {
            // Traditional transaction execution
            (success, result) = target.call{value: value}(data);
        }
        
        if (success) {
            ecosystemStats.totalTransactions++;
        }
        
        return (success, result);
    }

    /**
     * @dev Get comprehensive user wallet information
     */
    function getUserWalletInfo(address user) external view returns (
        bool hasWalletVM,
        address walletAddress,
        uint256 walletId,
        uint256 contributionScore,
        string[] memory activeFeatures,
        string[] memory connectedDapps
    ) {
        hasWalletVM = IPaxeerWalletVMFactory(walletVMFactory).hasWallet(user);
        
        if (hasWalletVM) {
            walletAddress = IPaxeerWalletVMFactory(walletVMFactory).getUserWallet(user);
            (,walletId,,contributionScore,,activeFeatures) = IPaxeerWalletVM(walletAddress).getWalletInfo();
        } else {
            walletAddress = user;
            walletId = 0;
            contributionScore = 0;
            activeFeatures = new string[](0);
        }
        
        // Get connected dApps from SSO manager
        try IPaxeerWalletManager(walletManager).getSessionInfo(user) returns (uint256, uint256, bool, string[] memory dapps) {
            connectedDapps = dapps;
        } catch {
            connectedDapps = new string[](0);
        }
    }

    /**
     * @dev Aggregate data contributions across all wallet VMs
     */
    function aggregateNetworkData() external view returns (
        uint256 totalWallets,
        uint256 activeWallets,
        uint256 totalContributions,
        uint256 totalRewards
    ) {
        return IPaxeerWalletVMFactory(walletVMFactory).getNetworkStats();
    }

    /**
     * @dev Cross-wallet interaction (send value between different wallet types)
     */
    function crossWalletTransfer(
        address recipient,
        uint256 amount,
        bytes memory data
    ) external payable nonReentrant {
        require(msg.value >= amount, "Insufficient value");
        
        address sender = msg.sender;
        bool senderHasVM = IPaxeerWalletVMFactory(walletVMFactory).hasWallet(sender);
        bool recipientHasVM = IPaxeerWalletVMFactory(walletVMFactory).hasWallet(recipient);
        
        if (recipientHasVM) {
            // Send to Wallet VM
            address recipientWalletVM = IPaxeerWalletVMFactory(walletVMFactory).getUserWallet(recipient);
            (bool success,) = recipientWalletVM.call{value: amount}(data);
            require(success, "Transfer to Wallet VM failed");
        } else {
            // Send to regular address
            (bool success,) = recipient.call{value: amount}(data);
            require(success, "Transfer failed");
        }
        
        emit CrossWalletTransaction(sender, recipient, amount);
    }

    /**
     * @dev Get ecosystem statistics
     */
    function getEcosystemStats() external view returns (EcosystemStats memory) {
        return ecosystemStats;
    }

    /**
     * @dev Check if user is connected to specific dApp
     */
    function isConnectedToDapp(address user, string memory dappId) external view returns (bool) {
        return dappConnections[user][dappId];
    }

    // Internal functions
    function _connectWalletVMToDapp(address user, address walletVM, string memory dappId) internal returns (bool) {
        // Mark connection
        dappConnections[user][dappId] = true;
        ecosystemStats.totalConnections++;
        
        emit EcosystemWalletConnected(user, walletVM, dappId);
        return true;
    }

    // Admin functions
    function updateWalletManager(address newWalletManager) external onlyOwner {
        walletManager = newWalletManager;
    }

    function updateWalletVMFactory(address newWalletVMFactory) external onlyOwner {
        walletVMFactory = newWalletVMFactory;
    }

    // Receive function
    receive() external payable {}
}
