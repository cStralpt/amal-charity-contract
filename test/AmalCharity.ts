import { expect } from "chai";
import hre from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { getAddress, parseEther, zeroAddress } from "viem";

interface CharityDetails {
    id: bigint;
    name: string;
    description: string;
    imageUrls: string[];
    targetFunds: bigint;
    raisedFunds: bigint;
    creator: `0x${string}`;
    isActive: boolean;
}

describe("AmalCharity Tests", function () {
    async function deployFixture() {
        const [owner, donor, creator, attacker] = await hre.viem.getWalletClients();
        const amalCharity = await hre.viem.deployContract("AmalCharity", [owner.account.address]);
        const publicClient = await hre.viem.getPublicClient();
        return {
            amalCharity,
            owner,
            donor,
            creator,
            attacker,
            publicClient
        };
    }

    describe("Access Control", () => {
        it("Should prevent non-owners from updating platform fee", async () => {
            const { amalCharity, donor } = await loadFixture(deployFixture);
            await expect(
                amalCharity.write.updatePlatformFee([500n], { account: donor.account })
            ).to.be.rejectedWith("Only the owner can call this");
        });

        it("Should prevent non-creators from modifying charity status", async () => {
            const { amalCharity, owner, attacker } = await loadFixture(deployFixture);
            await amalCharity.write.createCharity(
                ["Secure Charity", "Description", ["image.jpg"], parseEther("10")],
                { account: owner.account }
            );
            await expect(
                amalCharity.write.deactivateCharity([1n], { account: attacker.account })
            ).to.be.rejectedWith("Only the creator can deactivate the charity");
        });
    });

    describe("Input Validation", () => {
        it("Should reject zero-value donations", async () => {
            const { amalCharity, owner, donor } = await loadFixture(deployFixture);
            await amalCharity.write.createCharity(
                ["Test Charity", "Description", ["image.jpg"], parseEther("10")],
                { account: owner.account }
            );
            await expect(
                amalCharity.write.donateToCharity([1n], {
                    value: 0n,
                    account: donor.account
                })
            ).to.be.rejectedWith("Donation amount must be greater than 0");
        });

        it("Should prevent creating charities with empty image URLs", async () => {
            const { amalCharity, owner } = await loadFixture(deployFixture);
            await expect(
                amalCharity.write.createCharity(
                    ["Invalid Charity", "Description", [], parseEther("10")],
                    { account: owner.account }
                )
            ).to.be.rejectedWith("At least one image URL is required");
        });
    });

    describe("Dynamic Platform Fee Calculation", () => {
        it("Should calculate the base fee correctly", async () => {
            const { amalCharity, owner, donor } = await loadFixture(deployFixture);
            await amalCharity.write.createCharity(
                ["Base Fee Test", "Description", ["image.jpg"], parseEther("100")],
                { account: owner.account }
            );
            const donationAmount = parseEther("10");
            await amalCharity.write.donateToCharity([1n], {
                value: donationAmount,
                account: donor.account
            });
            const charity = await amalCharity.read.getCharityDetails([1n]) as unknown as CharityDetails;
            const expectedFee = (donationAmount * 200n) / 10000n; // Base fee = 0.2 ETH
            expect(charity.raisedFunds).to.equal(donationAmount - expectedFee);
        });

        it("Should cap the fee for large donations (> 10 ETH)", async () => {
            const { amalCharity, owner, donor } = await loadFixture(deployFixture);
            await amalCharity.write.createCharity(
                ["Large Donation Test", "Description", ["image.jpg"], parseEther("100")],
                { account: owner.account }
            );
            const largeDonation = parseEther("15");
            await amalCharity.write.donateToCharity([1n], {
                value: largeDonation,
                account: donor.account
            });
            const charity = await amalCharity.read.getCharityDetails([1n]) as unknown as CharityDetails;
            const cappedFee = (parseEther("10") * 200n) / 10000n; // Cap fee at 0.2 ETH
            expect(charity.raisedFunds).to.equal(largeDonation - cappedFee);
        });

        it("Should reduce the fee by 50% when charity is close to its target", async () => {
            const { amalCharity, owner, donor } = await loadFixture(deployFixture);
            await amalCharity.write.createCharity(
                ["Close to Target Test", "Description", ["image.jpg"], parseEther("10")],
                { account: owner.account }
            );
            await amalCharity.write.donateToCharity([1n], {
                value: parseEther("9"),
                account: donor.account
            });
            const finalDonation = parseEther("1");
            await amalCharity.write.donateToCharity([1n], {
                value: finalDonation,
                account: donor.account
            });
            const charity = await amalCharity.read.getCharityDetails([1n]) as unknown as CharityDetails;
            const baseFee = (finalDonation * 200n) / 10000n; // Base fee = 0.02 ETH
            const reducedFee = baseFee / 2n; // Reduced fee = 0.01 ETH
            expect(charity.raisedFunds).to.equal(parseEther("10") - reducedFee);
        });

        it("Should combine all conditions (large donation + close to target)", async () => {
            const { amalCharity, owner, donor } = await loadFixture(deployFixture);
            await amalCharity.write.createCharity(
                ["Combined Conditions Test", "Description", ["image.jpg"], parseEther("20")],
                { account: owner.account }
            );
            await amalCharity.write.donateToCharity([1n], {
                value: parseEther("18"),
                account: donor.account
            });
            const largeDonation = parseEther("15");
            await amalCharity.write.donateToCharity([1n], {
                value: largeDonation,
                account: donor.account
            });
            const charity = await amalCharity.read.getCharityDetails([1n]) as unknown as CharityDetails;
            const cappedFee = (parseEther("10") * 200n) / 10000n; // Cap fee at 0.2 ETH
            const reducedFee = cappedFee / 2n; // Reduced fee = 0.1 ETH
            expect(charity.raisedFunds).to.equal(parseEther("20") - reducedFee);
        });
    });

    describe("Reentrancy Protection", () => {
        it("Should block recursive donation calls", async () => {
            const { amalCharity, owner, attacker } = await loadFixture(deployFixture);
            const maliciousContract = await hre.viem.deployContract(
                "ReentrancyAttacker",
                [amalCharity.address],
                { client: { wallet: attacker } }
            );
            await amalCharity.write.createCharity(
                ["Vulnerable?", "Description", ["image.jpg"], parseEther("100")],
                { account: owner.account }
            );
            await expect(
                maliciousContract.write.attack([1], {
                    value: parseEther("1")
                })
            ).to.be.rejectedWith("Reentrant call detected");
        });
    });

    describe("Pagination and Sorting", () => {
        it("Should return paginated charities in ascending order", async () => {
            const { amalCharity, owner } = await loadFixture(deployFixture);
            for (let i = 1; i <= 5; i++) {
                await amalCharity.write.createCharity(
                    [`Charity ${i}`, "Description", ["image.jpg"], parseEther("10")],
                    { account: owner.account }
                );
            }
            const result = await amalCharity.read.getAllCharities([1n, 3n, 0]); // ASC order
            expect(result.length).to.equal(3);
            expect(result[0].name).to.equal("Charity 2");
            expect(result[2].name).to.equal("Charity 4");
        });

        it("Should return paginated charities in descending order", async () => {
            const { amalCharity, owner } = await loadFixture(deployFixture);
            for (let i = 1; i <= 5; i++) {
                await amalCharity.write.createCharity(
                    [`Charity ${i}`, "Description", ["image.jpg"], parseEther("10")],
                    { account: owner.account }
                );
            }
            const result = await amalCharity.read.getAllCharities([1n, 3n, 1]); // DESC order
            expect(result.length).to.equal(3);
            expect(result[0].name).to.equal("Charity 4");
            expect(result[2].name).to.equal("Charity 2");
        });

        it("Should handle invalid offsets gracefully", async () => {
            const { amalCharity, owner } = await loadFixture(deployFixture);
            await amalCharity.write.createCharity(
                ["Test Charity", "Description", ["image.jpg"], parseEther("10")],
                { account: owner.account }
            );
            await expect(
                amalCharity.read.getAllCharities([10n, 3n, 0])
            ).to.be.rejectedWith("Offset out of range");
        });
    });

    describe("Donation Retrieval", () => {
        it("Should retrieve donations by charity in ascending order", async () => {
            const { amalCharity, owner, donor } = await loadFixture(deployFixture);
            await amalCharity.write.createCharity(
                ["Donation Test", "Description", ["image.jpg"], parseEther("10")],
                { account: owner.account }
            );
            await amalCharity.write.donateToCharity([1n], {
                value: parseEther("1"),
                account: donor.account
            });
            const donations = await amalCharity.read.getDonationsByCharity([1n, 0]);
            expect(donations.length).to.equal(1);
            expect(donations[0].donor).to.equal(donor.account.address);
        });

        it("Should retrieve donations by donor with charity data", async () => {
            const { amalCharity, owner, donor } = await loadFixture(deployFixture);
            await amalCharity.write.createCharity(
                ["Donation Test", "Description", ["image.jpg"], parseEther("10")],
                { account: owner.account }
            );
            await amalCharity.write.donateToCharity([1n], {
                value: parseEther("1"),
                account: donor.account
            });
            const donations = await amalCharity.read.getDonationsByDonor([donor.account.address, 0]);
            expect(donations.length).to.equal(1);
            expect(donations[0].charity.name).to.equal("Donation Test");
        });
    });

    describe("Ownership Management", () => {
        it("Should prevent zero-address ownership transfers", async () => {
            const { amalCharity, owner } = await loadFixture(deployFixture);
            await expect(
                amalCharity.write.transferOwnership([zeroAddress], { account: owner.account })
            ).to.be.rejectedWith("New owner cannot be the zero address");
        });

        it("Should preserve access control after ownership transfer", async () => {
            const { amalCharity, owner, creator } = await loadFixture(deployFixture);
            await amalCharity.write.transferOwnership(
                [creator.account.address],
                { account: owner.account }
            );
            await expect(
                amalCharity.write.updatePlatformFee([500n], { account: owner.account })
            ).to.be.rejectedWith("Only the owner can call this");
        });
    });

    describe("Fee Withdrawals", () => {
        it("Should prevent unauthorized fee withdrawals", async () => {
            const { amalCharity, donor } = await loadFixture(deployFixture);
            await expect(
                amalCharity.write.withdrawPlatformFees({ account: donor.account })
            ).to.be.rejectedWith("Only platform wallet can call this");
        });

        it("Should correctly reset fee counter after withdrawal", async () => {
            const { amalCharity, owner, donor } = await loadFixture(deployFixture);
            await amalCharity.write.createCharity(
                ["Fee Test", "Description", ["image.jpg"], parseEther("10")],
                { account: owner.account }
            );
            await amalCharity.write.donateToCharity([1n], {
                value: parseEther("1"),
                account: donor.account
            });
            await amalCharity.write.withdrawPlatformFees({ account: owner.account });
            expect(await amalCharity.read.totalPlatformFees()).to.equal(0n);
        });
    });

    describe("Charity Reactivation", () => {
        it("Should allow creators to reactivate their charity", async () => {
            const { amalCharity, owner } = await loadFixture(deployFixture);
            await amalCharity.write.createCharity(
                ["Reactivation Test", "Description", ["image.jpg"], parseEther("10")],
                { account: owner.account }
            );
            await amalCharity.write.deactivateCharity([1n], { account: owner.account });
            await amalCharity.write.reactivateCharity([1n], { account: owner.account });
            const charity = await amalCharity.read.getCharityDetails([1n]) as unknown as CharityDetails;
            expect(charity.isActive).to.be.true;
        });

        it("Should prevent non-creators from reactivating a charity", async () => {
            const { amalCharity, owner, attacker } = await loadFixture(deployFixture);
            await amalCharity.write.createCharity(
                ["Reactivation Test", "Description", ["image.jpg"], parseEther("10")],
                { account: owner.account }
            );
            await amalCharity.write.deactivateCharity([1n], { account: owner.account });
            await expect(
                amalCharity.write.reactivateCharity([1n], { account: attacker.account })
            ).to.be.rejectedWith("Only the creator can reactivate the charity");
        });
    });
});