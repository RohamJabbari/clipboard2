using Clipboard2.Core.Sync;

namespace Clipboard2.Core.Tests;

/// <summary>Authenticators against <see cref="FakeCloud"/> (docs/sync/PROTOCOL.md → Authenticators).</summary>
public sealed partial class SyncEngineTests
{
    private const string Secret = "JBSWY3DPEHPK3PXP";

    [Fact]
    public async Task AuthenticatorSyncsToTheOwnersOtherDevicesAndDeleteRemovesItEverywhere()
    {
        var a = await SignedUp();
        var added = a.Account.Authenticators.Add("GitHub", "me", Secret)!;
        await a.Sync();
        var mine = a.Account.Authenticators.Find(added.Id)!;
        Assert.NotNull(mine.SpaceId);
        Assert.Equal("otp", Assert.Single(_cloud.Items(mine.SpaceId!)).Category);
        Assert.Contains(_cloud.SpacesQueries, q => q == "?include=direct,authenticator");

        var other = await SignedIn();
        var copy = Assert.Single(other.Account.Authenticators.All);
        Assert.Equal((added.Id, "GitHub", mine.SpaceId), (copy.Id, copy.Issuer, copy.SpaceId));
        Assert.Equal(added.Code(DateTime.UtcNow), copy.Code(DateTime.UtcNow));

        // A rename travels.
        a.Account.Authenticators.Rename(mine, "GitHub (work)", "me");
        await a.Sync();
        await other.Sync();
        Assert.Equal("GitHub (work)", Assert.Single(other.Account.Authenticators.All).Issuer);

        // Delete: the space goes, and the other device cleans up when it's no longer listed.
        Assert.True(await a.Account.DeleteAuthenticatorAsync(a.Account.Authenticators.Find(added.Id)!), a.Account.Error);
        Assert.False(_cloud.SpaceExists(mine.SpaceId!));
        Assert.Empty(a.Account.Authenticators.All);
        await other.Sync();
        Assert.Empty(other.Account.Authenticators.All);
    }

    [Fact]
    public async Task SignOutKeepsOwnAuthenticatorsAndSigningInAgainDoesNotDuplicateThem()
    {
        var a = await SignedUp();
        a.Account.Authenticators.Add("GitHub", "me", Secret);
        await a.Sync();
        var space = Assert.Single(a.Account.Authenticators.All).SpaceId;
        Assert.True(await a.Account.SignOutAsync(), a.Account.Error);
        Assert.Null(Assert.Single(a.Account.Authenticators.All).SpaceId);
        Assert.True(await a.Account.SignInAsync(Email, Password), a.Account.Error);
        await a.Sync();
        await a.Sync();
        Assert.Equal(space, Assert.Single(a.Account.Authenticators.All).SpaceId);
    }

    [Fact]
    public async Task SharingSendsSealedCodesNeverTheSecret()
    {
        var (a, b, _) = await Contacts();
        var otp = a.Account.Authenticators.Add("GitHub", "me", Secret)!;
        await a.Sync();
        otp = a.Account.Authenticators.Find(otp.Id)!;
        var friend = _cloud.Uid(Friend);
        var candidate = Assert.Single(a.Account.ShareCandidates(otp));
        Assert.Equal(friend, candidate.Uid);
        Assert.True(await a.Account.ShareAuthenticatorAsync(otp, friend, candidate.Name), a.Account.Error);

        // Only the owner is in the space; the recipient never gets its key or item.
        Assert.Equal([_cloud.Uid(Email)], _cloud.SpaceMembers(otp.SpaceId!));
        var share = _cloud.Shares(otp.SpaceId!)[friend];
        Assert.DoesNotContain(Secret, share.SealedCodes);
        Assert.Equal("friend", Assert.Single(a.Account.Authenticators.Find(otp.Id)!.People).Name);
        Assert.Empty(a.Account.ShareCandidates(a.Account.Authenticators.Find(otp.Id)!));

        await b.Sync();
        Assert.Empty(b.Account.Authenticators.All);
        var shared = Assert.Single(b.Account.Authenticators.Shared);
        Assert.Equal(("GitHub", "roham"), (shared.Issuer, shared.OwnerName));
        Assert.Equal(otp.Code(DateTime.UtcNow), shared.Code(DateTime.UtcNow));
        Assert.Equal("Shared by roham", shared.Status(DateTime.UtcNow));
        Assert.DoesNotContain(b.Store.SyncSpaces(), s => s.Id == otp.SpaceId);

        // Removing deletes their batch on the server; the codes they have keep working until they run out.
        var until = await a.Account.RemoveAuthenticatorShareAsync(a.Account.Authenticators.Find(otp.Id)!, friend);
        Assert.NotNull(until);
        Assert.Empty(_cloud.Shares(otp.SpaceId!));
        await b.Sync();
        Assert.Empty(b.Account.Authenticators.Shared);
    }

    [Fact]
    public async Task OwnerDevicesTopUpSharesRunningLow()
    {
        var (a, b, _) = await Contacts();
        var otp = a.Account.Authenticators.Add("GitHub", "me", Secret)!;
        await a.Sync();
        otp = a.Account.Authenticators.Find(otp.Id)!;
        var friend = _cloud.Uid(Friend);
        Assert.True(await a.Account.ShareAuthenticatorAsync(otp, friend, "friend"), a.Account.Error);
        var first = _cloud.Shares(otp.SpaceId!)[friend];
        var sealedBefore = first.SealedCodes;

        // 13 hours left: not due, nothing is sent again.
        _cloud.SetCodesUntil(otp.SpaceId!, friend, DateTimeOffset.UtcNow.AddHours(13).ToUnixTimeMilliseconds());
        await a.Engine().TopUpSharesAsync(null, force: true);
        Assert.Equal(sealedBefore, _cloud.Shares(otp.SpaceId!)[friend].SealedCodes);

        // 11 hours left: the next sync of any owner device sends 24 h again.
        _cloud.SetCodesUntil(otp.SpaceId!, friend, DateTimeOffset.UtcNow.AddHours(11).ToUnixTimeMilliseconds());
        var otherOwnerDevice = await SignedIn();
        await otherOwnerDevice.Engine().TopUpSharesAsync(null, force: true);
        var topped = _cloud.Shares(otp.SpaceId!)[friend];
        Assert.NotEqual(sealedBefore, topped.SealedCodes);
        Assert.True(topped.CodesUntil > DateTimeOffset.UtcNow.AddHours(23.9).ToUnixTimeMilliseconds());

        await b.Sync();
        Assert.False(Assert.Single(b.Account.Authenticators.Shared).IsLow(DateTime.UtcNow));
    }

    [Fact]
    public async Task TransferMovesTheSeedAndTheOldOwnerGetsCodes()
    {
        var (a, b, _) = await Contacts();
        var otp = a.Account.Authenticators.Add("GitHub", "me", Secret)!;
        await a.Sync();
        otp = a.Account.Authenticators.Find(otp.Id)!;
        var friend = _cloud.Uid(Friend);
        Assert.True(await a.Account.ShareAuthenticatorAsync(otp, friend, "friend"), a.Account.Error);
        var otherOwnerDevice = await SignedIn();
        Assert.Single(otherOwnerDevice.Account.Authenticators.All);

        Assert.True(await a.Account.TransferAuthenticatorAsync(a.Account.Authenticators.Find(otp.Id)!, friend, "friend"), a.Account.Error);
        Assert.Equal(friend, _cloud.OwnerOf(otp.SpaceId!));
        Assert.Empty(a.Account.Authenticators.All);   // the seed is gone here

        // The new owner gets the seed (and tops up the old owner's share on its sync).
        await b.Sync();
        var owned = Assert.Single(b.Account.Authenticators.All);
        Assert.Equal(otp.Code(DateTime.UtcNow), owned.Code(DateTime.UtcNow));
        Assert.Empty(b.Account.Authenticators.Shared);
        Assert.Equal("roham", Assert.Single(owned.People).Name);

        await a.Sync();
        var shared = Assert.Single(a.Account.Authenticators.Shared);
        Assert.Equal(("friend", otp.Code(DateTime.UtcNow)), (shared.OwnerName, shared.Code(DateTime.UtcNow)));
        // The owner's other device drops its copy of the seed too.
        await otherOwnerDevice.Sync();
        Assert.Empty(otherOwnerDevice.Account.Authenticators.All);
        Assert.Single(otherOwnerDevice.Account.Authenticators.Shared);
    }

    [Fact]
    public async Task RecipientCanLeaveAndStrangersCantBeSharedWith()
    {
        var (a, b, _) = await Contacts();
        var stranger = await SignedUp("stranger@example.com");
        var otp = a.Account.Authenticators.Add("GitHub", "me", Secret)!;
        await a.Sync();
        otp = a.Account.Authenticators.Find(otp.Id)!;
        Assert.False(await a.Account.ShareAuthenticatorAsync(otp, stranger.Account.Uid!, "stranger"));
        Assert.Contains("contacts", a.Account.Error);

        Assert.True(await a.Account.ShareAuthenticatorAsync(otp, b.Account.Uid!, "friend"), a.Account.Error);
        await b.Sync();
        Assert.True(await b.Account.LeaveAuthenticatorAsync(Assert.Single(b.Account.Authenticators.Shared)), b.Account.Error);
        Assert.Empty(b.Account.Authenticators.Shared);
        Assert.Empty(_cloud.Shares(otp.SpaceId!));
    }
}

internal static class AuthenticatorTestExtensions
{
    public static SyncEngine Engine(this object device) =>
        ((SyncAccount)device.GetType().GetProperty("Account")!.GetValue(device)!).Engine!;
}
