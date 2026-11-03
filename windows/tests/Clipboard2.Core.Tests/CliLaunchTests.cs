using Clipboard2.Core.AI;

namespace Clipboard2.Core.Tests;

/// <summary>Launching the npm-installed AI CLIs (claude.cmd, codex.cmd) on Windows.</summary>
public sealed class CliLaunchTests
{
    private const string ModernNodeShim = """
        @ECHO off
        GOTO start
        :find_dp0
        SET dp0=%~dp0
        EXIT /b
        :start
        SETLOCAL
        CALL :find_dp0

        IF EXIST "%dp0%\node.exe" (
          SET "_prog=%dp0%\node.exe"
        ) ELSE (
          SET "_prog=node"
          SET PATHEXT=%PATHEXT:;.JS;=;%
        )

        endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\node_modules\@openai\codex\bin\codex.js" %*
        """;

    private const string NativeShim = """
        @ECHO off
        GOTO start
        :find_dp0
        SET dp0=%~dp0
        EXIT /b
        :start
        SETLOCAL
        CALL :find_dp0
        "%dp0%\node_modules\@anthropic-ai\claude-code\bin\claude.exe"   %*
        """;

    private const string LegacyShim = """
        @IF EXIST "%~dp0\node.exe" (
          "%~dp0\node.exe"  "%~dp0\node_modules\@anthropic-ai\claude-code\cli.js" %*
        ) ELSE (
          @SETLOCAL
          @SET PATHEXT=%PATHEXT:;.JS;=;%
          node  "%~dp0\node_modules\@anthropic-ai\claude-code\cli.js" %*
        )
        """;

    [Fact]
    public void ParsesNpmShims()
    {
        Assert.Equal((@"node_modules\@openai\codex\bin\codex.js", true), Cli.ParseShim(ModernNodeShim));
        Assert.Equal((@"node_modules\@anthropic-ai\claude-code\bin\claude.exe", false), Cli.ParseShim(NativeShim));
        Assert.Equal((@"node_modules\@anthropic-ai\claude-code\cli.js", true), Cli.ParseShim(LegacyShim));
        Assert.Null(Cli.ParseShim("@echo off\r\necho hi\r\n"));
    }

    [Fact]
    public void ResolvesShimToNodeAndScript()
    {
        var shim = Path.Combine("C:", "Users", "A B", "AppData", "Roaming", "npm", "codex.cmd");
        var launch = Cli.Resolve(shim, _ => true, () => "node.exe", ModernNodeShim);
        Assert.False(launch.ViaCmd);
        Assert.EndsWith("node.exe", launch.FileName);
        Assert.Single(launch.Prefix);
        Assert.EndsWith("codex.js", launch.Prefix[0]);
    }

    [Fact]
    public void ResolvesShimToNativeExe()
    {
        var launch = Cli.Resolve(Path.Combine("npm", "claude.cmd"), _ => true, () => null, NativeShim);
        Assert.False(launch.ViaCmd);
        Assert.EndsWith("claude.exe", launch.FileName);
        Assert.Empty(launch.Prefix);
    }

    [Fact]
    public void FallsBackToCmdWithoutNodeOrForUnknownShims()
    {
        var shim = Path.Combine("npm", "claude.cmd");
        Assert.True(Cli.Resolve(shim, p => !p.EndsWith("node.exe"), () => null, LegacyShim).ViaCmd);
        Assert.True(Cli.Resolve(shim, _ => true, () => "node.exe", "@echo off").ViaCmd);
        Assert.False(Cli.Resolve("claude.exe").ViaCmd);
    }

    [Fact]
    public void CmdFallbackQuotesWholeCommandLine()
    {
        var args = Cli.CmdArguments(@"C:\Users\A B\npm\claude.cmd", ["-p", "--tools", "", "a & b"]);
        // /s strips only the outer pair, leaving every argument quoted.
        Assert.Equal("/d /s /c \"\"C:\\Users\\A B\\npm\\claude.cmd\" \"-p\" \"--tools\" \"\" \"a & b\"\"", args);
        Assert.Throws<ArgumentException>(() => Cli.CmdArguments("x.cmd", ["line1\nline2"]));
    }

    [Theory]
    [InlineData("plain", "\"plain\"")]
    [InlineData("say \"hi\"", "\"say \\\"hi\\\"\"")]
    [InlineData(@"C:\dir\", "\"C:\\dir\\\\\"")]
    [InlineData(@"a\\""b", "\"a\\\\\\\\\\\"b\"")]
    public void QuotesLikeCommandLineToArgvW(string arg, string expected) => Assert.Equal(expected, Cli.Quote(arg));

    [Fact]
    public void ClaudeArgumentsUseFileForSystemPromptWhenNeeded()
    {
        var client = new ClaudeCodeCliClient("sonnet");
        var inline = client.Arguments("line 1\nline 2");
        Assert.Equal("--system-prompt", inline[1]);
        Assert.Equal("line 1\nline 2", inline[2]);

        var viaFile = client.Arguments("line 1\nline 2", @"C:\Temp\prompt.txt");
        Assert.Equal("--system-prompt-file", viaFile[1]);
        Assert.Equal(@"C:\Temp\prompt.txt", viaFile[2]);
        Assert.DoesNotContain(viaFile, a => a.Contains('\n'));
        Assert.Equal(["--model", "sonnet"], viaFile[^2..]);
        // Every argument survives the cmd.exe fallback.
        Cli.CmdArguments("claude.cmd", viaFile);
    }

    [Fact]
    public void CliProcessesUseUtf8WithoutBom()
    {
        var info = Cli.StartInfo("claude.exe", ["-p"]);
        Assert.Empty(info.StandardInputEncoding!.GetPreamble());
        Assert.Equal("utf-8", info.StandardOutputEncoding!.WebName);
        Assert.Equal(["-p"], info.ArgumentList);
    }
}
