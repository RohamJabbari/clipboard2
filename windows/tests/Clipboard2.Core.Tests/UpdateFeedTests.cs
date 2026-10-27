using System.Text;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;

namespace Clipboard2.Core.Tests;

/// <summary>The signed Windows update feed (scripts/sign-windows-feed.sh signs, the app verifies).</summary>
public sealed class UpdateFeedTests
{
    private const string Feed = """
        {"Assets":[{"PackageId":"Clipboard2","Version":"1.4.0","Type":"Full","FileName":"Clipboard2-1.4.0-full.nupkg",
        "SHA1":"0123456789abcdef0123456789abcdef01234567","SHA256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","Size":123}]}
        """;

    private static (string PublicKey, Func<byte[], string> Sign) NewKey()
    {
        var key = new Ed25519PrivateKeyParameters(new SecureRandom());
        return (Convert.ToBase64String(key.GeneratePublicKey().GetEncoded()), message =>
        {
            var signer = new Ed25519Signer();
            signer.Init(true, key);
            signer.BlockUpdate(message, 0, message.Length);
            return Convert.ToBase64String(signer.GenerateSignature());
        });
    }

    [Fact]
    public void Rfc8032Vector()
    {
        // RFC 8032 §7.1, TEST 1 (empty message): the same Ed25519 that Sparkle's sign_update produces.
        var publicKey = Convert.ToBase64String(Convert.FromHexString("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"));
        var signature = Convert.ToBase64String(Convert.FromHexString(
            "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"));
        Assert.True(UpdateFeed.VerifySignature([], signature, publicKey));
        Assert.False(UpdateFeed.VerifySignature([0], signature, publicKey));
    }

    [Fact]
    public void ASignedFeedIsAcceptedAndReturnedWithoutABom()
    {
        var (publicKey, sign) = NewKey();
        var bytes = Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(Feed)).ToArray();
        var text = UpdateFeed.Verify(bytes, sign(bytes) + "\n", publicKey);
        Assert.StartsWith("{", text);
    }

    [Fact]
    public void TamperingAnotherKeyOrNoKeyIsRefused()
    {
        var (publicKey, sign) = NewKey();
        var (otherKey, _) = NewKey();
        var bytes = Encoding.UTF8.GetBytes(Feed);
        var signature = sign(bytes);
        var tampered = Encoding.UTF8.GetBytes(Feed.Replace("1.4.0", "9.9.9"));
        Assert.Throws<UpdateFeed.VerificationException>(() => UpdateFeed.Verify(tampered, signature, publicKey));
        Assert.Throws<UpdateFeed.VerificationException>(() => UpdateFeed.Verify(bytes, signature, otherKey));
        Assert.Throws<UpdateFeed.VerificationException>(() => UpdateFeed.Verify(bytes, signature, ""));
        Assert.Throws<UpdateFeed.VerificationException>(() => UpdateFeed.Verify(bytes, "", publicKey));
        Assert.Throws<UpdateFeed.VerificationException>(() => UpdateFeed.Verify(bytes, "not base64!", publicKey));
    }

    [Fact]
    public void ASignedFeedWithoutPackageHashesIsRefused()
    {
        var (publicKey, sign) = NewKey();
        var bytes = Encoding.UTF8.GetBytes(Feed.Replace("\"SHA256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",", ""));
        Assert.Throws<UpdateFeed.VerificationException>(() => UpdateFeed.Verify(bytes, sign(bytes), publicKey));
    }
}
