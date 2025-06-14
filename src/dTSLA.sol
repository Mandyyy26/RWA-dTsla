// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {ConfirmedOwner} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import { FunctionsClient } from "lib/chainlink-brownie-contracts/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import { FunctionsRequest } from "lib/chainlink-brownie-contracts/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Strings} from "lib/openzeppelin-contracts/contracts/utils/Strings.sol";

/*
* @title dTSLA
* @author Mandeep Malik
*/
contract dTSLA is ConfirmedOwner, FunctionsClient, ERC20{
    using FunctionsRequest for FunctionsRequest.Request;
    using Strings for uint256;

    error dTSLA__NotEnoughCollateral();
    error dTSLA__DoesntMeetMinimumWithdrawlAmount();
    error dTSLA__TransferFailed() ;

    enum MintOrRedeem{
        mint,
        redeem
    }

    struct dTslaRequest {
        uint256 amountOfToken;
        address requester;
        MintOrRedeem mintOrRedeem;
    }

    uint256 constant PRECISION = 1e18;

    address constant SEPOLIA_TSLA_PRICE_FEED = 0xc59E3633BAAC79493d908e63626716e204A45EdF; // this is actually LINK/USD for demo purposes as TSLA/USD is not available on SEPOLIA TESTNET
    address constant  SEPOLIA_FUNCTIONS_ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    address constant SEPOLIA_USDC_PRICE_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;
    address constant SEPOLIA_USDC = 0xd9145CCE52D386f254917e481eB44e9943F39138;
    bytes32 constant DON_ID = 0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000;
    uint32 constant GAS_LIMIT = 300_000;
    uint256 constant ADDITIONAL_FEED_PRECISION = 1e18;
    uint256 constant COLLATERAL_RATIO = 200; //200% collateral ratio
    uint256 constant COLLATERAL_PRECISION = 100;
    uint256 constant MINIMUM_WITHDRAWL_AMOUNT = 100e18;

    uint64 immutable i_subId;

    string private s_mintSourceCode;
    string private s_redeemSourceCode;
    uint256 private s_portfolioBalance;
    mapping(bytes32 requestId => dTslaRequest request) private s_requestIdToRequest;
    mapping(address user => uint256 pendingWithdrawlAmount) private s_userToWithdrawlAmount;



    constructor(string memory mintSourceCode, uint64 subId, string memory redeemSourceCode) ConfirmedOwner(msg.sender) FunctionsClient(SEPOLIA_FUNCTIONS_ROUTER) ERC20("dTSLA", "dTSLA"){
        s_mintSourceCode = mintSourceCode;
        i_subId = subId;
        s_redeemSourceCode = redeemSourceCode;
    }
    
    // send an http request to:
    // 1. See how much TSLA is bought
    // 2. If enough TSLA is in the alpaca account,
    // mint dTSLA.
    // two transaction function
    function sendMintRequest(uint256 amount) external onlyOwner returns(bytes32){
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_mintSourceCode);
        bytes32 requestId = _sendRequest(req.encodeCBOR(), i_subId, GAS_LIMIT, DON_ID );
        s_requestIdToRequest[requestId] = dTslaRequest(amount,msg.sender, MintOrRedeem.mint);
        return requestId;
    }

    /// Retunr the amout of TSLA value(in usd) is stored 

     function _mintFulFillRequest(bytes32 requestId, bytes memory response) internal {
        uint256 amountOfTokensToMint = s_requestIdToRequest[requestId].amountOfToken;
        s_portfolioBalance = uint256(bytes32(response));

        // If TSLA collateral >dTSLA to mint -> mint
        // how much tsla in $$$ do we have?
        // How much tsla in $$$ are we minting?
        if(_getCollateralRatioAdjustedTotalBalance(amountOfTokensToMint)> s_portfolioBalance){
            revert dTSLA__NotEnoughCollateral();
        }

        if(amountOfTokensToMint != 0){
            _mint(s_requestIdToRequest[requestId].requester, amountOfTokensToMint);
        }
    }

    /// @notice user sends a request to sell TSLA for USDC(redemptionToken)
    /// this will, have the chainlink function call our alpaca (bank)
    /// and do the following:
    /// 1. Sell TSLA on the brokerage
    /// 2  Buy USDC on the brokerage
    /// 3. Send USDC to this contract for the user to withdraw
    function sendRedeemRequest(uint256 amountdTsla) external{
        uint256 amountTslaInUsdc = getUsdcValueOfUsd(getUsdValueOfTsla(amountdTsla));
        if(amountTslaInUsdc < MINIMUM_WITHDRAWL_AMOUNT){
            revert dTSLA__DoesntMeetMinimumWithdrawlAmount();
        }

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript( s_redeemSourceCode);

        string[] memory args = new string[](2);
        args[0]  = amountdTsla.toString();
        args[1] = amountTslaInUsdc.toString();
        req.setArgs(args);


        bytes32 requestId = _sendRequest(req.encodeCBOR(), i_subId, GAS_LIMIT, DON_ID);
        s_requestIdToRequest[requestId] = dTslaRequest(amountdTsla, msg.sender, MintOrRedeem.redeem);

        _burn(msg.sender, amountdTsla);
    }

    function _redeemFulFillRequest(bytes32 requestId, bytes memory response) internal {
        // assume for now this has 18 decimals
        uint256 usdcAmount  = uint256(bytes32(response));
        if(usdcAmount ==0){
            uint256 amountOfdTslaBurned = s_requestIdToRequest[requestId].amountOfToken;
            _mint(s_requestIdToRequest[requestId].requester, amountOfdTslaBurned);
            return;
        }

        s_userToWithdrawlAmount[s_requestIdToRequest[requestId].requester] += usdcAmount;
    }

    function withdraw() external {
        uint256 amountToWithdraw = s_userToWithdrawlAmount[msg.sender];
        s_userToWithdrawlAmount[msg.sender] = 0;

        bool succ = ERC20(0xd9145CCE52D386f254917e481eB44e9943F39138).transfer(msg.sender,amountToWithdraw);
        if(!succ){
            revert dTSLA__TransferFailed();
        }
        
    }

    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory /*err*/ ) internal override {
        if(s_requestIdToRequest[requestId].mintOrRedeem == MintOrRedeem.mint){
            _mintFulFillRequest(requestId,response);
        }
        else{
            _redeemFulFillRequest(requestId, response);
        }
    }

    function _getCollateralRatioAdjustedTotalBalance(uint256 amountOfTokensToMint) internal view returns(uint256){
        uint256 calculatedNewTotalValue = getCalculatedNewTotalVlaue(amountOfTokensToMint);
       return (calculatedNewTotalValue * COLLATERAL_RATIO) / COLLATERAL_PRECISION;
    }

    function getCalculatedNewTotalVlaue(uint256 addedNumberOfTokens) internal view returns(uint256){
        // 10 dtsla tokens + 5 dtsla tokens = 15 dtsla tokens * tsla price (100) = 1500
        return ((totalSupply() + addedNumberOfTokens) * getTslaPrice()) / PRECISION;
    }

    function getUsdcValueOfUsd(uint256 usdAMount) public view returns(uint256){
        return (usdAMount * getUsdcPrice()) / PRECISION;
    }

    function getUsdValueOfTsla(uint256 tslaAmount) public view returns(uint256) {
        return (tslaAmount* getTslaPrice())/ PRECISION;
    }

    function getTslaPrice() public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(SEPOLIA_TSLA_PRICE_FEED);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price) * ADDITIONAL_FEED_PRECISION; //so that we have 18 decimals
    }

    function getUsdcPrice() public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(SEPOLIA_USDC_PRICE_FEED);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price) * ADDITIONAL_FEED_PRECISION; 
    }

    


    function getRequest(bytes32 requestId) public view returns(dTslaRequest memory){
        return s_requestIdToRequest[requestId];
    }

    function getPendingWithdrawlAmount(address user) public view returns (uint256){
        return s_userToWithdrawlAmount[user];
    }

    function getPortfolioBalance() public view returns (uint256){
        return s_portfolioBalance;
    }

    function getSubId() public view returns (uint64) {
        return i_subId;
    }

    function getMintSourceCode() public view returns (string memory){
        return s_mintSourceCode;
    }

    function getRedeemSourceCode() public view returns (string memory){
        return s_redeemSourceCode;
    }

    function getCollateralRatio() public pure returns (uint256) {
        return COLLATERAL_RATIO;
    }

    function getCollateralPrecision() public pure returns(uint256){
        return COLLATERAL_PRECISION;
    }

}
