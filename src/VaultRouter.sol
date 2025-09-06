// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

contract VaultRouter is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ---------------------------------------------------------------
    // EVENTS
    // ---------------------------------------------------------------
    
    event VaultAdded(address indexed vault, address indexed asset, uint256 priority);
    event VaultRemoved(address indexed vault);
    event VaultPriorityUpdated(address indexed vault, uint256 newPriority);
    event FundsRouted(address indexed fromVault, address indexed toVault, uint256 amount);
    event RoutingStrategyUpdated(PoolId indexed poolId, RoutingStrategy strategy);

    // ---------------------------------------------------------------
    // ENUMS & STRUCTS
    // ---------------------------------------------------------------

    enum RoutingStrategy {
        HIGHEST_YIELD,      // Route to vault with highest APY
        LOWEST_RISK,        // Route to vault with lowest risk score
        BALANCED,           // Balance between yield and risk
        MANUAL_PRIORITY,    // Use manually set priorities
        ROUND_ROBIN         // Distribute evenly across vaults
    }

    struct VaultInfo {
        address vault;
        address asset;
        uint256 priority;      // Higher number = higher priority
        uint256 riskScore;     // 1-100, lower is safer
        bool isActive;
        uint256 totalRouted;   // Track total amount routed to this vault
    }

    // ---------------------------------------------------------------
    // STATE VARIABLES
    // ---------------------------------------------------------------

    // Pool-specific routing configurations
    mapping(PoolId => RoutingStrategy) public poolRoutingStrategy;
    mapping(PoolId => address[]) public poolVaults;
    mapping(PoolId => mapping(address => bool)) public isVaultInPool;
    
    // Global vault registry
    mapping(address => VaultInfo) public vaultInfo;
    address[] public allVaults;
    
    // Asset to vaults mapping for quick lookup
    mapping(address => address[]) public assetToVaults;
    
    // Round robin state for even distribution
    mapping(PoolId => uint256) public roundRobinIndex;
    
    // Performance tracking
    mapping(PoolId => uint256) public totalSwapsProcessed;
    mapping(address => uint256) public vaultUtilization;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) Ownable(msg.sender) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------
    // VAULT MANAGEMENT FUNCTIONS
    // ---------------------------------------------------------------

    /**
     * @notice Add a new ERC4626 vault to the routing system
     * @param vault Address of the ERC4626 vault
     * @param priority Priority level (higher = more preferred)
     * @param riskScore Risk score 1-100 (lower = safer)
     */
    function addVault(address vault, uint256 priority, uint256 riskScore) external onlyOwner {
        require(vault != address(0), "Invalid vault address");
        require(riskScore >= 1 && riskScore <= 100, "Risk score must be 1-100");
        require(!vaultInfo[vault].isActive, "Vault already exists");

        address asset = IERC4626(vault).asset();
        
        vaultInfo[vault] = VaultInfo({
            vault: vault,
            asset: asset,
            priority: priority,
            riskScore: riskScore,
            isActive: true,
            totalRouted: 0
        });

        allVaults.push(vault);
        assetToVaults[asset].push(vault);

        emit VaultAdded(vault, asset, priority);
    }

    /**
     * @notice Remove a vault from the routing system
     * @param vault Address of the vault to remove
     */
    function removeVault(address vault) external onlyOwner {
        require(vaultInfo[vault].isActive, "Vault not active");
        
        vaultInfo[vault].isActive = false;
        
        // Remove from allVaults array
        for (uint256 i = 0; i < allVaults.length; i++) {
            if (allVaults[i] == vault) {
                allVaults[i] = allVaults[allVaults.length - 1];
                allVaults.pop();
                break;
            }
        }

        // Remove from asset mapping
        address asset = vaultInfo[vault].asset;
        address[] storage assetVaults = assetToVaults[asset];
        for (uint256 i = 0; i < assetVaults.length; i++) {
            if (assetVaults[i] == vault) {
                assetVaults[i] = assetVaults[assetVaults.length - 1];
                assetVaults.pop();
                break;
            }
        }

        emit VaultRemoved(vault);
    }

    /**
     * @notice Update vault priority
     * @param vault Address of the vault
     * @param newPriority New priority level
     */
    function updateVaultPriority(address vault, uint256 newPriority) external onlyOwner {
        require(vaultInfo[vault].isActive, "Vault not active");
        vaultInfo[vault].priority = newPriority;
        emit VaultPriorityUpdated(vault, newPriority);
    }

    /**
     * @notice Update vault risk score
     * @param vault Address of the vault
     * @param newRiskScore New risk score (1-100)
     */
    function updateVaultRiskScore(address vault, uint256 newRiskScore) external onlyOwner {
        require(vaultInfo[vault].isActive, "Vault not active");
        require(newRiskScore >= 1 && newRiskScore <= 100, "Risk score must be 1-100");
        vaultInfo[vault].riskScore = newRiskScore;
    }

    /**
     * @notice Set routing strategy for a specific pool
     * @param poolId The pool identifier
     * @param strategy The routing strategy to use
     */
    function setPoolRoutingStrategy(PoolId poolId, RoutingStrategy strategy) external onlyOwner {
        poolRoutingStrategy[poolId] = strategy;
        emit RoutingStrategyUpdated(poolId, strategy);
    }

    /**
     * @notice Add vaults to a specific pool's routing list
     * @param poolId The pool identifier
     * @param vaults Array of vault addresses to add
     */
    function addVaultsToPool(PoolId poolId, address[] calldata vaults) external onlyOwner {
        for (uint256 i = 0; i < vaults.length; i++) {
            require(vaultInfo[vaults[i]].isActive, "Vault not active");
            if (!isVaultInPool[poolId][vaults[i]]) {
                poolVaults[poolId].push(vaults[i]);
                isVaultInPool[poolId][vaults[i]] = true;
            }
        }
    }

    // ---------------------------------------------------------------
    // ROUTING LOGIC FUNCTIONS
    // ---------------------------------------------------------------

    /**
     * @notice Get the optimal vault for routing based on strategy
     * @param poolId The pool identifier
     * @param asset The asset being routed
     * @return vault The selected vault address
     */
    function getOptimalVault(PoolId poolId, address asset, uint256 /* amount */) public view returns (address vault) {
        address[] memory availableVaults = getAvailableVaults(poolId, asset);
        require(availableVaults.length > 0, "No vaults available");

        RoutingStrategy strategy = poolRoutingStrategy[poolId];
        
        if (strategy == RoutingStrategy.HIGHEST_YIELD) {
            return _getHighestYieldVault(availableVaults);
        } else if (strategy == RoutingStrategy.LOWEST_RISK) {
            return _getLowestRiskVault(availableVaults);
        } else if (strategy == RoutingStrategy.BALANCED) {
            return _getBalancedVault(availableVaults);
        } else if (strategy == RoutingStrategy.MANUAL_PRIORITY) {
            return _getHighestPriorityVault(availableVaults);
        } else if (strategy == RoutingStrategy.ROUND_ROBIN) {
            // Note: This modifies state, so this function should not be view when using ROUND_ROBIN
            // For view function, we'll return the current round robin selection without incrementing
            uint256 index = roundRobinIndex[poolId] % availableVaults.length;
            return availableVaults[index];
        }
        
        // Default to highest priority
        return _getHighestPriorityVault(availableVaults);
    }

    /**
     * @notice Get available vaults for a pool and asset
     */
    function getAvailableVaults(PoolId poolId, address asset) public view returns (address[] memory) {
        address[] memory poolVaultList = poolVaults[poolId];
        if (poolVaultList.length == 0) {
            // If no pool-specific vaults, use all vaults for this asset
            return assetToVaults[asset];
        }
        
        // Filter pool vaults by asset
        uint256 count = 0;
        for (uint256 i = 0; i < poolVaultList.length; i++) {
            if (vaultInfo[poolVaultList[i]].asset == asset && vaultInfo[poolVaultList[i]].isActive) {
                count++;
            }
        }
        
        address[] memory result = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < poolVaultList.length; i++) {
            if (vaultInfo[poolVaultList[i]].asset == asset && vaultInfo[poolVaultList[i]].isActive) {
                result[index++] = poolVaultList[i];
            }
        }
        
        return result;
    }

    function _getHighestYieldVault(address[] memory vaults) internal view returns (address bestVault) {
        uint256 bestYield = 0;
        bestVault = vaults[0];
        
        for (uint256 i = 0; i < vaults.length; i++) {
            // Simple yield approximation: totalAssets / totalSupply ratio
            IERC4626 vault = IERC4626(vaults[i]);
            uint256 totalAssets = vault.totalAssets();
            uint256 totalSupply = vault.totalSupply();
            
            if (totalSupply > 0) {
                uint256 yield = (totalAssets * 1e18) / totalSupply;
                if (yield > bestYield) {
                    bestYield = yield;
                    bestVault = vaults[i];
                }
            }
        }
    }

    function _getLowestRiskVault(address[] memory vaults) internal view returns (address bestVault) {
        uint256 lowestRisk = 101; // Start higher than max risk score
        bestVault = vaults[0];
        
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 riskScore = vaultInfo[vaults[i]].riskScore;
            if (riskScore < lowestRisk) {
                lowestRisk = riskScore;
                bestVault = vaults[i];
            }
        }
    }

    function _getBalancedVault(address[] memory vaults) internal view returns (address bestVault) {
        uint256 bestScore = 0;
        bestVault = vaults[0];
        
        for (uint256 i = 0; i < vaults.length; i++) {
            IERC4626 vault = IERC4626(vaults[i]);
            uint256 totalAssets = vault.totalAssets();
            uint256 totalSupply = vault.totalSupply();
            uint256 riskScore = vaultInfo[vaults[i]].riskScore;
            
            if (totalSupply > 0) {
                uint256 yield = (totalAssets * 1e18) / totalSupply;
                // Balance score: yield / risk (higher is better)
                uint256 balanceScore = (yield * 100) / riskScore;
                
                if (balanceScore > bestScore) {
                    bestScore = balanceScore;
                    bestVault = vaults[i];
                }
            }
        }
    }

    function _getHighestPriorityVault(address[] memory vaults) internal view returns (address bestVault) {
        uint256 highestPriority = 0;
        bestVault = vaults[0];
        
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 priority = vaultInfo[vaults[i]].priority;
            if (priority > highestPriority) {
                highestPriority = priority;
                bestVault = vaults[i];
            }
        }
    }

    // Note: round-robin advancing helper intentionally omitted as current
    // implementation returns the view-only selection in getOptimalVault.

    // ---------------------------------------------------------------
    // HOOK IMPLEMENTATIONS
    // ---------------------------------------------------------------

    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal
        override
        returns (bytes4)
    {
        // Set default routing strategy for new pools
        PoolId poolId = key.toId();
        if (poolRoutingStrategy[poolId] == RoutingStrategy(0)) {
            poolRoutingStrategy[poolId] = RoutingStrategy.MANUAL_PRIORITY;
        }
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address /* sender */, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        totalSwapsProcessed[poolId]++;
        
        // Extract routing information from hookData if provided
        if (hookData.length > 0) {
            // Custom routing logic can be implemented here
            // For now, we'll use the default strategy
        }
        
        // Determine which currency is being swapped out
        Currency currencyIn = params.zeroForOne ? key.currency0 : key.currency1;
        address assetIn = Currency.unwrap(currencyIn);
        
        if (assetIn != address(0)) { // Skip native ETH for now
            // Find optimal vault for the incoming asset
            address optimalVault = getOptimalVault(poolId, assetIn, uint256(int256(params.amountSpecified > 0 ? params.amountSpecified : -params.amountSpecified)));
            
            if (optimalVault != address(0)) {
                // We could implement vault deposit logic here
                // For now, just track the routing decision
                vaultUtilization[optimalVault]++;
            }
        }
        
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address /* sender */, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata /* hookData */)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        
        // Determine which currency was swapped in (input currency)
        Currency currencyIn = params.zeroForOne ? key.currency0 : key.currency1;
        address assetIn = Currency.unwrap(currencyIn);
        
        if (assetIn != address(0)) { // Skip native ETH for now
            // Get the amount that was swapped in
            uint256 amountIn = uint256(int256(params.zeroForOne ? -delta.amount0() : -delta.amount1()));
            
            // Find optimal vault for the input asset
            address optimalVault = getOptimalVault(poolId, assetIn, amountIn);
            
            if (optimalVault != address(0)) {
                // Update vault tracking
                vaultInfo[optimalVault].totalRouted += amountIn;
                
                // Emit routing event
                emit FundsRouted(address(0), optimalVault, amountIn);
            }
        }
        
        return (BaseHook.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------
    // VIEW FUNCTIONS
    // ---------------------------------------------------------------

    /**
     * @notice Get vault information
     */
    function getVaultInfo(address vault) external view returns (VaultInfo memory) {
        return vaultInfo[vault];
    }

    /**
     * @notice Get all active vaults
     */
    function getAllActiveVaults() external view returns (address[] memory activeVaults) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < allVaults.length; i++) {
            if (vaultInfo[allVaults[i]].isActive) {
                activeCount++;
            }
        }
        
        activeVaults = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < allVaults.length; i++) {
            if (vaultInfo[allVaults[i]].isActive) {
                activeVaults[index++] = allVaults[i];
            }
        }
    }

    /**
     * @notice Get vaults for a specific asset
     */
    function getVaultsForAsset(address asset) external view returns (address[] memory) {
        return assetToVaults[asset];
    }

    /**
     * @notice Get pool statistics
     */
    function getPoolStats(PoolId poolId) external view returns (uint256 swapsProcessed, RoutingStrategy strategy, uint256 vaultCount) {
        return (totalSwapsProcessed[poolId], poolRoutingStrategy[poolId], poolVaults[poolId].length);
    }
}
