// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "forge-std/Script.sol";

/// @title EnvUtils
/// @notice Safe wrappers for Foundry's vm.env*() cheatcodes with default fallbacks.
/// @dev Prevents script crashes when optional environment variables are missing.
///      Usage: import this into your Foundry scripts to replace direct vm.env*() calls.
///
/// Example:
/// ```solidity
/// import { EnvUtils } from "./utils/EnvUtils.sol";
///
/// contract MyScript is Script, EnvUtils {
///     function run() external {
///         uint256 pk = _envUintOr("DEPLOYER_PRIVATE_KEY", 0);
///         address optionalAddr = _envAddrOrZero("OPTIONAL_TARGET");
///         bool flag = _envBoolOr("DEBUG", false);
///         bytes memory data = _envBytesOrEmpty("FLASH_DATA");
///         string memory name = _envStringOr("ENVIRONMENT", "local");
///     }
/// }
/// ```
abstract contract EnvUtils is Script {
    /// @notice Try reading uint env var, else return default.
    function _envUintOr(string memory key, uint256 def) internal view returns (uint256 out) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return def;
        }
    }

    /// @notice Try reading address env var, else return zero address.
    function _envAddrOrZero(string memory key) internal view returns (address out) {
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return address(0);
        }
    }

    /// @notice Try reading bytes env var, else return empty bytes.
    function _envBytesOrEmpty(string memory key) internal view returns (bytes memory out) {
        try vm.envBytes(key) returns (bytes memory v) {
            return v;
        } catch {
            return bytes("");
        }
    }

    /// @notice Try reading string env var, else return default string.
    function _envStringOr(string memory key, string memory def) internal view returns (string memory out) {
        try vm.envString(key) returns (string memory v) {
            return v;
        } catch {
            return def;
        }
    }

    /// @notice Try reading bool env var, else return default.
    function _envBoolOr(string memory key, bool def) internal view returns (bool out) {
        try vm.envBool(key) returns (bool v) {
            return v;
        } catch {
            return def;
        }
    }

    /// @dev Utility to check if two strings are equal.
    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev Utility to JSON-encode an array of addresses → ["0x..","0x.."]
    function _addressesToJsonArray(address[] memory arr) internal pure returns (string memory) {
        bytes memory out = bytes("[");
        for (uint256 i = 0; i < arr.length; ++i) {
            out = abi.encodePacked(out, "\"", _toHexString(arr[i]), "\"");
            if (i + 1 < arr.length) {
                out = abi.encodePacked(out, ",");
            }
        }
        out = abi.encodePacked(out, "]");
        return string(out);
    }

    /// @dev Address → 0x-prefixed hex string
    function _toHexString(address a) internal pure returns (string memory) {
        bytes20 data = bytes20(a);
        bytes memory hexChars = "0123456789abcdef";
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = hexChars[uint8(data[i] >> 4)];
            str[3 + i * 2] = hexChars[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
}
