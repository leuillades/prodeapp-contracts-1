// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@reality.eth/contracts/development/contracts/RealityETH-3.0.sol";
import "./IERC2981.sol";

// If a version for mainnet was needed, gas could be saved by storing merkle hashes instead of all the questions and bets.

interface ITournamentFactory {
    function askRealitio(
        Tournament.RealitioQuestion memory questionsData,
        Tournament.RealitioSetup memory realitioSetup
    ) external returns(bytes32 questionID);
}

contract Tournament is ERC721, IERC2981 {
    struct RealitioQuestion {
        uint256 templateID;
        string question;
        uint32 openingTS;
    }

    struct RealitioSetup {
        address arbitrator;
        uint32 timeout;
        uint256 minBond;
    }

    struct TournamentInfo {
        string tournamentName;
        string tournamentSymbol;
        string tournamentUri;
    }

    struct Result {
        uint256 tokenID;
        uint248 points;
        bool claimed;
    }

    struct BetData {
        uint256 count;
        bytes32[] predictions;
    }

    uint256 public constant DIVISOR = 10000;

    TournamentInfo private tournamentInfo;
    address public manager;
    RealityETH_v3_0 public realitio;
    uint256 public nextTokenID;
    bool public initialized;
    uint256 public resultSubmissionPeriodStart;
    uint256 public price;
    uint256 public closingTime;
    uint256 public submissionTimeout;
    uint256 public managementFee;
    uint256 public totalPrize;

    bytes32[] public questionIDs;
    uint16[] public prizeWeights;
    mapping(bytes32 => BetData) public bets; // bets[tokenHash]
    mapping(uint256 => Result) public ranking; // ranking[index]
    mapping(uint256 => bytes32) public tokenIDtoTokenHash;

    event FundingReceived(
        address indexed _funder,
        uint256 _amount,
        string _message
    );

    event PlaceBet(
        address indexed _player,
        uint256 indexed tokenID,
        bytes32 indexed _tokenHash,
        bytes32[] _predictions
    );

    event BetReward(uint256 indexed _tokenID, uint256 _reward);

    event RankingUpdated(uint256 indexed _tokenID, uint256 _points, uint256 _index);

    event ProviderReward(address indexed _provider, uint256 _providerReward);

    event ManagementReward(address indexed _manager, uint256 _managementReward);

    event QuestionsRegistered(bytes32[] _questionIDs);

    event Prizes(uint16[] _prizes);

    constructor() ERC721("", "") {}

    function initialize(
        TournamentInfo memory _tournamentInfo,
        address _realityETH,
        uint256 _closingTime,
        uint256 _price,
        uint256 _submissionTimeout,
        uint256 _managementFee,
        address _manager,
        RealitioSetup memory _realitioSetup,
        RealitioQuestion[] memory _questionsData,
        uint16[] memory _prizeWeights
    ) external {
        require(!initialized, "Already initialized.");
        require(_managementFee < DIVISOR, "Management fee too big");

        tournamentInfo = _tournamentInfo;
        realitio = RealityETH_v3_0(_realityETH);
        closingTime = _closingTime;
        price = _price;
        submissionTimeout = _submissionTimeout;
        managementFee = _managementFee;
        manager = _manager;

        bytes32 previousQuestionID = bytes32(0);
        for (uint256 i = 0; i < _questionsData.length; i++) {
            require(_questionsData[i].openingTS > _closingTime, "Cannot open question in the betting period");
            // Chequear que vaya en orden alfabetico como en el governor.
            bytes32 questionID = ITournamentFactory(msg.sender).askRealitio(
                _questionsData[i],
                _realitioSetup
            );
            require(questionID >= previousQuestionID, "Questions are in incorrect order");
            previousQuestionID = questionID;
            questionIDs.push(questionID);
        }

        uint256 sumWeights;
        for (uint256 i = 0; i < _prizeWeights.length; i++) {
            sumWeights += uint256(_prizeWeights[i]);
        }
        require(sumWeights == DIVISOR, "Invalid weights");
        prizeWeights = _prizeWeights;

        initialized = true;
        emit QuestionsRegistered(questionIDs); 
        emit Prizes(_prizeWeights);
    }

    /** @dev Places a bet by providing predictions to each question. A bet NFT is minted.
     *  @param _provider Address to which to send a fee. If 0x0, it's ignored. Meant to be used by front-end providers.
     *  @param _results Answer predictions to the questions asked in Realitio.
     *  @return the minted token id.
     */
    function placeBet(address payable _provider, bytes32[] calldata _results)
        external
        payable
        returns (uint256)
    {
        require(initialized, "Not initialized");
        require(_results.length == questionIDs.length, "Results mismatch");
        require(msg.value >= price, "Not enough funds");
        require(block.timestamp < closingTime, "Bets not allowed");

        if (_provider != payable(0x0)) {
            uint256 providerReward = (msg.value * managementFee) / DIVISOR;
            _provider.send(providerReward);
            emit ProviderReward(_provider, providerReward);
        }

        bytes32 tokenHash = keccak256(abi.encodePacked(_results));
        tokenIDtoTokenHash[nextTokenID] = tokenHash;
        BetData storage bet = bets[tokenHash];
        if (bet.count == 0) bet.predictions = _results;
        bet.count += 1;

        _mint(msg.sender, nextTokenID);
        emit PlaceBet(msg.sender, nextTokenID, tokenHash, _results);

        return nextTokenID++;
    }

    /** @dev Passes the contract state to the submission period if all the Realitio results are available.
     *  The management fee is paid to the manager address.
     */
    function registerAvailabilityOfResults() external {
        require(block.timestamp > closingTime, "Bets ongoing");
        require(resultSubmissionPeriodStart == 0, "Results already available");

        for (uint256 i = 0; i < questionIDs.length; i++) {
            realitio.resultForOnceSettled(questionIDs[i]); // Reverts if not finalized.
        }

        resultSubmissionPeriodStart = block.timestamp;
        uint256 poolBalance = address(this).balance;
        uint256 managementReward = (poolBalance * managementFee) / DIVISOR;
        payable(manager).send(managementReward);
        totalPrize = poolBalance - managementReward;

        emit ManagementReward(manager, managementReward);
    }

    /** @dev Registers the points obtained by a bet after the results are known. Ranking should be filled
     *  in descending order. Bets which points were not registered cannot claimed rewards even if they
     *  got more points than the ones registered.
     *  @param _tokenID The token id of the bet which points are going to be registered.
     *  @param _rankIndex The alleged ranking position the bet belongs to.
     */
    function registerPoints(uint256 _tokenID, uint256 _rankIndex) external {
        require(resultSubmissionPeriodStart != 0, "Not in submission period");
        require(
            block.timestamp < resultSubmissionPeriodStart + submissionTimeout,
            "Submission period over"
        );
        require(_exists(_tokenID), "Token does not exist");

        bytes32[] memory predictions = bets[tokenIDtoTokenHash[_tokenID]].predictions;
        uint248 totalPoints;
        for (uint256 i = 0; i < questionIDs.length; i++) {
            if (predictions[i] == realitio.resultForOnceSettled(questionIDs[i])) {
                totalPoints += 1;
            }
        }

        require(totalPoints > 0, "You are not a winner");
        // This ensures that ranking[N].points >= ranking[N+1].points always
        require(
            _rankIndex == 0 || totalPoints < ranking[_rankIndex - 1].points, 
            "Invalid ranking index"
        );
        if (totalPoints > ranking[_rankIndex].points) {
            ranking[_rankIndex].tokenID = _tokenID;
            ranking[_rankIndex].points = totalPoints;
            emit RankingUpdated(_tokenID, totalPoints, _rankIndex);
        } else if (ranking[_rankIndex].points == totalPoints) {
            require(ranking[_rankIndex].tokenID != _tokenID, "Token already registered");
            uint256 i = 1;
            while (ranking[_rankIndex + i].points == totalPoints) {
                require(
                    ranking[_rankIndex + i].tokenID != _tokenID,
                    "Token already registered"
                );
                i += 1;
            }
            ranking[_rankIndex + i].tokenID = _tokenID;
            ranking[_rankIndex + i].points = totalPoints;
            emit RankingUpdated(_tokenID, totalPoints, _rankIndex + i);
        }
    }

    /** @dev Sends a prize to the token holder if applicable.
     *  @param _rankIndex The ranking position of the bet which reward is being claimed.
     */
    function claimRewards(uint256 _rankIndex) external {
        require(resultSubmissionPeriodStart != 0, "Not in claim period");
        require(
            block.timestamp > resultSubmissionPeriodStart + submissionTimeout,
            "Submission period not over"
        );
        require(!ranking[_rankIndex].claimed, "Already claimed");

        uint248 points = ranking[_rankIndex].points;
        uint256 numberOfPrizes = prizeWeights.length;
        uint256 rankingPosition = 0;
        uint256 cumWeigths = 0;
        uint256 sharedBetween = 0;

        // Infinite loop if ranking[_rankIndex].points = 0.
        while (true) {
            if (ranking[rankingPosition].points < points) break;
            if (ranking[rankingPosition].points == points) {
                if (rankingPosition < numberOfPrizes) {
                    cumWeigths += prizeWeights[rankingPosition];
                }
                sharedBetween += 1;
            }
            rankingPosition += 1;
        }

        uint256 reward = (totalPrize * cumWeigths) / (DIVISOR * sharedBetween);
        ranking[_rankIndex].claimed = true;
        payable(ownerOf(ranking[_rankIndex].tokenID)).transfer(reward);
        emit BetReward(ranking[_rankIndex].tokenID, reward);
    }

    /** @dev Edge case in which no one won or winners were not registered. All players who own a token
     *  are reimburse proportionally (management fee was discounted). Tokens are burnt.
     *  @param _tokenID The token id.
     */
    function reimbursePlayer(uint256 _tokenID) external {
        require(resultSubmissionPeriodStart != 0, "Not in claim period");
        require(
            block.timestamp > resultSubmissionPeriodStart + submissionTimeout,
            "Submission period not over"
        );
        require(ranking[0].points == 0, "Can't reimburse if there are winners");

        uint256 reimbursement = totalPrize / nextTokenID;
        address player = ownerOf(_tokenID);
        _burn(_tokenID); // Can only be reimbursed once.
        payable(player).transfer(reimbursement);
    }

    /** @dev Edge case in which there is a winner but one or more prizes are vacant.
     *  Vacant prizes are distributed equally among registered winner/s.
     */
    function distributeRemainingPrizes() external {
        require(resultSubmissionPeriodStart != 0, "Not in claim period");
        require(
            block.timestamp > resultSubmissionPeriodStart + submissionTimeout,
            "Submission period not over"
        );
        require(ranking[0].points > 0, "No winners");

        uint256 cumWeigths = 0;
        uint256 nWinners = 0;
        for (uint256 i = 0; i < prizeWeights.length; i++) {
            if (ranking[i].points == 0) {
                if (nWinners == 0) nWinners = i;
                require(!ranking[i].claimed, "Already claimed");
                ranking[i].claimed = true;
                cumWeigths += prizeWeights[i];
            }
        }

        require(cumWeigths > 0, "No vacant prizes");
        uint256 vacantPrize = (totalPrize * cumWeigths) / (DIVISOR * nWinners);
        for (uint256 rank = 0; rank < nWinners; rank++) {
            payable(ownerOf(ranking[rank].tokenID)).send(vacantPrize);
            emit BetReward(ranking[rank].tokenID, vacantPrize);
        }
    }

    /** @dev Increases the balance of the pool without participating. Only callable during the betting period.
     *  @param _message The message to publish.
     */
    function fundPool(string calldata _message) external payable {
        require(resultSubmissionPeriodStart == 0, "Results already available");
        require(msg.value > price, "Insufficient funds");
        emit FundingReceived(msg.sender, msg.value, _message);
    }

    /**
     * @dev See {IERC721Metadata-name}.
     */
    function name() public view override returns (string memory) {
        return tournamentInfo.tournamentName;
    }

    /**
     * @dev See {IERC721Metadata-symbol}.
     */
    function symbol() public view override returns (string memory) {
        return tournamentInfo.tournamentSymbol;
    }

    /**
     * @dev Base URI for computing {tokenURI}. If set, the resulting URI for each
     * token will be the concatenation of the `baseURI` and the `tokenId`. Empty
     * by default, can be overriden in child contracts.
     */
    function _baseURI() internal view override returns (string memory) {
        return tournamentInfo.tournamentUri;
    }

    function baseURI() external view returns (string memory) {
        return _baseURI();
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721)
        returns (bool)
    {
        return
            interfaceId == type(IERC2981).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function royaltyInfo(uint256, uint256 _salePrice)
        external
        view
        override(IERC2981)
        returns (address receiver, uint256 royaltyAmount)
    {
        receiver = manager;
        // royalty fee = management fee
        royaltyAmount = (_salePrice * managementFee) / DIVISOR;
    }
}
