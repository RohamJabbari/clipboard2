namespace Clipboard2.Core.AI;

/// <summary>Where API keys live (Windows Credential Manager in the app, in-memory in tests).</summary>
public interface IKeyStore
{
    string? Read(string account);
    bool Save(string account, string value, string label);
    void Delete(string account);
}

public enum AIProviderKind
{
    ClaudeCode, ChatGPT, Anthropic, OpenAI, Gemini, DeepSeek, Groq, XAI, Mistral, OpenRouter, Custom,
}

public static class AIProviders
{
    public static readonly AIProviderKind[] All = Enum.GetValues<AIProviderKind>();
    public static readonly AIProviderKind[] ApiProviders = [.. All.Where(p => !p.IsSubscription())];

    /// <summary>Signed in with a consumer plan through the vendor's own CLI, not an API key.</summary>
    public static bool IsSubscription(this AIProviderKind p) => p is AIProviderKind.ClaudeCode or AIProviderKind.ChatGPT;

    public static string Title(this AIProviderKind p) => p switch
    {
        AIProviderKind.ClaudeCode => "Claude — sign in with your account",
        AIProviderKind.ChatGPT => "ChatGPT — sign in with your account",
        AIProviderKind.Anthropic => "Anthropic (Claude)",
        AIProviderKind.OpenAI => "OpenAI (GPT)",
        AIProviderKind.Gemini => "Google Gemini",
        AIProviderKind.DeepSeek => "DeepSeek",
        AIProviderKind.Groq => "Groq",
        AIProviderKind.XAI => "xAI (Grok)",
        AIProviderKind.Mistral => "Mistral",
        AIProviderKind.OpenRouter => "OpenRouter",
        _ => "Custom endpoint (OpenAI-compatible)",
    };

    public static string ShortName(this AIProviderKind p) => p switch
    {
        AIProviderKind.ClaudeCode or AIProviderKind.Anthropic => "Claude",
        AIProviderKind.ChatGPT or AIProviderKind.OpenAI => "GPT",
        AIProviderKind.Gemini => "Gemini",
        AIProviderKind.DeepSeek => "DeepSeek",
        AIProviderKind.Groq => "Groq",
        AIProviderKind.XAI => "Grok",
        AIProviderKind.Mistral => "Mistral",
        AIProviderKind.OpenRouter => "OpenRouter",
        _ => "AI",
    };

    public static string DefaultBaseUrl(this AIProviderKind p) => p switch
    {
        AIProviderKind.Anthropic => "https://api.anthropic.com/v1",
        AIProviderKind.OpenAI => "https://api.openai.com/v1",
        AIProviderKind.Gemini => "https://generativelanguage.googleapis.com/v1beta/openai",
        AIProviderKind.DeepSeek => "https://api.deepseek.com",
        AIProviderKind.Groq => "https://api.groq.com/openai/v1",
        AIProviderKind.XAI => "https://api.x.ai/v1",
        AIProviderKind.Mistral => "https://api.mistral.ai/v1",
        AIProviderKind.OpenRouter => "https://openrouter.ai/api/v1",
        AIProviderKind.Custom => "http://localhost:11434/v1",
        _ => "",
    };

    /// <summary>Empty means "pick from the provider's live model list".</summary>
    public static string DefaultModel(this AIProviderKind p) => p switch
    {
        AIProviderKind.Anthropic => "claude-sonnet-5-5",
        AIProviderKind.OpenAI => "gpt-5.6",
        AIProviderKind.DeepSeek => "deepseek-flash",
        AIProviderKind.OpenRouter => "openrouter/auto",
        AIProviderKind.ClaudeCode => "sonnet",
        AIProviderKind.ChatGPT => "gpt-5.5",
        _ => "",
    };

    public static string[] PreferredModelHints(this AIProviderKind p) => p switch
    {
        AIProviderKind.Gemini => ["flash", "pro"],
        AIProviderKind.Groq => ["llama", "qwen"],
        AIProviderKind.XAI => ["grok"],
        AIProviderKind.Mistral => ["mistral-medium-latest", "mistral-small-latest", "latest"],
        _ => [],
    };

    public static bool RequiresApiKey(this AIProviderKind p) => !p.IsSubscription() && p != AIProviderKind.Custom;
    public static bool UsesApiKey(this AIProviderKind p) => !p.IsSubscription();
    public static string KeychainAccount(this AIProviderKind p) => p == AIProviderKind.Anthropic ? "api-key" : $"api-key-{p.ToString().ToLowerInvariant()}";
}

/// <summary>Works out which provider an API key belongs to: prefix first, then a live check.</summary>
public static class ApiKeyDetector
{
    public static List<AIProviderKind> Candidates(string rawKey)
    {
        var key = rawKey.Trim();
        if (key.StartsWith("sk-ant-")) return [AIProviderKind.Anthropic];
        if (key.StartsWith("sk-or-")) return [AIProviderKind.OpenRouter];
        if (key.StartsWith("AIza")) return [AIProviderKind.Gemini];
        if (key.StartsWith("gsk_")) return [AIProviderKind.Groq];
        if (key.StartsWith("xai-")) return [AIProviderKind.XAI];
        if (key.StartsWith("sk-proj-") || key.StartsWith("sk-svcacct-") || key.StartsWith("sk-admin-")) return [AIProviderKind.OpenAI];
        if (key.StartsWith("sk-"))
        {
            // DeepSeek keys are "sk-" + 32 hex characters; OpenAI's legacy keys are longer.
            var body = key[3..];
            var hex32 = body.Length == 32 && body.All(Uri.IsHexDigit);
            return hex32 ? [AIProviderKind.DeepSeek, AIProviderKind.OpenAI] : [AIProviderKind.OpenAI, AIProviderKind.DeepSeek];
        }
        if (key.Length == 32 && key.All(char.IsLetterOrDigit)) return [AIProviderKind.Mistral];
        return [];
    }

    public static async Task<AIProviderKind?> IdentifyAsync(string key, ModelLister lister, CancellationToken ct = default)
    {
        foreach (var provider in Candidates(key))
        {
            try
            {
                await lister.FetchAsync(provider, "", key, ct);
                return provider;
            }
            catch (OperationCanceledException) { throw; }
            catch { /* try the next candidate */ }
        }
        return null;
    }
}

public abstract record AIAction
{
    public sealed record Translate(string Language) : AIAction;
    public sealed record Summarize : AIAction;
    public sealed record FixGrammar : AIAction;
    public sealed record Explain : AIAction;
    public sealed record Custom(CustomPrompt Prompt) : AIAction;
    /// <summary>Free-form instruction typed into the Ctrl+K filter.</summary>
    public sealed record Instruction(string Text) : AIAction;

    public static readonly IReadOnlyList<AIAction> BuiltIn =
    [
        new Translate("English"), new Translate("German"), new Translate("Farsi"),
        new Summarize(), new FixGrammar(), new Explain(),
    ];

    public string Title => this switch
    {
        Translate t => $"Translate to {t.Language}",
        Summarize => "Summarize",
        FixGrammar => "Fix Grammar",
        Explain => "Explain",
        Custom c => string.IsNullOrEmpty(c.Prompt.Name) ? "Custom Prompt" : c.Prompt.Name,
        Instruction i => i.Text,
        _ => "",
    };

    public string SystemPrompt
    {
        get
        {
            const string suffix = "The input is the text inside the <text> tags. Reply with the result only — no preamble, quotes or commentary.";
            return this switch
            {
                Translate t => $"Translate the input into {t.Language}. Preserve meaning, tone, formatting and line breaks. {suffix}",
                Summarize => $"Summarize the input concisely in the same language as the input. {suffix}",
                FixGrammar => $"Correct grammar, spelling and punctuation in the input. Keep its language, meaning, tone and formatting unchanged otherwise. {suffix}",
                Explain => "Explain the input clearly and concisely for a smart reader. If it is code, explain what it does. Answer in the language of the input unless it is code. The input is the text inside the <text> tags.",
                Custom c => $"{c.Prompt.Prompt}\n\n{suffix}",
                Instruction i => $"Do the following with the input: {i.Text}\n\nIf it asks a question about the input, answer it concisely. Otherwise reply with the resulting text only — no preamble, quotes or commentary. The input is the text inside the <text> tags.",
                _ => suffix,
            };
        }
    }

    public static string UserMessage(string input) => $"<text>\n{input}\n</text>";
}
