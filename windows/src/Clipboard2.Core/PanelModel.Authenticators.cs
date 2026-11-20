namespace Clipboard2.Core;

/// <summary>What the panel needs from sync for authenticators (the app wraps its SyncAccount; tests fake it).</summary>
public interface IAuthenticatorSync
{
    /// <summary>Signed in: sharing, people and transfer are possible.</summary>
    bool IsSignedIn { get; }
    /// <summary>The last failure, to show as a notice.</summary>
    string? Error { get; }
    List<(string Uid, string Name)> ShareCandidates(Authenticator a);
    Task<bool> ShareAsync(Authenticator a, string uid, string name);
    /// <summary>Until when their codes keep working; null when it failed.</summary>
    Task<DateTime?> RemoveAsync(Authenticator a, string uid);
    Task<bool> TransferAsync(Authenticator a, string uid, string name);
    Task<bool> LeaveAsync(SharedAuthenticator shared);
    Task<bool> DeleteAsync(Authenticator a);
}

/// <summary>The inline Add / Rename form: Issuer, Account, Secret (adding by hand), and Advanced.</summary>
public sealed class AuthenticatorForm
{
    public Authenticator? Existing { get; init; }
    public string Issuer { get; set; } = "";
    public string Account { get; set; } = "";
    public string Secret { get; set; } = "";
    public OtpAlgorithm Algorithm { get; set; } = OtpAlgorithm.SHA1;
    public int Digits { get; set; } = Authenticator.DefaultDigits;
    public int Period { get; set; } = Authenticator.DefaultPeriod;
    public bool ShowAdvanced { get; set; }
    /// <summary>The secret came from a link or QR code: it isn't shown or asked for.</summary>
    public bool SecretFromLink { get; init; }
    /// <summary>The one-time tip about keeping important codes on a phone too.</summary>
    public bool ShowTip { get; init; }
    public string? Error { get; set; }
    public bool IsRename => Existing is not null;
}

/// <summary>Which picker the action list shows for an authenticator.</summary>
public enum OtpPickerKind { Share, Transfer }

public sealed partial class PanelModel
{
    public const string AuthenticatorTip =
        "Keep your most important 2FA codes on your phone too. Clipboard2 is convenient, but it puts the password and the code in one place.";
    public const string TransferNote = "They'll get the secret and own it; you'll get codes like everyone else.";
    public const string ShareNote = "They get codes, never the secret.";

    /// <summary>This user's authenticators and the codes shared with them; null hides them.</summary>
    public AuthenticatorStore? Authenticators { get; set; }
    public IAuthenticatorSync? AuthenticatorSync { get; set; }
    public Func<DateTime> Clock { get; set; } = () => DateTime.UtcNow;
    public Func<TimeSpan, Task> Delay { get; set; } = d => Task.Delay(d);

    /// <summary>An otpauth link that was copied (never stored): offered at the top of All until added or dismissed.</summary>
    public OtpAuthDraft? PendingOtp { get; private set; }
    public AuthenticatorForm? AuthenticatorForm { get; private set; }
    /// <summary>Shown with its secret and QR code after Windows Hello.</summary>
    public Authenticator? RevealedAuthenticator { get; private set; }
    /// <summary>People… is open for it.</summary>
    public Authenticator? PeopleOf { get; private set; }
    /// <summary>Waiting for the inline delete confirmation.</summary>
    public Authenticator? ConfirmingDelete { get; private set; }
    /// <summary>The action list is a picker of people for this authenticator.</summary>
    public (OtpPickerKind Kind, Authenticator Authenticator)? OtpPicker { get; private set; }
    /// <summary>Enter came with fewer than 3 s left: the next code is pasted when it starts.</summary>
    public bool IsWaitingForNextCode { get; private set; }

    public static readonly TimeSpan NextCodeThreshold = TimeSpan.FromSeconds(3);

    private void ResetAuthenticatorMode()
    {
        AuthenticatorForm = null;
        RevealedAuthenticator = null;
        PeopleOf = null;
        ConfirmingDelete = null;
        OtpPicker = null;
    }

    private List<(PanelEntry Entry, DateTime Date)> AuthenticatorRows() => Authenticators is not { } store ? [] :
    [
        .. store.All.Select(a => ((PanelEntry)new PanelEntry.AuthenticatorEntry(a), a.CreatedAt)),
        .. store.Shared.Select(s => ((PanelEntry)new PanelEntry.SharedCodeEntry(s), s.ReceivedAt)),
    ];

    private static string AuthenticatorSearchText(PanelEntry entry) => entry switch
    {
        PanelEntry.AuthenticatorEntry a => $"{a.Authenticator.Issuer} {a.Authenticator.Account}",
        PanelEntry.SharedCodeEntry s => $"{s.Shared.Issuer} {s.Shared.Account}",
        _ => "",
    };

    /// <summary>The code an entry shows right now (null: a share that ran out).</summary>
    public string? CurrentCode(PanelEntry entry) => entry switch
    {
        PanelEntry.AuthenticatorEntry a => a.Authenticator.Code(Clock()),
        PanelEntry.SharedCodeEntry s => s.Shared.Code(Clock()),
        _ => null,
    };

    public double SecondsLeft(PanelEntry entry) => entry switch
    {
        PanelEntry.AuthenticatorEntry a => a.Authenticator.SecondsLeft(Clock()),
        PanelEntry.SharedCodeEntry s => s.Shared.SecondsLeft(Clock()),
        _ => 0,
    };

    public static int PeriodOf(PanelEntry entry) => entry switch
    {
        PanelEntry.AuthenticatorEntry a => a.Authenticator.Period,
        PanelEntry.SharedCodeEntry s => s.Shared.Period,
        _ => 30,
    };

    /// <summary>The row's subtitle: the account, then who shared it or how many it's shared with.</summary>
    public string AuthenticatorSubtitle(PanelEntry entry) => entry switch
    {
        PanelEntry.AuthenticatorEntry { Authenticator: var a } =>
            string.Join(" · ", new[] { a.Subtitle, a.People.Count > 0 ? $"Shared with {a.People.Count}" : "" }.Where(s => s.Length > 0)),
        PanelEntry.SharedCodeEntry { Shared: var s } => string.Join(" · ", new[] { s.Account, s.Status(Clock()) }.Where(x => x.Length > 0)),
        _ => "",
    };

    // MARK: Adding

    /// <summary>An otpauth link was copied: it's offered at the top of All (it was never stored).</summary>
    public void OfferAuthenticator(OtpAuthDraft draft)
    {
        PendingOtp = draft;
        Refresh();
    }

    public void DismissOtpSuggestion()
    {
        if (PendingOtp is null) return;
        PendingOtp = null;
        Refresh(resetSelection: true);
    }

    /// <summary>New Authenticator… (by hand), or Add to Authenticator for a link or QR code.</summary>
    public void BeginAddAuthenticator(OtpAuthDraft? draft = null)
    {
        if (Authenticators is null) return;
        ResetMode();
        AuthenticatorForm = new AuthenticatorForm
        {
            Issuer = draft?.Issuer ?? "",
            Account = draft?.Account ?? "",
            Secret = draft?.Secret ?? "",
            Algorithm = draft?.Algorithm ?? OtpAlgorithm.SHA1,
            Digits = draft?.Digits ?? Authenticator.DefaultDigits,
            Period = draft?.Period ?? Authenticator.DefaultPeriod,
            SecretFromLink = draft is not null,
            ShowTip = !PanelSettings.AuthenticatorTipShown,
        };
        Mode = PanelMode.AuthenticatorForm;
        Notify();
    }

    public void BeginRenameAuthenticator(Authenticator a)
    {
        ResetMode();
        Select(new PanelEntry.AuthenticatorEntry(a).Id);
        AuthenticatorForm = new AuthenticatorForm
        {
            Existing = a, Issuer = a.Issuer, Account = a.Account, Algorithm = a.Algorithm, Digits = a.Digits, Period = a.Period,
        };
        Mode = PanelMode.AuthenticatorForm;
        Notify();
    }

    public void SubmitAuthenticatorForm()
    {
        if (AuthenticatorForm is not { } form || Authenticators is not { } store) return;
        if (form.Issuer.Trim().Length == 0 && form.Account.Trim().Length == 0)
        {
            form.Error = "Enter the issuer or the account.";
            Notify();
            return;
        }
        Authenticator? saved;
        if (form.Existing is { } existing)
        {
            saved = store.Rename(store.Find(existing.Id) ?? existing, form.Issuer, form.Account);
        }
        else
        {
            if (Base32.Decode(form.Secret) is null)
            {
                form.Error = "The secret isn't valid. It's the base32 key the site shows (letters A–Z and digits 2–7).";
                Notify();
                return;
            }
            saved = store.Add(form.Issuer, form.Account, form.Secret, form.Algorithm, form.Digits, form.Period);
            if (saved is not null)
            {
                if (form.SecretFromLink) PendingOtp = null;
                if (!PanelSettings.AuthenticatorTipShown)
                {
                    PanelSettings.AuthenticatorTipShown = true;
                    PanelSettings.Save();
                }
            }
        }
        if (saved is null)
        {
            form.Error = "Couldn't save it to Credential Manager.";
            Notify();
            return;
        }
        ResetMode();
        Refresh();
        Select(new PanelEntry.AuthenticatorEntry(saved).Id);
        ShowNotice(form.IsRename ? "Renamed" : $"Added “{saved.Title}”");
    }

    // MARK: Codes

    /// <summary>Enter: pastes the current code; with fewer than 3 s left, waits for the next one ("Next code…").</summary>
    public async Task PasteCodeAsync(PanelEntry entry)
    {
        if (CurrentCode(entry) is null)
        {
            ShowNotice("No codes right now");
            return;
        }
        var left = SecondsLeft(entry);
        if (left < NextCodeThreshold.TotalSeconds)
        {
            IsWaitingForNextCode = true;
            ShowNotice("Next code…");
            await Delay(TimeSpan.FromSeconds(left) + TimeSpan.FromMilliseconds(50));
            IsWaitingForNextCode = false;
        }
        if (CurrentCode(entry) is not { } code)
        {
            ShowNotice("No codes right now");
            return;
        }
        Host.ClosePanel();
        Host.PasteTransient(code);
    }

    public void CopyCode(PanelEntry entry)
    {
        if (CurrentCode(entry) is not { } code)
        {
            ShowNotice("No codes right now");
            return;
        }
        Host.CopyTransient(code);
        ResetMode();
        ShowNotice("Code copied · cleared in 30 seconds");
    }

    // MARK: Actions

    private List<PanelAction>? AuthenticatorActions(PanelEntry entry)
    {
        switch (entry)
        {
            case PanelEntry.OtpSuggestion:
                return [new PanelAction.AddAuthenticator()];
            case PanelEntry.SharedCodeEntry s:
                // Someone else's: codes only, and Leave. Nothing the server would refuse.
                return [.. s.Shared.IsOut(Clock()) ? [] : new PanelAction[] { new PanelAction.PasteCode(), new PanelAction.CopyCode() },
                        .. AuthenticatorSync is { IsSignedIn: true } ? [new PanelAction.LeaveAuthenticator()] : Array.Empty<PanelAction>()];
            case PanelEntry.AuthenticatorEntry { Authenticator: var a }:
                List<PanelAction> list = [new PanelAction.PasteCode(), new PanelAction.CopyCode(), new PanelAction.RenameAuthenticator()];
                // Sharing needs its space on the server (it gets one at the first sync).
                if (AuthenticatorSync is { IsSignedIn: true } && a.SpaceId is not null)
                {
                    list.Add(new PanelAction.ShareAuthenticator());
                    if (a.People.Count > 0) list.AddRange([new PanelAction.AuthenticatorPeople(), new PanelAction.TransferAuthenticator()]);
                }
                list.AddRange([new PanelAction.ShowAuthenticatorSecret(), new PanelAction.DeleteAuthenticator()]);
                return list;
            default:
                return null;
        }
    }

    private List<PanelAction> OtpPickerActions()
    {
        if (OtpPicker is not { } picker) return [];
        var a = Authenticators?.Find(picker.Authenticator.Id) ?? picker.Authenticator;
        return picker.Kind == OtpPickerKind.Share
            ? [.. (AuthenticatorSync?.ShareCandidates(a) ?? []).Select(p => new PanelAction.ShareAuthenticatorWith(p.Uid, p.Name))]
            : [.. a.People.Select(p => new PanelAction.TransferAuthenticatorTo(p.Uid, p.Name))];
    }

    /// <summary>The picker's one-line note (Share… or Transfer Ownership…).</summary>
    public string? OtpPickerNote => OtpPicker?.Kind switch
    {
        OtpPickerKind.Share => ShareNote,
        OtpPickerKind.Transfer => TransferNote,
        _ => null,
    };

    private void BeginOtpPicker(OtpPickerKind kind, Authenticator a)
    {
        ActionQuery = "";
        ActionSelection = 0;
        IsPickingGroup = false;
        IsPickingFolder = false;
        PickingShareFolder = null;
        OtpPicker = (kind, a);
        Mode = PanelMode.Actions;
        Notify();
    }

    private Authenticator? SelectedAuthenticator =>
        SelectedEntry is PanelEntry.AuthenticatorEntry { Authenticator: var a } ? Authenticators?.Find(a.Id) ?? a : null;

    private bool PerformAuthenticatorAction(PanelAction action)
    {
        var entry = SelectedEntry;
        var a = SelectedAuthenticator;
        switch (action)
        {
            case PanelAction.AddAuthenticator when entry is PanelEntry.OtpSuggestion o:
                BeginAddAuthenticator(o.Draft);
                return true;
            case PanelAction.PasteCode when entry is not null:
                ResetMode();
                _ = PasteCodeAsync(entry);
                return true;
            case PanelAction.CopyCode when entry is not null:
                CopyCode(entry);
                return true;
            case PanelAction.RenameAuthenticator when a is not null:
                BeginRenameAuthenticator(a);
                return true;
            case PanelAction.ShareAuthenticator when a is not null:
                BeginOtpPicker(OtpPickerKind.Share, a);
                return true;
            case PanelAction.TransferAuthenticator when a is not null:
                BeginOtpPicker(OtpPickerKind.Transfer, a);
                return true;
            case PanelAction.ShareAuthenticatorWith with when OtpPicker is { } picker:
                _ = ShareAsync(picker.Authenticator, with.Uid, with.Name);
                return true;
            case PanelAction.TransferAuthenticatorTo to when OtpPicker is { } picker:
                _ = TransferAsync(picker.Authenticator, to.Uid, to.Name);
                return true;
            case PanelAction.AuthenticatorPeople when a is not null:
                ShowPeople(a);
                return true;
            case PanelAction.ShowAuthenticatorSecret when a is not null:
                _ = RevealAuthenticatorAsync(a);
                return true;
            case PanelAction.DeleteAuthenticator when a is not null:
                BeginDeleteAuthenticator(a);
                return true;
            case PanelAction.LeaveAuthenticator when entry is PanelEntry.SharedCodeEntry s:
                _ = LeaveAsync(s.Shared);
                return true;
        }
        return false;
    }

    private async Task ShareAsync(Authenticator a, string uid, string name)
    {
        ResetMode();
        if (AuthenticatorSync is not { } sync) return;
        ShowNotice($"Sharing with {name}…");
        var ok = await sync.ShareAsync(a, uid, name);
        Refresh();
        ShowNotice(ok ? $"Shared with {name}" : sync.Error ?? "Couldn't share it");
    }

    private async Task TransferAsync(Authenticator a, string uid, string name)
    {
        ResetMode();
        if (AuthenticatorSync is not { } sync) return;
        var ok = await sync.TransferAsync(a, uid, name);
        Refresh(resetSelection: true);
        ShowNotice(ok ? $"{name} owns “{a.Title}” now" : sync.Error ?? "Couldn't transfer it");
    }

    private async Task LeaveAsync(SharedAuthenticator shared)
    {
        ResetMode();
        if (AuthenticatorSync is not { } sync) return;
        var ok = await sync.LeaveAsync(shared);
        Refresh(resetSelection: true);
        ShowNotice(ok ? $"Left “{shared.Title}”" : sync.Error ?? "Couldn't leave it");
    }

    public void ShowPeople(Authenticator a)
    {
        ResetMode();
        Select(new PanelEntry.AuthenticatorEntry(a).Id);
        PeopleOf = a;
        Mode = PanelMode.AuthenticatorPeople;
        Notify();
    }

    /// <summary>People… ▸ Remove.</summary>
    public async Task RemovePersonAsync(Authenticator a, string uid)
    {
        if (AuthenticatorSync is not { } sync) return;
        var until = await sync.RemoveAsync(a, uid);
        if (until is null)
        {
            ShowNotice(sync.Error ?? "Couldn't remove them");
            return;
        }
        var updated = Authenticators?.Find(a.Id) ?? a;
        if (PeopleOf is not null) PeopleOf = updated;
        if (updated.People.Count == 0 && Mode == PanelMode.AuthenticatorPeople) ResetMode();
        Refresh();
        ShowNotice($"Removed. Codes they already have work until {until.Value.ToLocalTime():t}.");
    }

    /// <summary>Show Secret / QR, after Windows Hello.</summary>
    public async Task RevealAuthenticatorAsync(Authenticator a)
    {
        ResetMode();
        if (!await Host.VerifyUserAsync($"show the secret of “{a.Title}”")) return;
        Select(new PanelEntry.AuthenticatorEntry(a).Id);
        RevealedAuthenticator = a;
        Mode = PanelMode.AuthenticatorSecret;
        Notify();
    }

    public void BeginDeleteAuthenticator(Authenticator a)
    {
        ResetMode();
        Select(new PanelEntry.AuthenticatorEntry(a).Id);
        ConfirmingDelete = a;
        Mode = PanelMode.ConfirmDelete;
        Notify();
    }

    /// <summary>The inline confirmation's Delete: for everyone it's shared with too.</summary>
    public async Task ConfirmDeleteAsync()
    {
        if (ConfirmingDelete is not { } a) return;
        var index = SelectedIndex ?? 0;
        ResetMode();
        var ok = AuthenticatorSync is { } sync ? await sync.DeleteAsync(a) : DeleteLocally(a);
        Refresh();
        if (Entries.Count > 0) Select(Entries[Math.Min(index, Entries.Count - 1)].Id);
        ShowNotice(ok ? $"Deleted “{a.Title}”" : AuthenticatorSync?.Error ?? "Couldn't delete it");
    }

    private bool DeleteLocally(Authenticator a)
    {
        Authenticators?.Delete(a.Id);
        return true;
    }

    private bool HandleAuthenticatorKey(KeyInput key)
    {
        switch (key.Key)
        {
            case PanelKey.Escape:
                ResetMode();
                return true;
            case PanelKey.Enter when Mode == PanelMode.ConfirmDelete:
                _ = ConfirmDeleteAsync();
                return true;
            case PanelKey.Enter:
                ResetMode();
                return true;
            default:
                return false;
        }
    }
}
