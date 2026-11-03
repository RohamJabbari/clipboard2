using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using Clipboard2.App.Platform;
using Microsoft.Data.Sqlite;
using Velopack;

namespace Clipboard2.App;

public static class Program
{
    private const string MutexName = @"Local\Softmaze.Clipboard2";
    private const string ShowEventName = @"Local\Softmaze.Clipboard2.Show";
    /// <summary>A downloaded update is applied after this long without keyboard or mouse input.</summary>
    private static readonly TimeSpan IdleBeforeUpdate = TimeSpan.FromMinutes(30);

    [STAThread]
    public static void Main(string[] args)
    {
        // Velopack install/update/uninstall hooks run (and exit) here. Its apply-on-startup is off:
        // UpdateService.ApplyPendingAtLaunch does that silently and restarts with --background.
        VelopackApp.Build()
            .SetAutoApplyOnStartup(false)
            .OnAfterUpdateFastCallback(_ => { })
            .OnBeforeUninstallFastCallback(_ => StartupRegistration.SetEnabled(false))   // no dead Run entry left behind
            .Run();

        using var mutex = new Mutex(true, MutexName, out var isFirst);
        if (!isFirst)
        {
            // Already running: ask that instance to open its panel, then quit.
            try { EventWaitHandle.OpenExisting(ShowEventName).Set(); } catch { }
            return;
        }
        try
        {
            Run(args);
        }
        finally
        {
            mutex.ReleaseMutex();
        }
    }

    private static void Run(string[] args)
    {
        Directory.CreateDirectory(AppServices.DataDirectory);
        Log.FilePath = Path.Combine(AppServices.DataDirectory, "clipboard2.log");
        if (UpdateService.ApplyPendingAtLaunch(Path.Combine(AppServices.DataDirectory, "update-attempt.txt"))) return;
        MoveCorruptDatabaseAside(Path.Combine(AppServices.DataDirectory, "history.db"));

        var app = new App();
        app.InitializeComponent();
        AppServices? services = null;
        var sessionEnding = false;
        app.SessionEnding += (_, _) => sessionEnding = true;
        app.Startup += (_, _) =>
        {
            try
            {
                services = new AppServices();
                services.Start(background: args.Contains("--background"));
            }
            catch (Exception ex)
            {
                // Don't keep running invisibly (and holding the single-instance mutex): say why and quit.
                Log.Error("Clipboard2 couldn't start", ex);
                try { services?.Shutdown(); } catch { }
                services = null;
                MessageBox.Show($"Clipboard2 couldn't start:\n\n{ex.Message}\n\nDetails are in the log:\n{Log.FilePath}",
                    "Clipboard2", MessageBoxButton.OK, MessageBoxImage.Error);
                app.Shutdown(1);
                return;
            }
            var running = services;
            var showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
            var listener = new Thread(() =>
            {
                while (showSignal.WaitOne()) app.Dispatcher.BeginInvoke(running.ShowPanel);
            }) { IsBackground = true, Name = "Clipboard2 single-instance listener" };
            listener.Start();

            // A quietly downloaded update otherwise waits for quit; someone who never quits gets it once they're away.
            var idleCheck = new DispatcherTimer { Interval = TimeSpan.FromMinutes(5) };
            idleCheck.Tick += (_, _) =>
            {
                if (running.Settings.InstallUpdatesAutomatically && running.Updates.RestartIfIdle(IdleBeforeUpdate)) idleCheck.Stop();
            };
            idleCheck.Start();
        };
        app.Exit += (_, _) =>
        {
            if (services is null) return;
            try { services.Shutdown(); }   // removes the tray icon before any update restart: no ghost icon
            catch (Exception ex) { Log.Error("Shutdown failed", ex); }
            // While Windows signs out the updater could be killed mid-way; the next launch applies it instead.
            if (!sessionEnding) services.Updates.ApplyOnExit();
        };
        app.DispatcherUnhandledException += (_, e) =>
        {
            // An untested corner shouldn't take the whole app down; log it and carry on.
            Log.Error("Unhandled UI exception", e.Exception);
            e.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Error("Unhandled exception", e.ExceptionObject as Exception);
        System.Threading.Tasks.TaskScheduler.UnobservedTaskException += (_, e) => { Log.Error("Unobserved task exception", e.Exception); e.SetObserved(); };
        app.Run();
    }

    /// <summary>
    /// Like the Mac app: a history database SQLite reports as corrupt or not a database is moved aside
    /// (<c>history.db.broken-&lt;timestamp&gt;</c>, with its -wal/-shm) and the app starts with an empty history
    /// instead of not starting at all. Other errors (locked, no disk space…) are left for the normal startup
    /// error message.
    /// </summary>
    private static void MoveCorruptDatabaseAside(string path)
    {
        if (!File.Exists(path)) return;
        try
        {
            using var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString());
            db.Open();
            using var command = db.CreateCommand();
            command.CommandText = "SELECT count(*) FROM sqlite_master;";
            command.ExecuteScalar();
            return;
        }
        catch (SqliteException ex) when (ex.SqliteErrorCode is 11 or 26)   // SQLITE_CORRUPT, SQLITE_NOTADB
        {
            Log.Error("The history database is damaged; moving it aside", ex);
        }
        catch (Exception ex)
        {
            Log.Error("Checking the history database failed", ex);
            return;
        }
        var suffix = ".broken-" + DateTime.Now.ToString("yyyyMMdd-HHmmss");
        foreach (var extra in new[] { "", "-wal", "-shm" })
        {
            try
            {
                if (File.Exists(path + extra)) File.Move(path + extra, path + suffix + extra);
            }
            catch (Exception ex)
            {
                Log.Error($"Couldn't move {path + extra} aside", ex);
            }
        }
    }
}
