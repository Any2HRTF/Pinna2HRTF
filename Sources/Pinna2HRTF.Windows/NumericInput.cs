using System.Globalization;
namespace Pinna2HRTF.Windows;

internal static class NumericInput
{
    public static string Canonical(string draft, bool integer, CultureInfo? culture = null)
    {
        culture ??= CultureInfo.CurrentCulture;
        draft = draft.Trim();
        const NumberStyles styles = NumberStyles.Float;
        var localized = double.TryParse(draft, styles, culture, out var local);
        var invariant = double.TryParse(draft, styles, CultureInfo.InvariantCulture, out var canonical);
        if (!localized && !invariant) throw new InvalidDataException("Enter a number without thousands separators.");
        var value = localized ? local : canonical;
        if (!double.IsFinite(value)) throw new InvalidDataException("Enter a finite number.");
        if (localized && invariant && local != canonical) throw new InvalidDataException("Use the local decimal separator; thousands separators are not supported.");
        var group = culture.NumberFormat.NumberGroupSeparator;
        var decimalMark = culture.NumberFormat.NumberDecimalSeparator;
        var groupedSpelling = group.Length > 0 && System.Text.RegularExpressions.Regex.IsMatch(draft,
            @"^[+-]?\d{1,3}(?:" + System.Text.RegularExpressions.Regex.Escape(group) + @"\d{3})+(?:" +
            System.Text.RegularExpressions.Regex.Escape(decimalMark) + @"\d+)?(?:[eE][+-]?\d+)?$");
        if (culture.Name.Equals("de-AT", StringComparison.OrdinalIgnoreCase) &&
            System.Text.RegularExpressions.Regex.IsMatch(draft, @"^[+-]?\d{1,3}(?:\.\d{3})+(?:,\d+)?$"))
            throw new InvalidDataException("This number is ambiguous. Enter 24000 without grouping, or 24,0 for twenty-four.");
        if (groupedSpelling && double.TryParse(draft, styles | NumberStyles.AllowThousands, culture, out var grouped) && grouped != value)
            throw new InvalidDataException("This number is ambiguous. Enter 24000 without grouping, or use the local decimal separator (for example 24,0).");
        if (!double.IsFinite(value)) throw new InvalidDataException("Enter a finite number.");
        if (integer && (value != Math.Truncate(value) || value < int.MinValue || value > int.MaxValue))
            throw new InvalidDataException("Enter a whole number within the supported range.");
        return integer ? ((int)value).ToString(CultureInfo.InvariantCulture) : value.ToString("R", CultureInfo.InvariantCulture);
    }
}
