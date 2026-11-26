using System;
using System.Threading;
using System.Windows;

namespace Lattice.App;

public partial class App : Application
{
    private Mutex? _single;
    private EventWaitHandle? _showSignal;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // One window per person signed in to Windows. A second start brings the first to the front.
        string scope = "";
#if DEBUG
        if (Array.IndexOf(e.Args, "--demo") >= 0) scope = ".demo"; // a preview may run beside the installed app
#endif
        _single = new Mutex(true, @"Local\ai.latticevpn.windows.app" + scope, out bool first);
        _showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\ai.latticevpn.windows.show" + scope);
        if (!first)
        {
            _showSignal.Set();
            Shutdown();
            return;
        }
        var window = new MainWindow();
        MainWindow = window;
        bool startHidden = Array.IndexOf(e.Args, "--tray") >= 0;
        if (!startHidden) window.Show();

        var listener = new Thread(() =>
        {
            while (_showSignal.WaitOne())
                Dispatcher.BeginInvoke(new Action(window.BringToFront));
        }) { IsBackground = true, Name = "show-signal" };
        listener.Start();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _single?.Dispose();
        base.OnExit(e);
    }
}
