// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title HourLoom
 * @notice A time bank on BOT Chain. The unit of account is an hour of
 *         somebody's work, not a token.
 *
 * Members join by posting a refundable bond. When you help someone, you log
 * the time; **they** confirm it, and the credit moves from their balance to
 * yours. Nothing can be fabricated, because the only person who can move
 * credit out of an account is its owner.
 *
 * Balances are signed. A member may go up to `debtFloorMinutes` into the red,
 * which is what lets a newcomer receive help before they have given any. The
 * floor is the whole risk model: the bond is forfeited to nobody and the debt
 * is social, so the floor is what stops it becoming an unbounded IOU.
 *
 * Note the one invariant: every confirmation moves the same number of minutes
 * out of one account and into another, so the sum of all balances is always
 * zero. The contract mints nothing.
 */
contract HourLoom is Ownable, Pausable, ReentrancyGuard {
    enum EntryStatus {
        Pending,
        Confirmed,
        Declined,
        Cancelled
    }

    struct Member {
        bool active;
        uint64 joinedAt;
        int256 balanceMinutes;
        uint32 givenCount;
        uint32 receivedCount;
        uint256 bond;
        string handle;
    }

    struct Entry {
        address from;
        address to;
        uint32 minutesGiven;
        EntryStatus status;
        uint64 createdAt;
        string memo;
    }

    struct Request {
        address who;
        uint32 minutesWanted;
        bool open;
        uint64 createdAt;
        string memo;
    }

    uint32 public constant MIN_MINUTES = 15;
    uint32 public constant MAX_MINUTES = 1440;
    uint256 public constant MAX_MEMO = 96;
    uint256 public constant MAX_HANDLE = 32;

    /// @notice Refundable on leaving with a square balance.
    uint256 public joinBond = 0.02 ether;
    /// @notice Non-refundable, goes to the protocol.
    uint256 public joinFee = 0.002 ether;
    /// @notice How far into the red a member may go, in minutes.
    int256 public debtFloorMinutes = -1440;

    uint256 public accumulatedFees;
    /// @notice Bonds held for active members.
    uint256 public bondedTotal;
    uint32 public memberCount;

    mapping(address => Member) private _members;
    Entry[] private _entries;
    Request[] private _requests;
    mapping(address => uint256[]) private _given;
    mapping(address => uint256[]) private _received;
    address[] private _roster;
    mapping(address => bool) private _onRoster;

    event Joined(address indexed who, string handle, uint256 bond, uint256 fee);
    event Left(address indexed who, uint256 bondReturned);
    event HoursLogged(uint256 indexed entryId, address indexed from, address indexed to, uint32 minutesGiven);
    event EntryConfirmed(uint256 indexed entryId, address indexed from, address indexed to, uint32 minutesGiven);
    event EntryDeclined(uint256 indexed entryId);
    event EntryCancelled(uint256 indexed entryId);
    event RequestPosted(uint256 indexed requestId, address indexed who, uint32 minutesWanted);
    event RequestClosed(uint256 indexed requestId);
    event TermsUpdated(uint256 joinBond, uint256 joinFee, int256 debtFloorMinutes);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {}

    // ------------------------------------------------------------ joining

    function join(string calldata handle) external payable whenNotPaused {
        require(!_members[msg.sender].active, "already a member");
        require(bytes(handle).length > 0 && bytes(handle).length <= MAX_HANDLE, "bad handle");
        require(msg.value == joinBond + joinFee, "wrong amount");

        // A returning member keeps the balance and history they left with.
        Member storage m = _members[msg.sender];
        m.active = true;
        m.joinedAt = uint64(block.timestamp);
        m.bond = joinBond;
        m.handle = handle;

        if (!_onRoster[msg.sender]) {
            _onRoster[msg.sender] = true;
            _roster.push(msg.sender);
        }

        bondedTotal += joinBond;
        accumulatedFees += joinFee;
        unchecked {
            memberCount += 1;
        }
        emit Joined(msg.sender, handle, joinBond, joinFee);
    }

    /**
     * @notice Leave and take the bond back.
     * @dev Only with a square balance. Owing time and walking away with the
     *      bond is exactly what the bond is there to discourage.
     */
    function leave() external nonReentrant {
        Member storage m = _members[msg.sender];
        require(m.active, "not a member");
        require(m.balanceMinutes == 0, "settle your balance first");

        uint256 bond = m.bond;
        m.active = false;
        m.bond = 0;
        bondedTotal -= bond;
        unchecked {
            memberCount -= 1;
        }
        emit Left(msg.sender, bond);

        if (bond > 0) {
            (bool ok, ) = payable(msg.sender).call{value: bond}("");
            require(ok, "bond return failed");
        }
    }

    // ------------------------------------------------------------- ledger

    /// @notice Log time you gave to another member. They must confirm it.
    function logHours(address to, uint32 minutesGiven, string calldata memo)
        external
        whenNotPaused
        returns (uint256 entryId)
    {
        require(_members[msg.sender].active, "not a member");
        require(_members[to].active, "they are not a member");
        require(to != msg.sender, "cannot log against yourself");
        require(minutesGiven >= MIN_MINUTES && minutesGiven <= MAX_MINUTES, "bad duration");
        require(bytes(memo).length <= MAX_MEMO, "memo too long");

        entryId = _entries.length;
        _entries.push(
            Entry({
                from: msg.sender,
                to: to,
                minutesGiven: minutesGiven,
                status: EntryStatus.Pending,
                createdAt: uint64(block.timestamp),
                memo: memo
            })
        );
        _given[msg.sender].push(entryId);
        _received[to].push(entryId);
        emit HoursLogged(entryId, msg.sender, to, minutesGiven);
    }

    /**
     * @notice Confirm time somebody gave you. This is the only call that moves
     *         credit, and only the person being debited can make it.
     * @dev Allowed while paused — a member should always be able to settle up.
     */
    function confirmEntry(uint256 entryId) external {
        Entry storage e = _entry(entryId);
        require(e.to == msg.sender, "not yours to confirm");
        require(e.status == EntryStatus.Pending, "not pending");

        Member storage giver = _members[e.from];
        Member storage taker = _members[msg.sender];
        require(giver.active && taker.active, "both must be members");

        int256 after_ = taker.balanceMinutes - int256(uint256(e.minutesGiven));
        require(after_ >= debtFloorMinutes, "would pass the debt floor");

        e.status = EntryStatus.Confirmed;
        taker.balanceMinutes = after_;
        giver.balanceMinutes += int256(uint256(e.minutesGiven));
        unchecked {
            giver.givenCount += 1;
            taker.receivedCount += 1;
        }
        emit EntryConfirmed(entryId, e.from, msg.sender, e.minutesGiven);
    }

    function declineEntry(uint256 entryId) external {
        Entry storage e = _entry(entryId);
        require(e.to == msg.sender, "not yours to decline");
        require(e.status == EntryStatus.Pending, "not pending");
        e.status = EntryStatus.Declined;
        emit EntryDeclined(entryId);
    }

    function cancelEntry(uint256 entryId) external {
        Entry storage e = _entry(entryId);
        require(e.from == msg.sender, "not yours to cancel");
        require(e.status == EntryStatus.Pending, "not pending");
        e.status = EntryStatus.Cancelled;
        emit EntryCancelled(entryId);
    }

    // ------------------------------------------------------------ requests

    function postRequest(uint32 minutesWanted, string calldata memo)
        external
        whenNotPaused
        returns (uint256 requestId)
    {
        require(_members[msg.sender].active, "not a member");
        require(minutesWanted >= MIN_MINUTES && minutesWanted <= MAX_MINUTES, "bad duration");
        require(bytes(memo).length > 0 && bytes(memo).length <= MAX_MEMO, "bad memo");

        requestId = _requests.length;
        _requests.push(
            Request({
                who: msg.sender,
                minutesWanted: minutesWanted,
                open: true,
                createdAt: uint64(block.timestamp),
                memo: memo
            })
        );
        emit RequestPosted(requestId, msg.sender, minutesWanted);
    }

    function closeRequest(uint256 requestId) external {
        require(requestId < _requests.length, "no such request");
        Request storage r = _requests[requestId];
        require(r.who == msg.sender, "not yours");
        require(r.open, "already closed");
        r.open = false;
        emit RequestClosed(requestId);
    }

    // --------------------------------------------------------------- views

    function getMember(address who) external view returns (Member memory) {
        return _members[who];
    }

    function balanceOf(address who) external view returns (int256) {
        return _members[who].balanceMinutes;
    }

    function isMember(address who) external view returns (bool) {
        return _members[who].active;
    }

    function entryCount() external view returns (uint256) {
        return _entries.length;
    }

    function getEntry(uint256 entryId) external view returns (Entry memory) {
        return _entry(entryId);
    }

    function entriesGivenBy(address who) external view returns (uint256[] memory) {
        return _given[who];
    }

    function entriesReceivedBy(address who) external view returns (uint256[] memory) {
        return _received[who];
    }

    function requestCount() external view returns (uint256) {
        return _requests.length;
    }

    function getRequest(uint256 requestId) external view returns (Request memory) {
        require(requestId < _requests.length, "no such request");
        return _requests[requestId];
    }

    function getRoster() external view returns (address[] memory) {
        return _roster;
    }

    /// @notice How much more a member could receive before hitting the floor.
    function headroomMinutes(address who) external view returns (uint256) {
        int256 room = _members[who].balanceMinutes - debtFloorMinutes;
        return room > 0 ? uint256(room) : 0;
    }

    /// @notice Newest-first page of entry ids.
    function getRecentEntries(uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _entries.length;
        if (limit > n) limit = n;
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = n - 1 - i;
        }
    }

    /// @notice Newest-first page of request ids.
    function getRecentRequests(uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _requests.length;
        if (limit > n) limit = n;
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = n - 1 - i;
        }
    }

    // --------------------------------------------------------------- admin

    function setTerms(uint256 newBond, uint256 newFee, int256 newFloor) external onlyOwner {
        require(newFloor <= 0, "floor must not be positive");
        require(newFloor >= -int256(uint256(MAX_MINUTES)) * 30, "floor too deep");
        joinBond = newBond;
        joinFee = newFee;
        debtFloorMinutes = newFloor;
        emit TermsUpdated(newBond, newFee, newFloor);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Bounded by `accumulatedFees`, so member bonds are never reachable.
    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "bad recipient");
        uint256 amount = accumulatedFees;
        require(amount > 0, "nothing to withdraw");
        accumulatedFees = 0;
        emit FeesWithdrawn(to, amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // ------------------------------------------------------------ internal

    function _entry(uint256 id) private view returns (Entry storage) {
        require(id < _entries.length, "no such entry");
        return _entries[id];
    }

    receive() external payable {
        accumulatedFees += msg.value;
    }
}
