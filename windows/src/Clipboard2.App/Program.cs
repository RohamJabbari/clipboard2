using System;
using System.Linq;
using System.Threading;
using System.Windows;
using Clipboard2.App.Platform;
using Velopack;

namespace Clipboard2.App;

public static class Program
{
    private const string MutexName = @"Local\Softmaze.Clipboard2";
    private const string ShowEventName = @"Local\Softmaze.Clipboard2.Show";

    [STAThread]
    public static void Main(string[] args)
    {
        // Velopack install/update/uninstall hooks run (and exit) here.
        VelopackApp.Build()
            .OnAfterUpdateFastCallback(_ => { })
            .Run();

        using var mutex = new Mutex(true, MutexName, out var isFirst);
        if (!isFirst)
        {
            // Already running: ask that instance to open its panel, then quit.
            try { EventWaitHandle.OpenExisting(ShowEventName).Set(); } catch { }
            return;
        }

        var app = new App();
        app.InitializeComponent();
        app.Startup += (_, _) =>
        {
            var services = new AppServices();
            services.Start(background: args.Contains("--background"));
            app.Exit += (_, _) => services.Shutdown();
            var showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
            var listener = new Thread(() =>
            {
                while (showSignal.WaitOne()) app.Dispatcher.BeginInvoke(services.ShowPanel);
            }) { IsBackground = true, Name = "Clipboard2 single-instance listener" };
            listener.Start();
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
}
