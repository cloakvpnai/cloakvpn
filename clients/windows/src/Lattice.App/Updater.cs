using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using NetSparkleUpdater;
using NetSparkleUpdater.Enums;
using NetSparkleUpdater.SignatureVerifiers;

namespace Lattice.App;

/// <summary>
/// Downloads and starts the installer for a newer Lattice VPN, when the person asks for it.
///
/// Nothing here runs on its own: <see cref="UpdateCheck"/> only shows the notice, and this
/// class does its work after the person clicks "Get the update".
///
/// What is trusted, and why:
///  - The list of releases (the feed) and the installer must both carry an Ed25519 signature
///    made with the Lattice release key. The public half is the constant below. A feed or an
///    installer without a good signature is refused, so someone who controls the download
///    server or the network still cannot get this app to run their file.
///  - The installer is also signed for Windows, which checks the publisher when it starts.
///  - The request carries no account number, device name or identifier.
///
/// The installer replaces the service, so the tunnel is down while it runs.
/// </summary>
public sealed class Updater
{
    /// <summary>Public half of the Lattice release key. The private half never leaves the build PC.</summary>
    public const string ReleaseKey = "PaIAYMp2MZ4Y+ZwYhmda3K94rk7JYUsN9rYOEsoOmCU=";

    private const string FeedBase = "https://downloads.latticevpn.ai/windows/";

    /// <summary>One feed for each kind of processor, since the installers differ.</summary>
    public static string FeedUrl
    {
        get
        {
#if DEBUG
            // Debug builds only: point the updater at a test feed.
            string? test = Environment.GetEnvironmentVariable("LATTICE_UPDATE_FEED");
            if (!string.IsNullOrEmpty(test)) return test;
#endif
            return FeedBase + (RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "appcast-arm64.xml" : "appcast-x64.xml");
        }
    }

    /// <summary>Whole numbers from 0 to 100 while the installer downloads.</summary>
    public event Action<int>? Progress;

    private bool _running;

    /// <summary>
    /// Fetches the feed, downloads the newest installer, checks both signatures and starts the
    /// installer. Returns false when there was nothing to install or anything failed; the caller
    /// then falls back to the download page. <paramref name="quit"/> must end the app at once,
    /// because the installer waits for it.
    /// </summary>
    public async Task<bool> RunAsync(Action quit)
    {
        if (_running) return true;
        _running = true;
        try
        {
            var sparkle = new SparkleUpdater(FeedUrl, new Ed25519Checker(SecurityMode.Strict, ReleaseKey))
            {
                UIFactory = null,
                RelaunchAfterUpdate = true,
                // A progress bar and no questions. Windows still asks for permission to install.
                CustomInstallerArguments = "/passive /norestart",
            };

            Note("asking " + FeedUrl);
            UpdateInfo info = await sparkle.CheckForUpdatesQuietly();
            Note($"feed {FeedUrl}: {info.Status}, {info.Updates?.Count ?? 0} newer");
            if (info.Status != UpdateStatus.UpdateAvailable || info.Updates is null || info.Updates.Count == 0) return false;
            AppCastItem newest = info.Updates[0];
            if (!FromLattice(newest.DownloadLink)) { Note("refused: installer is not at the Lattice download address"); return false; }

            var done = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
            bool quitting = false;
            sparkle.DownloadMadeProgress += (_, _, e) => Progress?.Invoke(e.ProgressPercentage);
            sparkle.DownloadFinished += (_, path) => done.TrySetResult(path);
            sparkle.DownloadHadError += (_, _, error) => { Note("download failed: " + error.Message); done.TrySetResult(null); };
            sparkle.DownloadCanceled += (_, _) => done.TrySetResult(null);
            sparkle.CloseApplication += () => { quitting = true; Note("installer started, closing"); quit(); };

            await sparkle.InitAndBeginDownload(newest);
            string? file = await done.Task;
            if (file is null) return false;
            Note($"downloaded {newest.Version} to {file}");

            // Refuses the file unless its signature matches the release key, then starts the
            // installer and calls quit.
            await sparkle.InstallUpdate(newest, file);
            if (!quitting) Note("refused: the installer was not started (bad signature or it could not run)");
            return quitting;
        }
        catch (Exception e)
        {
            Note("failed: " + e.GetType().Name + ": " + e.Message);
            return false;
        }
        finally
        {
            _running = false;
        }
    }

    /// <summary>Debug builds keep a short record of what the updater did. Release builds keep none.</summary>
    [System.Diagnostics.Conditional("DEBUG")]
    private static void Note(string line)
    {
        try { System.IO.File.AppendAllText(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "lattice-update.log"), DateTime.Now.ToString("HH:mm:ss ") + line + Environment.NewLine); }
        catch (Exception) { }
    }

    /// <summary>Installers come from the Lattice download address over HTTPS and nowhere else.</summary>
    private static bool FromLattice(string? link)
    {
#if DEBUG
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("LATTICE_UPDATE_FEED"))) return true;
#endif
        return Uri.TryCreate(link, UriKind.Absolute, out Uri? uri)
            && uri.Scheme == Uri.UriSchemeHttps
            && uri.Host.Equals("downloads.latticevpn.ai", StringComparison.OrdinalIgnoreCase);
    }
}
