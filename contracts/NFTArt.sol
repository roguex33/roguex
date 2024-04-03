// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/SignedSafeMath.sol";

interface IERC20Metadata {
    /// @return The name of the token
    function name() external view returns (string memory);

    /// @return The symbol of the token
    function symbol() external view returns (string memory);

    /// @return The number of decimal places the token has
    function decimals() external view returns (uint8);
}

struct PositionDisp {
    // the nonce for permits
    uint96 nonce;
    // the address that is approved for spending this token
    address operator;
    address token0;
    address token1;
    uint24 fee;
    // the ID of the pool with which this token is connected
    uint80 poolId;
    // the tick range of the position
    int24 tickLower;
    int24 tickUpper;
    // the liquidity of the position
    uint128 liquidity;
    uint128 tokenOwe0;
    uint128 tokenOwe1;
    uint128 spotFeeOwed0;
    uint128 spotFeeOwed1;
    uint128 perpFeeOwed0;
    uint128 perpFeeOwed1;
}

interface INonfungiblePositionManager {
    function positions(
        uint256 tokenId
    ) external view returns (PositionDisp memory);
}

library Base64 {
    bytes internal constant TABLE =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    /// @notice Encodes some bytes to the base64 representation
    function encode(bytes memory data) internal pure returns (string memory) {
        uint len = data.length;
        if (len == 0) return "";

        // multiply by 4/3 rounded up
        uint encodedLen = 4 * ((len + 2) / 3);

        // Add some extra buffer at the end
        bytes memory result = new bytes(encodedLen + 32);

        bytes memory table = TABLE;

        assembly {
            let tablePtr := add(table, 1)
            let resultPtr := add(result, 32)

            for {
                let i := 0
            } lt(i, len) {

            } {
                i := add(i, 3)
                let input := and(mload(add(data, i)), 0xffffff)

                let out := mload(add(tablePtr, and(shr(18, input), 0x3F)))
                out := shl(8, out)
                out := add(
                    out,
                    and(mload(add(tablePtr, and(shr(12, input), 0x3F))), 0xFF)
                )
                out := shl(8, out)
                out := add(
                    out,
                    and(mload(add(tablePtr, and(shr(6, input), 0x3F))), 0xFF)
                )
                out := shl(8, out)
                out := add(
                    out,
                    and(mload(add(tablePtr, and(input, 0x3F))), 0xFF)
                )
                out := shl(224, out)

                mstore(resultPtr, out)

                resultPtr := add(resultPtr, 4)
            }

            switch mod(len, 3)
            case 1 {
                mstore(sub(resultPtr, 2), shl(240, 0x3d3d))
            }
            case 2 {
                mstore(sub(resultPtr, 1), shl(248, 0x3d))
            }

            mstore(result, encodedLen)
        }

        return string(result);
    }
}

contract NFTArtProxy {
    using SafeMath for uint256;
    using SafeMath for uint160;
    using SafeMath for uint8;
    using SignedSafeMath for int256;

    function toString(uint value) internal pure returns (string memory) {
        // Inspired by OraclizeAPI's implementation - MIT license
        // https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol

        if (value == 0) {
            return "0";
        }
        uint temp = value;
        uint digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function tokenURI(
        INonfungiblePositionManager positionManager,
        uint256 tokenId
    ) external view returns (string memory output) {
        PositionDisp memory p = positionManager.positions(tokenId);
        string memory token0s = IERC20Metadata(p.token0).symbol();
        string memory token1s = IERC20Metadata(p.token1).symbol();
        return
            _tokenURI(
                tokenId,
                p.fee,
                p.tickLower,
                p.tickUpper,
                token0s,
                token1s
            );
    }

    function _tokenURI(
        uint _tokenId,
        uint24 _fee,
        int24 _tickUpper,
        int24 _tickLower,
        string memory _sym0,
        string memory _sym1
    ) public pure returns (string memory output) {
        output = '<svg width="440" height="260" viewBox="0 0 440 260" fill="none" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><rect width="440" height="260" rx="30" fill="#00c5f6" /><rect style="filter: url(#f1)" x="0" y="0" width="440px" height="260px"/><defs><filter id="f1"><feImage result="p0" xlink:href="data:image/svg+xml;base64,PHN2ZyB3aWR0aD0nMjkwJyBoZWlnaHQ9JzUwMCcgdmlld0JveD0nMCAwIDI5MCA1MDAnIHhtbG5zPSdodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2Zyc+PHJlY3Qgd2lkdGg9JzI5MHB4JyBoZWlnaHQ9JzUwMHB4JyBmaWxsPScjY2I2NjQxJy8+PC9zdmc+"/><feImage result="p1" xlink:href="data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMTI2IiBoZWlnaHQ9IjEyNiIgdmlld0JveD0iMCAwIDEyNiAxMjYiIGZpbGw9Im5vbmUiIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+CjxjaXJjbGUgY3g9IjYzIiBjeT0iNjMiIHI9IjYzIiBmaWxsPSIjMUVBN0U0Ii8+Cjwvc3ZnPgo="/><feImage result="p2" xlink:href="data:image/svg+xml;base64,PHN2ZyB3aWR0aD0nMjkwJyBoZWlnaHQ9JzUwMCcgdmlld0JveD0nMCAwIDI5MCA1MDAnIHhtbG5zPSdodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2Zyc+PGNpcmNsZSBjeD0nNTUnIGN5PSczNzEnIHI9JzEyMHB4JyBmaWxsPScjNzRiNGVhJy8+PC9zdmc+" /><feBlend mode="overlay" in="p0" in2="p1" /><feBlend mode="exclusion" in2="p2" /><feGaussianBlur in="blendOut" stdDeviation="60" /></filter> </defs><g><path d="M401.068 46.2936V46.3075H402.519L406.021 42.1638L409.509 46.3075H410.974V46.2936L406.747 41.2849L406.754 41.2761L406.022 40.4054L406.021 40.4059L402.519 36.2622H401.068V36.2762L405.282 41.2849L401.068 46.2936Z" fill="#fdfeff"/><path d="M406.76 39.5287L407.494 40.3971L410.96 36.2762V36.2622H409.509L406.76 39.5287Z" fill="#ffffff"/><path fill-rule="evenodd" clip-rule="evenodd" d="M346.817 41.8133C347.407 41.0001 347.687 39.2406 347.687 39.2406V39.2451C347.988 37.6567 347.746 36.0074 347.005 34.5881C346.935 34.4545 346.861 34.3218 346.782 34.1918C346.307 33.4052 345.685 32.7285 344.955 32.2028C344.224 31.677 343.4 31.3132 342.531 31.1334C341.602 30.9378 340.643 30.9575 339.721 31.1913C338.8 31.4251 337.938 31.8674 337.195 32.4875C336.998 32.6498 336.811 32.8243 336.635 33.0102C335.826 33.8524 335.232 34.5076 334.836 35.7123C334.518 36.6772 334.539 37.763 334.569 38.3C334.569 39.6894 335.143 42.01 336.155 43.0669C336.484 43.4102 336.784 43.6652 337.036 43.8787C337.559 44.3226 337.871 44.5872 337.782 45.0928C337.65 45.8414 335.671 46.204 335.671 46.204C335.671 46.204 334.671 46.6461 334 47.559C335.012 48.704 336.041 49.2562 336.941 49.647L336.985 49.6668C337.512 49.898 338.052 50.0936 338.602 50.2527C339.255 50.4383 339.92 50.5714 340.591 50.6508C340.631 50.6567 340.672 50.6611 340.712 50.6656L340.739 50.6685L340.758 50.6706C340.924 50.6887 341.091 50.7031 341.256 50.714H341.394C341.587 50.7239 341.779 50.732 341.972 50.732C343.204 50.7445 344.43 50.5544 345.606 50.1687C345.508 49.8329 345.399 49.507 345.279 49.1875C344.856 48.0545 344.199 47.0352 343.355 46.204C343.306 46.156 343.267 46.1176 343.233 46.0847L343.233 46.0847L343.233 46.0846L343.232 46.0844L343.232 46.084L343.232 46.0838C343.071 45.9282 343.035 45.8942 342.796 45.5332C342.506 45.0953 344.955 43.7275 344.955 43.7275C345.521 43.3049 346.227 42.6265 346.817 41.8133ZM344.028 34.5549C343.88 34.5461 343.731 34.5399 343.582 34.5365C342.614 34.4809 338.867 34.4611 338.867 37.4909C338.867 37.9126 338.837 38.2919 338.784 38.6345C338.566 40.0231 337.971 40.8223 337.538 41.4029C336.985 42.1459 336.698 42.5307 337.813 43.3345C339.318 44.4197 339.213 44.5506 338.739 45.145L338.739 45.145L338.739 45.1451L338.739 45.1451C338.658 45.2454 338.568 45.3589 338.473 45.4925C338.473 45.4925 338.95 45.9397 339.527 46.3436C339.825 46.5713 340.155 46.7838 340.465 46.8985C341.385 47.2385 342.972 47.0306 342.972 47.0306L342.958 47.0168L342.95 47.0096C342.984 47.0058 343.002 47.0035 343.002 47.0035C342.218 46.2566 341.941 45.2848 342.411 44.8751C341.392 45.0653 340.447 44.8508 339.67 44.4952C339.563 43.9649 339.336 43.5306 338.867 43.2734C337.327 42.4286 337.798 41.8328 338.485 40.9638L338.485 40.9637L338.485 40.9634L338.485 40.9633C338.562 40.8662 338.642 40.7657 338.721 40.661C339.952 41.063 340.675 40.8173 341.413 40.5667C341.974 40.3758 342.544 40.1821 343.353 40.2702C344.006 40.3412 344.424 40.633 344.816 40.9074C345.331 41.268 345.804 41.5988 346.714 41.3594C347.088 40.2095 347.136 38.8781 347.136 37.4909C347.136 34.9382 344.281 34.5946 343.86 34.5578C343.915 34.5558 343.971 34.5549 344.028 34.5549ZM340.759 37.9519C341.018 38.137 341.286 38.3112 341.553 38.4818C341.73 38.5938 341.907 38.7039 342.084 38.8131C342.105 38.8253 342.121 38.8439 342.13 38.8663C342.14 38.8886 342.143 38.9136 342.138 38.9377C342.079 39.2209 341.925 39.4723 341.705 39.6469C341.485 39.8215 341.214 39.9077 340.939 39.89C340.648 39.8688 340.375 39.7338 340.173 39.5115C339.972 39.2893 339.856 38.9958 339.85 38.6885C339.847 38.5024 339.885 38.3182 339.961 38.15C340.036 37.9817 340.147 37.834 340.286 37.7181C340.303 37.7038 340.325 37.6955 340.347 37.6942C340.369 37.6929 340.391 37.6987 340.41 37.7109C340.5 37.7672 340.587 37.8296 340.674 37.8913L340.674 37.8913C340.702 37.9117 340.73 37.932 340.759 37.9519ZM345.013 38.7713C345.313 38.681 345.612 38.5799 345.909 38.4707C345.939 38.4594 345.97 38.4479 346.001 38.4363L346.001 38.4363C346.101 38.3987 346.202 38.3607 346.304 38.329C346.325 38.3223 346.348 38.3227 346.369 38.3299C346.39 38.3372 346.409 38.351 346.422 38.3696C346.528 38.5185 346.601 38.6911 346.633 38.874C346.666 39.057 346.659 39.2454 346.612 39.4248C346.531 39.7197 346.348 39.9723 346.1 40.1332C345.852 40.2941 345.556 40.3518 345.27 40.2951C345 40.2386 344.758 40.0826 344.587 39.8552C344.416 39.6277 344.328 39.3436 344.338 39.0538C344.34 39.0289 344.349 39.0051 344.364 38.9861C344.38 38.9671 344.401 38.9538 344.424 38.9482C344.617 38.8895 344.815 38.83 345.013 38.7713ZM357.562 42.9194L360.101 46.2975H361.594V46.2835L359.041 42.9194H357.562ZM353.732 37.2174V46.2975H354.863V43.2422H354.862V40.177H354.863V37.9403C354.863 37.7915 354.914 37.6659 355.016 37.5636C355.128 37.452 355.258 37.3962 355.407 37.3962H359.99C360.138 37.3962 360.264 37.452 360.366 37.5636C360.478 37.6659 360.534 37.7915 360.534 37.9403V40.8842C360.534 41.033 360.478 41.1586 360.366 41.2609C360.264 41.3632 360.138 41.4143 359.99 41.4143H355.529V42.5584H359.99C360.297 42.5584 360.576 42.484 360.827 42.3352C361.087 42.177 361.292 41.9724 361.441 41.7213C361.589 41.4701 361.664 41.1911 361.664 40.8842V37.9403C361.664 37.6334 361.589 37.3544 361.441 37.1032C361.292 36.8521 361.087 36.6521 360.827 36.5033C360.576 36.3452 360.297 36.2661 359.99 36.2661H354.684C354.158 36.2661 353.732 36.692 353.732 37.2174ZM363.899 46.0743C364.159 46.2231 364.443 46.2975 364.75 46.2975H369.605C369.921 46.2975 370.205 46.2231 370.456 46.0743C370.717 45.9161 370.921 45.7115 371.07 45.4604C371.228 45.1999 371.307 44.9163 371.307 44.6093V39.8936C371.307 39.5867 371.228 39.3076 371.07 39.0565C370.921 38.796 370.717 38.5914 370.456 38.4426C370.205 38.2845 369.921 38.2054 369.605 38.2054H364.75C364.443 38.2054 364.159 38.2845 363.899 38.4426C363.648 38.5914 363.443 38.796 363.285 39.0565C363.136 39.3076 363.062 39.5867 363.062 39.8936V44.6093C363.062 44.9163 363.136 45.1999 363.285 45.4604C363.443 45.7115 363.648 45.9161 363.899 46.0743ZM369.605 45.1534H364.75C364.601 45.1534 364.471 45.1023 364.359 45C364.257 44.8883 364.206 44.7581 364.206 44.6093V39.8936C364.206 39.7448 364.257 39.6192 364.359 39.5169C364.471 39.4053 364.601 39.3495 364.75 39.3495H369.605C369.754 39.3495 369.88 39.4053 369.982 39.5169C370.093 39.6192 370.149 39.7448 370.149 39.8936V44.6093C370.149 44.7581 370.093 44.8883 369.982 45C369.88 45.1023 369.754 45.1534 369.605 45.1534ZM374.075 49.4925V48.3345H379.126C379.274 48.3345 379.4 48.2786 379.502 48.167C379.614 48.0647 379.67 47.9392 379.67 47.7903V47.047H379.67V43.9819H379.67V39.8936C379.67 39.7448 379.614 39.6192 379.502 39.5169C379.4 39.4053 379.274 39.3495 379.126 39.3495H374.27C374.122 39.3495 373.991 39.4053 373.88 39.5169C373.777 39.6192 373.726 39.7448 373.726 39.8936V44.6093C373.726 44.7581 373.777 44.8883 373.88 45C373.991 45.1023 374.122 45.1534 374.27 45.1534H378.994V46.2975H374.27C373.963 46.2975 373.68 46.2231 373.419 46.0743C373.168 45.9161 372.964 45.7115 372.805 45.4604C372.657 45.1999 372.582 44.9163 372.582 44.6093V39.8936C372.582 39.5867 372.657 39.3076 372.805 39.0565C372.964 38.796 373.168 38.5914 373.419 38.4426C373.68 38.2845 373.963 38.2054 374.27 38.2054H379.126C379.442 38.2054 379.726 38.2845 379.977 38.4426C380.237 38.5914 380.442 38.796 380.591 39.0565C380.739 39.3076 380.814 39.5867 380.814 39.8936V47.7903C380.814 48.1066 380.739 48.3903 380.591 48.6414C380.442 48.9018 380.237 49.1065 379.977 49.2553C379.726 49.4134 379.442 49.4925 379.126 49.4925H374.075ZM382.756 46.0743C383.017 46.2231 383.3 46.2975 383.607 46.2975H388.463C388.779 46.2975 389.063 46.2231 389.314 46.0743C389.574 45.9161 389.779 45.7115 389.928 45.4604C390.086 45.1999 390.165 44.9163 390.165 44.6093V39.3495C390.165 38.7176 389.653 38.2054 389.021 38.2054V44.6093C389.021 44.7581 388.965 44.8883 388.853 45C388.742 45.1023 388.611 45.1534 388.463 45.1534H383.607C383.459 45.1534 383.328 45.1023 383.217 45C383.114 44.8883 383.063 44.7581 383.063 44.6093V38.2054C382.431 38.2054 381.919 38.7176 381.919 39.3495V44.6093C381.919 44.9163 381.994 45.1999 382.142 45.4604C382.301 45.7115 382.505 45.9161 382.756 46.0743ZM393.076 46.2975C392.769 46.2975 392.485 46.2231 392.225 46.0743C391.974 45.9161 391.769 45.7115 391.611 45.4604C391.462 45.1999 391.388 44.9163 391.388 44.6093V39.8936C391.388 39.5867 391.462 39.3076 391.611 39.0565C391.769 38.796 391.974 38.5914 392.225 38.4426C392.485 38.2845 392.769 38.2054 393.076 38.2054H397.931C398.247 38.2054 398.531 38.2845 398.782 38.4426C399.043 38.5914 399.247 38.796 399.396 39.0565C399.554 39.3076 399.633 39.5867 399.633 39.8936V42.8235H392.532V44.6093C392.532 44.7581 392.583 44.8883 392.685 45C392.797 45.1023 392.927 45.1534 393.076 45.1534H399.633V46.2975H393.076ZM392.532 41.6794H398.475V39.8936C398.475 39.7448 398.42 39.6192 398.308 39.5169C398.206 39.4053 398.08 39.3495 397.931 39.3495H393.076C392.927 39.3495 392.797 39.4053 392.685 39.5169C392.583 39.6192 392.532 39.7448 392.532 39.8936V41.6794Z" fill="#f9fafa"/></g><g transform="translate(180,16)"><path d="M0 229.681V230H33.2859L113.62 135.125L193.634 230H227.24V229.681L130.263 115L130.433 114.799L113.63 94.863L113.62 94.875L33.2859 0H0V0.319444L96.657 115L0 229.681Z" fill="black" fill-opacity="0.05"/><path d="M130.559 74.7902L147.395 94.6736L226.92 0.319444V0H193.634L130.559 74.7902Z" fill="black" fill-opacity="0.05"/></g><rect x="15" y="15" width="410" height="230" rx="16" stroke="rgba(4,4,4,0.222)" stroke-opacity="0.8" stroke-width="2px"/><rect x="4" y="4" width="432" height="252" rx="24" stroke="#005f88" stroke-opacity="0.4" stroke-width="8px"/><text y="60px" x="32px" fill="#010101" font-weight="100" font-size="36px" text-shadow="4px">';
        output = string(
            abi.encodePacked(
                output,
                _sym0,
                "/",
                _sym1,
                "#",
                toString(_tokenId),
                '</text><text y="90px" x="32px" fill="#000000" font-weight="400" font-size="12px" text-shadow="4px">'
            )
        );
        output = string(
            abi.encodePacked(
                output,
                feeToPercentString(_fee),
                '</text><text y="155px" x="32px" fill="#000000" font-weight="700" font-size="12px">Min Tick</text><text y="175px" x="32px" fill="#000000" font-weight="100" font-size="16px">'
            )
        );
        output = string(
            abi.encodePacked(
                output,
                _tickLower > 0 ? "" : "-",
                toString(uint(int256(_tickLower))),
                '</text><text y="205px" x="32px" fill="#000000" font-weight="700" font-size="12px">Max Tick</text><text y="225px" x="32px" fill="#000000" font-weight="100" font-size="16px">'
            )
        );
        output = string(
            abi.encodePacked(
                output,
                _tickUpper > 0 ? "" : "-",
                toString(uint(int256(_tickUpper))),
                "</text></svg>"
            )
        );
        string memory json = Base64.encode(
            bytes(
                string(
                    abi.encodePacked(
                        '{"name": "Rougex NFT #',
                        toString(_tokenId),
                        '", "description": "Rougex v3 NFT", "image": "data:image/svg+xml;base64,',
                        Base64.encode(bytes(output)),
                        '"}'
                    )
                )
            )
        );
        output = string(
            abi.encodePacked("data:application/json;base64,", json)
        );
    }

    struct DecimalStringParams {
        // significant figures of decimal
        uint256 sigfigs;
        // length of decimal string
        uint8 bufferLength;
        // ending index for significant figures (funtion works backwards when copying sigfigs)
        uint8 sigfigIndex;
        // index of decimal place (0 if no decimal)
        uint8 decimalIndex;
        // start index for trailing/leading 0's for very small/large numbers
        uint8 zerosStartIndex;
        // end index for trailing/leading 0's for very small/large numbers
        uint8 zerosEndIndex;
        // true if decimal number is less than one
        bool isLessThanOne;
        // true if string should include "%"
        bool isPercent;
    }

    function feeToPercentString(
        uint24 fee
    ) internal pure returns (string memory) {
        if (fee == 0) {
            return "0%";
        }
        uint24 temp = fee;
        uint256 digits;
        uint8 numSigfigs;
        while (temp != 0) {
            if (numSigfigs > 0) {
                // count all digits preceding least significant figure
                numSigfigs++;
            } else if (temp % 10 != 0) {
                numSigfigs++;
            }
            digits++;
            temp /= 10;
        }

        DecimalStringParams memory params;
        uint256 nZeros;
        if (digits >= 5) {
            // if decimal > 1 (5th digit is the ones place)
            uint256 decimalPlace = digits.sub(numSigfigs) >= 4 ? 0 : 1;
            nZeros = digits.sub(5) < (numSigfigs.sub(1))
                ? 0
                : digits.sub(5).sub(numSigfigs.sub(1));
            params.zerosStartIndex = numSigfigs;
            params.zerosEndIndex = uint8(
                params.zerosStartIndex.add(nZeros).sub(1)
            );
            params.sigfigIndex = uint8(
                params.zerosStartIndex.sub(1).add(decimalPlace)
            );
            params.bufferLength = uint8(
                nZeros.add(numSigfigs.add(1)).add(decimalPlace)
            );
        } else {
            // else if decimal < 1
            nZeros = uint256(5).sub(digits);
            params.zerosStartIndex = 2;
            params.zerosEndIndex = uint8(
                nZeros.add(params.zerosStartIndex).sub(1)
            );
            params.bufferLength = uint8(nZeros.add(numSigfigs.add(2)));
            params.sigfigIndex = uint8((params.bufferLength).sub(2));
            params.isLessThanOne = true;
        }
        params.sigfigs = uint256(fee).div(10 ** (digits.sub(numSigfigs)));
        params.isPercent = true;
        params.decimalIndex = digits > 4 ? uint8(digits.sub(4)) : 0;

        return generateDecimalString(params);
    }

    function generateDecimalString(
        DecimalStringParams memory params
    ) private pure returns (string memory) {
        bytes memory buffer = new bytes(params.bufferLength);
        if (params.isPercent) {
            buffer[buffer.length - 1] = "%";
        }
        if (params.isLessThanOne) {
            buffer[0] = "0";
            buffer[1] = ".";
        }

        // add leading/trailing 0's
        for (
            uint256 zerosCursor = params.zerosStartIndex;
            zerosCursor < params.zerosEndIndex.add(1);
            zerosCursor++
        ) {
            buffer[zerosCursor] = bytes1(uint8(48));
        }
        // add sigfigs
        while (params.sigfigs > 0) {
            if (
                params.decimalIndex > 0 &&
                params.sigfigIndex == params.decimalIndex
            ) {
                buffer[params.sigfigIndex--] = ".";
            }
            buffer[params.sigfigIndex--] = bytes1(
                uint8(uint256(48).add(params.sigfigs % 10))
            );
            params.sigfigs /= 10;
        }
        return string(buffer);
    }
}
