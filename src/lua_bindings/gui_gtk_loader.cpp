#include "gui_gtk_loader.hpp"
#include "process_state.hpp"

#include <cstring>
#include <dlfcn.h>
#include <string>
#include <string_view>

namespace babet_gui::detail
{
namespace
{

constexpr const char *GTK4_SONAME = "libgtk-4.so.1";

using GtkDisableSetlocale = void (*)();
using GtkInitCheck = int (*)();
using GtkWindowNew = void *(*)();
using GtkWindowSetTitle = void (*)(void *, const char *);
using GtkWindowSetDefaultSize = void (*)(void *, int, int);
using GtkWindowSetChild = void (*)(void *, void *);
using GtkWindowPresent = void (*)(void *);
using GtkWindowDestroy = void (*)(void *);
using GtkFixedNew = void *(*)();
using GtkFixedPut = void (*)(void *, void *, double, double);
using GtkFixedRemove = void (*)(void *, void *);
using GtkTextViewNew = void *(*)();
using GtkTextViewGetBuffer = void *(*)(void *);
using GtkTextBufferSetText = void (*)(void *, const char *, int);
using GObjectGet = void (*)(void *, const char *, ...);
using GFree = void (*)(void *);
using GtkCheckButtonNewWithLabel = void *(*)(const char *);
using GtkCheckButtonSetLabel = void (*)(void *, const char *);
using GtkCheckButtonSetActive = void (*)(void *, int);
using GtkCheckButtonGetActive = int (*)(void *);
using GtkProgressBarNew = void *(*)();
using GtkProgressBarSetFraction = void (*)(void *, double);
using GtkProgressBarGetFraction = double (*)(void *);
using GtkProgressBarSetText = void (*)(void *, const char *);
using GtkProgressBarSetShowText = void (*)(void *, int);
using GtkExpanderNew = void *(*)(const char *);
using GtkExpanderSetLabel = void (*)(void *, const char *);
using GtkExpanderSetChild = void (*)(void *, void *);
using GtkExpanderSetExpanded = void (*)(void *, int);
using GtkExpanderGetExpanded = int (*)(void *);
using GtkGestureDragNew = void *(*)();
using GtkGestureSingleGetCurrentSequence = void *(*)(void *);
using GtkGestureGetLastEvent = void *(*)(void *, void *);
using GdkEventGetPosition = int (*)(void *, double *, double *);
using GtkWidgetSetSizeRequest = void (*)(void *, int, int);

using GtkBoxNew = void *(*)(int, int);
using GtkBoxAppend = void (*)(void *, void *);
using GtkBoxRemove = void (*)(void *, void *);
using GtkBoxReorderChildAfter = void (*)(void *, void *, void *);
using GtkScrolledWindowNew = void *(*)();
using GtkScrolledWindowSetChild = void (*)(void *, void *);
using GtkLabelNew = void *(*)(const char *);
using GtkLabelSetText = void (*)(void *, const char *);
using GtkButtonNewWithLabel = void *(*)(const char *);
using GtkButtonSetLabel = void (*)(void *, const char *);
using GtkEntryNew = void *(*)();
using GtkEntrySetPlaceholder = void (*)(void *, const char *);
using GtkEditableSetText = void (*)(void *, const char *);
using GtkEditableGetText = const char *(*)(void *);
using GtkEditableSetEditable = void (*)(void *, int);
using GtkSpinButtonNewWithRange = void *(*)(double, double, double);
using GtkSpinButtonGetValue = double (*)(void *);
using GtkSpinButtonSetValue = void (*)(void *, double);
using GtkSpinButtonSetDigits = void (*)(void *, unsigned int);
using GtkSpinButtonSetNumeric = void (*)(void *, int);
using GtkCalendarNew = void *(*)();
using GtkCalendarGetDate = void *(*)(void *);
using GtkCalendarSelectDay = void (*)(void *, void *);
using GtkCalendarMarkDay = void (*)(void *, unsigned int);
using GtkCalendarUnmarkDay = void (*)(void *, unsigned int);
using GtkCalendarClearMarks = void (*)(void *);
using GDateTimeNewLocal = void *(*)(int, int, int, int, int, double);
using GDateTimeGetInt = int (*)(void *);
using GDateTimeUnref = void (*)(void *);
using GtkGestureClickNew = void *(*)();
using GtkGestureSingleSetButton = void (*)(void *, unsigned int);
using GtkGestureSingleGetCurrentButton = unsigned int (*)(void *);
using GtkWidgetAddController = void (*)(void *, void *);
using GtkWidgetSetMargin = void (*)(void *, int);
using GtkWidgetSetBoolean = void (*)(void *, int);
using GtkCssProviderNew = void *(*)();
using GtkCssProviderLoadFromData = void (*)(void *, const char *, long);
using GtkCssProviderLoadFromString = void (*)(void *, const char *);
using GdkDisplayGetDefault = void *(*)();
using GtkStyleContextAddProviderForDisplay = void (*)(void *, void *, unsigned int);
using GtkStyleContextRemoveProviderForDisplay = void (*)(void *, void *);
using GtkWidgetCssClass = void (*)(void *, const char *);
using GtkWidgetGetParent = void *(*)(void *);
using GObjectRefSink = void *(*)(void *);
using GObjectUnref = void (*)(void *);
using GSignalConnectData = unsigned long (*)(void *, const char *, GtkCallback,
                                             void *, GtkClosureNotify,
                                             unsigned int);
using GMainContextIteration = int (*)(void *, int);
using GTimeoutAdd = unsigned int (*)(unsigned int, GtkSourceCallback, void *);
using GSourceRemove = int (*)(unsigned int);

struct GtkApi
{
    void *handle = nullptr;
    GtkDisableSetlocale disable_setlocale = nullptr;
    GtkInitCheck init_check = nullptr;
    GtkWindowNew window_new = nullptr;
    GtkWindowSetTitle window_set_title = nullptr;
    GtkWindowSetDefaultSize window_set_default_size = nullptr;
    GtkWindowSetChild window_set_child = nullptr;
    GtkWindowPresent window_present = nullptr;
    GtkWindowDestroy window_destroy = nullptr;
    GtkFixedNew fixed_new = nullptr;
    GtkFixedPut fixed_put = nullptr;
    GtkFixedPut fixed_move = nullptr;
    GtkFixedRemove fixed_remove = nullptr;
    GtkTextViewNew text_view_new = nullptr;
    GtkTextViewGetBuffer text_view_get_buffer = nullptr;
    GtkTextBufferSetText text_buffer_set_text = nullptr;
    GObjectGet object_get = nullptr;
    GFree glib_free = nullptr;
    GtkWidgetSetBoolean text_view_set_editable = nullptr;
    GtkCheckButtonNewWithLabel check_button_new_with_label = nullptr;
    GtkCheckButtonSetLabel check_button_set_label = nullptr;
    GtkCheckButtonSetActive check_button_set_active = nullptr;
    GtkCheckButtonGetActive check_button_get_active = nullptr;
    GtkProgressBarNew progress_bar_new = nullptr;
    GtkProgressBarSetFraction progress_bar_set_fraction = nullptr;
    GtkProgressBarGetFraction progress_bar_get_fraction = nullptr;
    GtkProgressBarSetText progress_bar_set_text = nullptr;
    GtkProgressBarSetShowText progress_bar_set_show_text = nullptr;
    GtkExpanderNew expander_new = nullptr;
    GtkExpanderSetLabel expander_set_label = nullptr;
    GtkExpanderSetChild expander_set_child = nullptr;
    GtkExpanderSetExpanded expander_set_expanded = nullptr;
    GtkExpanderGetExpanded expander_get_expanded = nullptr;
    GtkGestureDragNew gesture_drag_new = nullptr;
    GtkGestureSingleGetCurrentSequence gesture_single_get_current_sequence = nullptr;
    GtkGestureGetLastEvent gesture_get_last_event = nullptr;
    GdkEventGetPosition gdk_event_get_position = nullptr;
    GtkWidgetSetSizeRequest widget_set_size_request = nullptr;
    GtkBoxNew box_new = nullptr;
    GtkBoxAppend box_append = nullptr;
    GtkBoxRemove box_remove = nullptr;
    GtkBoxReorderChildAfter box_reorder_child_after = nullptr;
    GtkScrolledWindowNew scrolled_window_new = nullptr;
    GtkScrolledWindowSetChild scrolled_window_set_child = nullptr;
    GtkLabelNew label_new = nullptr;
    GtkLabelSetText label_set_text = nullptr;
    GtkButtonNewWithLabel button_new_with_label = nullptr;
    GtkButtonSetLabel button_set_label = nullptr;
    GtkEntryNew entry_new = nullptr;
    GtkEntrySetPlaceholder entry_set_placeholder = nullptr;
    GtkEditableSetText editable_set_text = nullptr;
    GtkEditableGetText editable_get_text = nullptr;
    GtkEditableSetEditable editable_set_editable = nullptr;
    GtkSpinButtonNewWithRange spin_button_new_with_range = nullptr;
    GtkSpinButtonGetValue spin_button_get_value = nullptr;
    GtkSpinButtonSetValue spin_button_set_value = nullptr;
    GtkSpinButtonSetDigits spin_button_set_digits = nullptr;
    GtkSpinButtonSetNumeric spin_button_set_numeric = nullptr;
    GtkCalendarNew calendar_new = nullptr;
    GtkCalendarGetDate calendar_get_date = nullptr;
    GtkCalendarSelectDay calendar_select_day = nullptr;
    GtkCalendarMarkDay calendar_mark_day = nullptr;
    GtkCalendarUnmarkDay calendar_unmark_day = nullptr;
    GtkCalendarClearMarks calendar_clear_marks = nullptr;
    GDateTimeNewLocal date_time_new_local = nullptr;
    GDateTimeGetInt date_time_get_year = nullptr;
    GDateTimeGetInt date_time_get_month = nullptr;
    GDateTimeGetInt date_time_get_day_of_month = nullptr;
    GDateTimeUnref date_time_unref = nullptr;
    void * (*gtk_drawing_area_new)() = nullptr;
    void (*gtk_drawing_area_set_content_width)(void *w, int width) = nullptr;
    void (*gtk_drawing_area_set_content_height)(void *w, int height) = nullptr;
    void (*gtk_drawing_area_set_draw_func)(void *w, GtkDrawCallback cb, void *data, GtkDestroyNotify notify) = nullptr;
    GtkGestureClickNew gesture_click_new = nullptr;
    GtkGestureSingleSetButton gesture_single_set_button = nullptr;
    GtkGestureSingleGetCurrentButton gesture_single_get_current_button = nullptr;
    GtkWidgetAddController widget_add_controller = nullptr;
    void (*gtk_widget_queue_draw)(void *w) = nullptr;
    GtkWidgetSetMargin widget_set_margin_top = nullptr;
    GtkWidgetSetMargin widget_set_margin_bottom = nullptr;
    GtkWidgetSetMargin widget_set_margin_start = nullptr;
    GtkWidgetSetMargin widget_set_margin_end = nullptr;
    GtkWidgetSetBoolean widget_set_hexpand = nullptr;
    GtkWidgetSetBoolean widget_set_vexpand = nullptr;
    GtkWidgetSetBoolean widget_set_visible = nullptr;
    GtkWidgetSetBoolean widget_set_sensitive = nullptr;
    GtkCssProviderNew css_provider_new = nullptr;
    GtkCssProviderLoadFromString css_provider_load_from_string = nullptr;
    GtkCssProviderLoadFromData css_provider_load_from_data = nullptr;
    GdkDisplayGetDefault display_get_default = nullptr;
    GtkStyleContextAddProviderForDisplay style_context_add_provider_for_display = nullptr;
    GtkStyleContextRemoveProviderForDisplay style_context_remove_provider_for_display = nullptr;
    GtkWidgetCssClass widget_add_css_class = nullptr;
    GtkWidgetCssClass widget_remove_css_class = nullptr;
    int (*cairo_status)(void *cr) = nullptr;
    const char * (*cairo_status_to_string)(int status) = nullptr;
    void (*cairo_save)(void *cr) = nullptr;
    void (*cairo_restore)(void *cr) = nullptr;
    void (*cairo_new_path)(void *cr) = nullptr;
    void (*cairo_close_path)(void *cr) = nullptr;
    void (*cairo_stroke)(void *cr) = nullptr;
    void (*cairo_fill)(void *cr) = nullptr;
    void (*cairo_move_to)(void *cr, double x, double y) = nullptr;
    void (*cairo_line_to)(void *cr, double x, double y) = nullptr;
    void (*cairo_rectangle)(void *cr, double x, double y, double width, double height) = nullptr;
    void (*cairo_arc)(void *cr, double x, double y, double radius, double start, double end) = nullptr;
    void (*cairo_set_line_width)(void *cr, double width) = nullptr;
    void (*cairo_set_source_rgb)(void *cr, double r, double g, double b) = nullptr;
    void (*cairo_set_source_rgba)(void *cr, double r, double g, double b, double a) = nullptr;
    void (*cairo_set_font_size)(void *cr, double size) = nullptr;
    void (*cairo_show_text)(void *cr, const char *text) = nullptr;
    GtkWidgetGetParent widget_get_parent = nullptr;
    GObjectRefSink object_ref_sink = nullptr;
    GObjectUnref object_unref = nullptr;
    GSignalConnectData signal_connect_data = nullptr;
    GMainContextIteration main_context_iteration = nullptr;
    GTimeoutAdd timeout_add = nullptr;
    GSourceRemove source_remove = nullptr;
};

GtkApi g_gtk;

enum class GtkLoadState
{
    not_attempted,
    loaded,
    failed,
};

GtkLoadState g_load_state = GtkLoadState::not_attempted;
void *g_resident_handle = nullptr;
std::string g_load_error;

std::string install_diagnostic(std::string_view detail)
{
    std::string message =
        "babet.gui: GTK 4 is required by this application but was not found or "
        "is unusable. Install the GTK 4 runtime, for example:\n"
        "  Debian/Ubuntu : sudo apt install libgtk-4-1\n"
        "  Arch Linux    : sudo pacman -S gtk4\n"
        "  Fedora        : sudo dnf install gtk4";
    if (!detail.empty())
    {
        message += "\nLoader detail: ";
        message.append(detail.data(), detail.size());
    }
    return message;
}

template <typename Function>
bool resolve(void *handle, const char *name, Function &function,
             std::string &error)
{
    static_assert(sizeof(Function) == sizeof(void *),
                  "GTK loader requires POSIX-sized function pointers");
    (void)::dlerror();
    void *symbol = ::dlsym(handle, name);
    const char *detail = ::dlerror();
    if (detail != nullptr || symbol == nullptr)
    {
        error = "missing GTK 4 dependency symbol '";
        error += name;
        error += "'";
        if (detail && *detail)
        {
            error += ": ";
            error += detail;
        }
        return false;
    }
    std::memcpy(&function, &symbol, sizeof(symbol));
    return true;
}

template <typename Function>
void resolve_optional(void *handle, const char *name, Function &function) noexcept
{
    static_assert(sizeof(Function) == sizeof(void *),
                  "GTK loader requires POSIX-sized function pointers");
    (void)::dlerror();
    void *symbol = ::dlsym(handle, name);
    const char *detail = ::dlerror();
    if (detail != nullptr || symbol == nullptr)
    {
        function = nullptr;
        return;
    }
    std::memcpy(&function, &symbol, sizeof(symbol));
}

#define BABET_GTK_RESOLVE(member, symbol)                                      \
    if (!resolve(handle, symbol, candidate.member, symbol_error))              \
        goto symbol_failure

} // namespace

bool gtk4_load(std::string &error)
{
    error.clear();
    if (g_load_state == GtkLoadState::loaded)
        return true;
    if (g_load_state == GtkLoadState::failed)
    {
        error = g_load_error;
        return false;
    }

    // dlopen can run constructors, and GTK initialization can start native
    // threads independently of workers.spawn. Freeze before either runs,
    // without holding the guard across dlopen or GTK callbacks. Keep the
    // freeze on every failure: partial native initialization is not rolled back.
    babet_runtime::freeze_process_state();
    (void)::dlerror();
    void *handle = ::dlopen(GTK4_SONAME, RTLD_NOW | RTLD_LOCAL);
    if (!handle)
    {
        const char *detail = ::dlerror();
        g_load_error = install_diagnostic(detail ? detail : "dlopen failed");
        g_load_state = GtkLoadState::failed;
        error = g_load_error;
        return false;
    }

    // A successfully opened GTK DSO is deliberately kept resident for the
    // lifetime of the process, even if symbol validation subsequently fails.
    // GTK/GLib may install process-wide state while the DSO is being loaded;
    // unloading a partially validated runtime is therefore not a supported
    // recovery strategy. Remembering the failed state also prevents repeated
    // dlopen() calls from incrementing the loader reference count.
    g_resident_handle = handle;

    GtkApi candidate;
    candidate.handle = handle;
    std::string symbol_error;

    BABET_GTK_RESOLVE(disable_setlocale, "gtk_disable_setlocale");
    BABET_GTK_RESOLVE(init_check, "gtk_init_check");
    BABET_GTK_RESOLVE(window_new, "gtk_window_new");
    BABET_GTK_RESOLVE(window_set_title, "gtk_window_set_title");
    BABET_GTK_RESOLVE(window_set_default_size, "gtk_window_set_default_size");
    BABET_GTK_RESOLVE(window_set_child, "gtk_window_set_child");
    BABET_GTK_RESOLVE(window_present, "gtk_window_present");
    BABET_GTK_RESOLVE(window_destroy, "gtk_window_destroy");
    BABET_GTK_RESOLVE(fixed_new, "gtk_fixed_new");
    BABET_GTK_RESOLVE(fixed_put, "gtk_fixed_put");
    BABET_GTK_RESOLVE(fixed_move, "gtk_fixed_move");
    BABET_GTK_RESOLVE(fixed_remove, "gtk_fixed_remove");
    BABET_GTK_RESOLVE(text_view_new, "gtk_text_view_new");
    BABET_GTK_RESOLVE(text_view_get_buffer, "gtk_text_view_get_buffer");
    BABET_GTK_RESOLVE(text_buffer_set_text, "gtk_text_buffer_set_text");
    BABET_GTK_RESOLVE(object_get, "g_object_get");
    BABET_GTK_RESOLVE(glib_free, "g_free");
    BABET_GTK_RESOLVE(text_view_set_editable, "gtk_text_view_set_editable");
    BABET_GTK_RESOLVE(check_button_new_with_label, "gtk_check_button_new_with_label");
    BABET_GTK_RESOLVE(check_button_set_label, "gtk_check_button_set_label");
    BABET_GTK_RESOLVE(check_button_set_active, "gtk_check_button_set_active");
    BABET_GTK_RESOLVE(check_button_get_active, "gtk_check_button_get_active");
    BABET_GTK_RESOLVE(progress_bar_new, "gtk_progress_bar_new");
    BABET_GTK_RESOLVE(progress_bar_set_fraction, "gtk_progress_bar_set_fraction");
    BABET_GTK_RESOLVE(progress_bar_get_fraction, "gtk_progress_bar_get_fraction");
    BABET_GTK_RESOLVE(progress_bar_set_text, "gtk_progress_bar_set_text");
    BABET_GTK_RESOLVE(progress_bar_set_show_text, "gtk_progress_bar_set_show_text");
    BABET_GTK_RESOLVE(expander_new, "gtk_expander_new");
    BABET_GTK_RESOLVE(expander_set_label, "gtk_expander_set_label");
    BABET_GTK_RESOLVE(expander_set_child, "gtk_expander_set_child");
    BABET_GTK_RESOLVE(expander_set_expanded, "gtk_expander_set_expanded");
    BABET_GTK_RESOLVE(expander_get_expanded, "gtk_expander_get_expanded");
    BABET_GTK_RESOLVE(gesture_drag_new, "gtk_gesture_drag_new");
    BABET_GTK_RESOLVE(gesture_single_get_current_sequence, "gtk_gesture_single_get_current_sequence");
    BABET_GTK_RESOLVE(gesture_get_last_event, "gtk_gesture_get_last_event");
    BABET_GTK_RESOLVE(gdk_event_get_position, "gdk_event_get_position");
    BABET_GTK_RESOLVE(widget_set_size_request, "gtk_widget_set_size_request");
    BABET_GTK_RESOLVE(box_new, "gtk_box_new");
    BABET_GTK_RESOLVE(box_append, "gtk_box_append");
    BABET_GTK_RESOLVE(box_remove, "gtk_box_remove");
    BABET_GTK_RESOLVE(box_reorder_child_after, "gtk_box_reorder_child_after");
    BABET_GTK_RESOLVE(scrolled_window_new, "gtk_scrolled_window_new");
    BABET_GTK_RESOLVE(scrolled_window_set_child, "gtk_scrolled_window_set_child");
    BABET_GTK_RESOLVE(label_new, "gtk_label_new");
    BABET_GTK_RESOLVE(label_set_text, "gtk_label_set_text");
    BABET_GTK_RESOLVE(button_new_with_label, "gtk_button_new_with_label");
    BABET_GTK_RESOLVE(button_set_label, "gtk_button_set_label");
    BABET_GTK_RESOLVE(entry_new, "gtk_entry_new");
    BABET_GTK_RESOLVE(entry_set_placeholder, "gtk_entry_set_placeholder_text");
    BABET_GTK_RESOLVE(editable_set_text, "gtk_editable_set_text");
    BABET_GTK_RESOLVE(editable_get_text, "gtk_editable_get_text");
    BABET_GTK_RESOLVE(editable_set_editable, "gtk_editable_set_editable");
    BABET_GTK_RESOLVE(spin_button_new_with_range, "gtk_spin_button_new_with_range");
    BABET_GTK_RESOLVE(spin_button_get_value, "gtk_spin_button_get_value");
    BABET_GTK_RESOLVE(spin_button_set_value, "gtk_spin_button_set_value");
    BABET_GTK_RESOLVE(spin_button_set_digits, "gtk_spin_button_set_digits");
    BABET_GTK_RESOLVE(spin_button_set_numeric, "gtk_spin_button_set_numeric");
    BABET_GTK_RESOLVE(calendar_new, "gtk_calendar_new");
    BABET_GTK_RESOLVE(calendar_get_date, "gtk_calendar_get_date");
    BABET_GTK_RESOLVE(calendar_select_day, "gtk_calendar_select_day");
    BABET_GTK_RESOLVE(calendar_mark_day, "gtk_calendar_mark_day");
    BABET_GTK_RESOLVE(calendar_unmark_day, "gtk_calendar_unmark_day");
    BABET_GTK_RESOLVE(calendar_clear_marks, "gtk_calendar_clear_marks");
    BABET_GTK_RESOLVE(date_time_new_local, "g_date_time_new_local");
    BABET_GTK_RESOLVE(date_time_get_year, "g_date_time_get_year");
    BABET_GTK_RESOLVE(date_time_get_month, "g_date_time_get_month");
    BABET_GTK_RESOLVE(date_time_get_day_of_month, "g_date_time_get_day_of_month");
    BABET_GTK_RESOLVE(date_time_unref, "g_date_time_unref");
    BABET_GTK_RESOLVE(gtk_drawing_area_new, "gtk_drawing_area_new");
    BABET_GTK_RESOLVE(gtk_drawing_area_set_content_width, "gtk_drawing_area_set_content_width");
    BABET_GTK_RESOLVE(gtk_drawing_area_set_content_height, "gtk_drawing_area_set_content_height");
    BABET_GTK_RESOLVE(gtk_drawing_area_set_draw_func, "gtk_drawing_area_set_draw_func");
    BABET_GTK_RESOLVE(gesture_click_new, "gtk_gesture_click_new");
    BABET_GTK_RESOLVE(gesture_single_set_button, "gtk_gesture_single_set_button");
    BABET_GTK_RESOLVE(gesture_single_get_current_button, "gtk_gesture_single_get_current_button");
    BABET_GTK_RESOLVE(widget_add_controller, "gtk_widget_add_controller");
    BABET_GTK_RESOLVE(gtk_widget_queue_draw, "gtk_widget_queue_draw");
    BABET_GTK_RESOLVE(widget_set_margin_top, "gtk_widget_set_margin_top");
    BABET_GTK_RESOLVE(widget_set_margin_bottom, "gtk_widget_set_margin_bottom");
    BABET_GTK_RESOLVE(widget_set_margin_start, "gtk_widget_set_margin_start");
    BABET_GTK_RESOLVE(widget_set_margin_end, "gtk_widget_set_margin_end");
    BABET_GTK_RESOLVE(widget_set_hexpand, "gtk_widget_set_hexpand");
    BABET_GTK_RESOLVE(widget_set_vexpand, "gtk_widget_set_vexpand");
    BABET_GTK_RESOLVE(widget_set_visible, "gtk_widget_set_visible");
    BABET_GTK_RESOLVE(widget_set_sensitive, "gtk_widget_set_sensitive");
    BABET_GTK_RESOLVE(css_provider_new, "gtk_css_provider_new");
    // GTK 4.12 introduced load_from_string() and deprecated load_from_data().
    // Keep both optional and require at least one so Babet remains compatible
    // with GTK 4.0-4.10 while preferring the modern API on newer runtimes.
    resolve_optional(handle, "gtk_css_provider_load_from_string",
                     candidate.css_provider_load_from_string);
    resolve_optional(handle, "gtk_css_provider_load_from_data",
                     candidate.css_provider_load_from_data);
    if (!candidate.css_provider_load_from_string &&
        !candidate.css_provider_load_from_data)
    {
        symbol_error =
            "missing GTK 4 CSS loader symbols "
            "'gtk_css_provider_load_from_string' and "
            "'gtk_css_provider_load_from_data'";
        goto symbol_failure;
    }
    BABET_GTK_RESOLVE(display_get_default, "gdk_display_get_default");
    BABET_GTK_RESOLVE(style_context_add_provider_for_display, "gtk_style_context_add_provider_for_display");
    BABET_GTK_RESOLVE(style_context_remove_provider_for_display, "gtk_style_context_remove_provider_for_display");
    BABET_GTK_RESOLVE(widget_add_css_class, "gtk_widget_add_css_class");
    BABET_GTK_RESOLVE(widget_remove_css_class, "gtk_widget_remove_css_class");
    BABET_GTK_RESOLVE(cairo_status, "cairo_status");
    BABET_GTK_RESOLVE(cairo_status_to_string, "cairo_status_to_string");
    BABET_GTK_RESOLVE(cairo_save, "cairo_save");
    BABET_GTK_RESOLVE(cairo_restore, "cairo_restore");
    BABET_GTK_RESOLVE(cairo_new_path, "cairo_new_path");
    BABET_GTK_RESOLVE(cairo_close_path, "cairo_close_path");
    BABET_GTK_RESOLVE(cairo_stroke, "cairo_stroke");
    BABET_GTK_RESOLVE(cairo_fill, "cairo_fill");
    BABET_GTK_RESOLVE(cairo_move_to, "cairo_move_to");
    BABET_GTK_RESOLVE(cairo_line_to, "cairo_line_to");
    BABET_GTK_RESOLVE(cairo_rectangle, "cairo_rectangle");
    BABET_GTK_RESOLVE(cairo_arc, "cairo_arc");
    BABET_GTK_RESOLVE(cairo_set_line_width, "cairo_set_line_width");
    BABET_GTK_RESOLVE(cairo_set_source_rgb, "cairo_set_source_rgb");
    BABET_GTK_RESOLVE(cairo_set_source_rgba, "cairo_set_source_rgba");
    BABET_GTK_RESOLVE(cairo_set_font_size, "cairo_set_font_size");
    BABET_GTK_RESOLVE(cairo_show_text, "cairo_show_text");
    BABET_GTK_RESOLVE(widget_get_parent, "gtk_widget_get_parent");
    BABET_GTK_RESOLVE(object_ref_sink, "g_object_ref_sink");
    BABET_GTK_RESOLVE(object_unref, "g_object_unref");
    BABET_GTK_RESOLVE(signal_connect_data, "g_signal_connect_data");
    BABET_GTK_RESOLVE(main_context_iteration, "g_main_context_iteration");
    BABET_GTK_RESOLVE(timeout_add, "g_timeout_add");
    BABET_GTK_RESOLVE(source_remove, "g_source_remove");

    g_gtk = candidate;
    g_load_state = GtkLoadState::loaded;
    return true;

symbol_failure:
    g_load_error = install_diagnostic(symbol_error);
    g_load_state = GtkLoadState::failed;
    error = g_load_error;
    return false;
}

#undef BABET_GTK_RESOLVE

bool gtk4_initialize(std::string &error)
{
    if (!gtk4_load(error))
        return false;
    g_gtk.disable_setlocale();
    if (g_gtk.init_check() == 0)
    {
        error =
            "babet.gui: GTK 4 is installed but no usable graphical display "
            "could be initialized (check DISPLAY/WAYLAND_DISPLAY and the "
            "desktop session)";
        return false;
    }
    error.clear();
    return true;
}

bool gtk4_loaded() noexcept { return g_gtk.handle != nullptr; }

void *gtk4_window_new() noexcept { return g_gtk.window_new(); }
void gtk4_window_set_title(void *w, const char *t) noexcept { g_gtk.window_set_title(w, t); }
void gtk4_window_set_default_size(void *w, int x, int y) noexcept { g_gtk.window_set_default_size(w, x, y); }
void gtk4_window_set_child(void *w, void *c) noexcept { g_gtk.window_set_child(w, c); }
void gtk4_window_present(void *w) noexcept { g_gtk.window_present(w); }
void gtk4_window_destroy(void *w) noexcept { g_gtk.window_destroy(w); }
void *gtk4_fixed_new() noexcept { return g_gtk.fixed_new(); }
void gtk4_fixed_put(void *p, void *c, double x, double y) noexcept { g_gtk.fixed_put(p, c, x, y); }
void gtk4_fixed_move(void *p, void *c, double x, double y) noexcept { g_gtk.fixed_move(p, c, x, y); }
void gtk4_fixed_remove(void *p, void *c) noexcept { g_gtk.fixed_remove(p, c); }
void *gtk4_text_view_new() noexcept { return g_gtk.text_view_new(); }
void *gtk4_text_view_get_buffer(void *v) noexcept { return g_gtk.text_view_get_buffer(v); }
void gtk4_text_buffer_set_text(void *b, const char *t) noexcept { g_gtk.text_buffer_set_text(b, t, -1); }
char *gtk4_text_buffer_dup_text(void *b) noexcept
{
    char *value = nullptr;
    g_gtk.object_get(b, "text", &value, nullptr);
    return value;
}
void gtk4_free(void *p) noexcept { g_gtk.glib_free(p); }
void gtk4_text_view_set_editable(void *v, bool b) noexcept { g_gtk.text_view_set_editable(v, b ? 1 : 0); }
void *gtk4_check_button_new_with_label(const char *s) noexcept { return g_gtk.check_button_new_with_label(s); }
void gtk4_check_button_set_label(void *c, const char *s) noexcept { g_gtk.check_button_set_label(c, s); }
void gtk4_check_button_set_active(void *c, bool b) noexcept { g_gtk.check_button_set_active(c, b ? 1 : 0); }
bool gtk4_check_button_get_active(void *c) noexcept { return g_gtk.check_button_get_active(c) != 0; }
void *gtk4_progress_bar_new() noexcept { return g_gtk.progress_bar_new(); }
void gtk4_progress_bar_set_fraction(void *p, double f) noexcept { g_gtk.progress_bar_set_fraction(p, f); }
double gtk4_progress_bar_get_fraction(void *p) noexcept { return g_gtk.progress_bar_get_fraction(p); }
void gtk4_progress_bar_set_text(void *p, const char *s) noexcept { g_gtk.progress_bar_set_text(p, s); }
void gtk4_progress_bar_set_show_text(void *p, bool b) noexcept { g_gtk.progress_bar_set_show_text(p, b ? 1 : 0); }
void *gtk4_expander_new(const char *s) noexcept { return g_gtk.expander_new(s); }
void gtk4_expander_set_label(void *e, const char *s) noexcept { g_gtk.expander_set_label(e, s); }
void gtk4_expander_set_child(void *e, void *c) noexcept { g_gtk.expander_set_child(e, c); }
void gtk4_expander_set_expanded(void *e, bool b) noexcept { g_gtk.expander_set_expanded(e, b ? 1 : 0); }
bool gtk4_expander_get_expanded(void *e) noexcept { return g_gtk.expander_get_expanded(e) != 0; }
void *gtk4_gesture_drag_new() noexcept { return g_gtk.gesture_drag_new(); }
bool gtk4_gesture_surface_position(void *gesture, double &x, double &y) noexcept
{
    void *sequence = g_gtk.gesture_single_get_current_sequence(gesture);
    void *event = g_gtk.gesture_get_last_event(gesture, sequence);
    return event && g_gtk.gdk_event_get_position(event, &x, &y) != 0;
}
void gtk4_widget_set_size_request(void *w, int width, int height) noexcept { g_gtk.widget_set_size_request(w, width, height); }

void *gtk4_box_new(int o, int s) noexcept { return g_gtk.box_new(o, s); }
void gtk4_box_append(void *b, void *c) noexcept { g_gtk.box_append(b, c); }
void gtk4_box_remove(void *b, void *c) noexcept { g_gtk.box_remove(b, c); }
void gtk4_box_reorder_child_after(void *b, void *c, void *s) noexcept
{ g_gtk.box_reorder_child_after(b, c, s); }
void *gtk4_scrolled_window_new() noexcept { return g_gtk.scrolled_window_new(); }
void gtk4_scrolled_window_set_child(void *s, void *c) noexcept { g_gtk.scrolled_window_set_child(s, c); }
void *gtk4_label_new(const char *t) noexcept { return g_gtk.label_new(t); }
void gtk4_label_set_text(void *l, const char *t) noexcept { g_gtk.label_set_text(l, t); }
void *gtk4_button_new_with_label(const char *t) noexcept { return g_gtk.button_new_with_label(t); }
void gtk4_button_set_label(void *b, const char *t) noexcept { g_gtk.button_set_label(b, t); }
void *gtk4_entry_new() noexcept { return g_gtk.entry_new(); }
void gtk4_entry_set_placeholder(void *e, const char *t) noexcept { g_gtk.entry_set_placeholder(e, t); }
void gtk4_editable_set_text(void *e, const char *t) noexcept { g_gtk.editable_set_text(e, t); }
const char *gtk4_editable_get_text(void *e) noexcept { return g_gtk.editable_get_text(e); }
void gtk4_editable_set_editable(void *e, bool v) noexcept { g_gtk.editable_set_editable(e, v ? 1 : 0); }
void *gtk4_spin_button_new_with_range(double minimum, double maximum, double step) noexcept { return g_gtk.spin_button_new_with_range(minimum, maximum, step); }
double gtk4_spin_button_get_value(void *s) noexcept { return g_gtk.spin_button_get_value(s); }
void gtk4_spin_button_set_value(void *s, double v) noexcept { g_gtk.spin_button_set_value(s, v); }
void gtk4_spin_button_set_digits(void *s, unsigned int d) noexcept { g_gtk.spin_button_set_digits(s, d); }
void gtk4_spin_button_set_numeric(void *s, bool v) noexcept { g_gtk.spin_button_set_numeric(s, v ? 1 : 0); }
void *gtk4_calendar_new() noexcept { return g_gtk.calendar_new(); }
void *gtk4_calendar_get_date(void *c) noexcept { return g_gtk.calendar_get_date(c); }
void gtk4_calendar_select_day(void *c, void *d) noexcept { g_gtk.calendar_select_day(c, d); }
void gtk4_calendar_mark_day(void *c, unsigned int day) noexcept { g_gtk.calendar_mark_day(c, day); }
void gtk4_calendar_unmark_day(void *c, unsigned int day) noexcept { g_gtk.calendar_unmark_day(c, day); }
void gtk4_calendar_clear_marks(void *c) noexcept { g_gtk.calendar_clear_marks(c); }
void *glib_date_time_new_local(int y, int m, int d, int h, int min, double sec) noexcept { return g_gtk.date_time_new_local(y, m, d, h, min, sec); }
int glib_date_time_get_year(void *d) noexcept { return g_gtk.date_time_get_year(d); }
int glib_date_time_get_month(void *d) noexcept { return g_gtk.date_time_get_month(d); }
int glib_date_time_get_day_of_month(void *d) noexcept { return g_gtk.date_time_get_day_of_month(d); }
void glib_date_time_unref(void *d) noexcept { g_gtk.date_time_unref(d); }
void * gtk4_drawing_area_new() noexcept { return g_gtk.gtk_drawing_area_new(); }
void gtk4_drawing_area_set_content_width(void *w, int width) noexcept { g_gtk.gtk_drawing_area_set_content_width(w, width); }
void gtk4_drawing_area_set_content_height(void *w, int height) noexcept { g_gtk.gtk_drawing_area_set_content_height(w, height); }
void gtk4_drawing_area_set_draw_func(void *w, GtkDrawCallback cb, void *data, GtkDestroyNotify notify) noexcept { g_gtk.gtk_drawing_area_set_draw_func(w, cb, data, notify); }
void *gtk4_gesture_click_new() noexcept { return g_gtk.gesture_click_new(); }
void gtk4_gesture_single_set_button(void *gesture, unsigned int button) noexcept { g_gtk.gesture_single_set_button(gesture, button); }
unsigned int gtk4_gesture_single_get_current_button(void *gesture) noexcept { return g_gtk.gesture_single_get_current_button(gesture); }
void gtk4_widget_add_controller(void *widget, void *controller) noexcept { g_gtk.widget_add_controller(widget, controller); }
void gtk4_widget_queue_draw(void *w) noexcept { g_gtk.gtk_widget_queue_draw(w); }
void gtk4_widget_set_margin_top(void *w, int m) noexcept { g_gtk.widget_set_margin_top(w, m); }
void gtk4_widget_set_margin_bottom(void *w, int m) noexcept { g_gtk.widget_set_margin_bottom(w, m); }
void gtk4_widget_set_margin_start(void *w, int m) noexcept { g_gtk.widget_set_margin_start(w, m); }
void gtk4_widget_set_margin_end(void *w, int m) noexcept { g_gtk.widget_set_margin_end(w, m); }
void gtk4_widget_set_hexpand(void *w, bool v) noexcept { g_gtk.widget_set_hexpand(w, v ? 1 : 0); }
void gtk4_widget_set_vexpand(void *w, bool v) noexcept { g_gtk.widget_set_vexpand(w, v ? 1 : 0); }
void gtk4_widget_set_visible(void *w, bool v) noexcept { g_gtk.widget_set_visible(w, v ? 1 : 0); }
void gtk4_widget_set_sensitive(void *w, bool v) noexcept { g_gtk.widget_set_sensitive(w, v ? 1 : 0); }
void *gtk4_css_provider_new() noexcept { return g_gtk.css_provider_new(); }
void gtk4_css_provider_load(void *provider, const char *css) noexcept
{
    if (g_gtk.css_provider_load_from_string)
        g_gtk.css_provider_load_from_string(provider, css);
    else
        g_gtk.css_provider_load_from_data(provider, css, -1L);
}
void *gdk4_display_get_default() noexcept { return g_gtk.display_get_default(); }
void gtk4_style_context_add_provider_for_display(void *display, void *provider, unsigned int priority) noexcept
{ g_gtk.style_context_add_provider_for_display(display, provider, priority); }
void gtk4_style_context_remove_provider_for_display(void *display, void *provider) noexcept
{ g_gtk.style_context_remove_provider_for_display(display, provider); }
void gtk4_widget_add_css_class(void *w, const char *css_class) noexcept
{ g_gtk.widget_add_css_class(w, css_class); }
void gtk4_widget_remove_css_class(void *w, const char *css_class) noexcept
{ g_gtk.widget_remove_css_class(w, css_class); }
int cairo_status(void *cr) noexcept { return g_gtk.cairo_status(cr); }
const char * cairo_status_to_string(int status) noexcept { return g_gtk.cairo_status_to_string(status); }
void cairo_save(void *cr) noexcept { g_gtk.cairo_save(cr); }
void cairo_restore(void *cr) noexcept { g_gtk.cairo_restore(cr); }
void cairo_new_path(void *cr) noexcept { g_gtk.cairo_new_path(cr); }
void cairo_close_path(void *cr) noexcept { g_gtk.cairo_close_path(cr); }
void cairo_stroke(void *cr) noexcept { g_gtk.cairo_stroke(cr); }
void cairo_fill(void *cr) noexcept { g_gtk.cairo_fill(cr); }
void cairo_move_to(void *cr, double x, double y) noexcept { g_gtk.cairo_move_to(cr, x, y); }
void cairo_line_to(void *cr, double x, double y) noexcept { g_gtk.cairo_line_to(cr, x, y); }
void cairo_rectangle(void *cr, double x, double y, double width, double height) noexcept { g_gtk.cairo_rectangle(cr, x, y, width, height); }
void cairo_arc(void *cr, double x, double y, double radius, double start, double end) noexcept { g_gtk.cairo_arc(cr, x, y, radius, start, end); }
void cairo_set_line_width(void *cr, double width) noexcept { g_gtk.cairo_set_line_width(cr, width); }
void cairo_set_source_rgb(void *cr, double r, double g, double b) noexcept { g_gtk.cairo_set_source_rgb(cr, r, g, b); }
void cairo_set_source_rgba(void *cr, double r, double g, double b, double a) noexcept { g_gtk.cairo_set_source_rgba(cr, r, g, b, a); }
void cairo_set_font_size(void *cr, double size) noexcept { g_gtk.cairo_set_font_size(cr, size); }
void cairo_show_text(void *cr, const char *text) noexcept { g_gtk.cairo_show_text(cr, text); }
void *gtk4_widget_get_parent(void *w) noexcept { return g_gtk.widget_get_parent(w); }
void *gtk4_object_ref_sink(void *o) noexcept { return g_gtk.object_ref_sink(o); }
void gtk4_object_unref(void *o) noexcept { g_gtk.object_unref(o); }
unsigned long gtk4_signal_connect(void *i, const char *s, GtkCallback c, void *d,
                                  GtkClosureNotify n) noexcept
{
    return g_gtk.signal_connect_data(i, s, c, d, n, 0U);
}
int gtk4_main_context_iteration(bool block) noexcept
{
    return g_gtk.main_context_iteration(nullptr, block ? 1 : 0);
}
unsigned int gtk4_timeout_add(unsigned int ms, GtkSourceCallback cb, void *d) noexcept
{
    return g_gtk.timeout_add(ms, cb, d);
}
bool gtk4_source_remove(unsigned int id) noexcept { return g_gtk.source_remove(id) != 0; }

} // namespace babet_gui::detail
