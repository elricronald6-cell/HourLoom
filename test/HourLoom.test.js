const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(String(n));
const BOND = E("0.02");
const FEE = E("0.002");
const ENTRY = BOND + FEE;

describe("HourLoom", function () {
  let hl, owner, ann, ben, cara, dan;

  beforeEach(async () => {
    [owner, ann, ben, cara, dan] = await ethers.getSigners();
    const F = await ethers.getContractFactory("HourLoom");
    hl = await F.deploy();
    await hl.waitForDeployment();
  });

  async function joinAll(...who) {
    for (const w of who) await hl.connect(w).join("member-" + w.address.slice(2, 6), { value: ENTRY });
  }

  it("takes a bond and a fee to join", async () => {
    await expect(hl.connect(ann).join("ann", { value: BOND })).to.be.revertedWith("wrong amount");
    await hl.connect(ann).join("ann", { value: ENTRY });

    const m = await hl.getMember(ann.address);
    expect(m.active).to.equal(true);
    expect(m.handle).to.equal("ann");
    expect(m.bond).to.equal(BOND);
    expect(await hl.bondedTotal()).to.equal(BOND);
    expect(await hl.accumulatedFees()).to.equal(FEE);
    expect(await hl.memberCount()).to.equal(1);

    await expect(hl.connect(ann).join("ann", { value: ENTRY })).to.be.revertedWith("already a member");
  });

  it("only lets members log time, and never against themselves", async () => {
    await joinAll(ann, ben);
    await expect(hl.connect(cara).logHours(ann.address, 60, "x")).to.be.revertedWith("not a member");
    await expect(hl.connect(ann).logHours(cara.address, 60, "x")).to.be.revertedWith("they are not a member");
    await expect(hl.connect(ann).logHours(ann.address, 60, "x")).to.be.revertedWith("cannot log against yourself");
    await expect(hl.connect(ann).logHours(ben.address, 5, "x")).to.be.revertedWith("bad duration");
    await expect(hl.connect(ann).logHours(ben.address, 2000, "x")).to.be.revertedWith("bad duration");
  });

  it("moves credit only when the person being debited confirms", async () => {
    await joinAll(ann, ben);
    await hl.connect(ann).logHours(ben.address, 120, "rewired the shop lights");
    const id = 0;

    await expect(hl.connect(ann).confirmEntry(id)).to.be.revertedWith("not yours to confirm");
    expect(await hl.balanceOf(ann.address)).to.equal(0);

    await hl.connect(ben).confirmEntry(id);
    expect(await hl.balanceOf(ann.address)).to.equal(120);
    expect(await hl.balanceOf(ben.address)).to.equal(-120);
    expect((await hl.getEntry(id)).status).to.equal(1);
    await expect(hl.connect(ben).confirmEntry(id)).to.be.revertedWith("not pending");
  });

  it("keeps the ledger square — balances always sum to zero", async () => {
    await joinAll(ann, ben, cara);
    await hl.connect(ann).logHours(ben.address, 180, "a");
    await hl.connect(ben).confirmEntry(0);
    await hl.connect(ben).logHours(cara.address, 60, "b");
    await hl.connect(cara).confirmEntry(1);

    const sum =
      (await hl.balanceOf(ann.address)) + (await hl.balanceOf(ben.address)) + (await hl.balanceOf(cara.address));
    expect(sum).to.equal(0);
    expect(await hl.balanceOf(ben.address)).to.equal(-120); // gave 60, received 180
  });

  it("stops a member passing the debt floor", async () => {
    await joinAll(ann, ben);
    // Floor is -1440 minutes.
    await hl.connect(ann).logHours(ben.address, 1440, "a long day");
    await hl.connect(ben).confirmEntry(0);
    expect(await hl.balanceOf(ben.address)).to.equal(-1440);
    expect(await hl.headroomMinutes(ben.address)).to.equal(0);

    await hl.connect(ann).logHours(ben.address, 15, "one more");
    await expect(hl.connect(ben).confirmEntry(1)).to.be.revertedWith("would pass the debt floor");
  });

  it("lets the recipient decline and the giver cancel", async () => {
    await joinAll(ann, ben);
    await hl.connect(ann).logHours(ben.address, 60, "a");
    await hl.connect(ben).declineEntry(0);
    expect((await hl.getEntry(0)).status).to.equal(2);
    expect(await hl.balanceOf(ann.address)).to.equal(0);

    await hl.connect(ann).logHours(ben.address, 60, "b");
    await expect(hl.connect(ben).cancelEntry(1)).to.be.revertedWith("not yours to cancel");
    await hl.connect(ann).cancelEntry(1);
    expect((await hl.getEntry(1)).status).to.equal(3);
    await expect(hl.connect(ben).confirmEntry(1)).to.be.revertedWith("not pending");
  });

  it("returns the bond only to a member who leaves square", async () => {
    await joinAll(ann, ben);
    await hl.connect(ann).logHours(ben.address, 60, "a");
    await hl.connect(ben).confirmEntry(0);

    await expect(hl.connect(ann).leave()).to.be.revertedWith("settle your balance first");
    await expect(hl.connect(ben).leave()).to.be.revertedWith("settle your balance first");

    // Ben pays Ann back in kind.
    await hl.connect(ben).logHours(ann.address, 60, "returned the favour");
    await hl.connect(ann).confirmEntry(1);
    expect(await hl.balanceOf(ann.address)).to.equal(0);

    await expect(hl.connect(ann).leave()).to.changeEtherBalance(ann, BOND);
    expect(await hl.memberCount()).to.equal(1);
    expect(await hl.bondedTotal()).to.equal(BOND);
  });

  it("keeps a returning member's history", async () => {
    await joinAll(ann, ben);
    await hl.connect(ann).logHours(ben.address, 60, "a");
    await hl.connect(ben).confirmEntry(0);
    await hl.connect(ben).logHours(ann.address, 60, "b");
    await hl.connect(ann).confirmEntry(1);
    await hl.connect(ann).leave();

    await hl.connect(ann).join("ann again", { value: ENTRY });
    const m = await hl.getMember(ann.address);
    expect(m.givenCount).to.equal(1);
    expect(m.receivedCount).to.equal(1);
    expect(m.handle).to.equal("ann again");
    expect((await hl.getRoster()).length).to.equal(2); // not listed twice
  });

  it("will not confirm an entry if either side has left", async () => {
    await joinAll(ann, ben);
    await hl.connect(ann).logHours(ben.address, 60, "a");
    await hl.connect(ann).leave();
    await expect(hl.connect(ben).confirmEntry(0)).to.be.revertedWith("both must be members");
  });

  it("runs a request board", async () => {
    await joinAll(ann, ben);
    await expect(hl.connect(cara).postRequest(60, "help")).to.be.revertedWith("not a member");
    await hl.connect(ann).postRequest(90, "need a hand moving a piano");

    const r = await hl.getRequest(0);
    expect(r.who).to.equal(ann.address);
    expect(r.minutesWanted).to.equal(90);
    expect(r.open).to.equal(true);

    await expect(hl.connect(ben).closeRequest(0)).to.be.revertedWith("not yours");
    await hl.connect(ann).closeRequest(0);
    expect((await hl.getRequest(0)).open).to.equal(false);
  });

  it("pauses joining and logging but never settling up", async () => {
    await joinAll(ann, ben);
    await hl.connect(ann).logHours(ben.address, 60, "a");
    await hl.connect(ben).logHours(ann.address, 60, "b");
    await hl.connect(owner).pause();

    await expect(hl.connect(cara).join("cara", { value: ENTRY })).to.be.revertedWithCustomError(hl, "EnforcedPause");
    await expect(hl.connect(ann).logHours(ben.address, 60, "c")).to.be.revertedWithCustomError(hl, "EnforcedPause");

    // Confirming and leaving still work — a member can always settle up.
    await hl.connect(ben).confirmEntry(0);
    await hl.connect(ann).confirmEntry(1);
    expect(await hl.balanceOf(ann.address)).to.equal(0);
    await expect(hl.connect(ann).leave()).to.changeEtherBalance(ann, BOND);
  });

  it("lets the owner reset the terms within sane bounds", async () => {
    await expect(hl.connect(owner).setTerms(E("0.05"), E("0.005"), 60)).to.be.revertedWith(
      "floor must not be positive"
    );
    await expect(hl.connect(owner).setTerms(E("0.05"), E("0.005"), -100000)).to.be.revertedWith("floor too deep");
    await expect(hl.connect(ann).setTerms(E("0.05"), E("0.005"), -720)).to.be.revertedWithCustomError(
      hl,
      "OwnableUnauthorizedAccount"
    );

    await hl.connect(owner).setTerms(E("0.05"), E("0.005"), -720);
    expect(await hl.debtFloorMinutes()).to.equal(-720);
    await hl.connect(ann).join("ann", { value: E("0.055") });
    expect((await hl.getMember(ann.address)).bond).to.equal(E("0.05"));
  });

  it("withdraws only fees, owner only, leaving bonds alone", async () => {
    await joinAll(ann, ben, cara);
    await expect(hl.connect(ann).withdrawFees(ann.address)).to.be.revertedWithCustomError(
      hl,
      "OwnableUnauthorizedAccount"
    );
    await expect(hl.connect(owner).withdrawFees(owner.address)).to.changeEtherBalance(owner, FEE * 3n);
    expect(await ethers.provider.getBalance(await hl.getAddress())).to.equal(BOND * 3n);
    expect(await hl.bondedTotal()).to.equal(BOND * 3n);
  });

  it("indexes entries in both directions and lists them newest first", async () => {
    await joinAll(ann, ben, cara);
    await hl.connect(ann).logHours(ben.address, 60, "a");
    await hl.connect(ann).logHours(cara.address, 60, "b");
    await hl.connect(ben).logHours(ann.address, 30, "c");

    expect((await hl.entriesGivenBy(ann.address)).map(Number)).to.deep.equal([0, 1]);
    expect((await hl.entriesReceivedBy(ann.address)).map(Number)).to.deep.equal([2]);
    expect((await hl.getRecentEntries(2)).map(Number)).to.deep.equal([2, 1]);
  });

  it("rejects an overlong memo and an empty handle", async () => {
    await joinAll(ann, ben);
    await expect(hl.connect(ann).join("", { value: ENTRY })).to.be.revertedWith("already a member");
    await expect(hl.connect(cara).join("", { value: ENTRY })).to.be.revertedWith("bad handle");
    await expect(hl.connect(ann).logHours(ben.address, 60, "x".repeat(200))).to.be.revertedWith("memo too long");
  });
});
