// Draws the port's button glyphs: one PNG per physical input, per controller style, in roughly
// the GameCube release's icon style (a glossy ball with a dark outline and a white letter).
// Built and run by make-button-glyphs.ps1; the PNGs it writes are committed, so this only runs
// when the art changes.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;

public static class ButtonGlyphs
{
    const int Size = 128;
    static readonly Color Outline = Color.FromArgb(255, 16, 16, 20);
    static string fontFamily = "Arial Black";

    // A face button: a ball in `fill` with `label` (text) or `symbol` (a drawn shape) on it.
    delegate void Painter(Graphics g);

    public static int Generate(string outDir, string font)
    {
        fontFamily = font;
        int count = 0;
        foreach (var style in Styles())
        {
            string dir = Path.Combine(outDir, style.Key);
            Directory.CreateDirectory(dir);
            foreach (var glyph in style.Value)
            {
                Save(Path.Combine(dir, glyph.Key + ".png"), glyph.Value);
                count++;
            }
        }
        string keys = Path.Combine(outDir, "keyboard");
        Directory.CreateDirectory(keys);
        foreach (var key in KeyLabels())
        {
            string label = key.Value;
            Save(Path.Combine(keys, key.Key + ".png"), g => Keycap(g, label));
            count++;
        }
        // A whole stick on the keyboard: four keys in an inverted T. The runtime picks these when a
        // stick's four directions are bound to exactly W A S D or to the arrow keys.
        Save(Path.Combine(keys, "WASD.png"), g => KeyCluster(g, new[] { "W", "A", "S", "D" }));
        Save(Path.Combine(keys, "ARROWS.png"), g => KeyCluster(g, new[] { "↑", "←", "↓", "→" }));
        return count + 2;
    }

    static void Save(string path, Painter paint)
    {
        using (var bmp = new Bitmap(Size, Size, PixelFormat.Format32bppArgb))
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.Clear(Color.Transparent);
            paint(g);
            bmp.Save(path, ImageFormat.Png);
        }
    }

    // ---- styles -------------------------------------------------------------------------------
    // Glyph ids are the emulator's input names with spaces as underscores ("Button_S", "Trigger_L"),
    // plus Left_Stick / Right_Stick / Pad for the stick and d-pad directions.

    static Dictionary<string, Dictionary<string, Painter>> Styles()
    {
        var styles = new Dictionary<string, Dictionary<string, Painter>>();

        Color gcGreen = Color.FromArgb(255, 34, 170, 64), gcRed = Color.FromArgb(255, 214, 40, 52);
        Color gcGray = Color.FromArgb(255, 176, 180, 190), gcPurple = Color.FromArgb(255, 96, 82, 204);
        Color gcYellow = Color.FromArgb(255, 238, 196, 30);
        styles["gamecube"] = new Dictionary<string, Painter>
        {
            { "Button_S", g => Ball(g, gcGreen, "A") },
            { "Button_W", g => Ball(g, gcRed, "B") },
            { "Button_E", g => Bean(g, gcGray, "X", 70) },
            { "Button_N", g => Bean(g, gcGray, "Y", -12) },
            { "Shoulder_R", g => Bar(g, gcPurple, "Z") },
            { "Shoulder_L", g => Bar(g, gcPurple, "Z") },
            { "Trigger_L", g => Shoulder(g, gcGray, "L", true) },
            { "Trigger_R", g => Shoulder(g, gcGray, "R", false) },
            { "Start", g => Pill(g, gcGray, "START") },
            { "Back", g => Pill(g, gcGray, "SELECT") },
            { "Guide", g => Pill(g, gcGray, "HOME") },
            { "Left_Stick", g => Stick(g, gcGray, "") },
            { "Right_Stick", g => Ball(g, gcYellow, "C") },
            { "Thumb_L", g => Stick(g, gcGray, "L") },
            { "Thumb_R", g => Stick(g, gcYellow, "C") },
            { "Pad", g => Dpad(g) },
        };

        Color psBody = Color.FromArgb(255, 34, 36, 42);
        styles["playstation"] = new Dictionary<string, Painter>
        {
            { "Button_S", g => Ball(g, psBody, null, s => Cross(s, Color.FromArgb(255, 124, 166, 236))) },
            { "Button_E", g => Ball(g, psBody, null, s => Ring(s, Color.FromArgb(255, 236, 98, 106))) },
            { "Button_W", g => Ball(g, psBody, null, s => Square(s, Color.FromArgb(255, 232, 140, 204))) },
            { "Button_N", g => Ball(g, psBody, null, s => Triangle(s, Color.FromArgb(255, 72, 200, 156))) },
            { "Shoulder_L", g => Bar(g, psBody, "L1") },
            { "Shoulder_R", g => Bar(g, psBody, "R1") },
            { "Trigger_L", g => Shoulder(g, psBody, "L2", true) },
            { "Trigger_R", g => Shoulder(g, psBody, "R2", false) },
            { "Start", g => Pill(g, psBody, "START") },
            { "Back", g => Pill(g, psBody, "SELECT") },
            { "Guide", g => Pill(g, psBody, "PS") },
            { "Left_Stick", g => Stick(g, psBody, "L") },
            { "Right_Stick", g => Stick(g, psBody, "R") },
            { "Thumb_L", g => Stick(g, psBody, "L3") },
            { "Thumb_R", g => Stick(g, psBody, "R3") },
            { "Pad", g => Dpad(g) },
        };

        Color xbDark = Color.FromArgb(255, 44, 46, 52);
        styles["xbox"] = new Dictionary<string, Painter>
        {
            { "Button_S", g => Ball(g, Color.FromArgb(255, 60, 176, 60), "A") },
            { "Button_E", g => Ball(g, Color.FromArgb(255, 222, 58, 48), "B") },
            { "Button_W", g => Ball(g, Color.FromArgb(255, 40, 112, 216), "X") },
            { "Button_N", g => Ball(g, Color.FromArgb(255, 238, 186, 24), "Y") },
            { "Shoulder_L", g => Bar(g, xbDark, "LB") },
            { "Shoulder_R", g => Bar(g, xbDark, "RB") },
            { "Trigger_L", g => Shoulder(g, xbDark, "LT", true) },
            { "Trigger_R", g => Shoulder(g, xbDark, "RT", false) },
            { "Start", g => Pill(g, xbDark, "START") },
            { "Back", g => Pill(g, xbDark, "BACK") },
            { "Guide", g => Pill(g, xbDark, "XBOX") },
            { "Left_Stick", g => Stick(g, xbDark, "LS") },
            { "Right_Stick", g => Stick(g, xbDark, "RS") },
            { "Thumb_L", g => Stick(g, xbDark, "LS") },
            { "Thumb_R", g => Stick(g, xbDark, "RS") },
            { "Pad", g => Dpad(g) },
        };

        // Nintendo's letters sit where Xbox's opposite ones do: A on the right, B at the bottom.
        Color swDark = Color.FromArgb(255, 58, 60, 66);
        styles["switch"] = new Dictionary<string, Painter>
        {
            { "Button_S", g => Ball(g, swDark, "B") },
            { "Button_E", g => Ball(g, swDark, "A") },
            { "Button_W", g => Ball(g, swDark, "Y") },
            { "Button_N", g => Ball(g, swDark, "X") },
            { "Shoulder_L", g => Bar(g, swDark, "L") },
            { "Shoulder_R", g => Bar(g, swDark, "R") },
            { "Trigger_L", g => Shoulder(g, swDark, "ZL", true) },
            { "Trigger_R", g => Shoulder(g, swDark, "ZR", false) },
            { "Start", g => Ball(g, swDark, "+") },
            { "Back", g => Ball(g, swDark, "-") },
            { "Guide", g => Pill(g, swDark, "HOME") },
            { "Left_Stick", g => Stick(g, swDark, "L") },
            { "Right_Stick", g => Stick(g, swDark, "R") },
            { "Thumb_L", g => Stick(g, swDark, "L") },
            { "Thumb_R", g => Stick(g, swDark, "R") },
            { "Pad", g => Dpad(g) },
        };
        return styles;
    }

    // DirectInput key names (as Dolphin's keyboard device reports them) and what their cap reads.
    static Dictionary<string, string> KeyLabels()
    {
        var keys = new Dictionary<string, string>();
        for (char c = 'A'; c <= 'Z'; c++) keys[c.ToString()] = c.ToString();
        for (char c = '0'; c <= '9'; c++) keys[c.ToString()] = c.ToString();
        for (int f = 1; f <= 15; f++) keys["F" + f] = "F" + f;
        for (int n = 0; n <= 9; n++) keys["NUMPAD" + n] = "NUM" + n;
        string[,] named =
        {
            { "UP", "↑" }, { "DOWN", "↓" }, { "LEFT", "←" }, { "RIGHT", "→" },
            { "RETURN", "ENTER" }, { "NUMPADENTER", "ENTER" }, { "SPACE", "SPACE" }, { "TAB", "TAB" },
            { "ESCAPE", "ESC" }, { "BACK", "BKSP" }, { "LSHIFT", "SHIFT" }, { "RSHIFT", "SHIFT" },
            { "LCONTROL", "CTRL" }, { "RCONTROL", "CTRL" }, { "LMENU", "ALT" }, { "RMENU", "ALT" },
            { "LWIN", "WIN" }, { "RWIN", "WIN" }, { "CAPITAL", "CAPS" }, { "INSERT", "INS" },
            { "DELETE", "DEL" }, { "HOME", "HOME" }, { "END", "END" }, { "PRIOR", "PGUP" },
            { "NEXT", "PGDN" }, { "MINUS", "-" }, { "EQUALS", "=" }, { "LBRACKET", "[" },
            { "RBRACKET", "]" }, { "SEMICOLON", ";" }, { "APOSTROPHE", "'" }, { "GRAVE", "`" },
            { "BACKSLASH", "\\" }, { "COMMA", "," }, { "PERIOD", "." }, { "SLASH", "/" },
            { "ADD", "+" }, { "SUBTRACT", "-" }, { "MULTIPLY", "*" }, { "DIVIDE", "/" },
            { "DECIMAL", "." }, { "NUMLOCK", "NUM" }, { "SCROLL", "SCRL" }, { "PAUSE", "PAUSE" },
            { "APPS", "MENU" }, { "OEM_102", "\\" },
        };
        for (int i = 0; i < named.GetLength(0); i++) keys[named[i, 0]] = named[i, 1];
        return keys;
    }

    // ---- shapes -------------------------------------------------------------------------------

    static GraphicsPath Circle(float inset)
    {
        var p = new GraphicsPath();
        p.AddEllipse(inset, inset, Size - 2 * inset, Size - 2 * inset);
        return p;
    }

    static GraphicsPath RoundRect(RectangleF r, float radius)
    {
        var p = new GraphicsPath();
        float d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    static Color Shade(Color c, float f)
    {
        Func<int, int> s = v => Math.Max(0, Math.Min(255, (int)(f >= 1 ? v + (255 - v) * (f - 1) : v * f)));
        return Color.FromArgb(c.A, s(c.R), s(c.G), s(c.B));
    }

    // The common treatment: dark outline, body lit from the top, a darker rim, a soft highlight.
    static void Glossy(Graphics g, GraphicsPath body, Color fill)
    {
        using (var pen = new Pen(Outline, 12) { LineJoin = LineJoin.Round })
            g.DrawPath(pen, body);
        RectangleF b = body.GetBounds();
        using (var brush = new LinearGradientBrush(b, Shade(fill, 1.35f), Shade(fill, 0.72f), LinearGradientMode.Vertical))
            g.FillPath(brush, body);
        using (var rim = new Pen(Shade(fill, 0.55f), 5) { LineJoin = LineJoin.Round })
            g.DrawPath(rim, body);
        var shine = new RectangleF(b.X + b.Width * 0.18f, b.Y + b.Height * 0.07f, b.Width * 0.64f, b.Height * 0.36f);
        using (var path = new GraphicsPath())
        {
            path.AddEllipse(shine);
            using (var brush = new LinearGradientBrush(shine, Color.FromArgb(120, 255, 255, 255), Color.FromArgb(0, 255, 255, 255), LinearGradientMode.Vertical))
                g.FillPath(brush, path);
        }
    }

    static void Label(Graphics g, string text, RectangleF area, Color color, float maxEm)
    {
        if (string.IsNullOrEmpty(text)) return;
        float em = maxEm;
        using (var probe = new GraphicsPath())
        {
            while (em > 8)
            {
                probe.Reset();
                probe.AddString(text, new FontFamily(fontFamily), 0, em, PointF.Empty, StringFormat.GenericTypographic);
                RectangleF r = probe.GetBounds();
                if (r.Width <= area.Width * 0.82f && r.Height <= area.Height * 0.62f) break;
                em -= 2;
            }
        }
        using (var path = new GraphicsPath())
        {
            path.AddString(text, new FontFamily(fontFamily), 0, em, PointF.Empty, StringFormat.GenericTypographic);
            RectangleF r = path.GetBounds();
            using (var m = new Matrix())
            {
                m.Translate(area.X + (area.Width - r.Width) / 2 - r.X, area.Y + (area.Height - r.Height) / 2 - r.Y);
                path.Transform(m);
            }
            using (var pen = new Pen(Color.FromArgb(220, 10, 10, 14), em * 0.16f) { LineJoin = LineJoin.Round })
                g.DrawPath(pen, path);
            using (var brush = new SolidBrush(color))
                g.FillPath(brush, path);
        }
    }

    static void Ball(Graphics g, Color fill, string label, Action<Graphics> symbol = null)
    {
        using (var body = Circle(8)) Glossy(g, body, fill);
        if (symbol != null) symbol(g);
        Label(g, label, new RectangleF(8, 10, Size - 16, Size - 16), Color.White, 84);
    }

    // The GameCube's X and Y: a kidney-shaped button, turned `degrees` clockwise from lying flat
    // (X stands almost upright, Y lies almost flat).
    static void Bean(Graphics g, Color fill, string label, float degrees)
    {
        using (var body = RoundRect(new RectangleF(10, 34, Size - 20, Size - 68), 30))
        using (var m = new Matrix())
        {
            m.RotateAt(degrees, new PointF(Size / 2f, Size / 2f));
            body.Transform(m);
            Glossy(g, body, fill);
        }
        Label(g, label, new RectangleF(16, 18, Size - 32, Size - 36), Color.White, 70);
    }

    static void Bar(Graphics g, Color fill, string label)
    {
        using (var body = RoundRect(new RectangleF(8, 30, Size - 16, Size - 60), 18)) Glossy(g, body, fill);
        Label(g, label, new RectangleF(8, 30, Size - 16, Size - 60), Color.White, 62);
    }

    // A shoulder or trigger: flat bottom, rounded top, rising toward the outside of the pad.
    static void Shoulder(Graphics g, Color fill, string label, bool left)
    {
        using (var body = new GraphicsPath())
        {
            body.AddBezier(10, 100, 10, 40, 40, 22, 80, 22);
            body.AddBezier(80, 22, 110, 22, 118, 50, 118, 100);
            body.CloseFigure();
            if (!left)
                using (var m = new Matrix(-1, 0, 0, 1, Size, 0)) body.Transform(m);
            Glossy(g, body, fill);
        }
        Label(g, label, new RectangleF(16, 38, Size - 32, 58), Color.White, 60);
    }

    static void Pill(Graphics g, Color fill, string label)
    {
        using (var body = RoundRect(new RectangleF(6, 38, Size - 12, Size - 76), 26)) Glossy(g, body, fill);
        Label(g, label, new RectangleF(10, 38, Size - 20, Size - 76), Color.White, 40);
    }

    static void Stick(Graphics g, Color fill, string label)
    {
        using (var body = Circle(8)) Glossy(g, body, fill);
        using (var ring = new Pen(Color.FromArgb(110, 0, 0, 0), 5))
            g.DrawEllipse(ring, 34, 34, Size - 68, Size - 68);
        Label(g, label, new RectangleF(30, 32, Size - 60, Size - 60), Color.White, 56);
    }

    static void Dpad(Graphics g)
    {
        using (var body = new GraphicsPath())
        {
            body.AddPolygon(new[] {
                new PointF(44, 8), new PointF(84, 8), new PointF(84, 44), new PointF(120, 44), new PointF(120, 84),
                new PointF(84, 84), new PointF(84, 120), new PointF(44, 120), new PointF(44, 84), new PointF(8, 84),
                new PointF(8, 44), new PointF(44, 44) });
            Glossy(g, body, Color.FromArgb(255, 70, 72, 80));
        }
    }

    // PlayStation symbols, drawn in their colour over the dark ball.
    static void SymbolStroke(Graphics g, Color color, Action<Pen> draw)
    {
        using (var shadow = new Pen(Color.FromArgb(200, 0, 0, 0), 20) { LineJoin = LineJoin.Round, StartCap = LineCap.Round, EndCap = LineCap.Round })
            draw(shadow);
        using (var pen = new Pen(color, 11) { LineJoin = LineJoin.Round, StartCap = LineCap.Round, EndCap = LineCap.Round })
            draw(pen);
    }

    // (Block bodies throughout: Windows PowerShell's Add-Type compiles C# 5.)
    static void Cross(Graphics g, Color c) { SymbolStroke(g, c, p => { g.DrawLine(p, 40, 40, 88, 88); g.DrawLine(p, 88, 40, 40, 88); }); }
    static void Ring(Graphics g, Color c) { SymbolStroke(g, c, p => g.DrawEllipse(p, 37, 37, 54, 54)); }
    static void Square(Graphics g, Color c) { SymbolStroke(g, c, p => g.DrawRectangle(p, 40, 40, 48, 48)); }
    static void Triangle(Graphics g, Color c) { SymbolStroke(g, c, p => g.DrawPolygon(p, new[] { new PointF(64, 34), new PointF(94, 86), new PointF(34, 86) })); }

    // A keyboard key: a light cap with a darker front edge.
    static void Keycap(Graphics g, string label)
    {
        Keycap(g, new RectangleF(10, 10, Size - 20, Size - 18), label, 1f);
    }

    // W on top, A S D below (or the arrows), each key a third of the glyph.
    static void KeyCluster(Graphics g, string[] labels)
    {
        const float key = 44, gap = 0;
        float left = (Size - 3 * key - 2 * gap) / 2, top = (Size - 2 * key - gap) / 2;
        Keycap(g, new RectangleF(left + key + gap, top, key, key), labels[0], key / Size);
        for (int i = 0; i < 3; i++)
            Keycap(g, new RectangleF(left + i * (key + gap), top + key + gap, key, key), labels[i + 1], key / Size);
    }

    // `cap` is the whole key, front edge included; `scale` shrinks outline, corners and lettering.
    static void Keycap(Graphics g, RectangleF cap, string label, float scale)
    {
        float lip = 8 * scale, radius = Math.Max(4, 18 * scale), outline = Math.Max(4, 12 * scale);
        var face = new RectangleF(cap.X, cap.Y, cap.Width, cap.Height - lip);
        using (var edge = RoundRect(new RectangleF(cap.X, cap.Y + lip, cap.Width, cap.Height - lip), radius))
        {
            using (var pen = new Pen(Outline, outline) { LineJoin = LineJoin.Round }) g.DrawPath(pen, edge);
            using (var brush = new SolidBrush(Color.FromArgb(255, 132, 136, 146))) g.FillPath(brush, edge);
        }
        using (var top = RoundRect(face, radius))
        {
            using (var pen = new Pen(Outline, outline) { LineJoin = LineJoin.Round }) g.DrawPath(pen, top);
            using (var brush = new LinearGradientBrush(face, Color.FromArgb(255, 250, 250, 252), Color.FromArgb(255, 206, 208, 214), LinearGradientMode.Vertical))
                g.FillPath(brush, top);
        }
        float em = (label.Length <= 1 ? 76 : label.Length <= 3 ? 50 : 36) * Math.Max(scale, 0.42f);
        using (var path = new GraphicsPath())
        {
            // The font has no arrows (Windows falls back to a thin one): draw them as a shape.
            int turn = "→↓←↑".IndexOf(label);
            if (turn >= 0)
            {
                path.AddPolygon(new[] {
                    new PointF(-28, -10), new PointF(4, -10), new PointF(4, -28), new PointF(34, 0),
                    new PointF(4, 28), new PointF(4, 10), new PointF(-28, 10) });
                using (var m = new Matrix()) { m.Rotate(turn * 90); m.Scale(em / 76, em / 76, MatrixOrder.Append); path.Transform(m); }
            }
            else
                path.AddString(label, new FontFamily(fontFamily), 0, em, PointF.Empty, StringFormat.GenericTypographic);
            RectangleF r = path.GetBounds();
            float fit = Math.Min(1f, (face.Width - 16 * scale) / Math.Max(1f, r.Width));
            using (var m = new Matrix())
            {
                m.Translate(face.X + face.Width / 2, face.Y + face.Height / 2);
                m.Scale(fit, fit);
                m.Translate(-(r.X + r.Width / 2), -(r.Y + r.Height / 2));
                path.Transform(m);
            }
            using (var brush = new SolidBrush(Color.FromArgb(255, 30, 32, 38))) g.FillPath(brush, path);
        }
    }
}
