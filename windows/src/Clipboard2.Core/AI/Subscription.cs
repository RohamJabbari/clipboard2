using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Clipboard2.Core.AI;

public enum SubscriptionCli { Claude, Codex }

public static class SubscriptionClis
{
    public static string ServiceName(this SubscriptionCli c) => c == SubscriptionCli.Claude ? "Claude" : "ChatGPT";
    public static string ToolName(this SubscriptionCli c) => c == SubscriptionCli.Claude ? "Claude Code" : "Codex";
    public static string PlanName(this SubscriptionCli c) => c == SubscriptionCli.Claude ? "Claude Pro or Max" : "ChatGPT Plus, Pro or Team";
    public static string? Executable(this SubscriptionCli c) => c == SubscriptionCli.Claude ? ClaudeCodeCliClient.Executable : CodexCliClient.Executable;
    public static string[] StatusArguments(this SubscriptionCli c) => c == SubscriptionCli.Claude ? ["auth", "status"] : ["login", "status"];
    public static string[] LoginArguments(this SubscriptionCli c) => c == SubscriptionCli.Claude ? ["auth", "login", "--claudeai"] : ["login"];
    public static string[] LogoutArguments(this SubscriptionCli c) => c == SubscriptionCli.Claude ? ["auth", "logout"] : ["logout"];

    /// <summary>Installer command run through PowerShell; no admin rights needed.</summary>
    public static string InstallCommand(this SubscriptionCli c) => c == SubscriptionCli.Claude
        ? "irm https://claude.ai/install.ps1 | iex"
        : "npm install -g @openai/codex";

    public static SubscriptionState? ParseStatus(this SubscriptionCli c, string output)
    {
        if (c == SubscriptionCli.Claude)
        {
            var start = output.IndexOf('{');
            var end = output.LastIndexOf('}');
            if (start < 0 || end <= start) return null;
            try
            {
                var json = JsonNode.Parse(output[start..(end + 1)]);
                if (json?["loggedIn"]?.GetValue<bool>() != true) return SubscriptionState.SignedOut();
                var account = new[] { "email", "emailAddress", "account", "organizationName" }
                    .Select(k => json[k]?.GetValue<string>()).FirstOrDefault(v => v is not null);
                return SubscriptionState.SignedIn(account);
            }
            catch { return null; }
        }
        var lower = output.ToLowerInvariant();
        if (lower.Contains("not logged in")) return SubscriptionState.SignedOut();
        if (lower.Contains("logged in")) return SubscriptionState.SignedIn(lower.Contains("chatgpt") ? "ChatGPT account" : "API key");
        return null;
    }
}

public enum SubscriptionPhase { Checking, NotInstalled, Installing, SignedOut, SigningIn, SignedIn, Failed }

public sealed record SubscriptionState(SubscriptionPhase Phase, string? Detail = null)
{
    public static SubscriptionState SignedIn(string? account) => new(SubscriptionPhase.SignedIn, account);
    public static SubscriptionState SignedOut() => new(SubscriptionPhase.SignedOut);
    public static SubscriptionState Failed(string message) => new(SubscriptionPhase.Failed, message);
}

/// <summary>Install, sign in (browser) and sign out for a subscription provider, all from the app.
/// The vendor's CLI owns the login; Clipboard2 never sees subscription tokens.</summary>
public sealed class SubscriptionAccount(SubscriptionCli cli)
{
    public SubscriptionCli Cli { get; } = cli;
    public SubscriptionState State { get; private set; } = new(SubscriptionPhase.Checking);
    public string? SignInUrl { get; private set; }
    public bool NeedsCode { get; private set; }
    public bool IsSignedIn => State.Phase == SubscriptionPhase.SignedIn;
    /// <summary>Raised on any state change; may fire on a background thread.</summary>
    public event Action? Changed;

    private Process? _login;

    private void Set(SubscriptionState state)
    {
        State = state;
        Changed?.Invoke();
    }

    public async Task RefreshAsync()
    {
        if (Cli.Executable() is not { } exe)
        {
            Set(new(SubscriptionPhase.NotInstalled));
            return;
        }
        if (State.Phase is not (SubscriptionPhase.SigningIn or SubscriptionPhase.Installing)) Set(new(SubscriptionPhase.Checking));
        try
        {
            var (_, output) = await AI.Cli.RunAsync(exe, Cli.StatusArguments(), TimeSpan.FromSeconds(30));
            Set(Cli.ParseStatus(output) ?? SubscriptionState.Failed($"Couldn't read the {Cli.ServiceName()} sign-in status."));
        }
        catch (Exception ex)
        {
            Set(SubscriptionState.Failed(ex.Message));
        }
    }

    public void SignIn()
    {
        if (Cli.Executable() is not { } exe)
        {
            Set(new(SubscriptionPhase.NotInstalled));
            return;
        }
        CancelSignIn();
        SignInUrl = null;
        NeedsCode = false;
        Set(new(SubscriptionPhase.SigningIn));
        try
        {
            var process = Process.Start(AI.Cli.StartInfo(exe, Cli.LoginArguments())) ?? throw new InvalidOperationException("Couldn't start sign-in.");
            process.EnableRaisingEvents = true;
            _output.Clear();
            // Read raw chunks, not lines: the "Paste code here >" prompt has no line break.
            _ = PumpAsync(process.StandardOutput);
            _ = PumpAsync(process.StandardError);
            process.Exited += async (_, _) =>
            {
                _login = null;
                NeedsCode = false;
                await RefreshAsync();
            };
            _login = process;
        }
        catch (Exception ex)
        {
            Set(SubscriptionState.Failed(ex.Message));
        }
    }

    private readonly System.Text.StringBuilder _output = new();

    private async Task PumpAsync(StreamReader reader)
    {
        var buffer = new char[1024];
        try
        {
            int read;
            while ((read = await reader.ReadAsync(buffer, 0, buffer.Length)) > 0) HandleOutput(new string(buffer, 0, read));
        }
        catch { /* process ended */ }
    }

    private void HandleOutput(string chunk)
    {
        string text;
        lock (_output) text = _output.Append(chunk).ToString();
        var lastNewline = text.LastIndexOf('\n');
        if (SignInUrl is null && lastNewline >= 0 && FirstUrl(text[..lastNewline]) is { } url)
        {
            SignInUrl = url;
            // Without a console the CLI often can't open the browser itself; do it here.
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
        }
        var lower = text.ToLowerInvariant();
        if (lower.Contains("paste") && lower.Contains("code")) NeedsCode = true;
        Changed?.Invoke();
    }

    public static string? FirstUrl(string line) =>
        Regex.Match(line, @"https://[^\s""'<>]+") is { Success: true } m ? m.Value.TrimEnd('.', ',', ')') : null;

    public void SubmitCode(string code)
    {
        if (_login is null || string.IsNullOrWhiteSpace(code)) return;
        try { _login.StandardInput.WriteLine(code.Trim()); } catch { }
    }

    public void CancelSignIn()
    {
        try { if (_login is { HasExited: false }) _login.Kill(true); } catch { }
        _login = null;
    }

    public async Task SignOutAsync()
    {
        if (Cli.Executable() is not { } exe) return;
        try { await AI.Cli.RunAsync(exe, Cli.LogoutArguments(), TimeSpan.FromSeconds(30)); } catch { }
        await RefreshAsync();
    }

    public async Task InstallAsync()
    {
        Set(new(SubscriptionPhase.Installing));
        try
        {
            var (code, output) = await AI.Cli.RunAsync("powershell.exe",
                ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", Cli.InstallCommand()], TimeSpan.FromMinutes(10));
            if (code != 0 || Cli.Executable() is null)
            {
                var tail = string.Join(" ", output.Split('\n', StringSplitOptions.RemoveEmptyEntries).TakeLast(2));
                Set(SubscriptionState.Failed($"Installation failed. {tail}"));
                return;
            }
        }
        catch (Exception ex)
        {
            Set(SubscriptionState.Failed($"Installation failed. {ex.Message}"));
            return;
        }
        await RefreshAsync();
    }
}

/// <summary>One streaming AI request shown in the quick panel's preview pane.</summary>
public sealed class AIRun(AIAction action, ClipItem item, string providerName)
{
    public AIAction Action { get; } = action;
    public ClipItem Item { get; } = item;
    public string ProviderName { get; } = providerName;
    public string Output { get; private set; } = "";
    public bool IsStreaming { get; private set; }
    public AIException? Error { get; private set; }
    public string? ErrorMessage { get; private set; }
    public bool IsFinished => !IsStreaming && ErrorMessage is null && Output.Length > 0;
    /// <summary>Raised on progress; may fire on a background thread.</summary>
    public event Action? Changed;

    private CancellationTokenSource? _cts;

    public void Start(Func<IAIStreamingClient> makeClient)
    {
        IAIStreamingClient client;
        try { client = makeClient(); }
        catch (Exception ex) { Fail(ex); return; }
        IsStreaming = true;
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;
        var system = Action.SystemPrompt;
        var user = AIAction.UserMessage(Item.Text);
        _ = Task.Run(async () =>
        {
            try
            {
                await foreach (var chunk in client.StreamAsync(system, user, ct))
                {
                    Output += chunk;
                    Changed?.Invoke();
                }
                IsStreaming = false;
                if (Output.Length == 0) ErrorMessage = "The model returned an empty response.";
                Changed?.Invoke();
            }
            catch (OperationCanceledException)
            {
                IsStreaming = false;
            }
            catch (Exception ex)
            {
                IsStreaming = false;
                Fail(ex);
            }
        }, ct);
    }

    private void Fail(Exception ex)
    {
        Error = ex as AIException;
        ErrorMessage = ex.Message;
        Changed?.Invoke();
    }

    public void Cancel()
    {
        _cts?.Cancel();
        IsStreaming = false;
    }
}
