// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "../lib/BLS12381.sol";
import "../../threshold/IAccessControlApplication.sol";

/**
* @title Coordinator
* @notice Coordination layer for DKG-TDec
*/
contract Coordinator is AccessControl {

    // Ritual
    event StartRitual(uint32 indexed ritualId, address indexed initiator, address[] participants);
    event StartAggregationRound(uint32 indexed ritualId);
    // TODO: Do we want the public key here? If so, we want 2 events or do we reuse this event?
    event EndRitual(uint32 indexed ritualId, bool successful);

    // Node
    event TranscriptPosted(uint32 indexed ritualId, address indexed node, bytes32 transcriptDigest);
    event AggregationPosted(uint32 indexed ritualId, address indexed node, bytes32 aggregatedTranscriptDigest);

    // Admin
    event TimeoutChanged(uint32 oldTimeout, uint32 newTimeout);
    event MaxDkgSizeChanged(uint16 oldSize, uint16 newSize);

    enum RitualState {
        NON_INITIATED,
        AWAITING_TRANSCRIPTS,
        AWAITING_AGGREGATIONS,
        TIMEOUT,
        INVALID,
        FINALIZED
    }

    struct Participant {
        address provider;
        bool aggregated;
        bytes transcript;  // TODO: Consider event processing complexity vs storage cost
        bytes decryptionRequestStaticKey;
    }

    // TODO: Optimize layout
    struct Ritual {
        address initiator;
        uint32 initTimestamp;
        uint32 endTimestamp;
        uint16 totalTranscripts;
        uint16 totalAggregations;
        address authority;
        uint16 dkgSize;
        bool aggregationMismatch;
        BLS12381.G1Point publicKey;
        bytes aggregatedTranscript;
        Participant[] participant;
    }

    bytes32 public constant PARAMETER_ADMIN_ROLE = keccak256("PARAMETER_ADMIN_ROLE");
    bytes32 public constant INITIATOR_ROLE = keccak256("INITIATOR_ROLE");

    IAccessControlApplication public immutable application;

    Ritual[] public rituals;
    uint32 public timeout;
    uint16 public maxDkgSize;
    bool public isInitiationRegulated;

    constructor(
        IAccessControlApplication app,
        uint32 _timeout,
        uint16 _maxDkgSize,
        address parameterAdmin,
        address[] initiators // change to a setter function instead?
    ) {
        application = app;
        timeout = _timeout;
        maxDkgSize = _maxDkgSize;

        _grantRole(PARAMETER_ADMIN_ROLE, parameterAdmin);
        for(uint i = 0; i < initiators.length; i++){
            _grantRole(INITIATOR_ROLE, initiators[i]);
        }
        isInitiationRegulated = initiators.length == 0;
    }

    function getRitualState(uint256 ritualId) external view returns (RitualState){
        // TODO: restrict to ritualID < rituals.length?
        return getRitualState(rituals[ritualId]);
    }

    function getRitualState(Ritual storage ritual) internal view returns (RitualState){
        uint32 t0 = ritual.initTimestamp;
        uint32 deadline = t0 + timeout;
        if (t0 == 0){
            return RitualState.NON_INITIATED;
        } else if (ritual.totalAggregations == ritual.dkgSize) {
            return RitualState.FINALIZED;
        } else if (ritual.aggregationMismatch){
            return RitualState.INVALID;
        } else if (block.timestamp > deadline){
            return RitualState.TIMEOUT;
        } else if (ritual.totalTranscripts < ritual.dkgSize) {
            return RitualState.AWAITING_TRANSCRIPTS;
        } else if (ritual.totalAggregations < ritual.dkgSize) {
            return RitualState.AWAITING_AGGREGATIONS;
        } else {
            // TODO: Is it possible to reach this state?
            //   - No public key
            //   - All transcripts and all aggregations
            //   - Still within the deadline
        }
    }


    function setTimeout(uint32 newTimeout) external onlyRole(PARAMETER_ADMIN_ROLE) {
        emit TimeoutChanged(timeout, newTimeout);
        timeout = newTimeout;
    }

    function setMaxDkgSize(uint16 newSize) external onlyRole(PARAMETER_ADMIN_ROLE) {
        emit MaxDkgSizeChanged(maxDkgSize, newSize);
        maxDkgSize = newSize;
    }

    function numberOfRituals() external view returns(uint256) {
        return rituals.length;
    }

    function getParticipants(uint32 ritualId) external view returns(Participant[] memory) {
        Ritual storage ritual = rituals[ritualId];
        return ritual.participant;
    }

    function initiateRitual(
        address[] calldata providers,
        address authority,
        uint32 duration
    ) external returns (uint32) {
        require(
            !isInitiatiorRegulated || hasRole(INITIATOR_ROLE, msg.sender),
            "Sender can't initiate ritual"
        );
        // TODO: Validate service fees, expiration dates, threshold
        uint256 length = providers.length;
        require(2 <= length && length <= maxDkgSize, "Invalid number of nodes");
        require(duration > 0, "Invalid ritual duration");  // TODO: We probably want to restrict it more

        uint32 id = uint32(rituals.length);
        Ritual storage ritual = rituals.push();
        ritual.initiator = msg.sender;
        ritual.authority = authority;
        ritual.dkgSize = uint32(length);
        ritual.initTimestamp = uint32(block.timestamp);
        ritual.endTimestamp = ritual.initTimestamp + duration;

        address previous = address(0);
        for(uint256 i=0; i < length; i++){
            Participant storage newParticipant = ritual.participant.push();
            address current = providers[i];
            require(previous < current, "Providers must be sorted");
            // TODO: Improve check for eligible nodes (staking, etc) - nucypher#3109
            // TODO: Change check to isAuthorized(), without amount
            require(
                application.authorizedStake(current) > 0, 
                "Not enough authorization"
            );
            newParticipant.provider = current;
            previous = current;
        }
        
        // TODO: Include cohort fingerprint in StartRitual event?
        emit StartRitual(id, ritual.authority, providers);
        return id;
    }

    function cohortFingerprint(address[] calldata nodes) public pure returns(bytes32) {
        return keccak256(abi.encode(nodes));
    }

    function postTranscript(uint32 ritualId, bytes calldata transcript) external {
        Ritual storage ritual = rituals[ritualId];
        require(
            getRitualState(ritual) == RitualState.AWAITING_TRANSCRIPTS,
            "Not waiting for transcripts"
        );

        address provider = application.stakingProviderFromOperator(msg.sender);
        Participant storage participant = getParticipantFromProvider(ritual, provider);

        require(
            application.authorizedStake(provider) > 0,
            "Not enough authorization"
        );
        require(
            participant.transcript.length == 0,
            "Node already posted transcript"
        );

        // TODO: Validate transcript size based on dkg size

        // Nodes commit to their transcript
        bytes32 transcriptDigest = keccak256(transcript);
        participant.transcript = transcript;  // TODO: ???
        emit TranscriptPosted(ritualId, provider, transcriptDigest);
        ritual.totalTranscripts++;

        // end round
        if (ritual.totalTranscripts == ritual.dkgSize){
            emit StartAggregationRound(ritualId);
        }
    }

    function postAggregation(
        uint32 ritualId,
        bytes calldata aggregatedTranscript,
        BLS12381.G1Point calldata publicKey,
        bytes calldata decryptionRequestStaticKey
    ) external {
        Ritual storage ritual = rituals[ritualId];
        require(
            getRitualState(ritual) == RitualState.AWAITING_AGGREGATIONS,
            "Not waiting for aggregations"
        );

        address provider = application.stakingProviderFromOperator(msg.sender);
        Participant storage participant = getParticipantFromProvider(ritual, provider);
        require(
            application.authorizedStake(provider) > 0,
            "Not enough authorization"
        );

        require(
            !participant.aggregated,
            "Node already posted aggregation"
        );

        require(
            participant.decryptionRequestStaticKey.length == 0,
            "Node already provided request encrypting key"
        );

        // nodes commit to their aggregation result
        bytes32 aggregatedTranscriptDigest = keccak256(aggregatedTranscript);
        participant.aggregated = true;
        participant.decryptionRequestStaticKey = decryptionRequestStaticKey;  // TODO validation?
        emit AggregationPosted(ritualId, provider, aggregatedTranscriptDigest);

        if (ritual.aggregatedTranscript.length == 0) {
            ritual.aggregatedTranscript = aggregatedTranscript;
            ritual.publicKey = publicKey;
        } else if (
            !BLS12381.eqG1Point(ritual.publicKey, publicKey) || 
            keccak256(ritual.aggregatedTranscript) != aggregatedTranscriptDigest
        ){
            ritual.aggregationMismatch = true;
            emit EndRitual({
                ritualId: ritualId,
                successful: false
            });
            // TODO: Consider freeing ritual storage
            return;
        }

        ritual.totalAggregations++;
        if (ritual.totalAggregations == ritual.dkgSize){
            emit EndRitual({
                ritualId: ritualId,
                successful: true
            });
            // TODO: Consider including public key in event
        }
    }

    function getParticipantFromProvider(
        Ritual storage ritual,
        address provider
    ) internal view returns (Participant storage) {
        uint length = ritual.participant.length;
        // TODO: Improve with binary search
        for(uint i = 0; i < length; i++){
            Participant storage participant = ritual.participant[i];
            if(participant.provider == provider){
                return participant;
            }
        }
        revert("Participant not part of ritual");
    }

    function getParticipantFromProvider(
        uint256 ritualID,
        address provider
    ) external view returns (Participant memory) {
        return getParticipantFromProvider(rituals[ritualID], provider);
    }
}
