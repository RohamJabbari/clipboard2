using System.Text;
using System.Text.Json.Nodes;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace Clipboard2.Core;

/// <summary>
/// The Windows update feed (Velopack's <c>releases.win.json</c>) is signed with an offline Ed25519 key that lives in
/// the developer's macOS Keychain (scripts/sign-windows-feed.sh); the signature, base64, is
/// <c>releases.win.json.sig</c> next to it. The app trusts a feed only with a valid signature from the embedded public
/// key, and only when every package in it has a SHA-256 (which Velopack then checks on download). Access to the
/// GitHub repository alone can no longer ship an update.
/// </summary>
public static class UpdateFeed
{
    public sealed class VerificationException(string message) : Exception(message);

    /// <summary>Throws <see cref="VerificationException"/> unless <paramref name="signature"/> (the .sig file's text)
    /// is a valid Ed25519 signature of exactly <paramref name="feed"/> by <paramref name="publicKeyBase64"/>, and the
    /// feed lists a SHA-256 for every package. Returns the feed as text, without a BOM.</summary>
    public static string Verify(byte[] feed, string signature, string publicKeyBase64)
    {
        if (!VerifySignature(feed, signature, publicKeyBase64)) throw new VerificationException("The update feed's signature isn't valid.");
        var text = Encoding.UTF8.GetString(feed).TrimStart('﻿');
        JsonObject json;
        try { json = JsonNode.Parse(text) as JsonObject ?? throw new VerificationException("The update feed isn't a JSON object."); }
        catch (System.Text.Json.JsonException ex) { throw new VerificationException("The update feed isn't valid JSON: " + ex.Message); }
        var assets = Property(json, "Assets") as JsonArray ?? throw new VerificationException("The update feed lists no packages.");
        foreach (var asset in assets.OfType<JsonObject>())
        {
            var sha = Property(asset, "SHA256") is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
            if (sha is null || sha.Length != 64 || !sha.All(Uri.IsHexDigit))
                throw new VerificationException($"Package {Property(asset, "FileName")} in the update feed has no SHA-256.");
        }
        return text;
    }

    public static bool VerifySignature(byte[] message, string signature, string publicKeyBase64)
    {
        try
        {
            var key = Convert.FromBase64String(publicKeyBase64.Trim());
            var sig = Convert.FromBase64String(signature.Trim());
            if (key.Length != Ed25519PublicKeyParameters.KeySize || sig.Length != Ed25519.SignatureSize) return false;
            var verifier = new Ed25519Signer();
            verifier.Init(false, new Ed25519PublicKeyParameters(key));
            verifier.BlockUpdate(message, 0, message.Length);
            return verifier.VerifySignature(sig);
        }
        catch (Exception ex) when (ex is FormatException or ArgumentException) { return false; }
    }

    /// <summary>Velopack writes PascalCase; read case-insensitively anyway.</summary>
    private static JsonNode? Property(JsonObject json, string name) =>
        json.FirstOrDefault(p => string.Equals(p.Key, name, StringComparison.OrdinalIgnoreCase)).Value;

    private static class Ed25519
    {
        public const int SignatureSize = 64;
    }
}
