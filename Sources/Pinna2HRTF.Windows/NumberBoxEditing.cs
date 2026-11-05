using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Pinna2HRTF.Windows;

// NumberBox's built-in X clears its text. In the fitter it instead cancels the
// current numeric draft. Keep drafts separate from model values until accepted.
internal static class NumberBoxEditing
{
    public static void Attach(NumberBox number, UIElement root, Control focusTarget,
        Func<double> read, Action<double> commit, Func<string, double?> parse, Func<double, string> format)
    {
        bool editing = false, updating = false, attached = false;
        double initial = read();
        double? validatedDraft = null;
        TextBox? inputBox = null;
        var clearButtons = new HashSet<Button>();

        bool Inside(DependencyObject? child)
        {
            while (child != null) {
                if (child.Equals(number)) return true;
                child = VisualTreeHelper.GetParent(child);
            }
            return false;
        }
        void Finish(bool cancel)
        {
            if (!editing) return;
            updating = true;
            try {
                if (cancel) commit(initial);
                else {
                    var text = inputBox?.Text ?? number.Text;
                    var draft = validatedDraft is double validated && double.IsFinite(validated) && text == format(validated)
                        ? validated : parse(text);
                    if (draft is double value && double.IsFinite(value)) commit(Math.Clamp(value, number.Minimum, number.Maximum));
                }
                var current = read();
                number.Value = current; number.Text = format(current);
                if (inputBox != null) inputBox.Text = format(current);
                editing = false;
            } finally { updating = false; }
            if (cancel || number.XamlRoot != null && Inside(FocusManager.GetFocusedElement(number.XamlRoot) as DependencyObject))
                number.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
                    () => focusTarget.Focus(FocusState.Programmatic));
        }
        void FindClear(DependencyObject parent)
        {
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) {
                var child = VisualTreeHelper.GetChild(parent, i);
                if (child is TextBox input) { inputBox = input; input.ApplyTemplate(); }
                if (child is Button { Name: "DeleteButton" } clear && clearButtons.Add(clear)) {
                    clear.Click += (_, args) => {
                        // Run after the TextBox template's own clear handler.
                        number.DispatcherQueue.TryEnqueue(() => Finish(true));
                    };
                }
                FindClear(child);
            }
        }
        PointerEventHandler outside = (_, args) => {
            if (editing && !Inside(args.OriginalSource as DependencyObject)) Finish(false);
        };
        number.Loaded += (_, _) => {
            number.ApplyTemplate(); FindClear(number);
            if (!attached) { root.AddHandler(UIElement.PointerPressedEvent, outside, true); attached = true; }
        };
        number.Unloaded += (_, _) => {
            editing = false;
            if (attached) { root.RemoveHandler(UIElement.PointerPressedEvent, outside); attached = false; }
        };
        number.GotFocus += (_, _) => {
            if (!editing) { initial = read(); validatedDraft = null; editing = true; }
            FindClear(number);
            // TextBox creates its clear-button template lazily on first focus.
            number.DispatcherQueue.TryEnqueue(() => FindClear(number));
        };
        number.LostFocus += (_, _) => {
            if (number.XamlRoot != null && !Inside(FocusManager.GetFocusedElement(number.XamlRoot) as DependencyObject)) Finish(false);
        };
        number.ValueChanged += (_, args) => {
            if (editing && !updating) validatedDraft = args.NewValue;
            if (!editing && !updating && double.IsFinite(args.NewValue)) commit(args.NewValue);
        };
        number.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler((_, args) => {
            if (args.Key is global::Windows.System.VirtualKey.Escape or global::Windows.System.VirtualKey.Enter) {
                args.Handled = true; Finish(args.Key == global::Windows.System.VirtualKey.Escape);
            }
        }), true);
    }
}
