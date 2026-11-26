using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Media.Media3D;

namespace Lattice.App;

public sealed record Region(string Id, string Name, string Short, string Address, double Latitude, double Longitude)
{
    /// <summary>Every region, with where its servers are to the nearest city. Same list as the other apps.</summary>
    public static readonly IReadOnlyList<Region> All = new[]
    {
        new Region("us-west-1", "US West (Oregon)", "US-W", "5.78.203.171", 45.52, -122.99),
        new Region("us-east-1", "US East (Virginia)", "US-E", "5.161.198.227", 39.04, -77.49),
        new Region("us-central-1", "US Central (Dallas)", "US-C", "207.148.1.253", 32.78, -96.80),
        new Region("de1", "Germany (Falkenstein)", "DE", "91.98.65.98", 50.48, 12.37),
        new Region("fi1", "Finland (Helsinki)", "FI", "204.168.252.70", 60.17, 24.94),
        new Region("es1", "Spain (Madrid)", "ES", "65.20.99.121", 40.42, -3.70),
        new Region("mx1", "Mexico (Mexico City)", "MX", "216.238.95.21", 19.43, -99.13),
        new Region("za1", "South Africa (Johannesburg)", "ZA", "139.84.248.50", -26.20, 28.05),
        new Region("in1", "India (Mumbai)", "IN", "65.20.77.179", 19.08, 72.88),
        new Region("jp1", "Japan (Tokyo)", "JP", "167.179.75.10", 35.68, 139.69),
    };

    public static Region? ById(string? id)
    {
        foreach (Region r in All) if (r.Id == id) return r;
        return null;
    }
}

/// <summary>
/// The Earth, as it looks from space right now.
///
/// A real sphere drawn by the graphics card, wrapped in NASA imagery that ships
/// inside the app (so it makes no network requests and uses no map service):
///   day side     Blue Marble Next Generation with topography and bathymetry
///   night side   Black Marble 2016 city lights, shown only where it is night
///   clouds       the Blue Marble cloud layer, on its own shell, drifting slowly
/// The sun is placed where it really is at this moment, so the line between day
/// and night on the globe is the real one. Oceans catch the sun; land does not.
/// One dot per Lattice location sits on top, the exit in use lit and pulsing.
/// </summary>
public sealed class GlobeControl : Grid
{
    private const double DegreesPerSecond = 3.0;
    private const double Rad = Math.PI / 180.0;
    private const double ViewScale = 1.05;   // the 3D view is a little wider than the planet, for the cloud shell

    private sealed class Layer : FrameworkElement
    {
        public Action<DrawingContext, Size>? Draw;
        protected override void OnRender(DrawingContext dc) => Draw?.Invoke(dc, RenderSize);
    }

    private readonly Layer _back = new(), _front = new() { IsHitTestVisible = false };
    private readonly Viewport3D _view = new() { IsHitTestVisible = false, ClipToBounds = false, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
    private readonly AxisAngleRotation3D _spin = new(new Vector3D(0, 1, 0), 0), _tilt = new(new Vector3D(1, 0, 0), 0);
    private readonly AxisAngleRotation3D _cloudSpin = new(new Vector3D(0, 1, 0), 0);
    private readonly DirectionalLight _sun = new(Colors.White, new Vector3D(0, 0, -1));
    private readonly DirectionalLight _sunFill = new(Color.FromRgb(0x8C, 0x8C, 0x8C), new Vector3D(0, 0, -1));
    private readonly Stopwatch _clock = Stopwatch.StartNew();

    private byte[]? _nightPixels;            // Bgr32, NightWidth x NightHeight
    private WriteableBitmap? _nightLit;      // the night lights, masked to where it is night
    private const int NightWidth = 2048, NightHeight = 1024;
    private double _bakedSunLon = double.NaN;

    private double _centerLon = -100, _centerLat = 18;
    private double _last, _holdUntil, _lastDraw;
    private double _swingFromLon, _swingFromLat, _swingToLon, _swingToLat, _swingStart = -1;
    private Point? _dragFrom;
    private bool _dragged, _built;
    private string? _selected;
    private bool _connected;

    public event Action<Region>? Picked;

    private static readonly Color Mint = Color.FromRgb(0x5F, 0xE3, 0xB5);
    private static readonly Brush MintBrush = Frozen(Mint);
    private static readonly Brush MintPale = Frozen(Color.FromRgb(0xBF, 0xF3, 0xDC));
    private static readonly Brush DotWhite = Frozen(Color.FromArgb(0xF2, 0xFF, 0xFF, 0xFF));
    private static readonly Brush DotShadow = Frozen(Color.FromArgb(0xA0, 0, 0, 0));
    private static readonly Brush Space = Frozen(Color.FromRgb(0x03, 0x05, 0x0B));

    private static Brush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }

    public GlobeControl()
    {
        ClipToBounds = true;
        Cursor = Cursors.Hand;
#if DEBUG
        // Preview builds only: start facing a chosen longitude and stay there, for screenshots.
        if (double.TryParse(Environment.GetEnvironmentVariable("LATTICE_GLOBE_LON"), out double lon)) { _centerLon = Wrap(lon); _holdUntil = double.MaxValue; }
#endif
        Children.Add(_back);
        Children.Add(_view);
        Children.Add(_front);
        _back.Draw = DrawBack;
        _front.Draw = DrawFront;
        Loaded += (_, _) => { Build(); CompositionTarget.Rendering += OnFrame; };
        Unloaded += (_, _) => CompositionTarget.Rendering -= OnFrame;
        SizeChanged += (_, _) => Place();
    }

    // ---- building the scene ----

    private static BitmapSource Load(string name, int decodeWidth = 0)
    {
        var image = new BitmapImage();
        image.BeginInit();
        image.UriSource = new Uri($"pack://application:,,,/Assets/Earth/{name}.jpg");
        image.CacheOption = BitmapCacheOption.OnLoad;
        if (decodeWidth > 0) image.DecodePixelWidth = decodeWidth;
        image.EndInit();
        image.Freeze();
        return image;
    }

    private static byte[] Pixels(BitmapSource source, out int width, out int height)
    {
        var converted = new FormatConvertedBitmap(source, PixelFormats.Bgr32, null, 0);
        width = converted.PixelWidth; height = converted.PixelHeight;
        var pixels = new byte[width * height * 4];
        converted.CopyPixels(pixels, width * 4, 0);
        return pixels;
    }

    private static ImageBrush Texture(ImageSource image)
    {
        var brush = new ImageBrush(image) { ViewportUnits = BrushMappingMode.Absolute, Viewport = new Rect(0, 0, 1, 1), Stretch = Stretch.Fill, TileMode = TileMode.None };
        RenderOptions.SetCachingHint(brush, CachingHint.Cache);
        RenderOptions.SetBitmapScalingMode(brush, BitmapScalingMode.HighQuality);
        return brush;
    }

    /// <summary>A sphere of the given radius with a world map wrapped round it: longitude 0 faces the viewer, north is up.</summary>
    private static MeshGeometry3D Sphere(double radius, int rows, int columns)
    {
        var mesh = new MeshGeometry3D();
        var positions = new Point3DCollection((rows + 1) * (columns + 1));
        var normals = new Vector3DCollection((rows + 1) * (columns + 1));
        var texture = new PointCollection((rows + 1) * (columns + 1));
        for (int i = 0; i <= rows; i++)
        {
            double lat = (90 - 180.0 * i / rows) * Rad, sinLat = Math.Sin(lat), cosLat = Math.Cos(lat);
            for (int j = 0; j <= columns; j++)
            {
                double lon = (-180 + 360.0 * j / columns) * Rad;
                double x = cosLat * Math.Sin(lon), y = sinLat, z = cosLat * Math.Cos(lon);
                positions.Add(new Point3D(x * radius, y * radius, z * radius));
                normals.Add(new Vector3D(x, y, z));
                texture.Add(new Point((double)j / columns, (double)i / rows));
            }
        }
        var indices = new Int32Collection(rows * columns * 6);
        for (int i = 0; i < rows; i++)
        {
            for (int j = 0; j < columns; j++)
            {
                int a = i * (columns + 1) + j, b = a + columns + 1, c = a + 1, d = b + 1;
                indices.Add(a); indices.Add(b); indices.Add(c);
                indices.Add(c); indices.Add(b); indices.Add(d);
            }
        }
        mesh.Positions = positions; mesh.Normals = normals; mesh.TextureCoordinates = texture; mesh.TriangleIndices = indices;
        mesh.Freeze();
        return mesh;
    }

    private void Build()
    {
        if (_built) return;
        _built = true;
        try
        {
            BitmapSource day = Load("day");

            // Where the sun may glint: open water only. Found from the day image itself.
            byte[] small = Pixels(Load("day", 1024), out int sw, out int sh);
            var mask = new byte[sw * sh * 4];
            for (int p = 0; p < small.Length; p += 4)
            {
                int b = small[p], g = small[p + 1], r = small[p + 2];
                bool water = b > r * 1.25 && b >= g * 0.92 && r < 90;
                byte v = water ? (byte)150 : (byte)0;
                mask[p] = (byte)Math.Min(255, v + 20 * (water ? 1 : 0)); mask[p + 1] = v; mask[p + 2] = (byte)(v * 0.92); mask[p + 3] = 255;
            }
            var water1 = BitmapSource.Create(sw, sh, 96, 96, PixelFormats.Bgr32, null, mask, sw * 4);
            water1.Freeze();

            // City lights: kept in memory, and painted only onto the night side (see BakeNight).
            _nightPixels = Pixels(Load("night", NightWidth), out _, out _);
            _nightLit = new WriteableBitmap(NightWidth, NightHeight, 96, 96, PixelFormats.Bgr32, null);

            // Clouds: the grey image becomes white with see-through gaps.
            byte[] grey = Pixels(Load("clouds"), out int cw, out int ch);
            var clouds = new byte[cw * ch * 4];
            for (int p = 0; p < grey.Length; p += 4)
            {
                double c = grey[p + 1] / 255.0;
                double alpha = Math.Clamp((c - 0.12) / 0.70, 0, 1);
                alpha = alpha * alpha * (3 - 2 * alpha) * 0.92;
                clouds[p] = 255; clouds[p + 1] = 255; clouds[p + 2] = 255; clouds[p + 3] = (byte)(alpha * 255);
            }
            var cloudImage = BitmapSource.Create(cw, ch, 96, 96, PixelFormats.Bgra32, null, clouds, cw * 4);
            cloudImage.Freeze();

            var surface = new MaterialGroup();
            surface.Children.Add(new DiffuseMaterial(Texture(day)));
            surface.Children.Add(new SpecularMaterial(Texture(water1), 22));
            surface.Children.Add(new EmissiveMaterial(Texture(_nightLit)));

            var turn = new Transform3DGroup();
            turn.Children.Add(new RotateTransform3D(_spin));
            turn.Children.Add(new RotateTransform3D(_tilt));
            var earth = new GeometryModel3D(Sphere(1, 96, 192), surface) { Transform = turn };

            var cloudTurn = new Transform3DGroup();
            cloudTurn.Children.Add(new RotateTransform3D(_cloudSpin));
            cloudTurn.Children.Add(new RotateTransform3D(_tilt));
            var shell = new GeometryModel3D(Sphere(1.012, 64, 128), new DiffuseMaterial(Texture(cloudImage))) { Transform = cloudTurn };

            var scene = new Model3DGroup();
            scene.Children.Add(new AmbientLight(Color.FromRgb(0x26, 0x2B, 0x36)));
            scene.Children.Add(_sun);
            scene.Children.Add(_sunFill);
            scene.Children.Add(earth);
            scene.Children.Add(shell);
            _view.Children.Add(new ModelVisual3D { Content = scene });
            _view.Camera = new OrthographicCamera(new Point3D(0, 0, 6), new Vector3D(0, 0, -1), new Vector3D(0, 1, 0), 2 * ViewScale) { NearPlaneDistance = 1, FarPlaneDistance = 12 };
            Place();
        }
        catch (Exception e) when (e is System.IO.IOException or NotSupportedException or InvalidOperationException)
        {
            // Without the imagery the panel still shows space, the atmosphere and the location dots.
            _view.Children.Clear();
        }
    }

    /// <summary>Where the sun is overhead right now: latitude and longitude in degrees. Good to about a degree.</summary>
    private static (double Lat, double Lon) Subsolar()
    {
        DateTime utc = DateTime.UtcNow;
        double hours = utc.Hour + utc.Minute / 60.0 + utc.Second / 3600.0;
        double lat = -23.44 * Math.Cos(2 * Math.PI * (utc.DayOfYear + 10) / 365.0);
        return (lat, Wrap(-15 * (hours - 12)));
    }

    /// <summary>
    /// Paints the city lights onto the night half of the world map, fading through
    /// dusk. Redone when the sun has moved half a degree, about every two minutes.
    /// </summary>
    private void BakeNight((double Lat, double Lon) sun)
    {
        if (_nightPixels is null || _nightLit is null) return;
        if (!double.IsNaN(_bakedSunLon) && Math.Abs(Wrap(sun.Lon - _bakedSunLon)) < 0.5) return;
        _bakedSunLon = sun.Lon;

        double sinD = Math.Sin(sun.Lat * Rad), cosD = Math.Cos(sun.Lat * Rad);
        var cosLon = new double[NightWidth];
        for (int x = 0; x < NightWidth; x++) cosLon[x] = Math.Cos(((x + 0.5) / NightWidth * 360 - 180 - sun.Lon) * Rad);

        var output = new byte[_nightPixels.Length];
        for (int y = 0; y < NightHeight; y++)
        {
            double lat = (90 - (y + 0.5) / NightHeight * 180) * Rad;
            double a = Math.Sin(lat) * sinD, b = Math.Cos(lat) * cosD;
            int row = y * NightWidth * 4;
            for (int x = 0; x < NightWidth; x++)
            {
                double towardSun = a + b * cosLon[x];           // 1 at noon, -1 at midnight
                double t = (0.08 - towardSun) / 0.26;           // dusk is a band, not a line
                if (t <= 0) continue;
                if (t > 1) t = 1;
                t = t * t * (3 - 2 * t);
                int p = row + x * 4;
                // lift the lights, keep the dark ground dark
                int bl = _nightPixels[p], g = _nightPixels[p + 1], r = _nightPixels[p + 2];
                double glow = Math.Max(r, Math.Max(g, bl)) / 255.0;
                double gain = t * (0.55 + 1.9 * glow);
                output[p] = (byte)Math.Min(255, bl * gain);
                output[p + 1] = (byte)Math.Min(255, g * gain);
                output[p + 2] = (byte)Math.Min(255, r * gain);
            }
        }
        _nightLit.WritePixels(new Int32Rect(0, 0, NightWidth, NightHeight), output, NightWidth * 4, 0);
    }

    // ---- placing and turning ----

    private Point Center => new(ActualWidth / 2, ActualHeight * 0.52);
    private double Radius => Math.Max(10, Math.Min(ActualWidth * 0.44, ActualHeight * 0.40));

    private void Place()
    {
        double side = 2 * Radius * ViewScale;
        Point c = Center;
        _view.Width = side; _view.Height = side;
        _view.Margin = new Thickness(c.X - side / 2, c.Y - side / 2, 0, 0);
        _back.InvalidateVisual();
    }

    /// <summary>Tells the globe what to show. A new connection swings the globe to the exit and rests on it.</summary>
    public void Show(string? selectedRegion, bool connected)
    {
        bool changed = selectedRegion != _selected || connected != _connected;
        _selected = selectedRegion; _connected = connected;
        if (!changed) return;
        if (connected && Region.ById(selectedRegion) is { } exit)
        {
            _swingFromLon = _centerLon; _swingFromLat = _centerLat;
            double delta = Wrap(exit.Longitude - _centerLon);
            _swingToLon = _centerLon + delta; _swingToLat = Math.Clamp(exit.Latitude, -45, 45);
            _swingStart = _clock.Elapsed.TotalSeconds;
            _holdUntil = double.MaxValue;
        }
    }

    private static double Wrap(double lon)
    {
        while (lon > 180) lon -= 360;
        while (lon < -180) lon += 360;
        return lon;
    }

    private void OnFrame(object? sender, EventArgs e)
    {
        double now = _clock.Elapsed.TotalSeconds;
        if (_swingStart >= 0)
        {
            double v = Math.Min(1, (now - _swingStart) / 1.1);
            double ease = 1 - Math.Pow(1 - v, 3);
            _centerLon = Wrap(_swingFromLon + (_swingToLon - _swingFromLon) * ease);
            _centerLat = _swingFromLat + (_swingToLat - _swingFromLat) * ease;
            if (v >= 1) { _swingStart = -1; _holdUntil = now + 6; }
        }
        else if (_last > 0 && now >= _holdUntil && SystemParameters.ClientAreaAnimation) // rests when Windows animations are off
        {
            double dt = Math.Min(now - _last, 0.1);
            _centerLon = Wrap(_centerLon + DegreesPerSecond * dt);
            _centerLat += (18 - _centerLat) * Math.Min(1, dt * 0.4);
        }
        _last = now;
        if (now - _lastDraw < 1.0 / 60 || !IsVisible) return;
        _lastDraw = now;

        Aim();
        _spin.Angle = -_centerLon;
        _tilt.Angle = _centerLat;
        _cloudSpin.Angle = -_centerLon + now * 0.35;   // weather drifts east, slowly

        var sun = Subsolar();
        BakeNight(sun);
        Project(sun.Lon * Rad, Math.Sin(sun.Lat * Rad), Math.Cos(sun.Lat * Rad), out _sunX, out _sunY, out _sunZ);
        var from = new Vector3D(-_sunX, -_sunY, -_sunZ);
        _sun.Direction = from; _sunFill.Direction = from;
        _front.InvalidateVisual();
    }

    // ---- where things land on screen (matches the 3D view exactly) ----

    private double _lon0, _sin0, _cos0, _sunX, _sunY, _sunZ = 1;

    private void Aim()
    {
        _lon0 = _centerLon * Rad;
        _sin0 = Math.Sin(_centerLat * Rad);
        _cos0 = Math.Cos(_centerLat * Rad);
    }

    /// <summary>x to the right, y up, z toward the viewer, on a sphere of radius 1. z above 0 is the near side.</summary>
    private void Project(double lonRad, double sinLat, double cosLat, out double x, out double y, out double z)
    {
        double dl = lonRad - _lon0, cosDl = Math.Cos(dl);
        x = cosLat * Math.Sin(dl);
        y = _cos0 * sinLat - _sin0 * cosLat * cosDl;
        z = _sin0 * sinLat + _cos0 * cosLat * cosDl;
    }

    // ---- the 2D layers behind and in front of the planet ----

    private void DrawBack(DrawingContext dc, Size size)
    {
        dc.DrawRectangle(Space, null, new Rect(size));
        Point c = Center; double r = Radius;

        // A faint band of the Milky Way, then stars of mixed size and warmth.
        var band = new LinearGradientBrush(Color.FromArgb(0, 60, 80, 140), Color.FromArgb(0, 60, 80, 140), new Point(0, 0.15), new Point(1, 0.85));
        band.GradientStops.Insert(1, new GradientStop(Color.FromArgb(0x1E, 70, 95, 160), 0.5));
        dc.DrawRectangle(band, null, new Rect(size));
        var random = new Random(20261125);
        for (int i = 0; i < 260; i++)
        {
            double x = random.NextDouble() * size.Width, y = random.NextDouble() * size.Height;
            double magnitude = Math.Pow(random.NextDouble(), 3.2);
            double radius = 0.35 + magnitude * 1.15;
            byte alpha = (byte)(70 + magnitude * 185);
            Color tint = (i % 7) switch { 0 => Color.FromArgb(alpha, 255, 226, 190), 1 => Color.FromArgb(alpha, 190, 214, 255), _ => Color.FromArgb(alpha, 255, 255, 255) };
            dc.DrawEllipse(new SolidColorBrush(tint), null, new Point(x, y), radius, radius);
        }

        // The air, seen edge-on past the rim of the planet.
        var halo = new RadialGradientBrush();
        halo.GradientStops.Add(new GradientStop(Color.FromArgb(0, 80, 150, 255), 0.0));
        halo.GradientStops.Add(new GradientStop(Color.FromArgb(0x88, 96, 170, 255), 0.832));
        halo.GradientStops.Add(new GradientStop(Color.FromArgb(0x38, 70, 140, 255), 0.90));
        halo.GradientStops.Add(new GradientStop(Color.FromArgb(0, 50, 110, 255), 1.0));
        dc.DrawEllipse(halo, null, c, r * 1.2, r * 1.2);
    }

    private void DrawFront(DrawingContext dc, Size size)
    {
        Point c = Center; double r = Radius;

        // Air over the surface: thin at the centre, thick toward the limb, brighter on the sunlit side.
        var limb = new RadialGradientBrush();
        limb.GradientStops.Add(new GradientStop(Color.FromArgb(0, 120, 180, 255), 0.0));
        limb.GradientStops.Add(new GradientStop(Color.FromArgb(0, 120, 180, 255), 0.70));
        limb.GradientStops.Add(new GradientStop(Color.FromArgb(0x30, 120, 185, 255), 0.90));
        limb.GradientStops.Add(new GradientStop(Color.FromArgb(0x80, 150, 205, 255), 1.0));
        dc.DrawEllipse(limb, null, c, r, r);

        double flat = Math.Sqrt(_sunX * _sunX + _sunY * _sunY);
        if (flat > 0.05)
        {
            // a crescent of scattered sunlight on the day-side limb, and shadow on the far limb
            double ux = _sunX / flat, uy = -_sunY / flat;
            var rim = new RadialGradientBrush();
            rim.GradientStops.Add(new GradientStop(Color.FromArgb(0, 175, 220, 255), 0.78));
            rim.GradientStops.Add(new GradientStop(Color.FromArgb((byte)(0x78 * Math.Min(1, flat * 1.4)), 175, 220, 255), 1.0));
            // only on the side facing the sun, fading out round the disc
            var side = new LinearGradientBrush(Color.FromArgb(0, 0, 0, 0), Colors.Black,
                new Point(c.X - ux * r * 0.15, c.Y - uy * r * 0.15), new Point(c.X + ux * r, c.Y + uy * r)) { MappingMode = BrushMappingMode.Absolute };
            dc.PushOpacityMask(side);
            dc.DrawEllipse(rim, null, c, r, r);
            dc.Pop();
        }

        // Location dots. The exit in use is larger, mint, and sends out a ring.
        double pulse = _clock.Elapsed.TotalSeconds % 1.8 / 1.8;
        foreach (Region region in Region.All)
        {
            Project(region.Longitude * Rad, Math.Sin(region.Latitude * Rad), Math.Cos(region.Latitude * Rad), out double x, out double y, out double z);
            if (z <= 0.03) continue;
            var at = new Point(c.X + r * x, c.Y - r * y);
            bool selected = region.Id == _selected, live = _connected && selected;
            double fade = Math.Min(1, z * 5);   // dots dim as they near the horizon
            dc.PushOpacity(fade);
            if (live)
            {
                var halo = new RadialGradientBrush(Color.FromArgb(0x70, Mint.R, Mint.G, Mint.B), Color.FromArgb(0, Mint.R, Mint.G, Mint.B));
                dc.DrawEllipse(halo, null, at, 16, 16);
                var ring = new Pen(new SolidColorBrush(Color.FromArgb((byte)(235 * (1 - pulse)), Mint.R, Mint.G, Mint.B)), 1.6);
                dc.DrawEllipse(null, ring, at, 5 + 15 * pulse, 5 + 15 * pulse);
            }
            double dot = live ? 5.0 : selected ? 4.0 : 3.0;
            dc.DrawEllipse(DotShadow, null, at, dot + 1.4, dot + 1.4);
            dc.DrawEllipse(live ? MintBrush : selected ? MintPale : DotWhite, null, at, dot, dot);
            dc.Pop();
        }
    }

    // ---- mouse ----

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        _dragFrom = e.GetPosition(this); _dragged = false;
        CaptureMouse();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (_dragFrom is not { } from || e.LeftButton != MouseButtonState.Pressed) return;
        Point now = e.GetPosition(this);
        double dx = now.X - from.X, dy = now.Y - from.Y;
        if (Math.Abs(dx) + Math.Abs(dy) < 3 && !_dragged) return;
        _dragged = true; _swingStart = -1;
        _centerLon = Wrap(_centerLon - dx / Radius / Rad);
        _centerLat = Math.Clamp(_centerLat + dy / Radius / Rad, -70, 70);
        _dragFrom = now;
        _holdUntil = _clock.Elapsed.TotalSeconds + 5;
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        ReleaseMouseCapture();
        Point at = e.GetPosition(this);
        bool wasDrag = _dragged;
        _dragFrom = null; _dragged = false;
        if (wasDrag) return;
        Aim();
        Point c = Center; double r = Radius;
        Region? best = null; double bestDistance = 24;
        foreach (Region region in Region.All)
        {
            Project(region.Longitude * Rad, Math.Sin(region.Latitude * Rad), Math.Cos(region.Latitude * Rad), out double x, out double y, out double z);
            if (z <= 0) continue;
            double d = Math.Sqrt(Math.Pow(c.X + r * x - at.X, 2) + Math.Pow(c.Y - r * y - at.Y, 2));
            if (d < bestDistance) { bestDistance = d; best = region; }
        }
        if (best is not null)
        {
            _holdUntil = _clock.Elapsed.TotalSeconds + 5;
            Picked?.Invoke(best);
        }
    }
}
