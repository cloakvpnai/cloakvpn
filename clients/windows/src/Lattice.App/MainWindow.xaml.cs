using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Lattice.App;

public partial class MainWindow : Window
{
    private enum Tile { Session, Traffic, Latency, Keys }

    private sealed record Row(Border Card, TextBlock Name, Border Chip, TextBlock Check);

    private readonly ServiceClient _service = new();
    private readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private readonly Dictionary<string, Row> _rows = new();
    private readonly Dictionary<Tile, (Border Box, TextBlock Label, TextBlock Value)> _tiles = new();
    private readonly Dictionary<string, ImageSource> _flags = new();
    private readonly System.Windows.Forms.NotifyIcon _tray = new();
    private Status _status = new();
    private string? _pick;
    private Tile? _open;
    private bool _polling, _pulsing, _breathing, _reallyClose, _trayHintShown;
    private bool _demo = false; // only ever set in debug builds
    private int _missed;

    private Brush B(string key) => (Brush)FindResource(key);
    private FontFamily F(string key) => (FontFamily)FindResource(key);

    public MainWindow()
    {
        InitializeComponent();
        BuildRegions();
        BuildTiles();
        BuildAbout();
        BuildTray();
        Globe.Picked += region => _ = ConnectTo(region.Id);
#if DEBUG
        // Debug builds only: "--demo connected", "--demo connecting" or "--demo off" shows the
        // window with made-up figures and never talks to the service. Used for layout checks
        // and store screenshots, so those carry no real address.
        string[] args = Environment.GetCommandLineArgs();
        int demo = Array.IndexOf(args, "--demo");
        if (demo >= 0)
        {
            _demo = true;
            string mode = demo + 1 < args.Length ? args[demo + 1] : "off";
            _status = new Status
            {
                SignedIn = mode != "signin", State = mode is "connected" or "connecting" ? mode : "off", Region = "us-west-1", Exit = "198.51.100.77",
                Since = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 754, BytesIn = 48_300_000, BytesOut = 6_120_000, KeyChanges = 1,
                LatencyMs = 84, LatencyBestMs = 79, LatencyAverageMs = 86, Tier = "basic", ActiveUntil = "2026-12-28T08:15:59Z",
                DeviceLimit = 3, DeviceCount = 3, CertificateUntil = DateTimeOffset.UtcNow.AddDays(30).ToUnixTimeSeconds(),
            };
            if (Array.IndexOf(args, "--tile") is int t and >= 0 && t + 1 < args.Length && Enum.TryParse(args[t + 1], true, out Tile tile)) _open = tile;
            if (Array.IndexOf(args, "--tab") is int tab and >= 0 && tab + 1 < args.Length)
                Loaded += (_, _) => { if (args[tab + 1] == "account") TabAccount.IsChecked = true; else if (args[tab + 1] == "about") TabAbout.IsChecked = true; };
            // --update <file contents>: shows what the update notice would do with that reply.
            if (Array.IndexOf(args, "--update") is int u and >= 0 && u + 1 < args.Length)
                Loaded += (_, _) => ShowUpdate(UpdateCheck.Read(args[u + 1].Replace('\'', '"'), new Version(2, 0, 0)));
            _poll.Tick += (_, _) => Paint();
            Loaded += (_, _) => { Paint(); _poll.Start(); };
            return;
        }
#endif
        _poll.Tick += async (_, _) => await Poll();
        Loaded += async (_, _) => { await Poll(); _poll.Start(); };
        // Look for a newer version shortly after opening, then once a day while the app stays open.
        _updates.Tick += async (_, _) => { _updates.Interval = TimeSpan.FromHours(24); await LookForUpdate(); };
        Loaded += (_, _) => _updates.Start();
    }

    private readonly DispatcherTimer _updates = new() { Interval = TimeSpan.FromSeconds(20) };

    private async System.Threading.Tasks.Task LookForUpdate()
    {
        Version current = typeof(MainWindow).Assembly.GetName().Version ?? new Version(0, 0, 0);
        ShowUpdate(await UpdateCheck.CheckAsync(new Version(current.Major, current.Minor, Math.Max(0, current.Build))));
    }

    private void ShowUpdate(UpdateCheck.Result? update)
    {
        if (update is null) { UpdateBanner.Visibility = Visibility.Collapsed; return; }
        UpdateText.Text = update.Required
            ? $"This version is no longer supported. Version {update.Latest.ToString(3)} is required."
            : $"Lattice VPN {update.Latest.ToString(3)} is available.";
        UpdateDismiss.Visibility = update.Required ? Visibility.Collapsed : Visibility.Visible;
        UpdateBanner.Visibility = Visibility.Visible;
    }

    private void UpdateBanner_Click(object sender, System.Windows.Input.MouseButtonEventArgs e) => OpenWeb(UpdateCheck.DownloadPage);

    private void UpdateDismiss_Click(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        e.Handled = true;
        UpdateBanner.Visibility = Visibility.Collapsed;
    }

    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    /// <summary>Rounded corners and a navy edge on Windows 11. Older Windows ignores these.</summary>
    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        IntPtr hwnd = new System.Windows.Interop.WindowInteropHelper(this).Handle;
        int dark = 1, round = 2, edge = 0x004F3122; // colours are blue-green-red
        DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));   // dark frame
        DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));  // rounded corners
        DwmSetWindowAttribute(hwnd, 34, ref edge, sizeof(int));   // edge colour
    }

    private void OnMinimise(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void OnHide(object sender, RoutedEventArgs e) => Close();

    // ---- building the fixed parts ----

    private ImageSource Flag(string regionId)
    {
        string country = regionId.Length >= 2 ? regionId[..2] : "us";
        if (!_flags.TryGetValue(country, out ImageSource? image))
        {
            var bitmap = new BitmapImage(new Uri($"pack://application:,,,/Assets/Flags/{country}.png"));
            bitmap.Freeze();
            _flags[country] = image = bitmap;
        }
        return image;
    }

    private void BuildRegions()
    {
        foreach (Region region in Region.All)
        {
            var flag = new Border
            {
                Width = 28, Height = 20, CornerRadius = new CornerRadius(4), VerticalAlignment = VerticalAlignment.Center,
                Background = new ImageBrush(Flag(region.Id)) { Stretch = Stretch.UniformToFill },
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)), BorderThickness = new Thickness(0.5),
            };
            RenderOptions.SetBitmapScalingMode(flag, BitmapScalingMode.HighQuality);
            var name = new TextBlock { Text = region.Name, FontSize = 13, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(10, 0, 6, 0) };
            var chipText = new TextBlock { Text = region.Short, FontFamily = F("Mono"), FontSize = 9.5, FontWeight = FontWeights.SemiBold, Foreground = B("Muted") };
            var chip = new Border { Child = chipText, Background = B("Chip"), CornerRadius = new CornerRadius(5), Padding = new Thickness(6, 2, 6, 2), VerticalAlignment = VerticalAlignment.Center };
            var check = new TextBlock { Text = "", FontFamily = F("Icons"), FontSize = 14, FontWeight = FontWeights.Bold, Foreground = B("Mint"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 3, 0), Visibility = Visibility.Collapsed };
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(name, 1); Grid.SetColumn(chip, 2); Grid.SetColumn(check, 2);
            grid.Children.Add(flag); grid.Children.Add(name); grid.Children.Add(chip); grid.Children.Add(check);
            var card = new Border
            {
                Child = grid, CornerRadius = new CornerRadius(11), Padding = new Thickness(11, 0, 10, 0), Height = 40, Margin = new Thickness(0, 0, 0, 5),
                Background = B("Card"), BorderBrush = B("CardLine"), BorderThickness = new Thickness(1),
                Cursor = Cursors.Hand, Focusable = true, FocusVisualStyle = null,
            };
            System.Windows.Automation.AutomationProperties.SetName(card, region.Name);
            string id = region.Id;
            card.MouseLeftButtonUp += (_, _) => OnRegion(id);
            card.KeyDown += (_, e) => { if (e.Key is Key.Enter or Key.Space) { OnRegion(id); e.Handled = true; } };
            card.MouseEnter += (_, _) => PaintRows();
            card.MouseLeave += (_, _) => PaintRows();
            card.GotKeyboardFocus += (_, _) => PaintRows();
            card.LostKeyboardFocus += (_, _) => PaintRows();
            RegionList.Children.Add(card);
            _rows[id] = new Row(card, name, chip, check);
        }
    }

    private void BuildTiles()
    {
        foreach ((Tile tile, string label) in new[] { (Tile.Session, "SESSION"), (Tile.Traffic, "DOWN / UP"), (Tile.Latency, "LATENCY"), (Tile.Keys, "NEW KEYS") })
        {
            var l = new TextBlock { Text = label, Style = (Style)FindResource("Label"), FontSize = 9.5 };
            var v = new TextBlock { Text = "--", FontFamily = F("Mono"), FontSize = 13, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 3, 0, 0) };
            var stack = new StackPanel(); stack.Children.Add(l); stack.Children.Add(v);
            var box = new Border
            {
                Child = stack, Background = B("Card"), BorderBrush = B("CardLine"), BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(11), Padding = new Thickness(11, 8, 8, 9), Margin = new Thickness(3), Cursor = Cursors.Hand, Focusable = true, FocusVisualStyle = null,
            };
            Tile t = tile;
            void Toggle() { _open = _open == t ? null : t; if (_open is not null) TabGlobe.IsChecked = true; Paint(); }
            box.MouseLeftButtonUp += (_, e) => { Toggle(); e.Handled = true; };
            box.KeyDown += (_, e) => { if (e.Key is Key.Enter or Key.Space) { Toggle(); e.Handled = true; } };
            System.Windows.Automation.AutomationProperties.SetName(box, label);
            Tiles.Children.Add(box);
            _tiles[tile] = (box, l, v);
        }
    }

    private TextBlock Heading(string text) => new() { Text = text, FontFamily = F("Display"), FontSize = 20, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 0, 12) };
    private TextBlock Para(string text, bool muted = true) => new() { Text = text, FontSize = 13.5, Foreground = muted ? B("Muted") : B("Ink"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 9), LineHeight = 20 };
    private TextBlock Section(string text) => new() { Text = text, Style = (Style)FindResource("Label"), Margin = new Thickness(0, 8, 0, 8) };

    private Grid Fact(string label, string value, bool mono = true)
    {
        var g = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(170) });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.Children.Add(new TextBlock { Text = label, Foreground = B("Muted") });
        var v = new TextBlock { Text = value, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
        if (mono) { v.FontFamily = F("Mono"); v.FontSize = 13; }
        Grid.SetColumn(v, 1);
        g.Children.Add(v);
        return g;
    }

    private Button Link(string text, Action act, string style = "Flat")
    {
        var b = new Button { Content = text, Style = (Style)FindResource(style), Margin = new Thickness(0, 0, 8, 0) };
        b.Click += (_, _) => act();
        return b;
    }

    private static void OpenWeb(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch (Win32Exception) { }
    }

    private void BuildAbout()
    {
        string version = typeof(MainWindow).Assembly.GetName().Version?.ToString(3) ?? "";
        var head = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 14) };
        head.Children.Add(new Image { Source = new BitmapImage(new Uri("pack://application:,,,/Assets/lattice-logo.png")), Width = 46, Height = 46 });
        var title = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        title.Children.Add(new TextBlock { Text = "Lattice VPN", FontFamily = F("Display"), FontSize = 20, FontWeight = FontWeights.Bold });
        title.Children.Add(new TextBlock { Text = "Version " + version + " for Windows", Foreground = B("Muted"), FontSize = 12.5 });
        head.Children.Add(title);
        AboutStack.Children.Add(head);
        AboutStack.Children.Add(Para("Every connection uses the CNSA 2.0 algorithm suite. There is no other mode. While the VPN is on, nothing leaves this PC outside the tunnel except traffic on your local network.", muted: false));
        AboutStack.Children.Add(Section("ENCRYPTION"));
        AboutStack.Children.Add(Fact("Key exchange", "ML-KEM-1024"));
        AboutStack.Children.Add(Fact("Signatures", "ML-DSA-87"));
        AboutStack.Children.Add(Fact("Cipher", "AES-256-GCM"));
        AboutStack.Children.Add(Fact("Protocol", "TLS 1.3"));
        AboutStack.Children.Add(Fact("New keys", "Every 10 minutes"));
        AboutStack.Children.Add(Section("PRIVACY"));
        AboutStack.Children.Add(Para("Lattice keeps no record of what you do. Session figures in this window are counted on this PC and are not sent anywhere."));
        var links = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 12) };
        links.Children.Add(Link("Privacy policy", () => OpenWeb("https://latticevpn.ai/privacy")));
        links.Children.Add(Link("latticevpn.ai", () => OpenWeb("https://latticevpn.ai")));
        AboutStack.Children.Add(links);
        AboutStack.Children.Add(Section("THIRD PARTY SOFTWARE"));
        AboutStack.Children.Add(Para("OpenSSL 3.5, copyright the OpenSSL Project Authors, under the Apache License 2.0."));
        AboutStack.Children.Add(Para("Wintun network adapter, copyright WireGuard LLC, distributed unmodified under its prebuilt binaries license. \"Wintun\" and \"WireGuard\" are trademarks of their owner; Lattice VPN is not affiliated with or endorsed by them."));
        AboutStack.Children.Add(Para("Earth imagery: NASA Earth Observatory (Blue Marble Next Generation by Reto Stockli; Black Marble night lights by Joshua Stevens with Suomi NPP VIIRS data from Miguel Roman, NASA GSFC). Flags from flag-icons by Panayiotis Lipiridis, under the MIT License."));
        AboutStack.Children.Add(Para("The full license texts are in the Licenses folder where Lattice VPN is installed."));
    }

    private void BuildTray()
    {
        using var stream = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/lattice.ico")).Stream;
        _tray.Icon = new System.Drawing.Icon(stream, System.Windows.Forms.SystemInformation.SmallIconSize);
        _tray.Text = "Lattice VPN";
        _tray.Visible = true;
        _tray.MouseClick += (_, e) => { if (e.Button == System.Windows.Forms.MouseButtons.Left) BringToFront(); };
        var menu = new System.Windows.Forms.ContextMenuStrip();
        menu.Items.Add("Open Lattice VPN", null, (_, _) => BringToFront());
        var toggle = new System.Windows.Forms.ToolStripMenuItem("Connect");
        toggle.Click += (_, _) => OnPower(this, new RoutedEventArgs());
        menu.Items.Add(toggle);
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        menu.Items.Add("Quit the window (the VPN stays as it is)", null, (_, _) => { _reallyClose = true; Close(); });
        menu.Opening += (_, _) => { toggle.Text = _status.Connected || _status.Busy ? "Disconnect" : "Connect"; toggle.Enabled = _status.SignedIn; };
        _tray.ContextMenuStrip = menu;
    }

    public void BringToFront()
    {
        Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_reallyClose)
        {
            // Closing the window keeps Lattice in the notification area.
            e.Cancel = true;
            Hide();
            if (!_trayHintShown)
            {
                _trayHintShown = true;
                _tray.ShowBalloonTip(4000, "Lattice VPN is still here", "Click the shield in the notification area to open it again.", System.Windows.Forms.ToolTipIcon.None);
            }
            return;
        }
        _poll.Stop();
        _tray.Visible = false;
        _tray.Dispose();
        _service.Dispose();
        base.OnClosing(e);
        Application.Current.Shutdown();
    }

    // ---- talking to the service ----

    private async System.Threading.Tasks.Task Poll()
    {
        if (_polling) return;
        _polling = true;
        try
        {
            Reply reply = await _service.SendAsync("status", timeoutMs: 2500);
            if (reply.Status is { } s) { _status = s; _missed = 0; }
            else if (!reply.ServiceReachable) _missed++;
            ServiceBanner.Visibility = _missed >= 4 ? Visibility.Visible : Visibility.Collapsed;
            Paint();
        }
        finally { _polling = false; }
    }

    private async System.Threading.Tasks.Task Send(string command, string? region = null)
    {
        Reply reply = await _service.SendAsync(command, region);
        if (reply.Status is { } s) _status = s;
        Paint();
    }

    private string CurrentRegion => _pick ?? (_status.Region.Length > 0 ? _status.Region : Region.All[0].Id);

    private async System.Threading.Tasks.Task ConnectTo(string region)
    {
        _pick = region;
        if (!_status.Busy) _status.State = "connecting";
        Paint();
        await Send("connect", region);
    }

    private async void OnPower(object sender, RoutedEventArgs e)
    {
        if (!_status.SignedIn) return;
        if (_status.Connected || _status.Busy) await Send("disconnect");
        else await ConnectTo(CurrentRegion);
    }

    private void OnRegion(string id)
    {
        // While the VPN is on, picking a location moves the tunnel there without letting traffic out in between.
        if (_status.Connected || _status.Busy) _ = ConnectTo(id);
        else { _pick = id; Paint(); }
    }

    // ---- sign in and out ----

    private static string Clean(string text) => new(text.ToUpperInvariant().Where(c => "0123456789ABCDEFGHJKMNPQRSTVWXYZ".Contains(c)).ToArray());

    private void OnAccountTyped(object sender, TextChangedEventArgs e)
    {
        SignInButton.IsEnabled = Clean(AccountBox.Text).Length == 25;
        SignInError.Text = "";
    }

    private void OnAccountKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && SignInButton.IsEnabled) OnSignIn(sender, e);
    }

    private async void OnSignIn(object sender, RoutedEventArgs e)
    {
        string account = Clean(AccountBox.Text);
        if (account.Length != 25) return;
        SignInButton.IsEnabled = false; SignInButton.Content = "Checking";
        Reply reply = await _service.SendAsync("signin", account: account, timeoutMs: 40000);
        SignInButton.Content = "Sign in";
        if (reply.Ok && reply.Status is { } s)
        {
            _status = s;
            AccountBox.Clear();
        }
        else
        {
            SignInError.Text = reply.Error.Length > 0 ? reply.Error : "Could not sign in. Try again.";
            SignInButton.IsEnabled = true;
        }
        Paint();
    }

    private async void SignOut()
    {
        MessageBoxResult answer = MessageBox.Show(this,
            "Sign out of Lattice VPN on this PC?\n\nThe VPN is switched off, this PC is removed from your account, and its key is erased. You will need your account number to sign in again.",
            "Lattice VPN", MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel);
        if (answer != MessageBoxResult.OK) return;
        Reply reply = await _service.SendAsync("signout", timeoutMs: 40000);
        if (reply.Status is { } s) _status = s;
        _pick = null;
        TabGlobe.IsChecked = true;
        Paint();
    }

    // ---- painting ----

    private void OnTab(object sender, RoutedEventArgs e)
    {
        if (GlobeView is null) return;
        bool home = TabGlobe.IsChecked == true;
        GlobeView.Visibility = LocationsView.Visibility = home ? Visibility.Visible : Visibility.Collapsed;
        AccountView.Visibility = TabAccount.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        AboutView.Visibility = TabAbout.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        if (!home) _open = null;
        if (TabAccount.IsChecked == true)
        {
            PaintAccount();
            if (!_demo) _ = Send("account");
        }
    }

    private void OnGlobeSize(object sender, SizeChangedEventArgs e) =>
        GlobeClip.Clip = new RectangleGeometry(new Rect(0, 0, GlobeClip.ActualWidth, GlobeClip.ActualHeight), 15, 15);

    private void OnCloseDetail(object sender, MouseButtonEventArgs e) { _open = null; Paint(); }

    private void PaintRows()
    {
        string current = CurrentRegion;
        foreach ((string id, Row row) in _rows)
        {
            bool selected = id == current, live = selected && _status.Connected;
            bool offered = _status.Regions.Count == 0 || _status.Regions.Contains(id);
            row.Card.Background = live ? new SolidColorBrush(Color.FromRgb(0x12, 0x2B, 0x3A)) : row.Card.IsMouseOver || selected ? B("CardHover") : B("Card");
            row.Card.BorderBrush = live ? B("Mint") : row.Card.IsKeyboardFocused ? B("Ink") : selected ? (_status.Busy ? B("Amber") : B("Faint")) : B("CardLine");
            row.Name.Foreground = live ? B("MintInk") : B("Ink");
            row.Check.Visibility = live ? Visibility.Visible : Visibility.Collapsed;
            row.Chip.Visibility = live ? Visibility.Collapsed : Visibility.Visible;
            row.Card.Opacity = offered ? 1 : 0.4;
            row.Card.IsEnabled = offered;
        }
    }

    private void SetPulse(bool on)
    {
        if (on == _pulsing) return;
        _pulsing = on;
        foreach ((System.Windows.Shapes.Ellipse ring, double delay) in new[] { (Pulse1, 0.0), (Pulse2, 1.1) })
        {
            var scale = (ScaleTransform)ring.RenderTransform;
            if (!on || !SystemParameters.ClientAreaAnimation)
            {
                ring.BeginAnimation(OpacityProperty, null);
                scale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
                scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
                ring.Opacity = 0;
                continue;
            }
            var ease = new QuadraticEase { EasingMode = EasingMode.EaseOut };
            var grow = new DoubleAnimation(1.0, 1.32, TimeSpan.FromSeconds(2.2)) { RepeatBehavior = RepeatBehavior.Forever, BeginTime = TimeSpan.FromSeconds(delay), EasingFunction = ease };
            var fade = new DoubleAnimation(0.7, 0, TimeSpan.FromSeconds(2.2)) { RepeatBehavior = RepeatBehavior.Forever, BeginTime = TimeSpan.FromSeconds(delay), EasingFunction = ease };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
            ring.BeginAnimation(OpacityProperty, fade);
        }
    }

    /// <summary>While connecting, the power button breathes.</summary>
    private void SetBreathing(bool on)
    {
        if (on == _breathing) return;
        _breathing = on;
        if (on && SystemParameters.ClientAreaAnimation)
            PowerButton.BeginAnimation(OpacityProperty, new DoubleAnimation(1.0, 0.55, TimeSpan.FromSeconds(0.8)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
        else { PowerButton.BeginAnimation(OpacityProperty, null); PowerButton.Opacity = 1; }
    }

    private static string Bytes(long b) => b < 1_000_000 ? $"{Math.Max(0, b) / 1000} KB"
        : b < 1_000_000_000 ? (b / 1_000_000.0).ToString("0.0", CultureInfo.InvariantCulture) + " MB"
        : (b / 1_000_000_000.0).ToString("0.00", CultureInfo.InvariantCulture) + " GB";

    private static string ShortBytes(long b) => b < 1_000_000 ? $"{Math.Max(0, b) / 1000}K"
        : b < 100_000_000 ? (b / 1_000_000.0).ToString("0.0", CultureInfo.InvariantCulture) + "M"
        : b < 1_000_000_000 ? $"{b / 1_000_000}M"
        : (b / 1_000_000_000.0).ToString("0.0", CultureInfo.InvariantCulture) + "G";

    private string SessionText()
    {
        if (!_status.Connected || _status.Since <= 0) return "Not connected";
        long s = Math.Max(0, DateTimeOffset.UtcNow.ToUnixTimeSeconds() - _status.Since);
        return $"{s / 3600:00}:{s % 3600 / 60:00}:{s % 60:00}";
    }

    private void Paint()
    {
        Status s = _status;
        bool signIn = !s.SignedIn && _missed < 4;
        SignInView.Visibility = signIn ? Visibility.Visible : Visibility.Collapsed;
        MainView.Visibility = s.SignedIn ? Visibility.Visible : Visibility.Hidden;
        TabBar.Visibility = s.SignedIn ? Visibility.Visible : Visibility.Hidden;
        if (signIn && !AccountBox.IsKeyboardFocusWithin && IsActive) AccountBox.Focus();

        Region? region = Region.ById(CurrentRegion);
        Region? live = s.Connected ? Region.ById(s.Region) : null;
        if (s.Connected && _pick is not null && _pick == s.Region) _pick = null;

        // the power button: bright mint ring and teal face when protected, amber while working
        (PowerButton.BorderBrush, PowerButton.Background, PowerGlyph.Foreground) = s.State switch
        {
            "connected" => (B("Mint"), B("MintFill"), B("Mint")),
            "connecting" or "reconnecting" => (B("Amber"), B("AmberFill"), B("Amber")),
            "error" => (B("Danger"), B("OffFill"), B("Danger")),
            _ => (B("OffRing"), B("OffFill"), B("Muted")),
        };
        SetPulse(s.Connected);
        SetBreathing(s.Busy);
        AuraColour.Color = s.Connected ? Color.FromArgb(0x55, 0x3D, 0xDC, 0x97) : s.Busy ? Color.FromArgb(0x40, 0xFF, 0xB1, 0x3B) : Color.FromArgb(0x3A, 0x2E, 0x6B, 0xFF);

        (StatusTitle.Text, StatusTitle.Foreground) = s.State switch
        {
            "connected" => ("Protected", B("Ink")),
            "connecting" => ("Connecting", B("Ink")),
            "reconnecting" => ("Reconnecting", B("Ink")),
            "error" => ("Could not connect", B("Danger")),
            _ => ("Not protected", B("Ink")),
        };
        StatusSub.Text = s.State switch
        {
            "connected" => "Tunnel active · " + (live?.Name ?? s.Region),
            "connecting" or "reconnecting" => s.Message.Length > 0 ? s.Message : "Traffic is held until the tunnel is up",
            "error" => s.Message,
            _ => "Click to connect through " + (region?.Name ?? "a location"),
        };
        PillDot.Fill = s.Connected ? B("Mint") : s.Busy ? B("Amber") : B("Faint");
        PillText.Foreground = s.Connected ? B("Ink") : B("Muted");
        PillText.Text = s.Connected
            ? "CNSA 2.0 active · " + (s.KeyChanges == 1 ? "1 key change" : $"{s.KeyChanges} key changes")
            : s.Busy ? "Nothing leaves this PC meanwhile" : "CNSA 2.0 · quantum-resistant";
        _tray.Text = s.Connected ? $"Lattice VPN: protected ({live?.Short ?? s.Region})" : s.Busy ? "Lattice VPN: connecting" : "Lattice VPN: not protected";

        PaintRows();
        Globe.Show(s.Connected || s.Busy ? s.Region : CurrentRegion, s.Connected);

        // globe header
        LiveDot.Fill = live is null ? B("Muted") : B("Mint");
        LiveLabel.Text = live is null ? "LOCATIONS" : "LIVE CONNECTION";
        LiveName.Text = live?.Name ?? "Click a dot to pick a location";
        LiveName.Foreground = live is null ? B("Ink") : B("MintInk");
        LiveFlagBox.Visibility = live is null ? Visibility.Collapsed : Visibility.Visible;
        if (live is not null) LiveFlag.ImageSource = Flag(live.Id);
        GlobeHeader.Visibility = _open is null ? Visibility.Visible : Visibility.Hidden;

        // tiles
        string latency = s.Connected && s.LatencyMs > 0 ? $"{s.LatencyMs} ms" : "--";
        _tiles[Tile.Session].Value.Text = s.Connected ? SessionText() : "--";
        _tiles[Tile.Traffic].Value.Text = s.Connected ? $"{ShortBytes(s.BytesIn)} / {ShortBytes(s.BytesOut)}" : "--";
        _tiles[Tile.Latency].Value.Text = latency;
        _tiles[Tile.Keys].Value.Text = s.Connected && s.KeyChanges > 0 ? $"{s.KeyChanges} so far" : "10 min";
        foreach ((Tile tile, var t) in _tiles)
        {
            bool open = _open == tile;
            t.Value.Foreground = s.Connected ? B("MintInk") : B("Ink");
            t.Label.Foreground = open ? B("Mint") : B("Muted");
            t.Box.BorderBrush = open ? B("Mint") : t.Box.IsKeyboardFocused ? B("Ink") : B("CardLine");
        }
        PaintDetail(live, latency);
        if (AccountView.Visibility == Visibility.Visible) PaintAccount();
    }

    private void PaintDetail(Region? live, string latency)
    {
        if (_open is not { } tile) { DetailBox.Visibility = Visibility.Collapsed; return; }
        Status s = _status;
        DetailStack.Children.Clear();
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 5) };
        var close = new TextBlock { Text = "", FontFamily = F("Icons"), FontSize = 10, Foreground = B("Muted") };
        DockPanel.SetDock(close, Dock.Right);
        head.Children.Add(close);
        head.Children.Add(new TextBlock
        {
            Text = tile switch { Tile.Session => "THIS SESSION", Tile.Traffic => "DATA THIS SESSION", Tile.Latency => "LATENCY TO THE EXIT", _ => "KEY CHANGES" },
            Style = (Style)FindResource("Label"), Foreground = B("Mint"),
        });
        DetailStack.Children.Add(head);

        TextBlock Big(string text) => new() { Text = text, FontFamily = F("Mono"), FontSize = 22, FontWeight = FontWeights.Bold, Foreground = live is null ? B("Ink") : B("MintInk"), Margin = new Thickness(0, 0, 0, 6) };
        DockPanel Line(string label, string value)
        {
            var d = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
            var v = new TextBlock { Text = value, FontFamily = F("Mono"), FontSize = 12, FontWeight = FontWeights.SemiBold };
            DockPanel.SetDock(v, Dock.Right);
            d.Children.Add(v);
            d.Children.Add(new TextBlock { Text = label, FontSize = 12.5, Foreground = B("Muted") });
            return d;
        }
        TextBlock Note(string text) => new() { Text = text, FontSize = 11.5, Foreground = B("Muted"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 0) };

        switch (tile)
        {
            case Tile.Session:
                DetailStack.Children.Add(Big(SessionText()));
                if (live is not null)
                {
                    DetailStack.Children.Add(Line("Exit", live.Name));
                    DetailStack.Children.Add(Line("Exit address", s.Exit.Length > 0 ? s.Exit : live.Address));
                    if (s.Since > 0) DetailStack.Children.Add(Line("Connected at", DateTimeOffset.FromUnixTimeSeconds(s.Since).LocalDateTime.ToShortTimeString()));
                }
                else DetailStack.Children.Add(Note("Click the power button, or a dot on the globe, to connect."));
                break;
            case Tile.Traffic:
                if (live is not null)
                {
                    var row = new System.Windows.Controls.Primitives.UniformGrid { Rows = 1, Columns = 3, Margin = new Thickness(0, 0, 0, 4) };
                    foreach ((string label, long value) in new[] { ("DOWN", s.BytesIn), ("UP", s.BytesOut), ("TOTAL", s.BytesIn + s.BytesOut) })
                    {
                        var pair = new StackPanel();
                        pair.Children.Add(new TextBlock { Text = label, Style = (Style)FindResource("Label") });
                        pair.Children.Add(new TextBlock { Text = Bytes(value), FontFamily = F("Mono"), FontSize = 15, FontWeight = FontWeights.Bold, Foreground = B("MintInk") });
                        row.Children.Add(pair);
                    }
                    DetailStack.Children.Add(row);
                }
                else DetailStack.Children.Add(Big("--"));
                DetailStack.Children.Add(Note("Counted on this PC for this session only. Not saved and not sent to Lattice."));
                break;
            case Tile.Latency:
                DetailStack.Children.Add(Big(latency));
                if (live is not null && s.LatencyBestMs > 0)
                {
                    DetailStack.Children.Add(Line("Best", $"{s.LatencyBestMs} ms"));
                    DetailStack.Children.Add(Line("Average", $"{s.LatencyAverageMs} ms"));
                }
                DetailStack.Children.Add(Note(live is not null ? $"Round trip from this PC to {live.Name} and back, through the tunnel." : "Shown while connected."));
                break;
            default:
                DetailStack.Children.Add(Big(live is not null ? $"{s.KeyChanges} so far" : "--"));
                DetailStack.Children.Add(Line("Replaced", "Every 10 minutes"));
                DetailStack.Children.Add(Line("Key exchange", "ML-KEM-1024"));
                DetailStack.Children.Add(Line("Signatures", "ML-DSA-87"));
                DetailStack.Children.Add(Line("Cipher", "AES-256-GCM"));
                break;
        }
        DetailBox.Visibility = Visibility.Visible;
    }

    private static string Day(string rfc3339) =>
        DateTimeOffset.TryParse(rfc3339, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out DateTimeOffset d) && d.Year > 2000
            ? d.LocalDateTime.ToString("MMMM d, yyyy", CultureInfo.CurrentCulture) : "--";

    private void PaintAccount()
    {
        Status s = _status;
        AccountStack.Children.Clear();
        AccountStack.Children.Add(Heading("Account"));
        AccountStack.Children.Add(Fact("Subscription", s.Tier.Length > 0 ? "Active" : "Not active", mono: false));
        if (s.Tier.Length > 0) AccountStack.Children.Add(Fact("Plan", char.ToUpper(s.Tier[0], CultureInfo.InvariantCulture) + s.Tier[1..], mono: false));
        AccountStack.Children.Add(Fact("Paid through", Day(s.ActiveUntil), mono: false));
        if (s.DeviceLimit > 0) AccountStack.Children.Add(Fact("Devices", $"{s.DeviceCount} of {s.DeviceLimit} in use", mono: false));
        AccountStack.Children.Add(Fact("This PC's certificate", s.CertificateUntil > 0
            ? "Valid until " + DateTimeOffset.FromUnixTimeSeconds(s.CertificateUntil).LocalDateTime.ToString("MMMM d, yyyy", CultureInfo.CurrentCulture) + ". It renews by itself."
            : "Issued the first time you connect", mono: false));
        AccountStack.Children.Add(new Border { Height = 1, Background = B("CardLine"), Margin = new Thickness(0, 6, 0, 14) });
        AccountStack.Children.Add(Para("Your subscription works on every device you sign in on, up to your plan's device limit. If you sign in on more devices than the plan allows, the one that has gone longest without connecting is signed out to make room."));
        AccountStack.Children.Add(Para("Subscriptions are managed at latticevpn.ai. Your account number is never shown in this window."));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        buttons.Children.Add(Link("Manage subscription", () => OpenWeb("https://latticevpn.ai")));
        buttons.Children.Add(Link("Sign out of this PC", SignOut));
        AccountStack.Children.Add(buttons);
    }
}
