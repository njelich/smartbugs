/**
 *Submitted for verification at Etherscan.io on 2020-10-23
*/

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;

interface IERC20 { // brief interface for erc20 token tx
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

library Address { // helper for address type - see openzeppelin-contracts/blob/master/contracts/utils/Address.sol
    function isContract(address account) internal view returns (bool) {
        bytes32 codehash;
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        assembly { codehash := extcodehash(account) }
        return (codehash != accountHash && codehash != 0x0);
    }
}

library SafeERC20 { // wrapper around erc20 token tx for non-standard contract - see openzeppelin-contracts/blob/master/contracts/token/ERC20/SafeERC20.sol
    using Address for address;
    
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }
    
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }
    
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        require(address(token).isContract(), "SafeERC20: call to non-contract");
        (bool success, bytes memory returnData) = address(token).call(data);
        require(success, "SafeERC20: low-level call failed");

        if (returnData.length > 0) { // return data is optional
            require(abi.decode(returnData, (bool)), "SafeERC20: erc20 operation did not succeed");
        }
    }
}

library SafeMath { // arithmetic wrapper for unit under/overflow check
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a);

        return c;
    }
    
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a);
        uint256 c = a - b;

        return c;
    }
    
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b);

        return c;
    }
    
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0);
        uint256 c = a / b;

        return c;
    }
}

contract ReentrancyGuard { // call wrapper for reentrancy check
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() internal {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract MYSTIC is ReentrancyGuard { 
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /***************
    GLOBAL CONSTANTS
    ***************/
    address internal depositToken; // deposit token contract reference - default = wETH
    address internal stakeToken; // stake token contract reference for guild voting shares 
    address internal constant wETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // canonical ether token wrapper contract reference 
    uint256 internal proposalDeposit; // default = 10 deposit token 
    uint256 internal processingReward; // default = 0.1 - amount of deposit token to give to whoever processes a proposal
    uint256 internal periodDuration; // default = 17280 = 4.8 hours in seconds (5 periods per day)
    uint256 internal votingPeriodLength; // default = 35 periods (7 days)
    uint256 internal gracePeriodLength; // default = 35 periods (7 days)
    uint256 internal dilutionBound; // default = 3 - maximum multiplier a YES voter will be obligated to pay in case of mass ragequit
    uint256 internal summoningTime; // needed to determine the current period
    bool private initialized; // internally tracks deployment under eip-1167 proxy pattern
    
    // HARD-CODED LIMITS
    uint256 constant MAX_GUILD_BOUND = 10**36; // maximum bound for guild member accounting
    uint256 constant MAX_TOKEN_WHITELIST_COUNT = 400; // maximum number of whitelisted tokens
    uint256 constant MAX_TOKEN_GUILDBANK_COUNT = 200; // maximum number of tokens with non-zero balance in guildbank

    // GUILD TOKEN DETAILS
    uint8 public constant decimals = 18;
    string internal name; // set at summoning
    string public constant symbol = "DAO";
    
    // *******************
    // INTERNAL ACCOUNTING
    // *******************
    address internal constant GUILD = address(0xdead);
    address internal constant ESCROW = address(0xdeaf);
    address internal constant TOTAL = address(0xdeed);
    uint256 internal proposalCount; // total proposals submitted
    uint256 internal totalShares; // total shares across all members
    uint256 internal totalLoot; // total loot across all members
    uint256 internal totalSupply; // total shares & loot across all members (total guild tokens)
    uint256 internal totalGuildBankTokens; // total tokens with non-zero balance in guild bank

    mapping(address => uint256) internal balanceOf; // guild token balances
    mapping(address => mapping(address => uint256)) internal allowance; // guild token (loot) allowances
    mapping(address => mapping(address => uint256)) private userTokenBalances; // userTokenBalances[userAddress][tokenAddress]
    
    address[] internal approvedTokens;
    mapping(address => bool) internal tokenWhitelist;
    
    uint256[] internal proposalQueue;
    mapping(uint256 => bytes) internal actions; 
    mapping(uint256 => Proposal) internal proposals;

    mapping(address => bool) internal proposedToWhitelist;
    mapping(address => bool) internal proposedToKick;
    
    mapping(address => Member) internal members;
    mapping(address => address) internal memberAddressByDelegateKey;

    // **************
    // EVENT TRACKING
    // **************
    event SubmitProposal(address indexed applicant, uint256 sharesRequested, uint256 lootRequested, uint256 tributeOffered, address tributeToken, uint256 paymentRequested, address paymentToken, bytes32 details, uint8[8] flags, bytes data, uint256 proposalId, address indexed delegateKey, address indexed memberAddress);
    event CancelProposal(uint256 indexed proposalId, address applicantAddress);
    event SponsorProposal(address indexed delegateKey, address indexed memberAddress, uint256 proposalId, uint256 proposalIndex, uint256 startingPeriod);
    event SubmitVote(uint256 proposalId, uint256 indexed proposalIndex, address indexed delegateKey, address indexed memberAddress, uint8 uintVote);
    event ProcessProposal(uint256 indexed proposalIndex, uint256 indexed proposalId, bool didPass);
    event ProcessActionProposal(uint256 indexed proposalIndex, uint256 indexed proposalId, bool didPass);
    event ProcessGuildKickProposal(uint256 indexed proposalIndex, uint256 indexed proposalId, bool didPass);
    event ProcessWhitelistProposal(uint256 indexed proposalIndex, uint256 indexed proposalId, bool didPass);
    event UpdateDelegateKey(address indexed memberAddress, address newDelegateKey);
    event Ragequit(address indexed memberAddress, uint256 sharesToBurn, uint256 lootToBurn);
    event TokensCollected(address indexed token, uint256 amountToCollect);
    event Withdraw(address indexed memberAddress, address token, uint256 amount);
    event ConvertSharesToLoot(address indexed memberAddress, uint256 amount);
    event StakeTokenForShares(address indexed memberAddress, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount); // guild token (loot) allowance tracking
    event Transfer(address indexed sender, address indexed recipient, uint256 amount); // guild token mint, burn & loot transfer tracking
    
    enum Vote {
        Null, // default value, counted as abstention
        Yes,
        No
    }
    
    struct Member {
        address delegateKey; // the key responsible for submitting proposals & voting - defaults to member address unless updated
        uint8 exists; // always true (1) once a member has been created
        uint256 shares; // the # of voting shares assigned to this member
        uint256 loot; // the loot amount available to this member (combined with shares on ragekick) - transferable by guild token
        uint256 highestIndexYesVote; // highest proposal index # on which the member voted YES
        uint256 jailed; // set to proposalIndex of a passing guild kick proposal for this member, prevents voting on & sponsoring proposals
    }
    
    struct Proposal {
        address applicant; // the applicant who wishes to become a member - this key will be used for withdrawals (doubles as target for alt. proposals)
        address proposer; // the account that submitted the proposal (can be non-member)
        address sponsor; // the member that sponsored the proposal (moving it into the queue)
        address tributeToken; // tribute token contract reference
        address paymentToken; // payment token contract reference
        uint8[8] flags; // [sponsored, processed, didPass, cancelled, whitelist, guildkick, action, standard]
        uint256 sharesRequested; // the # of shares the applicant is requesting
        uint256 lootRequested; // the amount of loot the applicant is requesting
        uint256 paymentRequested; // amount of tokens requested as payment
        uint256 tributeOffered; // amount of tokens offered as tribute
        uint256 startingPeriod; // the period in which voting can start for this proposal
        uint256 yesVotes; // the total number of YES votes for this proposal
        uint256 noVotes; // the total number of NO votes for this proposal
        uint256 maxTotalSharesAndLootAtYesVote; // the maximum # of total shares encountered at a yes vote on this proposal
        bytes32 details; // proposal details to add context for members 
        mapping(address => Vote) votesByMember; // the votes on this proposal by each member
    }
    
    modifier onlyDelegate {
        require(members[memberAddressByDelegateKey[msg.sender]].shares > 0, "!delegate");
        _;
    }

    function init(
        address _depositToken,
        address _stakeToken,
        address[] memory _summoner,
        uint256[] memory _summonerShares,
        uint256 _summonerDeposit,
        uint256 _proposalDeposit,
        uint256 _processingReward,
        uint256 _periodDuration,
        uint256 _votingPeriodLength,
        uint256 _gracePeriodLength,
        uint256 _dilutionBound,
        string memory _guildName
    ) external {
        require(!initialized, "initialized");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(_depositToken != _stakeToken, "depositToken = stakeToken");
        require(_summoner.length == _summonerShares.length, "summoner != summonerShares");
        require(_proposalDeposit >= _processingReward, "_processingReward > _proposalDeposit");
        
        for (uint256 i = 0; i < _summoner.length; i++) {
            growGuild(_summoner[i], _summonerShares[i], 0);
        }
        
        require(totalShares <= MAX_GUILD_BOUND, "guild maxed");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        tokenWhitelist[_depositToken] = true;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        approvedTokens.push(_depositToken);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        
        if (_summonerDeposit > 0) {
            totalGuildBankTokens += 1;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            unsafeAddToBalance(GUILD, _depositToken, _summonerDeposit);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        }
        
        depositToken = _depositToken;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        stakeToken = _stakeToken;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        proposalDeposit = _proposalDeposit;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        processingReward = _processingReward;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        periodDuration = _periodDuration;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        votingPeriodLength = _votingPeriodLength;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        gracePeriodLength = _gracePeriodLength;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        dilutionBound = _dilutionBound;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        summoningTime = now;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        name = _guildName;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        initialized = true;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
    }
    
    /*****************
    PROPOSAL FUNCTIONS
    *****************/
    function submitProposal(
        address applicant,
        uint256 sharesRequested,
        uint256 lootRequested,
        uint256 tributeOffered,
        address tributeToken,
        uint256 paymentRequested,
        address paymentToken,
        bytes32 details
    ) external nonReentrant payable returns (uint256 proposalId) {
        require(sharesRequested.add(lootRequested) <= MAX_GUILD_BOUND, "guild maxed");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(tokenWhitelist[tributeToken], "tributeToken != whitelist");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(tokenWhitelist[paymentToken], "paymentToken != whitelist");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(applicant != GUILD && applicant != ESCROW && applicant != TOTAL, "applicant unreservable");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(members[applicant].jailed == 0, "applicant jailed");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC

        if (tributeOffered > 0 && userTokenBalances[GUILD][tributeToken] == 0) {	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            require(totalGuildBankTokens < MAX_TOKEN_GUILDBANK_COUNT, "guildbank maxed");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        }
        
        // collect tribute from proposer & store it in MYSTIC until the proposal is processed - if ether, wrap into wETH
        if (msg.value > 0) {
            require(tributeToken == wETH && msg.value == tributeOffered, "!ethBalance");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            (bool success, ) = wETH.call{value: msg.value}("");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            require(success, "!ethCall");
            IERC20(wETH).safeTransfer(address(this), msg.value);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        } else {
            IERC20(tributeToken).safeTransferFrom(msg.sender, address(this), tributeOffered);
        }
        
        unsafeAddToBalance(ESCROW, tributeToken, tributeOffered);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        
        uint8[8] memory flags; // [sponsored, processed, didPass, cancelled, whitelist, guildkick, action, standard]
        flags[7] = 1; // standard

        _submitProposal(applicant, sharesRequested, lootRequested, tributeOffered, tributeToken, paymentRequested, paymentToken, details, flags, "");
        
        return proposalCount - 1; // return proposalId - contracts calling submit might want it	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
    }
    
     function submitActionProposal( // stages arbitrary function calls for member vote - based on Raid Guild 'Minion'
        address actionTo, // target account for action (e.g., address to receive ether, token, dao, etc.)
        uint256 actionTokenAmount, // helps check outbound guild bank token amount does not exceed internal balance / amount to update bank if successful 
        uint256 actionValue, // ether value, if any, in call 
        bytes32 details, // details tx staged for member execution - as external, extra care should be applied in diligencing action 
        bytes calldata data // data for function call
    ) external nonReentrant returns (uint256 proposalId) {
        uint8[8] memory flags; // [sponsored, processed, didPass, cancelled, whitelist, guildkick, action, standard]
        flags[6] = 1; // action
        
        _submitProposal(actionTo, 0, 0, actionValue, address(0), actionTokenAmount, address(0), details, flags, data);
        
        return proposalCount - 1;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
    }

    function submitGuildKickProposal(address memberToKick, bytes32 details) external nonReentrant returns (uint256 proposalId) {
        Member memory member = members[memberToKick];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(member.shares > 0 || member.loot > 0, "!share||loot");
        require(members[memberToKick].jailed == 0, "jailed");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        uint8[8] memory flags; // [sponsored, processed, didPass, cancelled, whitelist, guildkick, action, standard]
        flags[5] = 1; // guildkick

        _submitProposal(memberToKick, 0, 0, 0, address(0), 0, address(0), details, flags, "");
        
        return proposalCount - 1;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
    }
    
    function submitWhitelistProposal(address tokenToWhitelist, bytes32 details) external nonReentrant returns (uint256 proposalId) {
        require(tokenToWhitelist != address(0), "!token");
        require(tokenToWhitelist != stakeToken, "tokenToWhitelist = stakeToken");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(!tokenWhitelist[tokenToWhitelist], "whitelisted");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(approvedTokens.length < MAX_TOKEN_WHITELIST_COUNT, "whitelist maxed");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        uint8[8] memory flags; // [sponsored, processed, didPass, cancelled, whitelist, guildkick, action, standard]
        flags[4] = 1; // whitelist

        _submitProposal(address(0), 0, 0, 0, tokenToWhitelist, 0, address(0), details, flags, "");
        
        return proposalCount - 1;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
    }

    function _submitProposal(
        address applicant,
        uint256 sharesRequested,
        uint256 lootRequested,
        uint256 tributeOffered,
        address tributeToken,
        uint256 paymentRequested,
        address paymentToken,
        bytes32 details,
        uint8[8] memory flags,
        bytes memory data
    ) internal {
        Proposal memory proposal = Proposal({
            applicant : applicant,
            proposer : msg.sender,
            sponsor : address(0),
            tributeToken : tributeToken,
            paymentToken : paymentToken,
            flags : flags,
            sharesRequested : sharesRequested,
            lootRequested : lootRequested,
            paymentRequested : paymentRequested,
            tributeOffered : tributeOffered,
            startingPeriod : 0,
            yesVotes : 0,
            noVotes : 0,
            maxTotalSharesAndLootAtYesVote : 0,
            details : details
        });
        
        if (proposal.flags[6] == 1) {
            actions[proposalCount] = data;
        }
        
        proposals[proposalCount] = proposal;
        // NOTE: argument order matters, avoid stack too deep
        emit SubmitProposal(applicant, sharesRequested, lootRequested, tributeOffered, tributeToken, paymentRequested, paymentToken, details, flags, data, proposalCount, msg.sender, memberAddressByDelegateKey[msg.sender]);
        
        proposalCount += 1;
    }

    function sponsorProposal(uint256 proposalId) external nonReentrant onlyDelegate {
        // collect proposal deposit from sponsor & store it in MYSTIC until the proposal is processed
        IERC20(depositToken).safeTransferFrom(msg.sender, address(this), proposalDeposit);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        unsafeAddToBalance(ESCROW, depositToken, proposalDeposit);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        Proposal storage proposal = proposals[proposalId];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(proposal.proposer != address(0), "!proposed");
        require(proposal.flags[0] == 0, "sponsored");
        require(proposal.flags[3] == 0, "cancelled");
        require(members[proposal.applicant].jailed == 0, "applicant jailed");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC

        if (proposal.tributeOffered > 0 && userTokenBalances[GUILD][proposal.tributeToken] == 0) {	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            require(totalGuildBankTokens < MAX_TOKEN_GUILDBANK_COUNT, "guildbank maxed");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        }

        // whitelist proposal
        if (proposal.flags[4] == 1) {
            require(!tokenWhitelist[address(proposal.tributeToken)], "whitelisted");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            require(!proposedToWhitelist[address(proposal.tributeToken)], "whitelist proposed");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            require(approvedTokens.length < MAX_TOKEN_WHITELIST_COUNT, "whitelist maxed");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            proposedToWhitelist[address(proposal.tributeToken)] = true;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC

        // guild kick proposal
        } else if (proposal.flags[5] == 1) {
            require(!proposedToKick[proposal.applicant], "kick proposed");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            proposedToKick[proposal.applicant] = true;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        }

        // compute startingPeriod for proposal
        uint256 startingPeriod = max(
            getCurrentPeriod(),
            proposalQueue.length == 0 ? 0 : proposals[proposalQueue[proposalQueue.length - 1]].startingPeriod	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        ) + 1;

        proposal.startingPeriod = startingPeriod;
        proposal.sponsor = memberAddressByDelegateKey[msg.sender];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        proposal.flags[0] = 1; // sponsored
        // append proposal to the queue
        proposalQueue.push(proposalId);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        
        emit SponsorProposal(msg.sender, proposal.sponsor, proposalId, proposalQueue.length - 1, startingPeriod);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
    }

    // NOTE: In MYSTIC, proposalIndex != proposalId
    function submitVote(uint256 proposalIndex, uint8 uintVote) external nonReentrant onlyDelegate {
        address memberAddress = memberAddressByDelegateKey[msg.sender];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        Member storage member = members[memberAddress];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(proposalIndex < proposalQueue.length, "!proposed");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        uint256 proposalId = proposalQueue[proposalIndex];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        Proposal storage proposal = proposals[proposalId];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(uintVote < 3, ">2");
        Vote vote = Vote(uintVote);
        require(getCurrentPeriod() >= proposal.startingPeriod, "pending");
        require(!hasVotingPeriodExpired(proposal.startingPeriod), "expired");
        require(proposal.votesByMember[memberAddress] == Vote.Null, "voted");
        require(vote == Vote.Yes || vote == Vote.No, "!Yes||No");
        proposal.votesByMember[memberAddress] = vote;

        if (vote == Vote.Yes) {
            proposal.yesVotes += member.shares;

            // set highest index (latest) yes vote - must be processed for member to ragequit
            if (proposalIndex > member.highestIndexYesVote) {
                member.highestIndexYesVote = proposalIndex;
            }

            // set maximum of total shares encountered at a yes vote - used to bound dilution for yes voters
            if (totalSupply > proposal.maxTotalSharesAndLootAtYesVote) {	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
                proposal.maxTotalSharesAndLootAtYesVote = totalSupply;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            }

        } else if (vote == Vote.No) {
            proposal.noVotes += member.shares;
        }
     
        // NOTE: subgraph indexes by proposalId not proposalIndex since proposalIndex isn't set until it's been sponsored but proposal is created on submission
        emit SubmitVote(proposalId, proposalIndex, msg.sender, memberAddress, uintVote);
    }

    function processProposal(uint256 proposalIndex) external nonReentrant {
        _validateProposalForProcessing(proposalIndex);
        uint256 proposalId = proposalQueue[proposalIndex];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        Proposal storage proposal = proposals[proposalId];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(proposal.flags[7] == 1, "!standard");
        proposal.flags[1] = 1; // processed
        
        bool didPass = _didPass(proposalIndex);
        // Make the proposal fail if the new total number of shares & loot exceeds the limit
        if (totalSupply.add(proposal.sharesRequested).add(proposal.lootRequested) > MAX_GUILD_BOUND) {	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            didPass = false;
        }

        // Make the proposal fail if it is requesting more tokens as payment than the available guild bank balance
        if (proposal.paymentRequested > userTokenBalances[GUILD][proposal.paymentToken]) {	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            didPass = false;
        }

        // Make the proposal fail if it would result in too many tokens with non-zero balance in guild bank
        if (proposal.tributeOffered > 0 && userTokenBalances[GUILD][proposal.tributeToken] == 0 && totalGuildBankTokens >= MAX_TOKEN_GUILDBANK_COUNT) {	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            didPass = false;
        }

        // PROPOSAL PASSED
        if (didPass) {
            proposal.flags[2] = 1; // didPass

            growGuild(proposal.applicant, proposal.sharesRequested, proposal.lootRequested);

            // if the proposal tribute is the first token of its kind to make it into the guild bank, increment total guild bank tokens
            if (userTokenBalances[GUILD][proposal.tributeToken] == 0 && proposal.tributeOffered > 0) {	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
                totalGuildBankTokens += 1;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            }

            unsafeInternalTransfer(ESCROW, GUILD, proposal.tributeToken, proposal.tributeOffered);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            unsafeInternalTransfer(GUILD, proposal.applicant, proposal.paymentToken, proposal.paymentRequested);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC

            // if the proposal spends 100% of guild bank balance for a token, decrement total guild bank tokens
            if (userTokenBalances[GUILD][proposal.paymentToken] == 0 && proposal.paymentRequested > 0) {	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
                totalGuildBankTokens -= 1;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            }

        // PROPOSAL FAILED
        } else {
            // return all tokens to the proposer (not the applicant, because funds come from proposer)
            unsafeInternalTransfer(ESCROW, proposal.proposer, proposal.tributeToken, proposal.tributeOffered);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        }

        _returnDeposit(proposal.sponsor);
        
        emit ProcessProposal(proposalIndex, proposalId, didPass);
    }
    
     function processActionProposal(uint256 proposalIndex) external nonReentrant returns (bool, bytes memory) {
        _validateProposalForProcessing(proposalIndex);
        uint256 proposalId = proposalQueue[proposalIndex];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        bytes storage action = actions[proposalId];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        Proposal storage proposal = proposals[proposalId];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(proposal.flags[6] == 1, "!action");
        proposal.flags[1] = 1; // processed

        bool didPass = _didPass(proposalIndex);
        // Make the proposal fail if it is requesting more accounted tokens than the available guild bank balance
        if (tokenWhitelist[proposal.applicant] && proposal.paymentRequested > userTokenBalances[GUILD][proposal.applicant]) {	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            didPass = false;
        }
        
        // Make the proposal fail if it is requesting more ether than the available local balance
        if (proposal.tributeOffered > address(this).balance) {
            didPass = false;
        }

        if (didPass) {
            proposal.flags[2] = 1; // didPass
            (bool success, bytes memory returnData) = proposal.applicant.call{value: proposal.tributeOffered}(action);
            if (tokenWhitelist[proposal.applicant]) {	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
                unsafeSubtractFromBalance(GUILD, proposal.applicant, proposal.paymentRequested);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
                // if the action proposal spends 100% of guild bank balance for a token, decrement total guild bank tokens
                if (userTokenBalances[GUILD][proposal.applicant] == 0 && proposal.paymentRequested > 0) {totalGuildBankTokens -= 1;}	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            }
            return (success, returnData);
        }
        
        _returnDeposit(proposal.sponsor);
        
        emit ProcessActionProposal(proposalIndex, proposalId, didPass);
    }

    function processGuildKickProposal(uint256 proposalIndex) external nonReentrant {
        _validateProposalForProcessing(proposalIndex);
        uint256 proposalId = proposalQueue[proposalIndex];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        Proposal storage proposal = proposals[proposalId];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(proposal.flags[5] == 1, "!kick");
        proposal.flags[1] = 1; // processed

        bool didPass = _didPass(proposalIndex);
        if (didPass) {
            proposal.flags[2] = 1; // didPass
            Member storage member = members[proposal.applicant];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            member.jailed = proposalIndex;
            // transfer shares to loot
            member.loot = member.loot.add(member.shares);
            totalShares = totalShares.sub(member.shares);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            totalLoot = totalLoot.add(member.shares);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            member.shares = 0; // revoke all shares
        }

        proposedToKick[proposal.applicant] = false;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC

        _returnDeposit(proposal.sponsor);
        
        emit ProcessGuildKickProposal(proposalIndex, proposalId, didPass);
    }
    
    function processWhitelistProposal(uint256 proposalIndex) external nonReentrant {
        _validateProposalForProcessing(proposalIndex);
        uint256 proposalId = proposalQueue[proposalIndex];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        Proposal storage proposal = proposals[proposalId];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(proposal.flags[4] == 1, "!whitelist");
        proposal.flags[1] = 1; // processed

        bool didPass = _didPass(proposalIndex);
        if (approvedTokens.length >= MAX_TOKEN_WHITELIST_COUNT) {	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            didPass = false;
        }

        if (didPass) {
            proposal.flags[2] = 1; // didPass
            tokenWhitelist[address(proposal.tributeToken)] = true;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            approvedTokens.push(proposal.tributeToken);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        }

        proposedToWhitelist[address(proposal.tributeToken)] = false;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC

        _returnDeposit(proposal.sponsor);
        
        emit ProcessWhitelistProposal(proposalIndex, proposalId, didPass);
    }
    
    function _didPass(uint256 proposalIndex) internal view returns (bool didPass) {
        Proposal memory proposal = proposals[proposalQueue[proposalIndex]];
        
        if (proposal.yesVotes > proposal.noVotes) {
            didPass = true;
        }
        
        // Make the proposal fail if the dilutionBound is exceeded
        if ((totalSupply.mul(dilutionBound)) < proposal.maxTotalSharesAndLootAtYesVote) {
            didPass = false;
        }

        // Make the proposal fail if the applicant is jailed
        // - for standard proposals, we don't want the applicant to get any shares/loot/payment
        // - for guild kick proposals, we should never be able to propose to kick a jailed member (or have two kick proposals active), so it doesn't matter
        if (members[proposal.applicant].jailed != 0) {
            didPass = false;
        }

        return didPass;
    }

    function _validateProposalForProcessing(uint256 proposalIndex) internal view {
        require(proposalIndex < proposalQueue.length, "!proposal");
        Proposal memory proposal = proposals[proposalQueue[proposalIndex]];
        require(getCurrentPeriod() >= proposal.startingPeriod.add(votingPeriodLength).add(gracePeriodLength), "!ready");
        require(proposal.flags[1] == 0, "processed");
        require(proposalIndex == 0 || proposals[proposalQueue[proposalIndex - 1]].flags[1] == 1, "prior !processed");
    }

    function _returnDeposit(address sponsor) internal {
        unsafeInternalTransfer(ESCROW, msg.sender, depositToken, processingReward);
        unsafeInternalTransfer(ESCROW, sponsor, depositToken, proposalDeposit - processingReward);
    }

    function ragequit(uint256 sharesToBurn, uint256 lootToBurn) external nonReentrant {
        require(members[msg.sender].exists == 1, "!member");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        _ragequit(msg.sender, sharesToBurn, lootToBurn);
    }

    function _ragequit(address memberAddress, uint256 sharesToBurn, uint256 lootToBurn) internal {
        uint256 initialTotalSharesAndLoot = totalSupply;
        Member storage member = members[memberAddress];
        require(member.shares >= sharesToBurn, "!shares");
        require(member.loot >= lootToBurn, "!loot");
        require(canRagequit(member.highestIndexYesVote), "!ragequit until highest index proposal member voted YES processes");
        uint256 sharesAndLootToBurn = sharesToBurn.add(lootToBurn);

        // burn guild token, shares & loot
        balanceOf[memberAddress] = balanceOf[memberAddress].sub(sharesAndLootToBurn);
        member.shares = member.shares.sub(sharesToBurn);
        member.loot = member.loot.sub(lootToBurn);
        totalShares = totalShares.sub(sharesToBurn);
        totalLoot = totalLoot.sub(lootToBurn);
        totalSupply = totalShares.add(totalLoot);

        for (uint256 i = 0; i < approvedTokens.length; i++) {
            uint256 amountToRagequit = fairShare(userTokenBalances[GUILD][approvedTokens[i]], sharesAndLootToBurn, initialTotalSharesAndLoot);
            if (amountToRagequit > 0) { // gas optimization to allow a higher maximum token limit
                // deliberately not using safemath here to keep overflows from preventing the function execution (which would break ragekicks)
                // if a token overflows, it is because the supply was artificially inflated to oblivion, so we probably don't care about it anyways
                userTokenBalances[GUILD][approvedTokens[i]] -= amountToRagequit;
                userTokenBalances[memberAddress][approvedTokens[i]] += amountToRagequit;
            }
        }

        emit Ragequit(memberAddress, sharesToBurn, lootToBurn);
        emit Transfer(memberAddress, address(0), sharesAndLootToBurn);
    }

    function ragekick(address memberToKick) external nonReentrant onlyDelegate {
        Member storage member = members[memberToKick];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(member.jailed != 0, "!jailed");
        require(member.loot > 0, "!loot"); // note - should be impossible for jailed member to have shares
        require(canRagequit(member.highestIndexYesVote), "!ragequit until highest index proposal member voted YES processes");
        _ragequit(memberToKick, 0, member.loot);
    }
    
    function withdrawBalance(address token, uint256 amount) external nonReentrant {
        _withdrawBalance(token, amount);
    }

    function withdrawBalances(address[] calldata tokens, uint256[] calldata amounts, bool max) external nonReentrant {
        require(tokens.length == amounts.length, "tokens != amounts");
        for (uint256 i=0; i < tokens.length; i++) {
            uint256 withdrawAmount = amounts[i];
            if (max) { // withdraw the maximum balance
                withdrawAmount = userTokenBalances[msg.sender][tokens[i]];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            }
            _withdrawBalance(tokens[i], withdrawAmount);
        }
    }
    
    function _withdrawBalance(address token, uint256 amount) internal {
        require(userTokenBalances[msg.sender][token] >= amount, "!balance");
        IERC20(token).safeTransfer(msg.sender, amount);
        unsafeSubtractFromBalance(msg.sender, token, amount);
        emit Withdraw(msg.sender, token, amount);
    }

    function collectTokens(address token) external nonReentrant onlyDelegate {
        uint256 amountToCollect = IERC20(token).balanceOf(address(this)).sub(userTokenBalances[TOTAL][token]);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        // only collect if 1) there are tokens to collect & 2) token is whitelisted
        require(amountToCollect > 0, "!amount");
        require(tokenWhitelist[token], "!whitelisted");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        
        if (userTokenBalances[GUILD][token] == 0 && totalGuildBankTokens < MAX_TOKEN_GUILDBANK_COUNT) {totalGuildBankTokens += 1;}	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        unsafeAddToBalance(GUILD, token, amountToCollect);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC

        emit TokensCollected(token, amountToCollect);
    }

    // NOTE: requires that delegate key which sent the original proposal cancels, msg.sender = proposal.proposer
    function cancelProposal(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(proposal.flags[0] == 0, "sponsored");
        require(proposal.flags[3] == 0, "cancelled");
        require(msg.sender == proposal.proposer, "!proposer");
        proposal.flags[3] = 1; // cancelled
       
        unsafeInternalTransfer(ESCROW, proposal.proposer, proposal.tributeToken, proposal.tributeOffered);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        
        emit CancelProposal(proposalId, msg.sender);
    }

    function updateDelegateKey(address newDelegateKey) external nonReentrant {
        require(members[msg.sender].shares > 0, "!shareholder");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(newDelegateKey != address(0), "newDelegateKey = 0");

        // skip checks if member is setting the delegate key to their member address
        if (newDelegateKey != msg.sender) {
            require(members[newDelegateKey].exists == 0, "!overwrite members");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
            require(members[memberAddressByDelegateKey[newDelegateKey]].exists == 0, "!overwrite keys");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        }

        Member storage member = members[msg.sender];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        memberAddressByDelegateKey[member.delegateKey] = address(0);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        memberAddressByDelegateKey[newDelegateKey] = msg.sender;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        member.delegateKey = newDelegateKey;

        emit UpdateDelegateKey(msg.sender, newDelegateKey);
    }
    
    // can only ragequit if the latest proposal you voted YES on has been processed
    function canRagequit(uint256 highestIndexYesVote) public view returns (bool) {
        require(highestIndexYesVote < proposalQueue.length, "!proposal");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        return proposals[proposalQueue[highestIndexYesVote]].flags[1] == 1;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
    }

    function hasVotingPeriodExpired(uint256 startingPeriod) public view returns (bool) {
        return getCurrentPeriod() >= startingPeriod.add(votingPeriodLength);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
    }
    
    /***************
    GETTER FUNCTIONS
    ***************/
    function max(uint256 x, uint256 y) internal pure returns (uint256) {
        return x >= y ? x : y;
    }
    
    function getCurrentPeriod() public view returns (uint256) {
        return now.sub(summoningTime).div(periodDuration);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
    }
    
    function getMemberProposalVote(address memberAddress, uint256 proposalIndex) external view returns (Vote) {
        require(members[memberAddress].exists == 1, "!member");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        require(proposalIndex < proposalQueue.length, "!proposed");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        return proposals[proposalQueue[proposalIndex]].votesByMember[memberAddress];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
    }

    function getProposalFlags(uint256 proposalId) external view returns (uint8[8] memory) {
        return proposals[proposalId].flags;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
    }
    
    function getProposalQueueLength() external view returns (uint256) {
        return proposalQueue.length;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
    }
    
    function getTokenCount() external view returns (uint256) {
        return approvedTokens.length;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
    }

    function getUserTokenBalance(address user, address token) external view returns (uint256) {
        return userTokenBalances[user][token];	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
    }
    
    /***************
    HELPER FUNCTIONS
    ***************/
    receive() external payable {}
    
    function fairShare(uint256 balance, uint256 shares, uint256 totalSharesAndLoot) internal pure returns (uint256) {
        require(totalSharesAndLoot != 0);

        if (balance == 0) { return 0; }

        uint256 prod = balance * shares;

        if (prod / balance == shares) { // no overflow in multiplication above?
            return prod / totalSharesAndLoot;
        }

        return (balance / totalSharesAndLoot) * shares;
    }
    
    function growGuild(address account, uint256 shares, uint256 loot) internal {
        // if the account is already a member, add to their existing shares & loot
        if (members[account].exists == 1) {
            members[account].shares = members[account].shares.add(shares);
            members[account].loot = members[account].loot.add(loot);

        // if the account is a new member, create a new record for them
        } else {
            // if new member is already taken by a member's delegateKey, reset it to their member address
            if (members[memberAddressByDelegateKey[account]].exists == 1) {
                address memberToOverride = memberAddressByDelegateKey[account];
                memberAddressByDelegateKey[memberToOverride] = memberToOverride;
                members[memberToOverride].delegateKey = memberToOverride;
            }
        
            members[account] = Member({
                delegateKey : account,
                exists : 1, // 'true'
                shares : shares,
                loot : loot.add(members[account].loot), // take into account loot from pre-membership transfers
                highestIndexYesVote : 0,
                jailed : 0
            });
            memberAddressByDelegateKey[account] = account;
        }
        
        uint256 sharesAndLoot = shares.add(loot);
        // mint new guild token, update total shares & loot 
        balanceOf[account] = balanceOf[account].add(sharesAndLoot);
        totalShares = totalShares.add(shares);
        totalLoot = totalLoot.add(loot);
        totalSupply = totalShares.add(totalLoot);
        
        emit Transfer(address(0), account, sharesAndLoot);
    }
    
    function unsafeAddToBalance(address user, address token, uint256 amount) internal {
        userTokenBalances[user][token] += amount;
        userTokenBalances[TOTAL][token] += amount;
    }
    
    function unsafeInternalTransfer(address from, address to, address token, uint256 amount) internal {
        unsafeSubtractFromBalance(from, token, amount);
        unsafeAddToBalance(to, token, amount);
    }

    function unsafeSubtractFromBalance(address user, address token, uint256 amount) internal {
        userTokenBalances[user][token] -= amount;
        userTokenBalances[TOTAL][token] -= amount;
    }
    
    /********************
    GUILD TOKEN FUNCTIONS
    ********************/
    function approve(address spender, uint256 amount) external returns (bool) {
        require(amount == 0 || allowance[msg.sender][spender] == 0);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        allowance[msg.sender][spender] = amount;	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function convertSharesToLoot(uint256 sharesToLoot) external nonReentrant {
        members[msg.sender].shares = members[msg.sender].shares.sub(sharesToLoot);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        members[msg.sender].loot = members[msg.sender].loot.add(sharesToLoot);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        totalShares = totalShares.sub(sharesToLoot);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        totalLoot = totalLoot.add(sharesToLoot);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        emit ConvertSharesToLoot(msg.sender, sharesToLoot);
    }
    
    function stakeTokenForShares(uint256 amount) external nonReentrant {
        IERC20(stakeToken).safeTransferFrom(msg.sender, address(this), amount); // deposit stake token & claim shares (1:1)	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        growGuild(msg.sender, amount, 0);
        require(totalSupply <= MAX_GUILD_BOUND, "guild maxed");	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        emit StakeTokenForShares(msg.sender, amount);
    }

    function transfer(address recipient, uint256 lootToTransfer) external returns (bool) {
        members[msg.sender].loot = members[msg.sender].loot.sub(lootToTransfer);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        members[recipient].loot = members[recipient].loot.add(lootToTransfer);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        balanceOf[msg.sender] = balanceOf[msg.sender].sub(lootToTransfer);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        balanceOf[recipient] = balanceOf[recipient].add(lootToTransfer);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        emit Transfer(msg.sender, recipient, lootToTransfer);
        return true;
    }
    
    function transferFrom(address sender, address recipient, uint256 lootToTransfer) external returns (bool) {
        allowance[sender][msg.sender] = allowance[sender][msg.sender].sub(lootToTransfer);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        members[sender].loot = members[sender].loot.sub(lootToTransfer);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        members[recipient].loot = members[recipient].loot.add(lootToTransfer);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        balanceOf[sender] = balanceOf[sender].sub(lootToTransfer);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        balanceOf[recipient] = balanceOf[recipient].add(lootToTransfer);	//inject NONPUBLIC VAR ACCESSD BY PUBLIC FUNC
        emit Transfer(sender, recipient, lootToTransfer);
        return true;
    }
}