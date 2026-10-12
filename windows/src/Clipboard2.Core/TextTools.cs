using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Clipboard2.Core;

public static class TextPreview
{
    /// <summary>Single-line excerpt for list rows: whitespace runs collapse to one space.</summary>
    public static string Make(string text, int limit = 300)
    {
        var sb = new StringBuilder(Math.Min(limit, text.Length));
        var lastWasSpace = false;
        foreach (var ch in text.AsSpan(0, Math.Min(text.Length, limit * 4)))
        {
            if (char.IsWhiteSpace(ch))
            {
                if (!lastWasSpace && sb.Length > 0) sb.Append(' ');
                lastWasSpace = true;
            }
            else
            {
                sb.Append(ch);
                lastWasSpace = false;
            }
            if (sb.Length >= limit) break;
        }
        return sb.ToString().Trim();
    }
}

public static class ContentHasher
{
    /// <summary>Text and rich text share a namespace; surrounding whitespace is ignored.</summary>
    public static string HashText(string text) => "text:" + Sha256(Encoding.UTF8.GetBytes(text.Trim()));

    public static string HashFiles(IEnumerable<string> paths) =>
        "file:" + Sha256(Encoding.UTF8.GetBytes(string.Join("\n", paths)));

    /// <summary>Hash of decoded BGRA pixels, so re-encoded copies of one picture match.</summary>
    public static string HashPixels(int width, int height, ReadOnlySpan<byte> bgra) =>
        $"image:px:{width}x{height}:" + Sha256(bgra);

    public static string HashBytes(ReadOnlySpan<byte> data) => "image:" + Sha256(data);

    private static string Sha256(ReadOnlySpan<byte> data) => Convert.ToHexStringLower(SHA256.HashData(data));
}

/// <summary>
/// Every whitespace-separated query token must appear in the candidate as a case-insensitive
/// subsequence. Contiguous runs, word starts and exact substrings score higher.
/// </summary>
public static class FuzzyMatcher
{
    public const int MaxCandidateLength = 4_000;

    public static int? Score(string query, string candidate)
    {
        var tokens = query.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length == 0) return 0;
        var haystack = (candidate.Length > MaxCandidateLength ? candidate[..MaxCandidateLength] : candidate).ToLowerInvariant();
        var total = 0;
        foreach (var token in tokens)
        {
            if (ScoreToken(token, haystack) is not { } s) return null;
            total += s;
        }
        return total;
    }

    private static int? ScoreToken(string token, string haystack)
    {
        if (token.Length > haystack.Length) return null;
        var index = haystack.IndexOf(token, StringComparison.Ordinal);
        if (index >= 0)
        {
            var wordStart = index == 0 || !char.IsLetter(haystack[index - 1]);
            return 1_000 + token.Length * 10 + (wordStart ? 200 : 0) - Math.Min(index, 300);
        }
        int score = 0, t = 0, previous = -2;
        for (var i = 0; i < haystack.Length && t < token.Length; i++)
        {
            if (haystack[i] != token[t]) continue;
            score += 1;
            if (i == previous + 1) score += 5;
            if (i == 0 || !char.IsLetter(haystack[i - 1])) score += 8;
            previous = i;
            t++;
        }
        return t == token.Length ? score : null;
    }
}

public enum Transform
{
    PlainText, TrimWhitespace, Uppercase, Lowercase, TitleCase, JsonPrettify, JsonMinify,
    UrlEncode, UrlDecode, Base64Encode, Base64Decode, RemoveLineBreaks,
}

public static class Transforms
{
    public static readonly Transform[] All = Enum.GetValues<Transform>();

    public static string Title(this Transform t) => t switch
    {
        Transform.PlainText => "Paste as Plain Text",
        Transform.TrimWhitespace => "Trim Whitespace",
        Transform.Uppercase => "UPPERCASE",
        Transform.Lowercase => "lowercase",
        Transform.TitleCase => "Title Case",
        Transform.JsonPrettify => "Prettify JSON",
        Transform.JsonMinify => "Minify JSON",
        Transform.UrlEncode => "URL Encode",
        Transform.UrlDecode => "URL Decode",
        Transform.Base64Encode => "Base64 Encode",
        Transform.Base64Decode => "Base64 Decode",
        _ => "Remove Line Breaks",
    };

    /// <summary>Segoe Fluent Icons glyph for menus.</summary>
    public static string Glyph(this Transform t) => t switch
    {
        Transform.JsonPrettify or Transform.JsonMinify => "",
        Transform.UrlEncode or Transform.UrlDecode => "",
        Transform.Base64Encode => "",
        Transform.Base64Decode => "",
        Transform.TrimWhitespace => "",
        _ => "",
    };

    /// <summary>Null when the input isn't valid for the transform (e.g. malformed JSON).</summary>
    public static string? Apply(this Transform t, string input) => t switch
    {
        Transform.PlainText => input,
        Transform.TrimWhitespace => input.Trim(),
        Transform.Uppercase => input.ToUpper(CultureInfo.CurrentCulture),
        Transform.Lowercase => input.ToLower(CultureInfo.CurrentCulture),
        Transform.TitleCase => TitleCased(input),
        Transform.JsonPrettify => JsonFormatter.Format(input, pretty: true),
        Transform.JsonMinify => JsonFormatter.Format(input, pretty: false),
        Transform.UrlEncode => Uri.EscapeDataString(input),
        Transform.UrlDecode => SafeUnescape(input.Replace('+', ' ')),
        Transform.Base64Encode => Convert.ToBase64String(Encoding.UTF8.GetBytes(input)),
        Transform.Base64Decode => DecodeBase64(input),
        _ => string.Join(" ", input.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
                .Select(l => l.Trim()).Where(l => l.Length > 0)),
    };

    private static string TitleCased(string input)
    {
        var sb = new StringBuilder(input.Length);
        var atWordStart = true;
        foreach (var ch in input)
        {
            if (char.IsLetterOrDigit(ch))
            {
                sb.Append(atWordStart ? char.ToUpper(ch, CultureInfo.CurrentCulture) : char.ToLower(ch, CultureInfo.CurrentCulture));
                atWordStart = false;
            }
            else
            {
                sb.Append(ch);
                if (ch != '\'' && ch != '’') atWordStart = true;
            }
        }
        return sb.ToString();
    }

    private static string? SafeUnescape(string s)
    {
        try { return Uri.UnescapeDataString(s); } catch { return null; }
    }

    private static string? DecodeBase64(string input)
    {
        var s = input.Trim().Replace("\n", "").Replace("\r", "").Replace('-', '+').Replace('_', '/');
        if (s.Length % 4 is var r and > 0) s += new string('=', 4 - r);
        try
        {
            var bytes = Convert.FromBase64String(s);
            var text = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(bytes);
            return text;
        }
        catch { return null; }
    }
}

/// <summary>Re-indents JSON without reordering keys or touching number formatting.</summary>
public static class JsonFormatter
{
    public static string? Format(string input, bool pretty, string indent = "  ")
    {
        try { using var _ = JsonDocument.Parse(input, new JsonDocumentOptions { AllowTrailingCommas = false }); }
        catch { return null; }

        var sb = new StringBuilder(input.Length);
        int level = 0;
        bool inString = false, escaped = false;
        void Newline() { sb.Append('\n'); for (var i = 0; i < Math.Max(0, level); i++) sb.Append(indent); }

        for (var i = 0; i < input.Length; i++)
        {
            var c = input[i];
            if (inString)
            {
                sb.Append(c);
                if (escaped) escaped = false;
                else if (c == '\\') escaped = true;
                else if (c == '"') inString = false;
                continue;
            }
            switch (c)
            {
                case '"':
                    inString = true;
                    sb.Append(c);
                    break;
                case '{' or '[':
                    var j = i + 1;
                    while (j < input.Length && char.IsWhiteSpace(input[j])) j++;
                    var closer = c == '{' ? '}' : ']';
                    if (j < input.Length && input[j] == closer)
                    {
                        sb.Append(c).Append(closer);
                        i = j;
                        break;
                    }
                    sb.Append(c);
                    if (pretty) { level++; Newline(); }
                    break;
                case '}' or ']':
                    if (pretty) { level--; Newline(); }
                    sb.Append(c);
                    break;
                case ',':
                    sb.Append(c);
                    if (pretty) Newline();
                    break;
                case ':':
                    sb.Append(c);
                    if (pretty) sb.Append(' ');
                    break;
                default:
                    if (!char.IsWhiteSpace(c)) sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }
}

public sealed record SnippetExpansion(string Text, int CursorOffsetFromEnd);

/// <summary>Expands {date}, {time}, {clipboard}, {cursor} and custom {fields} in snippet bodies.</summary>
public static class SnippetExpander
{
    public static readonly HashSet<string> BuiltIns = new(StringComparer.OrdinalIgnoreCase) { "date", "time", "clipboard", "cursor" };

    private abstract record Token;
    private sealed record Literal(string Text) : Token;
    private sealed record Placeholder(string Name) : Token;

    public static List<string> CustomFields(string body)
    {
        var seen = new HashSet<string>();
        var fields = new List<string>();
        foreach (var token in Tokenize(body))
            if (token is Placeholder p && !BuiltIns.Contains(p.Name) && seen.Add(p.Name)) fields.Add(p.Name);
        return fields;
    }

    public static SnippetExpansion Expand(string body, IReadOnlyDictionary<string, string>? values, string? clipboard,
                                          DateTime? now = null, CultureInfo? culture = null)
    {
        var time = now ?? DateTime.Now;
        var c = culture ?? CultureInfo.CurrentCulture;
        var output = new StringBuilder();
        int? cursor = null;
        foreach (var token in Tokenize(body))
        {
            switch (token)
            {
                case Literal l: output.Append(l.Text); break;
                case Placeholder p:
                    switch (p.Name.ToLowerInvariant())
                    {
                        case "date": output.Append(time.ToString(c.DateTimeFormat.LongDatePattern, c)); break;
                        case "time": output.Append(time.ToString(c.DateTimeFormat.ShortTimePattern, c)); break;
                        case "clipboard": output.Append(clipboard ?? ""); break;
                        case "cursor": cursor ??= output.Length; break;
                        default: output.Append(values is not null && values.TryGetValue(p.Name, out var v) ? v : ""); break;
                    }
                    break;
            }
        }
        var text = output.ToString();
        return new SnippetExpansion(text, cursor is { } at ? new StringInfo(text[at..]).LengthInTextElements : 0);
    }

    private static bool IsNameStart(char c) => char.IsLetter(c) || c == '_';
    private static bool IsNameChar(char c) => char.IsLetterOrDigit(c) || c is '_' or '-' or ' ';

    private static List<Token> Tokenize(string body)
    {
        var tokens = new List<Token>();
        var literal = new StringBuilder();
        var i = 0;
        while (i < body.Length)
        {
            var c = body[i];
            if (c == '{' && i + 1 < body.Length && IsNameStart(body[i + 1]))
            {
                var j = i + 1;
                while (j < body.Length && j - i <= 40 && IsNameChar(body[j])) j++;
                if (j < body.Length && body[j] == '}')
                {
                    var name = body[(i + 1)..j].Trim();
                    if (name.Length > 0)
                    {
                        if (literal.Length > 0) { tokens.Add(new Literal(literal.ToString())); literal.Clear(); }
                        tokens.Add(new Placeholder(name));
                        i = j + 1;
                        continue;
                    }
                }
            }
            literal.Append(c);
            i++;
        }
        if (literal.Length > 0) tokens.Add(new Literal(literal.ToString()));
        return tokens;
    }
}
