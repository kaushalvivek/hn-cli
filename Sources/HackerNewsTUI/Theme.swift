public enum Theme {
    public static let accentColor = Color.rgb(255, 102, 0)
    public static let linkColor = Color.rgb(88, 166, 255)
    public static let successColor = Color.rgb(63, 185, 80)
    public static let errorColor = Color.rgb(248, 81, 73)
    public static let warningColor = Color.rgb(210, 153, 34)

    public static let accent = Style(fg: accentColor, bold: true)
    public static let accentPlain = Style(fg: accentColor)
    public static let link = Style(fg: linkColor)
    public static let success = Style(fg: successColor)
    public static let error = Style(fg: errorColor)
    public static let warning = Style(fg: warningColor)

    /// Dim is used instead of a fixed gray so the theme adapts to light and
    /// dark terminal backgrounds.
    public static let muted = Style(dim: true)
    public static let faint = Style(dim: true)
    public static let border = Style(dim: true)
    public static let selected = Style(reverse: true)
    public static let selectedAccent = Style(fg: accentColor, reverse: true)
    public static let header = Style(bold: true)
    public static let headerMuted = Style(dim: true)
    public static let badge = Style(fg: accentColor, bold: true)
    public static let code = Style(italic: true)
}
