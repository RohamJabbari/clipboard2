using System.Globalization;
using Clipboard2.Core;
using Clipboard2.Core.AI;

namespace Clipboard2.Core.Tests;

public sealed class StoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "c2tests-" + Guid.NewGuid());
    private readonly ClipStore _store;
    private readonly BlobStore _blobs;

    public StoreTests()
    {
        _blobs = new BlobStore(_dir);
        _store = new ClipStore(":memory:", _blobs);
    }

    public void Dispose()
    {
        _store.Dispose();
        try { Directory.Delete(_dir, true); } catch { }
    }

    private static DateTime T(double seconds) => new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(seconds);

    [Fact]
    public void CopyingSameTextTwiceKeepsOneItemAndMovesItToTop()
    {
        _store.Ingest(ProcessedCapture.ForText("hello"), T(0));
        _store.Ingest(ProcessedCapture.ForText("world"), T(1));
        _store.Ingest(ProcessedCapture.ForText("hello"), T(2));
        var items = _store.AllItems();
        Assert.Equal(2, items.Count);
        Assert.Equal("hello", items[0].Text);
        Assert.Equal(2, items[0].CopyCount);
    }

    [Fact]
    public void RichAndPlainOfSameTextDedupe()
    {
        _store.Ingest(ProcessedCapture.ForText("same"));
        _store.Ingest(ProcessedCapture.ForText("same", rtf: @"{\rtf1 same}"));
        var items = _store.AllItems();
        Assert.Single(items);
        Assert.Equal(ClipKind.RichText, items[0].Kind);
    }

    [Fact]
    public void SurroundingWhitespaceIsIgnored()
    {
        _store.Ingest(ProcessedCapture.ForText("hello"));
        _store.Ingest(ProcessedCapture.ForText("  hello\r\n"));
        Assert.Equal(1, _store.Count());
    }

    [Fact]
    public void DifferentTextIsNotDeduped()
    {
        _store.Ingest(ProcessedCapture.ForText("a"));
        _store.Ingest(ProcessedCapture.ForText("b"));
        Assert.Equal(2, _store.Count());
    }

    [Fact]
    public void DedupeUpdatesSourceApp()
    {
        _store.Ingest(ProcessedCapture.ForText("x", source: new("a.exe", "A")));
        _store.Ingest(ProcessedCapture.ForText("x", source: new("b.exe", "B")));
        Assert.Equal("b.exe", _store.AllItems()[0].SourceId);
    }

    [Fact]
    public void DuplicateImageRemovesRedundantBlob()
    {
        ProcessedCapture Capture(string file)
        {
            _blobs.Write([1, 2, 3], file);
            return new ProcessedCapture { Kind = ClipKind.Image, Preview = "Image", Hash = "image:abc", ImageFile = file };
        }
        _store.Ingest(Capture("first.png"));
        _store.Ingest(Capture("second.png"));
        Assert.Equal(1, _store.Count());
        Assert.Equal(["first.png"], _blobs.AllFileNames());
    }

    [Fact]
    public void RetentionTrimsToMaxItemsKeepingNewest()
    {
        for (var i = 0; i < 10; i++) _store.Ingest(ProcessedCapture.ForText($"item {i}"), T(i));
        _store.EnforceRetention(3, null, T(100));
        Assert.Equal(["item 9", "item 8", "item 7"], _store.AllItems().Select(i => i.Text));
    }

    [Fact]
    public void RetentionRemovesOldItemsAndZeroMeansNoCountLimit()
    {
        var now = T(1_000_000);
        _store.Ingest(ProcessedCapture.ForText("20 min old"), now.AddMinutes(-20));
        _store.Ingest(ProcessedCapture.ForText("5 min old"), now.AddMinutes(-5));
        _store.EnforceRetention(0, TimeSpan.FromMinutes(15), now);
        Assert.Equal(["5 min old"], _store.AllItems().Select(i => i.Text));
    }

    [Fact]
    public void PinnedAndLabelledItemsNeverExpire()
    {
        var now = T(10_000_000);
        var pinned = _store.Ingest(ProcessedCapture.ForText("pinned"), now.AddDays(-400));
        _store.TogglePin(pinned);
        var labelled = _store.Ingest(ProcessedCapture.ForText("10.0.4.12"), now.AddDays(-400));
        _store.SetLabel("  Staging DB host ", labelled);
        for (var i = 0; i < 5; i++) _store.Ingest(ProcessedCapture.ForText($"n{i}"), now.AddSeconds(-i));
        _store.EnforceRetention(2, TimeSpan.FromDays(30), now);
        Assert.Equal(new HashSet<string> { "pinned", "10.0.4.12", "n0", "n1" }, _store.AllItems().Select(i => i.Text).ToHashSet());
        Assert.Equal("Staging DB host", labelled.Label);
        Assert.Equal("Staging DB host", labelled.DisplayTitle);
        Assert.NotNull(FuzzyMatcher.Score("staging", labelled.SearchableText));
    }

    [Fact]
    public void RetentionDeletesImageBlobs()
    {
        _blobs.Write([0], "img.png");
        _blobs.Write([0], "img-thumb.png");
        var now = T(10_000_000);
        _store.Ingest(new ProcessedCapture { Kind = ClipKind.Image, Hash = "image:1", ImageFile = "img.png", ThumbnailFile = "img-thumb.png" }, now.AddDays(-90));
        _store.EnforceRetention(500, TimeSpan.FromDays(30), now);
        Assert.Equal(0, _store.Count());
        Assert.Empty(_blobs.AllFileNames());
    }

    [Fact]
    public void ClearHistoryKeepsPinned()
    {
        var a = _store.Ingest(ProcessedCapture.ForText("a"));
        _store.Ingest(ProcessedCapture.ForText("b"));
        _store.TogglePin(a);
        _store.ClearHistory();
        Assert.Equal(["a"], _store.AllItems().Select(i => i.Text));
    }

    [Fact]
    public void ReplaceTextMergesDuplicates()
    {
        var a = _store.Ingest(ProcessedCapture.ForText("draft"));
        _store.Ingest(ProcessedCapture.ForText("final"));
        _store.ReplaceText(a, "final");
        Assert.Equal(1, _store.Count());
        Assert.Equal(a.Id, _store.AllItems()[0].Id);
    }

    [Fact]
    public void RemoveUnpinnedMatchingSecretHashesKeepsPinned()
    {
        var secretCopy = _store.Ingest(ProcessedCapture.ForText("hunter2"));
        var pinnedCopy = _store.Ingest(ProcessedCapture.ForText("pinned-secret"));
        _store.TogglePin(pinnedCopy);
        _store.Ingest(ProcessedCapture.ForText("normal"));
        _store.RemoveUnpinned(new HashSet<string> { secretCopy.ContentHash, pinnedCopy.ContentHash });
        Assert.Equal(new HashSet<string> { "pinned-secret", "normal" }, _store.AllItems().Select(i => i.Text).ToHashSet());
    }

    [Fact]
    public void SnippetsRoundTrip()
    {
        var s = _store.CreateSnippet("sig", ";sig", "Best, R");
        s.Body = "Best regards";
        _store.SaveSnippet(s);
        Assert.Equal("Best regards", Assert.Single(_store.AllSnippets()).Body);
        _store.DeleteSnippet(s);
        Assert.Empty(_store.AllSnippets());
    }
}

public sealed class TransformTests
{
    [Fact] public void Trim() => Assert.Equal("hi there", Transform.TrimWhitespace.Apply("  hi there \n"));

    [Fact]
    public void CaseTransforms()
    {
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
        Assert.Equal("HELLO", Transform.Uppercase.Apply("Hello"));
        Assert.Equal("The Quick Brown Fox's Tail", Transform.TitleCase.Apply("the QUICK brown fox's tail"));
        Assert.Equal("Don't-Stop", Transform.TitleCase.Apply("don't-stop"));
    }

    [Fact]
    public void JsonPrettifyPreservesKeyOrder()
    {
        var input = """{"z":1,"a":[1,2,{"k":"v, with: punctuation {}"}],"e":{}}""";
        var expected = "{\n  \"z\": 1,\n  \"a\": [\n    1,\n    2,\n    {\n      \"k\": \"v, with: punctuation {}\"\n    }\n  ],\n  \"e\": {}\n}";
        Assert.Equal(expected, Transform.JsonPrettify.Apply(input));
    }

    [Fact]
    public void JsonMinifyAndInvalid()
    {
        Assert.Equal("""{"a":[1,2],"b":"x y"}""", Transform.JsonMinify.Apply("{\n  \"a\" : [ 1, 2 ],\n  \"b\" : \"x y\"\n}"));
        Assert.Null(Transform.JsonPrettify.Apply("{nope"));
        Assert.Equal("""{"a":"say \"hi\" "}""", Transform.JsonMinify.Apply("""{ "a" : "say \"hi\" " }"""));
    }

    [Fact]
    public void UrlAndBase64()
    {
        var encoded = Transform.UrlEncode.Apply("a b&c=d/é?");
        Assert.Equal("a%20b%26c%3Dd%2F%C3%A9%3F", encoded);
        Assert.Equal("a b&c=d/é?", Transform.UrlDecode.Apply(encoded!));
        Assert.Equal("a b", Transform.UrlDecode.Apply("a+b"));
        Assert.Equal("SGVsbG8sIFdpZW4h", Transform.Base64Encode.Apply("Hello, Wien!"));
        Assert.Equal("Hello, Wien!", Transform.Base64Decode.Apply("SGVsbG8sIFdpZW4h"));
        Assert.Equal("Hello", Transform.Base64Decode.Apply("SGVsbG8"));
        Assert.Null(Transform.Base64Decode.Apply("not base64!!"));
    }

    [Fact] public void RemoveLineBreaks() => Assert.Equal("one two three", Transform.RemoveLineBreaks.Apply("one\n  two\r\n\nthree "));

    [Fact]
    public void Fuzzy()
    {
        Assert.NotNull(FuzzyMatcher.Score("hlo", "hello"));
        Assert.Null(FuzzyMatcher.Score("xyz", "hello"));
        Assert.True(FuzzyMatcher.Score("port", "import report") > FuzzyMatcher.Score("port", "p o r t"));
        Assert.Null(FuzzyMatcher.Score("foo baz", "foo and bar"));
    }
}

public sealed class SnippetTests
{
    [Fact]
    public void CustomFieldsInOrder() =>
        Assert.Equal(["name", "link"], SnippetExpander.CustomFields("Hi {name}, {date} — see {link}. Bye {name}{cursor}{clipboard}{time}"));

    [Fact]
    public void ExpandsBuiltInsAndValues()
    {
        var result = SnippetExpander.Expand("Hi {name}! Clip: {clipboard} {date}", new Dictionary<string, string> { ["name"] = "Roham" },
            "XYZ", new DateTime(2026, 10, 8), CultureInfo.InvariantCulture);
        Assert.Equal("Hi Roham! Clip: XYZ Thursday, 08 October 2026", result.Text);
    }

    [Fact]
    public void CursorOffset()
    {
        var r = SnippetExpander.Expand("<b>{cursor}</b>", null, null);
        Assert.Equal("<b></b>", r.Text);
        Assert.Equal(4, r.CursorOffsetFromEnd);
    }

    [Fact]
    public void LeavesJsonAlone()
    {
        const string json = """{"key": 1} and { spaced } and {} and {9lives}""";
        Assert.Empty(SnippetExpander.CustomFields(json));
        Assert.Equal(json, SnippetExpander.Expand(json, null, null).Text);
    }
}

public sealed class AITests
{
    [Fact]
    public void ClaudeRequestHasHeadersAndFallback()
    {
        var request = new ClaudeClient("sk-test", "claude-sonnet-5-5").MakeRequest("sys", "hello");
        Assert.Equal("https://api.anthropic.com/v1/messages", request.RequestUri!.ToString());
        Assert.Equal("sk-test", request.Headers.GetValues("x-api-key").Single());
        Assert.Equal("2023-06-01", request.Headers.GetValues("anthropic-version").Single());
        Assert.Equal(ClaudeClient.FallbackBeta, request.Headers.GetValues("anthropic-beta").Single());
        var body = request.Content!.ReadAsStringAsync().Result;
        Assert.Contains("\"fallbacks\":\"default\"", body);
        Assert.Contains("\"effort\":\"low\"", body);
    }

    [Fact]
    public void OpenAICompatibleRequest()
    {
        var request = new OpenAICompatibleClient("https://api.deepseek.com/", "sk-x", "deepseek-flash").MakeRequest("sys", "hi");
        Assert.Equal("https://api.deepseek.com/chat/completions", request.RequestUri!.ToString());
        Assert.Equal("Bearer sk-x", request.Headers.Authorization!.ToString());
        Assert.Throws<AIException>(() => new OpenAICompatibleClient("not a url", null, "m").MakeRequest("s", "u"));
    }

    [Fact]
    public void SseParsing()
    {
        Assert.Equal(new SseEvent.TextDelta("Hallo"), SseParser.Parse("""data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hallo"}}"""));
        Assert.Equal(new SseEvent.Stop("refusal"), SseParser.Parse("""data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"""));
        Assert.Null(SseParser.Parse("event: ping"));
        Assert.Equal(new SseEvent.TextDelta("Hi"), SseParser.ParseOpenAI("""data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"""));
        Assert.Equal(new SseEvent.Done(), SseParser.ParseOpenAI("data: [DONE]"));
        Assert.Equal("invalid x-api-key", SseParser.ErrorMessage("""{"type":"error","error":{"message":"invalid x-api-key"}}"""));
    }

    [Fact]
    public void CliEventParsing()
    {
        Assert.Equal(new ClaudeCodeCliClient.LineEvent.Delta("Guten"),
            ClaudeCodeCliClient.Parse("""{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Guten"}}}"""));
        Assert.Equal(new ClaudeCodeCliClient.LineEvent.Result(true, "Not logged in"),
            ClaudeCodeCliClient.Parse("""{"type":"result","is_error":true,"result":"Not logged in"}"""));
        Assert.Equal(new CodexCliClient.LineEvent.Message("Guten Morgen"),
            CodexCliClient.Parse("""{"type":"item.completed","item":{"type":"agent_message","text":"Guten Morgen"}}"""));
        Assert.Equal(new CodexCliClient.LineEvent.Other(),
            CodexCliClient.Parse("""{"type":"item.completed","item":{"type":"error","message":"metadata"}}"""));
        Assert.Equal("The 'x' model is not supported",
            CodexCliClient.InnerMessage("""{"type":"error","status":400,"error":{"message":"The 'x' model is not supported"}}"""));
    }

    [Theory]
    [InlineData("sk-ant-api03-abc", AIProviderKind.Anthropic)]
    [InlineData("sk-or-v1-abc", AIProviderKind.OpenRouter)]
    [InlineData("AIzaSyD-abc", AIProviderKind.Gemini)]
    [InlineData("gsk_abc", AIProviderKind.Groq)]
    [InlineData("xai-abc", AIProviderKind.XAI)]
    [InlineData("sk-proj-abc", AIProviderKind.OpenAI)]
    [InlineData("sk-0123456789abcdef0123456789abcdef", AIProviderKind.DeepSeek)]
    public void KeyDetection(string key, AIProviderKind first) => Assert.Equal(first, ApiKeyDetector.Candidates(key)[0]);

    [Fact]
    public void SubscriptionStatus()
    {
        Assert.Equal(SubscriptionPhase.SignedOut, SubscriptionCli.Claude.ParseStatus("""{"loggedIn": false}""")!.Phase);
        Assert.Equal("a@b.c", SubscriptionCli.Claude.ParseStatus("warn\n{\"loggedIn\": true, \"email\": \"a@b.c\"}")!.Detail);
        Assert.Equal(SubscriptionPhase.SignedIn, SubscriptionCli.Codex.ParseStatus("Logged in using ChatGPT")!.Phase);
        Assert.Equal(SubscriptionPhase.SignedOut, SubscriptionCli.Codex.ParseStatus("Not logged in")!.Phase);
        Assert.Null(SubscriptionCli.Codex.ParseStatus("boom"));
        Assert.Equal("https://claude.ai/oauth?x=1", SubscriptionAccount.FirstUrl("Open https://claude.ai/oauth?x=1."));
    }

    [Fact]
    public void FactoryNeedsKeysAndModels()
    {
        var keys = new MemoryKeys();
        Assert.Equal(AIErrorKind.MissingApiKey, Assert.Throws<AIException>(() => AIClientFactory.Make(AIProviderKind.DeepSeek, "deepseek-flash", "", keys)).Kind);
        Assert.Equal(AIErrorKind.MissingModel, Assert.Throws<AIException>(() => AIClientFactory.Make(AIProviderKind.Custom, " ", "http://x/v1", keys)).Kind);
        Assert.IsType<CodexCliClient>(AIClientFactory.Make(AIProviderKind.ChatGPT, "gpt-5.5", "", keys));
        Assert.DoesNotContain(AIProviderKind.ChatGPT, AIProviders.ApiProviders);
    }
}

internal sealed class MemoryKeys : IKeyStore
{
    private readonly Dictionary<string, string> _values = [];
    public string? Read(string account) => _values.GetValueOrDefault(account);
    public bool Save(string account, string value, string label) { _values[account] = value; return true; }
    public void Delete(string account) => _values.Remove(account);
}
