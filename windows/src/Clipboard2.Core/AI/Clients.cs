using System.Diagnostics;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Clipboard2.Core.AI;

public enum AIErrorKind { MissingApiKey, MissingModel, BadUrl, Http, Api, Refusal, InvalidResponse, CliNotFound, NotSignedIn }

public sealed class AIException(AIErrorKind kind, string message, AIProviderKind? provider = null) : Exception(message)
{
    public AIErrorKind Kind { get; } = kind;
    public AIProviderKind? Provider { get; } = provider;
    public bool NeedsSettings => Kind is AIErrorKind.MissingApiKey or AIErrorKind.MissingModel or AIErrorKind.BadUrl
        or AIErrorKind.CliNotFound or AIErrorKind.NotSignedIn;

    public static AIException MissingKey(AIProviderKind p) => new(AIErrorKind.MissingApiKey, $"Add your {p.Title()} API key in Settings → AI.", p);
    public static AIException NotSignedIn() => new(AIErrorKind.NotSignedIn, "Sign in with your account in Settings → AI.");
    public static AIException CliMissing(string service) => new(AIErrorKind.CliNotFound, $"{service} isn't set up yet. Open Settings → AI to install it and sign in.");
}

public abstract record SseEvent
{
    public sealed record TextDelta(string Text) : SseEvent;
    public sealed record Stop(string? Reason) : SseEvent;
    public sealed record Error(string Message) : SseEvent;
    public sealed record Done : SseEvent;
    public sealed record Other : SseEvent;
}

public static class SseParser
{
    private static JsonNode? Data(string line)
    {
        if (!line.StartsWith("data:")) return null;
        try { return JsonNode.Parse(line[5..].Trim()); } catch { return null; }
    }

    /// <summary>Anthropic Messages API stream.</summary>
    public static SseEvent? Parse(string line)
    {
        if (Data(line) is not JsonObject json || json["type"]?.GetValue<string>() is not { } type) return null;
        return type switch
        {
            "content_block_delta" when json["delta"]?["type"]?.GetValue<string>() == "text_delta"
                => new SseEvent.TextDelta(json["delta"]?["text"]?.GetValue<string>() ?? ""),
            "message_delta" => new SseEvent.Stop(json["delta"]?["stop_reason"]?.GetValue<string>()),
            "error" => new SseEvent.Error(json["error"]?["message"]?.GetValue<string>() ?? "Unknown API error"),
            _ => new SseEvent.Other(),
        };
    }

    /// <summary>OpenAI-style Chat Completions stream (also DeepSeek, OpenRouter, Ollama…).</summary>
    public static SseEvent? ParseOpenAI(string line)
    {
        if (!line.StartsWith("data:")) return null;
        if (line[5..].Trim() == "[DONE]") return new SseEvent.Done();
        if (Data(line) is not JsonObject json) return null;
        if (json["error"] is JsonObject error) return new SseEvent.Error(error["message"]?.GetValue<string>() ?? "Unknown API error");
        if (json["choices"] is not JsonArray { Count: > 0 } choices || choices[0] is not JsonObject choice) return new SseEvent.Other();
        if (choice["delta"]?["content"] is JsonValue content && content.GetValue<string>() is { Length: > 0 } text)
            return new SseEvent.TextDelta(text);
        if (choice["finish_reason"] is JsonValue reason) return new SseEvent.Stop(reason.GetValue<string>());
        return new SseEvent.Other();
    }

    public static string ErrorMessage(string body)
    {
        try
        {
            var json = JsonNode.Parse(body);
            return json?["error"]?["message"]?.GetValue<string>()
                ?? (json?["error"] is JsonValue v ? v.GetValue<string>() : null)
                ?? json?["message"]?.GetValue<string>()
                ?? body[..Math.Min(500, body.Length)];
        }
        catch { return body[..Math.Min(500, body.Length)]; }
    }
}

public interface IAIStreamingClient
{
    IAsyncEnumerable<string> StreamAsync(string system, string user, CancellationToken ct = default);
}

internal static class Http
{
    public static readonly HttpClient Client = new() { Timeout = TimeSpan.FromMinutes(2) };

    public static async IAsyncEnumerable<string> Lines(HttpRequestMessage request, [EnumeratorCancellation] CancellationToken ct)
    {
        using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(ct);
            throw new AIException(AIErrorKind.Http, $"Request failed ({(int)response.StatusCode}): {SseParser.ErrorMessage(body)}");
        }
        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        using var reader = new StreamReader(stream);
        while (await reader.ReadLineAsync(ct) is { } line) yield return line;
    }
}

public sealed class ClaudeClient(string apiKey, string model) : IAIStreamingClient
{
    public const string Endpoint = "https://api.anthropic.com/v1/messages";
    public const string FallbackBeta = "server-side-fallback-2026-07-01";
    public static readonly HashSet<string> FallbackModels = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-opus-5", "claude-fable-5-1"];
    public static readonly string[] EffortPrefixes = ["claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-sonnet-5", "claude-haiku-5",
        "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"];

    public HttpRequestMessage MakeRequest(string system, string user, int maxTokens = 8_192)
    {
        var body = new JsonObject
        {
            ["model"] = model,
            ["max_tokens"] = maxTokens,
            ["stream"] = true,
            ["system"] = system,
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = user }),
        };
        if (EffortPrefixes.Any(model.StartsWith)) body["output_config"] = new JsonObject { ["effort"] = "low" };
        var request = new HttpRequestMessage(HttpMethod.Post, Endpoint);
        request.Headers.Add("x-api-key", apiKey);
        request.Headers.Add("anthropic-version", "2023-06-01");
        if (FallbackModels.Contains(model))
        {
            body["fallbacks"] = "default";
            request.Headers.Add("anthropic-beta", FallbackBeta);
        }
        request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        return request;
    }

    public async IAsyncEnumerable<string> StreamAsync(string system, string user, [EnumeratorCancellation] CancellationToken ct = default)
    {
        await foreach (var line in Http.Lines(MakeRequest(system, user), ct))
        {
            switch (SseParser.Parse(line))
            {
                case SseEvent.TextDelta d: yield return d.Text; break;
                case SseEvent.Stop { Reason: "refusal" }: throw new AIException(AIErrorKind.Refusal, "The model declined this request.");
                case SseEvent.Error e: throw new AIException(AIErrorKind.Api, e.Message);
            }
        }
    }
}

/// <summary>OpenAI Chat Completions format — OpenAI, Gemini, DeepSeek, Groq, xAI, Mistral, OpenRouter, Ollama…</summary>
public sealed class OpenAICompatibleClient(string baseUrl, string? apiKey, string model, IReadOnlyDictionary<string, string>? extraHeaders = null)
    : IAIStreamingClient
{
    public HttpRequestMessage MakeRequest(string system, string user)
    {
        var trimmed = baseUrl.Trim().TrimEnd('/');
        if (!Uri.TryCreate(trimmed + "/chat/completions", UriKind.Absolute, out var url) || !url.Scheme.StartsWith("http"))
            throw new AIException(AIErrorKind.BadUrl, "The base URL in Settings → AI isn't valid.");
        var request = new HttpRequestMessage(HttpMethod.Post, url);
        if (!string.IsNullOrEmpty(apiKey)) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        foreach (var (k, v) in extraHeaders ?? new Dictionary<string, string>()) request.Headers.TryAddWithoutValidation(k, v);
        var body = new JsonObject
        {
            ["model"] = model,
            ["stream"] = true,
            ["messages"] = new JsonArray(
                new JsonObject { ["role"] = "system", ["content"] = system },
                new JsonObject { ["role"] = "user", ["content"] = user }),
        };
        request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        return request;
    }

    public async IAsyncEnumerable<string> StreamAsync(string system, string user, [EnumeratorCancellation] CancellationToken ct = default)
    {
        await foreach (var line in Http.Lines(MakeRequest(system, user), ct))
        {
            switch (SseParser.ParseOpenAI(line))
            {
                case SseEvent.TextDelta d: yield return d.Text; break;
                case SseEvent.Stop { Reason: "content_filter" }: throw new AIException(AIErrorKind.Refusal, "The model declined this request.");
                case SseEvent.Error e: throw new AIException(AIErrorKind.Api, e.Message);
                case SseEvent.Done: yield break;
            }
        }
    }
}

/// <summary>Finds and launches the vendors' CLIs (Claude Code, Codex) on Windows.</summary>
public static class Cli
{
    private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    private static string AppData => Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    private static string LocalAppData => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    public static string? Find(string name)
    {
        string[] candidates =
        [
            Path.Combine(Home, ".local", "bin", name + ".exe"),
            Path.Combine(AppData, "npm", name + ".cmd"),
            Path.Combine(LocalAppData, "Programs", name, name + ".exe"),
            Path.Combine(Home, "scoop", "shims", name + ".exe"),
            Path.Combine(Home, ".local", "bin", name),          // macOS/Linux, for tests
            "/opt/homebrew/bin/" + name,
        ];
        var found = candidates.FirstOrDefault(File.Exists);
        if (found is not null) return found;
        // Fall back to PATH.
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            foreach (var ext in new[] { ".exe", ".cmd", "" })
            {
                var path = Path.Combine(dir, name + ext);
                if (File.Exists(path)) return path;
            }
        }
        return null;
    }

    /// <summary>.cmd shims (npm) must run through cmd.exe.</summary>
    public static ProcessStartInfo StartInfo(string executable, IEnumerable<string> arguments)
    {
        var info = new ProcessStartInfo
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            WorkingDirectory = Path.GetTempPath(),   // keeps project instruction files out of the prompt
        };
        if (executable.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase))
        {
            info.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
            info.ArgumentList.Add("/c");
            info.ArgumentList.Add(executable);
        }
        else
        {
            info.FileName = executable;
        }
        foreach (var a in arguments) info.ArgumentList.Add(a);
        return info;
    }

    public static async Task<(int ExitCode, string Output)> RunAsync(string executable, IEnumerable<string> arguments,
                                                                      TimeSpan? timeout = null, CancellationToken ct = default)
    {
        using var process = Process.Start(StartInfo(executable, arguments)) ?? throw new InvalidOperationException("Couldn't start " + executable);
        process.StandardInput.Close();
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout ?? TimeSpan.FromMinutes(5));
        var stdout = process.StandardOutput.ReadToEndAsync(cts.Token);
        var stderr = process.StandardError.ReadToEndAsync(cts.Token);
        try { await process.WaitForExitAsync(cts.Token); }
        catch (OperationCanceledException) { try { process.Kill(true); } catch { } throw; }
        return (process.ExitCode, await stdout + await stderr);
    }

    /// <summary>Starts the CLI, writes the prompt to stdin and yields stdout lines.</summary>
    public static async IAsyncEnumerable<string> StreamLinesAsync(string executable, IEnumerable<string> arguments, string stdin,
                                                                  [EnumeratorCancellation] CancellationToken ct)
    {
        using var process = Process.Start(StartInfo(executable, arguments)) ?? throw new InvalidOperationException("Couldn't start " + executable);
        using var registration = ct.Register(() => { try { if (!process.HasExited) process.Kill(true); } catch { } });
        await process.StandardInput.WriteAsync(stdin);
        process.StandardInput.Close();
        _ = process.StandardError.ReadToEndAsync(ct);
        while (await process.StandardOutput.ReadLineAsync(ct) is { } line) yield return line;
    }
}

/// <summary>Claude Code CLI (<c>claude -p</c>) on the user's Claude Pro/Max login.</summary>
public sealed class ClaudeCodeCliClient(string model) : IAIStreamingClient
{
    public static string? Executable => Cli.Find("claude");

    public List<string> Arguments(string system)
    {
        var args = new List<string>
        {
            "-p", "--system-prompt", system, "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
            "--no-session-persistence", "--output-format", "stream-json", "--include-partial-messages", "--verbose",
        };
        if (model.Length > 0) args.AddRange(["--model", model]);
        return args;
    }

    public abstract record LineEvent
    {
        public sealed record Delta(string Text) : LineEvent;
        public sealed record Message(string Text) : LineEvent;
        public sealed record Result(bool IsError, string Text) : LineEvent;
        public sealed record Other : LineEvent;
    }

    public static LineEvent Parse(string line)
    {
        JsonNode? json;
        try { json = JsonNode.Parse(line); } catch { return new LineEvent.Other(); }
        switch (json?["type"]?.GetValue<string>())
        {
            case "stream_event":
                var ev = json["event"];
                if (ev?["type"]?.GetValue<string>() == "content_block_delta" && ev["delta"]?["type"]?.GetValue<string>() == "text_delta")
                    return new LineEvent.Delta(ev["delta"]?["text"]?.GetValue<string>() ?? "");
                return new LineEvent.Other();
            case "assistant":
                var text = string.Concat((json["message"]?["content"] as JsonArray ?? [])
                    .Where(c => c?["type"]?.GetValue<string>() == "text").Select(c => c?["text"]?.GetValue<string>()));
                return text.Length == 0 ? new LineEvent.Other() : new LineEvent.Message(text);
            case "result":
                return new LineEvent.Result(json["is_error"]?.GetValue<bool>() ?? false, json["result"]?.GetValue<string>() ?? "");
            default:
                return new LineEvent.Other();
        }
    }

    public async IAsyncEnumerable<string> StreamAsync(string system, string user, [EnumeratorCancellation] CancellationToken ct = default)
    {
        var exe = Executable ?? throw AIException.CliMissing("Claude");
        var streamed = false;
        var buffered = new StringBuilder();
        await foreach (var line in Cli.StreamLinesAsync(exe, Arguments(system), user, ct))
        {
            switch (Parse(line))
            {
                case LineEvent.Delta d:
                    streamed = true;
                    yield return d.Text;
                    break;
                case LineEvent.Message m:
                    buffered.Append(m.Text);
                    break;
                case LineEvent.Result r when r.IsError:
                    if (r.Text.Contains("not logged in", StringComparison.OrdinalIgnoreCase) || r.Text.Contains("/login")) throw AIException.NotSignedIn();
                    throw new AIException(AIErrorKind.Api, r.Text.Length == 0 ? "Claude reported an error." : r.Text);
                case LineEvent.Result r:
                    if (!streamed) yield return buffered.Length > 0 ? buffered.ToString() : r.Text;
                    break;
            }
        }
    }
}

/// <summary>OpenAI's Codex CLI (<c>codex exec</c>) on the user's ChatGPT plan.</summary>
public sealed class CodexCliClient(string model) : IAIStreamingClient
{
    public static string? Executable => Cli.Find("codex");

    public List<string> Arguments()
    {
        var args = new List<string> { "exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--ignore-rules", "--ignore-user-config", "--json" };
        if (model.Length > 0) args.AddRange(["-m", model]);
        args.Add("-");
        return args;
    }

    public abstract record LineEvent
    {
        public sealed record Message(string Text) : LineEvent;
        public sealed record Failure(string Text) : LineEvent;
        public sealed record Other : LineEvent;
    }

    public static LineEvent Parse(string line)
    {
        JsonNode? json;
        try { json = JsonNode.Parse(line); } catch { return new LineEvent.Other(); }
        switch (json?["type"]?.GetValue<string>())
        {
            case "item.completed":
                var item = json["item"];
                return item?["type"]?.GetValue<string>() == "agent_message" && item["text"]?.GetValue<string>() is { } text
                    ? new LineEvent.Message(text) : new LineEvent.Other();
            case "turn.failed" or "error":
                var raw = json["error"]?["message"]?.GetValue<string>() ?? json["message"]?.GetValue<string>() ?? "Unknown error";
                return new LineEvent.Failure(InnerMessage(raw));
            default:
                return new LineEvent.Other();
        }
    }

    public static string InnerMessage(string raw)
    {
        try { return JsonNode.Parse(raw)?["error"]?["message"]?.GetValue<string>() ?? raw; }
        catch { return raw; }
    }

    public async IAsyncEnumerable<string> StreamAsync(string system, string user, [EnumeratorCancellation] CancellationToken ct = default)
    {
        var exe = Executable ?? throw AIException.CliMissing("ChatGPT");
        await foreach (var line in Cli.StreamLinesAsync(exe, Arguments(), system + "\n\n" + user, ct))
        {
            switch (Parse(line))
            {
                case LineEvent.Message m: yield return m.Text; break;
                case LineEvent.Failure f:
                    var lower = f.Text.ToLowerInvariant();
                    if (lower.Contains("not logged in") || lower.Contains("401") || lower.Contains("unauthorized") || lower.Contains("login"))
                        throw AIException.NotSignedIn();
                    throw new AIException(AIErrorKind.Api, f.Text);
            }
        }
    }
}

public static class AIClientFactory
{
    public static IAIStreamingClient Make(AIProviderKind provider, string model, string customBaseUrl, IKeyStore keys)
    {
        model = model.Trim();
        if (!provider.IsSubscription() && model.Length == 0)
            throw new AIException(AIErrorKind.MissingModel, "Choose a model in Settings → AI.");
        var key = provider.UsesApiKey() ? keys.Read(provider.KeychainAccount()) : null;
        if (provider.RequiresApiKey() && key is null) throw AIException.MissingKey(provider);
        return provider switch
        {
            AIProviderKind.Anthropic => new ClaudeClient(key!, model),
            AIProviderKind.OpenRouter => new OpenAICompatibleClient(provider.DefaultBaseUrl(), key, model,
                new Dictionary<string, string> { ["X-Title"] = "Clipboard2" }),
            AIProviderKind.Custom => new OpenAICompatibleClient(customBaseUrl, key, model),
            AIProviderKind.ClaudeCode => new ClaudeCodeCliClient(model),
            AIProviderKind.ChatGPT => new CodexCliClient(model),
            _ => new OpenAICompatibleClient(provider.DefaultBaseUrl(), key, model),
        };
    }
}

/// <summary>Lists models from each provider's /models endpoint so IDs never go stale.</summary>
public sealed class ModelLister(IKeyStore keys)
{
    public static readonly string[] ClaudeCodeModels = ["sonnet", "opus", "haiku"];

    public async Task<List<string>> FetchAsync(AIProviderKind provider, string customBaseUrl, string? apiKey = null, CancellationToken ct = default)
    {
        if (provider == AIProviderKind.ClaudeCode) return [.. ClaudeCodeModels];
        if (provider == AIProviderKind.ChatGPT) return ChatGptModels();
        var baseUrl = (provider == AIProviderKind.Custom ? customBaseUrl : provider.DefaultBaseUrl()).Trim().TrimEnd('/');
        if (!Uri.TryCreate(baseUrl + "/models", UriKind.Absolute, out var url))
            throw new AIException(AIErrorKind.BadUrl, "The base URL in Settings → AI isn't valid.");
        var key = apiKey ?? keys.Read(provider.KeychainAccount());
        if (provider.RequiresApiKey() && key is null) throw AIException.MissingKey(provider);
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (provider == AIProviderKind.Anthropic)
        {
            request.Headers.Add("x-api-key", key);
            request.Headers.Add("anthropic-version", "2023-06-01");
        }
        else if (key is not null)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        }
        using var response = await Http.Client.SendAsync(request, ct);
        var body = await response.Content.ReadAsStringAsync(ct);
        if (!response.IsSuccessStatusCode)
            throw new AIException(AIErrorKind.Http, $"Request failed ({(int)response.StatusCode}): {SseParser.ErrorMessage(body)}");
        var data = JsonNode.Parse(body)?["data"] as JsonArray ?? throw new AIException(AIErrorKind.InvalidResponse, "Unexpected response from the API.");
        var ids = data.Select(m => m?["id"]?.GetValue<string>()?.Replace("models/", "")).OfType<string>().Order().ToList();
        return provider == AIProviderKind.OpenAI ? [.. Relevant(ids)] : ids;
    }

    /// <summary>OpenAI's list includes embeddings, audio, image and moderation models; keep chat ones.</summary>
    public static IEnumerable<string> Relevant(IEnumerable<string> ids)
    {
        string[] excluded = ["embedding", "whisper", "tts", "dall-e", "image", "audio", "moderation", "realtime", "transcribe", "search", "davinci", "babbage", "sora"];
        return ids.Where(id => !excluded.Any(id.Contains));
    }

    public static string? PreferredModel(IReadOnlyList<string> models, AIProviderKind provider)
    {
        foreach (var hint in provider.PreferredModelHints())
            if (models.FirstOrDefault(m => m.Contains(hint)) is { } match) return match;
        return models.FirstOrDefault();
    }

    /// <summary>Models a ChatGPT login may use, from Codex's own cache.</summary>
    public static List<string> ChatGptModels()
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "models_cache.json");
        try
        {
            var json = JsonNode.Parse(File.ReadAllText(path));
            var list = (json as JsonArray) ?? (json?["models"] as JsonArray);
            var slugs = list?.Select(m => (m?["slug"] ?? m?["id"])?.GetValue<string>()).OfType<string>()
                .Where(s => !s.Contains("review")).ToList() ?? [];
            return slugs.Count > 0 ? slugs : ["gpt-5.5"];
        }
        catch { return ["gpt-5.5"]; }
    }
}
