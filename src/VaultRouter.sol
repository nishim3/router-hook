// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    event VaultDeposited(address indexed vault, address indexed asset, uint256 assets, uint256 shares);

    /**
     * @notice Deposit all held balance of an asset into a selected vault and send shares to a receiver.
     * @param poolId Pool used to resolve optimal vault when forcedVault is zero
     * @param asset ERC20 asset address to deposit
     * @param receiver Address that will receive the ERC4626 shares
     * @param minShares Minimum acceptable shares minted for slippage safety
     * @param forcedVault Optional explicit vault to use (must be active and match asset). If zero, uses strategy
     */
    function depositHeldToVault(
        PoolId poolId,
        address asset,
        address receiver,
        uint256 minShares,
        address forcedVault
    ) external onlyOwner returns (address vault, uint256 assets, uint256 shares) {
        require(asset != address(0), "Invalid asset");
        assets = IERC20(asset).balanceOf(address(this));
        require(assets > 0, "No assets to deposit");

        if (forcedVault != address(0)) {
            require(vaultInfo[forcedVault].isActive, "Vault not active");
            require(vaultInfo[forcedVault].asset == asset, "Vault asset mismatch");
            vault = forcedVault;
        } else {
            vault = getOptimalVault(poolId, asset, assets);
        }

        IERC20(asset).approve(vault, assets);
        shares = IERC4626(vault).deposit(assets, receiver);
        require(shares >= minShares, "minShares");

        vaultInfo[vault].totalRouted += assets;
        emit FundsRouted(address(0), vault, assets);
        emit VaultDeposited(vault, asset, assets, shares);
    }

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
        uint256 allVaultsIndex; // Index in the allVaults array
        uint256 assetVaultsIndex; // Index in the assetToVaults array
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
            totalRouted: 0,
            allVaultsIndex: allVaults.length,
            assetVaultsIndex: assetToVaults[asset].length
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
        
        // O(1) removal for allVaults
        uint256 vaultIndex = vaultInfo[vault].allVaultsIndex;
        address lastVault = allVaults[allVaults.length - 1];
        if (lastVault != vault) {
            allVaults[vaultIndex] = lastVault;
            vaultInfo[lastVault].allVaultsIndex = vaultIndex;
        }
        allVaults.pop();

        // O(1) removal for assetToVaults
        address asset = vaultInfo[vault].asset;
        address[] storage assetVaults = assetToVaults[asset];
        uint256 assetVaultIndex = vaultInfo[vault].assetVaultsIndex;
        address lastAssetVault = assetVaults[assetVaults.length - 1];
        if (lastAssetVault != vault) {
            assetVaults[assetVaultIndex] = lastAssetVault;
            vaultInfo[lastAssetVault].assetVaultsIndex = assetVaultIndex;
        }
        assetVaults.pop();

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
            // Note: This is a simple yield approximation based on the vault's current "share price"
            // (total assets per share). It reflects past performance and is not a forward-looking APY.
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

    function _getNextRoundRobinVault(PoolId poolId, address[] memory vaults) internal returns (address) {
        require(vaults.length > 0, "No vaults for round robin");
        uint256 index = roundRobinIndex[poolId] % vaults.length;
        roundRobinIndex[poolId] = (index + 1) % vaults.length;
        return vaults[index];
    }

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

    function _beforeSwap(address /* sender */, PoolKey calldata key, SwapParams calldata /* params */, bytes calldata /* hookData */)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        totalSwapsProcessed[poolId]++;
        
        // Vault selection logic is moved to afterSwap to save gas,
        // as the decision is only acted upon after the swap completes.
        
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address /* sender */, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        
        // Decode optional routing parameters: (shareReceiver, forcedVault, minShares)
        address shareReceiver = address(this);
        address forcedVault = address(0);
        uint256 minShares = 0;
        if (hookData.length == 96) {
            (shareReceiver, forcedVault, minShares) = abi.decode(hookData, (address, address, uint256));
        }

        // Determine output asset (the token received by the swap receiver)
        Currency currencyOut = params.zeroForOne ? key.currency1 : key.currency0;
        address assetOut = Currency.unwrap(currencyOut);
        
        if (assetOut != address(0)) { // Skip native ETH for now
            // Amount out reflected as positive amount on the out leg of delta
            uint256 amountOut = uint256(int256(params.zeroForOne ? delta.amount1() : delta.amount0()));
            if (amountOut > 0) {
                // Use forced vault if provided, else select optimal if any available
                address selectedVault = forcedVault;
                if (selectedVault == address(0)) {
                    RoutingStrategy strategy = poolRoutingStrategy[poolId];
                    address[] memory availableVaults = getAvailableVaults(poolId, assetOut);
                    if (availableVaults.length > 0) {
                        if (strategy == RoutingStrategy.ROUND_ROBIN) {
                            selectedVault = _getNextRoundRobinVault(poolId, availableVaults);
                        } else {
                            selectedVault = getOptimalVault(poolId, assetOut, amountOut);
                        }
                    }
                } else {
                    require(vaultInfo[selectedVault].isActive, "Vault not active");
                    require(vaultInfo[selectedVault].asset == assetOut, "Vault asset mismatch");
                }

                if (selectedVault != address(0)) {
                    vaultUtilization[selectedVault]++;
                    // Best-effort deposit using tokens held by this hook (works when receiver is this hook)
                    uint256 balance = IERC20(assetOut).balanceOf(address(this));
                    uint256 depositAssets = balance < amountOut ? balance : amountOut;
                    if (depositAssets > 0) {
                        IERC20(assetOut).approve(selectedVault, depositAssets);
                        uint256 shares = IERC4626(selectedVault).deposit(depositAssets, shareReceiver);
                        require(shares >= minShares, "minShares");
                        emit VaultDeposited(selectedVault, assetOut, depositAssets, shares);
                    }
                    // Track routing decision on the intended amountOut
                    vaultInfo[selectedVault].totalRouted += amountOut;
                    emit FundsRouted(address(0), selectedVault, amountOut);
                }
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
