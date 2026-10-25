#include "gui_gtk_loader.hpp"
#include "process_state.hpp"

#include <cstring>
#include <cstddef>
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
using GtkWindowSetTransientFor = void (*)(void *, void *);
using GtkWindowSetBoolean = void (*)(void *, int);
using GtkWindowSetIconName = void (*)(void *, const char *);
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
using GType = std::size_t;
using GtkDragSourceNew = void *(*)();
using GtkDragSourceSetActions = void (*)(void *, unsigned int);
using GtkDragSourceSetContent = void (*)(void *, void *);
using GtkDragSourceSetIcon = void (*)(void *, void *, int, int);
using GtkWidgetPaintableNew = void *(*)(void *);
using GdkContentProviderNewTyped = void *(*)(GType, ...);
using GTypeFromName = GType (*)(const char *);
using GtkDropTargetNew = void *(*)(GType, unsigned int);
using GtkDropTargetSetPreload = void (*)(void *, int);
using GtkDropTargetSetActions = void (*)(void *, unsigned int);
using GtkDropTargetReject = void (*)(void *);
using GtkDropTargetGetValue = const void *(*)(void *);
using GtkDropTargetGetDrop = void *(*)(void *);
using GdkDropGetDrag = void *(*)(void *);
using GdkDropGetActions = unsigned int (*)(void *);
using GdkDragGetSelectedAction = unsigned int (*)(void *);
using GValueGetString = const char *(*)(const void *);
using GUtf8Validate = int (*)(const char *, std::ptrdiff_t, const char **);
using GtkGestureSingleGetCurrentSequence = void *(*)(void *);
using GtkGestureGetLastEvent = void *(*)(void *, void *);
using GdkEventGetPosition = int (*)(void *, double *, double *);
using GtkWidgetSetSizeRequest = void (*)(void *, int, int);
using GtkWidgetSetString = void (*)(void *, const char *);
using GtkWidgetGrabFocus = int (*)(void *);
using GtkWidgetGetBoolean = int (*)(void *);
using GtkWidgetGetInt = int (*)(void *);
using GtkWidgetSetInt = void (*)(void *, int);
struct GraphenePoint { float x; float y; };
using GtkWidgetComputePoint = int (*)(void *, void *, const GraphenePoint *, GraphenePoint *);
using GtkWidgetPick = void *(*)(void *, double, double, unsigned int);
using GtkEventControllerNew = void *(*)();
using GtkEventControllerGetCurrentEventState = unsigned int (*)(void *);
using GtkEventControllerSetPropagationPhase = void (*)(void *, int);
using GdkKeyvalName = const char *(*)(unsigned int);

using GtkBoxNew = void *(*)(int, int);
using GtkSeparatorNew = void *(*)(int);
using GtkPanedNew = void *(*)(int);
using GtkPanedSetChild = void (*)(void *, void *);
using GtkPanedSetPosition = void (*)(void *, int);
using GtkPanedGetPosition = int (*)(void *);
using GtkPanedSetBoolean = void (*)(void *, int);
using GtkBoxAppend = void (*)(void *, void *);
using GtkBoxRemove = void (*)(void *, void *);
using GtkBoxReorderChildAfter = void (*)(void *, void *, void *);
using GtkScrolledWindowNew = void *(*)();
using GtkScrolledWindowSetChild = void (*)(void *, void *);
using GtkLabelNew = void *(*)(const char *);
using GtkLabelSetText = void (*)(void *, const char *);
using GtkLabelSetBoolean = void (*)(void *, int);
using GtkLabelSetWrapMode = void (*)(void *, int);
using GtkLabelSetXAlign = void (*)(void *, float);
using GtkImageNewFromIconName = void *(*)(const char *);
using GtkImageSetFromIconName = void (*)(void *, const char *);
using GtkButtonNewWithLabel = void *(*)(const char *);
using GtkButtonSetLabel = void (*)(void *, const char *);
using GtkButtonSetIconName = void (*)(void *, const char *);
using GtkMenuButtonNew = void *(*)();
using GtkMenuButtonSetString = void (*)(void *, const char *);
using GtkMenuButtonSetPopover = void (*)(void *, void *);
using GtkMenuButtonPopup = void (*)(void *);
using GtkPopoverNew = void *(*)();
using GtkPopoverSetChild = void (*)(void *, void *);
using GtkPopoverSetBoolean = void (*)(void *, int);
using GtkPopoverSetPosition = void (*)(void *, int);
struct GdkRectangle { int x; int y; int width; int height; };
using GtkPopoverSetPointingTo = void (*)(void *, const GdkRectangle *);
using GtkPopoverAction = void (*)(void *);
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
using GtkWidgetSetParent = void (*)(void *, void *);
using GtkWidgetUnparent = void (*)(void *);
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
    void * (*rich_gtk_text_tag_new)(const char *a) = nullptr;
    void * (*rich_gtk_text_buffer_get_tag_table)(void *a) = nullptr;
    int (*rich_gtk_text_tag_table_add)(void *a, void *b) = nullptr;
    void * (*rich_gtk_text_tag_table_lookup)(void *a, const char *b) = nullptr;
    void (*rich_gtk_text_buffer_get_bounds)(void *a, TextIter *b, TextIter *c) = nullptr;
    char * (*rich_gtk_text_buffer_get_text)(void *a, const TextIter *b, const TextIter *c, int d) = nullptr;
    void (*rich_gtk_text_buffer_get_iter_at_offset)(void *a, TextIter *b, int c) = nullptr;
    void (*rich_gtk_text_buffer_apply_tag)(void *a, void *b, const TextIter *c, const TextIter *d) = nullptr;
    void (*rich_gtk_text_buffer_remove_tag)(void *a, void *b, const TextIter *c, const TextIter *d) = nullptr;
    void (*rich_gtk_text_buffer_remove_all_tags)(void *a, const TextIter *b, const TextIter *c) = nullptr;
    int (*rich_gtk_text_iter_get_offset)(const TextIter *a) = nullptr;
    int (*rich_gtk_text_iter_has_tag)(const TextIter *a, void *b) = nullptr;
    int (*rich_gtk_text_iter_starts_tag)(const TextIter *a, void *b) = nullptr;
    int (*rich_gtk_text_iter_backward_to_tag_toggle)(TextIter *a, void *b) = nullptr;
    int (*rich_gtk_text_iter_forward_to_tag_toggle)(TextIter *a, void *b) = nullptr;
    void (*rich_gtk_text_view_window_to_buffer_coords)(void *a, int b, int c, int d, int *e, int *f) = nullptr;
    int (*rich_gtk_text_view_get_iter_at_location)(void *a, TextIter *b, int c, int d) = nullptr;
    void * (*rich_g_value_init)(NativeValue *a, std::size_t b) = nullptr;
    void (*rich_g_value_unset)(NativeValue *a) = nullptr;
    void (*rich_g_value_set_string)(NativeValue *a, const char *b) = nullptr;
    void (*rich_g_value_set_int)(NativeValue *a, int b) = nullptr;
    void (*rich_g_value_set_boolean)(NativeValue *a, int b) = nullptr;
    void (*rich_g_value_set_double)(NativeValue *a, double b) = nullptr;
    void (*rich_g_value_set_enum)(NativeValue *a, int b) = nullptr;
    void (*rich_g_object_set_property)(void *a, const char *b, const NativeValue *c) = nullptr;
    std::ptrdiff_t (*rich_g_utf8_pointer_to_offset)(const char *a, const char *b) = nullptr;
    void (*rich_gtk_drop_target_set_gtypes)(void *a, const std::size_t *b, std::size_t c) = nullptr;
    std::size_t (*rich_gdk_file_list_get_type)() = nullptr;
    const NativeSList * (*rich_gdk_file_list_get_files)(void *a) = nullptr;
    void * (*rich_g_value_get_boxed)(const void *a) = nullptr;
    int (*rich_g_type_check_value_holds)(const void *a, std::size_t b) = nullptr;
    void * (*files_gtk_picture_new)() = nullptr;
    void (*files_gtk_picture_set_paintable)(void *a, void *b) = nullptr;
    void * (*files_gtk_picture_get_paintable)(void *a) = nullptr;
    void (*files_gtk_picture_set_can_shrink)(void *a, int b) = nullptr;
    void (*files_gtk_picture_set_content_fit)(void *a, int b) = nullptr;
    void (*files_gtk_picture_set_alternative_text)(void *a, const char *b) = nullptr;
    int (*files_gdk_paintable_get_intrinsic_width)(void *a) = nullptr;
    int (*files_gdk_paintable_get_intrinsic_height)(void *a) = nullptr;
    void * (*files_gdk_texture_new_from_filename)(const char *a, void **b) = nullptr;
    void (*files_g_error_free)(void *a) = nullptr;
    void * (*files_gtk_file_dialog_new)() = nullptr;
    void (*files_gtk_file_dialog_set_title)(void *a, const char *b) = nullptr;
    void (*files_gtk_file_dialog_set_modal)(void *a, int b) = nullptr;
    void (*files_gtk_file_dialog_set_initial_folder)(void *a, void *b) = nullptr;
    void (*files_gtk_file_dialog_set_initial_name)(void *a, const char *b) = nullptr;
    void (*files_gtk_file_dialog_set_filters)(void *a, void *b) = nullptr;
    unsigned int (*files_gtk_dialog_error_quark)() = nullptr;
    void * (*files_g_cancellable_new)() = nullptr;
    void (*files_g_cancellable_cancel)(void *a) = nullptr;
    void * (*files_g_file_new_for_path)(const char *a) = nullptr;
    char * (*files_g_file_get_path)(void *a) = nullptr;
    char * (*files_g_file_get_uri)(void *a) = nullptr;
    void * (*files_gtk_file_filter_new)() = nullptr;
    std::size_t (*files_gtk_file_filter_get_type)() = nullptr;
    void (*files_gtk_file_filter_set_name)(void *a, const char *b) = nullptr;
    void (*files_gtk_file_filter_add_pattern)(void *a, const char *b) = nullptr;
    void (*files_gtk_file_filter_add_mime_type)(void *a, const char *b) = nullptr;
    void * (*files_g_list_store_new)(std::size_t a) = nullptr;
    void (*files_g_list_store_append)(void *a, void *b) = nullptr;
    unsigned int (*files_g_list_model_get_n_items)(void *a) = nullptr;
    void * (*files_g_list_model_get_item)(void *a, unsigned int b) = nullptr;
    void (*files_gtk_file_dialog_open)(void *a, void *b, void *c, GtkAsyncReadyCallback cb, void *d) = nullptr;
    void * (*files_gtk_file_dialog_open_finish)(void *a, void *b, void **c) = nullptr;
    void (*files_gtk_file_dialog_open_multiple)(void *a, void *b, void *c, GtkAsyncReadyCallback cb, void *d) = nullptr;
    void * (*files_gtk_file_dialog_open_multiple_finish)(void *a, void *b, void **c) = nullptr;
    void (*files_gtk_file_dialog_save)(void *a, void *b, void *c, GtkAsyncReadyCallback cb, void *d) = nullptr;
    void * (*files_gtk_file_dialog_save_finish)(void *a, void *b, void **c) = nullptr;

    void *handle = nullptr;
    GtkDisableSetlocale disable_setlocale = nullptr;
    GtkInitCheck init_check = nullptr;
    GtkWindowNew window_new = nullptr;
    GtkWindowSetTitle window_set_title = nullptr;
    GtkWindowSetDefaultSize window_set_default_size = nullptr;
    GtkWindowSetChild window_set_child = nullptr;
    GtkWindowPresent window_present = nullptr;
    GtkWindowDestroy window_destroy = nullptr;
    GtkWindowSetTransientFor window_set_transient_for = nullptr;
    GtkWindowSetBoolean window_set_modal = nullptr;
    GtkWindowSetIconName window_set_icon_name = nullptr;
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
    GtkWidgetSetInt text_view_set_wrap_mode = nullptr;
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
    GtkDragSourceNew drag_source_new = nullptr;
    GtkDragSourceSetActions drag_source_set_actions = nullptr;
    GtkDragSourceSetContent drag_source_set_content = nullptr;
    GtkDragSourceSetIcon drag_source_set_icon = nullptr;
    GtkWidgetPaintableNew widget_paintable_new = nullptr;
    GdkContentProviderNewTyped content_provider_new_typed = nullptr;
    GTypeFromName type_from_name = nullptr;
    GtkDropTargetNew drop_target_new = nullptr;
    GtkDropTargetSetPreload drop_target_set_preload = nullptr;
    GtkDropTargetSetActions drop_target_set_actions = nullptr;
    GtkDropTargetReject drop_target_reject = nullptr;
    GtkDropTargetGetValue drop_target_get_value = nullptr;
    GtkDropTargetGetDrop drop_target_get_drop = nullptr;
    GdkDropGetDrag drop_get_drag = nullptr;
    GdkDropGetActions drop_get_actions = nullptr;
    GdkDragGetSelectedAction drag_get_selected_action = nullptr;
    GValueGetString value_get_string = nullptr;
    GUtf8Validate utf8_validate = nullptr;
    GtkGestureSingleGetCurrentSequence gesture_single_get_current_sequence = nullptr;
    GtkGestureGetLastEvent gesture_get_last_event = nullptr;
    GdkEventGetPosition gdk_event_get_position = nullptr;
    GtkWidgetSetSizeRequest widget_set_size_request = nullptr;
    GtkWidgetSetString widget_set_cursor_from_name = nullptr;
    GtkWidgetSetString widget_set_tooltip_text = nullptr;
    GtkWidgetGrabFocus widget_grab_focus = nullptr;
    GtkWidgetGetBoolean widget_has_focus = nullptr;
    GtkWidgetGetBoolean widget_get_mapped = nullptr;
    GtkWidgetGetInt widget_get_width = nullptr;
    GtkWidgetGetInt widget_get_height = nullptr;
    GtkWidgetComputePoint widget_compute_point = nullptr;
    GtkWidgetPick widget_pick = nullptr;
    GtkWidgetSetInt widget_set_halign = nullptr;
    GtkWidgetSetInt widget_set_valign = nullptr;
    GtkEventControllerNew event_controller_motion_new = nullptr;
    GtkEventControllerNew event_controller_key_new = nullptr;
    GtkEventControllerGetCurrentEventState event_controller_get_current_event_state = nullptr;
    GtkEventControllerSetPropagationPhase event_controller_set_propagation_phase = nullptr;
    GdkKeyvalName keyval_name = nullptr;
    GtkBoxNew box_new = nullptr;
    GtkSeparatorNew separator_new = nullptr;
    GtkPanedNew paned_new = nullptr;
    GtkPanedSetChild paned_set_start_child = nullptr;
    GtkPanedSetChild paned_set_end_child = nullptr;
    GtkPanedSetPosition paned_set_position = nullptr;
    GtkPanedGetPosition paned_get_position = nullptr;
    GtkPanedSetBoolean paned_set_resize_start_child = nullptr;
    GtkPanedSetBoolean paned_set_resize_end_child = nullptr;
    GtkPanedSetBoolean paned_set_shrink_start_child = nullptr;
    GtkPanedSetBoolean paned_set_shrink_end_child = nullptr;
    GtkPanedSetBoolean paned_set_wide_handle = nullptr;
    GtkBoxAppend box_append = nullptr;
    GtkBoxRemove box_remove = nullptr;
    GtkBoxReorderChildAfter box_reorder_child_after = nullptr;
    GtkScrolledWindowNew scrolled_window_new = nullptr;
    GtkScrolledWindowSetChild scrolled_window_set_child = nullptr;
    GtkLabelNew label_new = nullptr;
    GtkLabelSetText label_set_text = nullptr;
    GtkLabelSetBoolean label_set_wrap = nullptr;
    GtkLabelSetWrapMode label_set_wrap_mode = nullptr;
    GtkLabelSetXAlign label_set_xalign = nullptr;
    GtkImageNewFromIconName image_new_from_icon_name = nullptr;
    GtkImageSetFromIconName image_set_from_icon_name = nullptr;
    GtkButtonNewWithLabel button_new_with_label = nullptr;
    GtkButtonSetLabel button_set_label = nullptr;
    GtkButtonSetIconName button_set_icon_name = nullptr;
    GtkMenuButtonNew menu_button_new = nullptr;
    GtkMenuButtonSetString menu_button_set_label = nullptr;
    GtkMenuButtonSetString menu_button_set_icon_name = nullptr;
    GtkMenuButtonSetPopover menu_button_set_popover = nullptr;
    GtkMenuButtonPopup menu_button_popup = nullptr;
    GtkMenuButtonPopup menu_button_popdown = nullptr;
    GtkPopoverNew popover_new = nullptr;
    GtkPopoverSetChild popover_set_child = nullptr;
    GtkPopoverSetBoolean popover_set_has_arrow = nullptr;
    GtkPopoverSetBoolean popover_set_autohide = nullptr;
    GtkPopoverSetPosition popover_set_position = nullptr;
    GtkPopoverSetPointingTo popover_set_pointing_to = nullptr;
    GtkPopoverAction popover_popup = nullptr;
    GtkPopoverAction popover_popdown = nullptr;
    GtkPopoverAction popover_present = nullptr;
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
    GtkWidgetSetParent widget_set_parent = nullptr;
    GtkWidgetUnparent widget_unparent = nullptr;
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
    BABET_GTK_RESOLVE(window_set_transient_for, "gtk_window_set_transient_for");
    BABET_GTK_RESOLVE(window_set_modal, "gtk_window_set_modal");
    BABET_GTK_RESOLVE(window_set_icon_name, "gtk_window_set_icon_name");
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
    BABET_GTK_RESOLVE(text_view_set_wrap_mode, "gtk_text_view_set_wrap_mode");
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
    BABET_GTK_RESOLVE(drag_source_new, "gtk_drag_source_new");
    BABET_GTK_RESOLVE(drag_source_set_actions, "gtk_drag_source_set_actions");
    BABET_GTK_RESOLVE(drag_source_set_content, "gtk_drag_source_set_content");
    BABET_GTK_RESOLVE(drag_source_set_icon, "gtk_drag_source_set_icon");
    BABET_GTK_RESOLVE(widget_paintable_new, "gtk_widget_paintable_new");
    BABET_GTK_RESOLVE(content_provider_new_typed, "gdk_content_provider_new_typed");
    BABET_GTK_RESOLVE(type_from_name, "g_type_from_name");
    BABET_GTK_RESOLVE(drop_target_new, "gtk_drop_target_new");
    BABET_GTK_RESOLVE(drop_target_set_preload, "gtk_drop_target_set_preload");
    BABET_GTK_RESOLVE(drop_target_set_actions, "gtk_drop_target_set_actions");
    BABET_GTK_RESOLVE(drop_target_reject, "gtk_drop_target_reject");
    BABET_GTK_RESOLVE(drop_target_get_value, "gtk_drop_target_get_value");
    BABET_GTK_RESOLVE(drop_target_get_drop, "gtk_drop_target_get_drop");
    BABET_GTK_RESOLVE(drop_get_drag, "gdk_drop_get_drag");
    BABET_GTK_RESOLVE(drop_get_actions, "gdk_drop_get_actions");
    BABET_GTK_RESOLVE(drag_get_selected_action, "gdk_drag_get_selected_action");
    BABET_GTK_RESOLVE(value_get_string, "g_value_get_string");
    BABET_GTK_RESOLVE(utf8_validate, "g_utf8_validate");
    BABET_GTK_RESOLVE(gesture_single_get_current_sequence, "gtk_gesture_single_get_current_sequence");
    BABET_GTK_RESOLVE(gesture_get_last_event, "gtk_gesture_get_last_event");
    BABET_GTK_RESOLVE(gdk_event_get_position, "gdk_event_get_position");
    BABET_GTK_RESOLVE(widget_set_size_request, "gtk_widget_set_size_request");
    BABET_GTK_RESOLVE(widget_set_cursor_from_name, "gtk_widget_set_cursor_from_name");
    BABET_GTK_RESOLVE(widget_set_tooltip_text, "gtk_widget_set_tooltip_text");
    BABET_GTK_RESOLVE(widget_grab_focus, "gtk_widget_grab_focus");
    BABET_GTK_RESOLVE(widget_has_focus, "gtk_widget_has_focus");
    BABET_GTK_RESOLVE(widget_get_mapped, "gtk_widget_get_mapped");
    BABET_GTK_RESOLVE(widget_get_width, "gtk_widget_get_width");
    BABET_GTK_RESOLVE(widget_get_height, "gtk_widget_get_height");
    BABET_GTK_RESOLVE(widget_compute_point, "gtk_widget_compute_point");
    BABET_GTK_RESOLVE(widget_pick, "gtk_widget_pick");
    BABET_GTK_RESOLVE(widget_set_halign, "gtk_widget_set_halign");
    BABET_GTK_RESOLVE(widget_set_valign, "gtk_widget_set_valign");
    BABET_GTK_RESOLVE(event_controller_motion_new, "gtk_event_controller_motion_new");
    BABET_GTK_RESOLVE(event_controller_key_new, "gtk_event_controller_key_new");
    BABET_GTK_RESOLVE(event_controller_get_current_event_state, "gtk_event_controller_get_current_event_state");
    BABET_GTK_RESOLVE(event_controller_set_propagation_phase, "gtk_event_controller_set_propagation_phase");
    BABET_GTK_RESOLVE(keyval_name, "gdk_keyval_name");
    BABET_GTK_RESOLVE(box_new, "gtk_box_new");
    BABET_GTK_RESOLVE(separator_new, "gtk_separator_new");
    BABET_GTK_RESOLVE(paned_new, "gtk_paned_new");
    BABET_GTK_RESOLVE(paned_set_start_child, "gtk_paned_set_start_child");
    BABET_GTK_RESOLVE(paned_set_end_child, "gtk_paned_set_end_child");
    BABET_GTK_RESOLVE(paned_set_position, "gtk_paned_set_position");
    BABET_GTK_RESOLVE(paned_get_position, "gtk_paned_get_position");
    BABET_GTK_RESOLVE(paned_set_resize_start_child, "gtk_paned_set_resize_start_child");
    BABET_GTK_RESOLVE(paned_set_resize_end_child, "gtk_paned_set_resize_end_child");
    BABET_GTK_RESOLVE(paned_set_shrink_start_child, "gtk_paned_set_shrink_start_child");
    BABET_GTK_RESOLVE(paned_set_shrink_end_child, "gtk_paned_set_shrink_end_child");
    BABET_GTK_RESOLVE(paned_set_wide_handle, "gtk_paned_set_wide_handle");
    BABET_GTK_RESOLVE(box_append, "gtk_box_append");
    BABET_GTK_RESOLVE(box_remove, "gtk_box_remove");
    BABET_GTK_RESOLVE(box_reorder_child_after, "gtk_box_reorder_child_after");
    BABET_GTK_RESOLVE(scrolled_window_new, "gtk_scrolled_window_new");
    BABET_GTK_RESOLVE(scrolled_window_set_child, "gtk_scrolled_window_set_child");
    BABET_GTK_RESOLVE(label_new, "gtk_label_new");
    BABET_GTK_RESOLVE(label_set_text, "gtk_label_set_text");
    BABET_GTK_RESOLVE(label_set_wrap, "gtk_label_set_wrap");
    BABET_GTK_RESOLVE(label_set_wrap_mode, "gtk_label_set_wrap_mode");
    BABET_GTK_RESOLVE(label_set_xalign, "gtk_label_set_xalign");
    BABET_GTK_RESOLVE(image_new_from_icon_name, "gtk_image_new_from_icon_name");
    BABET_GTK_RESOLVE(image_set_from_icon_name, "gtk_image_set_from_icon_name");
    BABET_GTK_RESOLVE(button_new_with_label, "gtk_button_new_with_label");
    BABET_GTK_RESOLVE(button_set_label, "gtk_button_set_label");
    BABET_GTK_RESOLVE(button_set_icon_name, "gtk_button_set_icon_name");
    BABET_GTK_RESOLVE(menu_button_new, "gtk_menu_button_new");
    BABET_GTK_RESOLVE(menu_button_set_label, "gtk_menu_button_set_label");
    BABET_GTK_RESOLVE(menu_button_set_icon_name, "gtk_menu_button_set_icon_name");
    BABET_GTK_RESOLVE(menu_button_set_popover, "gtk_menu_button_set_popover");
    BABET_GTK_RESOLVE(menu_button_popup, "gtk_menu_button_popup");
    BABET_GTK_RESOLVE(menu_button_popdown, "gtk_menu_button_popdown");
    BABET_GTK_RESOLVE(popover_new, "gtk_popover_new");
    BABET_GTK_RESOLVE(popover_set_child, "gtk_popover_set_child");
    BABET_GTK_RESOLVE(popover_set_has_arrow, "gtk_popover_set_has_arrow");
    BABET_GTK_RESOLVE(popover_set_autohide, "gtk_popover_set_autohide");
    BABET_GTK_RESOLVE(popover_set_position, "gtk_popover_set_position");
    BABET_GTK_RESOLVE(popover_set_pointing_to, "gtk_popover_set_pointing_to");
    BABET_GTK_RESOLVE(popover_popup, "gtk_popover_popup");
    BABET_GTK_RESOLVE(popover_popdown, "gtk_popover_popdown");
    BABET_GTK_RESOLVE(popover_present, "gtk_popover_present");
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
    BABET_GTK_RESOLVE(widget_set_parent, "gtk_widget_set_parent");
    BABET_GTK_RESOLVE(widget_unparent, "gtk_widget_unparent");
    BABET_GTK_RESOLVE(object_ref_sink, "g_object_ref_sink");
    BABET_GTK_RESOLVE(object_unref, "g_object_unref");
    BABET_GTK_RESOLVE(signal_connect_data, "g_signal_connect_data");
    BABET_GTK_RESOLVE(main_context_iteration, "g_main_context_iteration");
    BABET_GTK_RESOLVE(timeout_add, "g_timeout_add");
    BABET_GTK_RESOLVE(source_remove, "g_source_remove");

    resolve_optional(handle, "gtk_picture_new", candidate.files_gtk_picture_new);
    resolve_optional(handle, "gtk_picture_set_paintable", candidate.files_gtk_picture_set_paintable);
    resolve_optional(handle, "gtk_picture_get_paintable", candidate.files_gtk_picture_get_paintable);
    resolve_optional(handle, "gtk_picture_set_can_shrink", candidate.files_gtk_picture_set_can_shrink);
    resolve_optional(handle, "gtk_picture_set_content_fit", candidate.files_gtk_picture_set_content_fit);
    resolve_optional(handle, "gtk_picture_set_alternative_text", candidate.files_gtk_picture_set_alternative_text);
    resolve_optional(handle, "gdk_paintable_get_intrinsic_width", candidate.files_gdk_paintable_get_intrinsic_width);
    resolve_optional(handle, "gdk_paintable_get_intrinsic_height", candidate.files_gdk_paintable_get_intrinsic_height);
    resolve_optional(handle, "gdk_texture_new_from_filename", candidate.files_gdk_texture_new_from_filename);
    resolve_optional(handle, "g_error_free", candidate.files_g_error_free);
    resolve_optional(handle, "gtk_file_dialog_new", candidate.files_gtk_file_dialog_new);
    resolve_optional(handle, "gtk_file_dialog_set_title", candidate.files_gtk_file_dialog_set_title);
    resolve_optional(handle, "gtk_file_dialog_set_modal", candidate.files_gtk_file_dialog_set_modal);
    resolve_optional(handle, "gtk_file_dialog_set_initial_folder", candidate.files_gtk_file_dialog_set_initial_folder);
    resolve_optional(handle, "gtk_file_dialog_set_initial_name", candidate.files_gtk_file_dialog_set_initial_name);
    resolve_optional(handle, "gtk_file_dialog_set_filters", candidate.files_gtk_file_dialog_set_filters);
    resolve_optional(handle, "gtk_dialog_error_quark", candidate.files_gtk_dialog_error_quark);
    resolve_optional(handle, "g_cancellable_new", candidate.files_g_cancellable_new);
    resolve_optional(handle, "g_cancellable_cancel", candidate.files_g_cancellable_cancel);
    resolve_optional(handle, "g_file_new_for_path", candidate.files_g_file_new_for_path);
    resolve_optional(handle, "g_file_get_path", candidate.files_g_file_get_path);
    resolve_optional(handle, "g_file_get_uri", candidate.files_g_file_get_uri);
    resolve_optional(handle, "gtk_file_filter_new", candidate.files_gtk_file_filter_new);
    resolve_optional(handle, "gtk_file_filter_get_type", candidate.files_gtk_file_filter_get_type);
    resolve_optional(handle, "gtk_file_filter_set_name", candidate.files_gtk_file_filter_set_name);
    resolve_optional(handle, "gtk_file_filter_add_pattern", candidate.files_gtk_file_filter_add_pattern);
    resolve_optional(handle, "gtk_file_filter_add_mime_type", candidate.files_gtk_file_filter_add_mime_type);
    resolve_optional(handle, "g_list_store_new", candidate.files_g_list_store_new);
    resolve_optional(handle, "g_list_store_append", candidate.files_g_list_store_append);
    resolve_optional(handle, "g_list_model_get_n_items", candidate.files_g_list_model_get_n_items);
    resolve_optional(handle, "g_list_model_get_item", candidate.files_g_list_model_get_item);
    resolve_optional(handle, "gtk_file_dialog_open", candidate.files_gtk_file_dialog_open);
    resolve_optional(handle, "gtk_file_dialog_open_finish", candidate.files_gtk_file_dialog_open_finish);
    resolve_optional(handle, "gtk_file_dialog_open_multiple", candidate.files_gtk_file_dialog_open_multiple);
    resolve_optional(handle, "gtk_file_dialog_open_multiple_finish", candidate.files_gtk_file_dialog_open_multiple_finish);
    resolve_optional(handle, "gtk_file_dialog_save", candidate.files_gtk_file_dialog_save);
    resolve_optional(handle, "gtk_file_dialog_save_finish", candidate.files_gtk_file_dialog_save_finish);
    resolve_optional(handle, "gtk_text_tag_new", candidate.rich_gtk_text_tag_new);
    resolve_optional(handle, "gtk_text_buffer_get_tag_table", candidate.rich_gtk_text_buffer_get_tag_table);
    resolve_optional(handle, "gtk_text_tag_table_add", candidate.rich_gtk_text_tag_table_add);
    resolve_optional(handle, "gtk_text_tag_table_lookup", candidate.rich_gtk_text_tag_table_lookup);
    resolve_optional(handle, "gtk_text_buffer_get_bounds", candidate.rich_gtk_text_buffer_get_bounds);
    resolve_optional(handle, "gtk_text_buffer_get_text", candidate.rich_gtk_text_buffer_get_text);
    resolve_optional(handle, "gtk_text_buffer_get_iter_at_offset", candidate.rich_gtk_text_buffer_get_iter_at_offset);
    resolve_optional(handle, "gtk_text_buffer_apply_tag", candidate.rich_gtk_text_buffer_apply_tag);
    resolve_optional(handle, "gtk_text_buffer_remove_tag", candidate.rich_gtk_text_buffer_remove_tag);
    resolve_optional(handle, "gtk_text_buffer_remove_all_tags", candidate.rich_gtk_text_buffer_remove_all_tags);
    resolve_optional(handle, "gtk_text_iter_get_offset", candidate.rich_gtk_text_iter_get_offset);
    resolve_optional(handle, "gtk_text_iter_has_tag", candidate.rich_gtk_text_iter_has_tag);
    resolve_optional(handle, "gtk_text_iter_starts_tag", candidate.rich_gtk_text_iter_starts_tag);
    resolve_optional(handle, "gtk_text_iter_backward_to_tag_toggle", candidate.rich_gtk_text_iter_backward_to_tag_toggle);
    resolve_optional(handle, "gtk_text_iter_forward_to_tag_toggle", candidate.rich_gtk_text_iter_forward_to_tag_toggle);
    resolve_optional(handle, "gtk_text_view_window_to_buffer_coords", candidate.rich_gtk_text_view_window_to_buffer_coords);
    resolve_optional(handle, "gtk_text_view_get_iter_at_location", candidate.rich_gtk_text_view_get_iter_at_location);
    resolve_optional(handle, "g_value_init", candidate.rich_g_value_init);
    resolve_optional(handle, "g_value_unset", candidate.rich_g_value_unset);
    resolve_optional(handle, "g_value_set_string", candidate.rich_g_value_set_string);
    resolve_optional(handle, "g_value_set_int", candidate.rich_g_value_set_int);
    resolve_optional(handle, "g_value_set_boolean", candidate.rich_g_value_set_boolean);
    resolve_optional(handle, "g_value_set_double", candidate.rich_g_value_set_double);
    resolve_optional(handle, "g_value_set_enum", candidate.rich_g_value_set_enum);
    resolve_optional(handle, "g_object_set_property", candidate.rich_g_object_set_property);
    resolve_optional(handle, "g_utf8_pointer_to_offset", candidate.rich_g_utf8_pointer_to_offset);
    resolve_optional(handle, "gtk_drop_target_set_gtypes", candidate.rich_gtk_drop_target_set_gtypes);
    resolve_optional(handle, "gdk_file_list_get_type", candidate.rich_gdk_file_list_get_type);
    resolve_optional(handle, "gdk_file_list_get_files", candidate.rich_gdk_file_list_get_files);
    resolve_optional(handle, "g_value_get_boxed", candidate.rich_g_value_get_boxed);
    resolve_optional(handle, "g_type_check_value_holds", candidate.rich_g_type_check_value_holds);
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

// Optional image/file-dialog surface. Callers check availability first.
void * files_gtk_picture_new() noexcept { return g_gtk.files_gtk_picture_new(); }
void files_gtk_picture_set_paintable(void *a, void *b) noexcept { return g_gtk.files_gtk_picture_set_paintable(a,b); }
void * files_gtk_picture_get_paintable(void *a) noexcept { return g_gtk.files_gtk_picture_get_paintable(a); }
void files_gtk_picture_set_can_shrink(void *a, int b) noexcept { return g_gtk.files_gtk_picture_set_can_shrink(a,b); }
void files_gtk_picture_set_content_fit(void *a, int b) noexcept { return g_gtk.files_gtk_picture_set_content_fit(a,b); }
void files_gtk_picture_set_alternative_text(void *a, const char *b) noexcept { return g_gtk.files_gtk_picture_set_alternative_text(a,b); }
int files_gdk_paintable_get_intrinsic_width(void *a) noexcept { return g_gtk.files_gdk_paintable_get_intrinsic_width(a); }
int files_gdk_paintable_get_intrinsic_height(void *a) noexcept { return g_gtk.files_gdk_paintable_get_intrinsic_height(a); }
void * files_gdk_texture_new_from_filename(const char *a, void **b) noexcept { return g_gtk.files_gdk_texture_new_from_filename(a,b); }
void files_g_error_free(void *a) noexcept { return g_gtk.files_g_error_free(a); }
void * files_gtk_file_dialog_new() noexcept { return g_gtk.files_gtk_file_dialog_new(); }
void files_gtk_file_dialog_set_title(void *a, const char *b) noexcept { return g_gtk.files_gtk_file_dialog_set_title(a,b); }
void files_gtk_file_dialog_set_modal(void *a, int b) noexcept { return g_gtk.files_gtk_file_dialog_set_modal(a,b); }
void files_gtk_file_dialog_set_initial_folder(void *a, void *b) noexcept { return g_gtk.files_gtk_file_dialog_set_initial_folder(a,b); }
void files_gtk_file_dialog_set_initial_name(void *a, const char *b) noexcept { return g_gtk.files_gtk_file_dialog_set_initial_name(a,b); }
void files_gtk_file_dialog_set_filters(void *a, void *b) noexcept { return g_gtk.files_gtk_file_dialog_set_filters(a,b); }
unsigned int files_gtk_dialog_error_quark() noexcept { return g_gtk.files_gtk_dialog_error_quark(); }
void * files_g_cancellable_new() noexcept { return g_gtk.files_g_cancellable_new(); }
void files_g_cancellable_cancel(void *a) noexcept { return g_gtk.files_g_cancellable_cancel(a); }
void * files_g_file_new_for_path(const char *a) noexcept { return g_gtk.files_g_file_new_for_path(a); }
char * files_g_file_get_path(void *a) noexcept { return g_gtk.files_g_file_get_path(a); }
char * files_g_file_get_uri(void *a) noexcept { return g_gtk.files_g_file_get_uri ? g_gtk.files_g_file_get_uri(a) : nullptr; }
void * files_gtk_file_filter_new() noexcept { return g_gtk.files_gtk_file_filter_new(); }
std::size_t files_gtk_file_filter_get_type() noexcept { return g_gtk.files_gtk_file_filter_get_type(); }
void files_gtk_file_filter_set_name(void *a, const char *b) noexcept { return g_gtk.files_gtk_file_filter_set_name(a,b); }
void files_gtk_file_filter_add_pattern(void *a, const char *b) noexcept { return g_gtk.files_gtk_file_filter_add_pattern(a,b); }
void files_gtk_file_filter_add_mime_type(void *a, const char *b) noexcept { return g_gtk.files_gtk_file_filter_add_mime_type(a,b); }
void * files_g_list_store_new(std::size_t a) noexcept { return g_gtk.files_g_list_store_new(a); }
void files_g_list_store_append(void *a, void *b) noexcept { return g_gtk.files_g_list_store_append(a,b); }
unsigned int files_g_list_model_get_n_items(void *a) noexcept { return g_gtk.files_g_list_model_get_n_items(a); }
void * files_g_list_model_get_item(void *a, unsigned int b) noexcept { return g_gtk.files_g_list_model_get_item(a,b); }
void files_gtk_file_dialog_open(void *a, void *b, void *c, GtkAsyncReadyCallback cb, void *d) noexcept { return g_gtk.files_gtk_file_dialog_open(a,b,c,cb,d); }
void * files_gtk_file_dialog_open_finish(void *a, void *b, void **c) noexcept { return g_gtk.files_gtk_file_dialog_open_finish(a,b,c); }
void files_gtk_file_dialog_open_multiple(void *a, void *b, void *c, GtkAsyncReadyCallback cb, void *d) noexcept { return g_gtk.files_gtk_file_dialog_open_multiple(a,b,c,cb,d); }
void * files_gtk_file_dialog_open_multiple_finish(void *a, void *b, void **c) noexcept { return g_gtk.files_gtk_file_dialog_open_multiple_finish(a,b,c); }
void files_gtk_file_dialog_save(void *a, void *b, void *c, GtkAsyncReadyCallback cb, void *d) noexcept { return g_gtk.files_gtk_file_dialog_save(a,b,c,cb,d); }
void * files_gtk_file_dialog_save_finish(void *a, void *b, void **c) noexcept { return g_gtk.files_gtk_file_dialog_save_finish(a,b,c); }
bool gtk4_picture_available() noexcept { return g_gtk.files_gtk_picture_new && g_gtk.files_gtk_picture_set_paintable && g_gtk.files_gtk_picture_get_paintable && g_gtk.files_gtk_picture_set_can_shrink && g_gtk.files_gtk_picture_set_alternative_text && g_gtk.files_gdk_paintable_get_intrinsic_width && g_gtk.files_gdk_paintable_get_intrinsic_height; }
bool gtk4_texture_file_available() noexcept { return g_gtk.files_gdk_texture_new_from_filename && g_gtk.files_g_error_free; }
bool gtk4_content_fit_available() noexcept { return g_gtk.files_gtk_picture_set_content_fit; }
bool gtk4_file_dialog_available() noexcept { return g_gtk.files_gtk_file_dialog_new && g_gtk.files_gtk_file_dialog_set_title && g_gtk.files_gtk_file_dialog_set_modal && g_gtk.files_gtk_file_dialog_set_initial_folder && g_gtk.files_gtk_file_dialog_set_initial_name && g_gtk.files_gtk_file_dialog_set_filters && g_gtk.files_gtk_dialog_error_quark && g_gtk.files_g_cancellable_new && g_gtk.files_g_cancellable_cancel && g_gtk.files_g_file_new_for_path && g_gtk.files_g_file_get_path && g_gtk.files_gtk_file_filter_new && g_gtk.files_gtk_file_filter_get_type && g_gtk.files_gtk_file_filter_set_name && g_gtk.files_gtk_file_filter_add_pattern && g_gtk.files_gtk_file_filter_add_mime_type && g_gtk.files_g_list_store_new && g_gtk.files_g_list_store_append && g_gtk.files_g_list_model_get_n_items && g_gtk.files_g_list_model_get_item && g_gtk.files_gtk_file_dialog_open && g_gtk.files_gtk_file_dialog_open_finish && g_gtk.files_gtk_file_dialog_open_multiple && g_gtk.files_gtk_file_dialog_open_multiple_finish && g_gtk.files_gtk_file_dialog_save && g_gtk.files_gtk_file_dialog_save_finish && g_gtk.files_g_error_free; }
// GError has a public, stable GLib ABI.
struct FileError { unsigned int domain; int code; char *message; };
const char *gtk4_error_message(void *p) noexcept {
    auto *e = static_cast<FileError *>(p);
    return e && e->message ? e->message : "GTK error without details";
}
bool gtk4_dialog_dismissed(void *p) noexcept {
    auto *e = static_cast<FileError *>(p);
    return e && e->domain == g_gtk.files_gtk_dialog_error_quark() &&
        (e->code == 1 || e->code == 2);
}

void *gtk4_window_new() noexcept { return g_gtk.window_new(); }
void gtk4_window_set_title(void *w, const char *t) noexcept { g_gtk.window_set_title(w, t); }
void gtk4_window_set_default_size(void *w, int x, int y) noexcept { g_gtk.window_set_default_size(w, x, y); }
void gtk4_window_set_child(void *w, void *c) noexcept { g_gtk.window_set_child(w, c); }
void gtk4_window_present(void *w) noexcept { g_gtk.window_present(w); }
void gtk4_window_destroy(void *w) noexcept { g_gtk.window_destroy(w); }
void gtk4_window_set_transient_for(void *w, void *p) noexcept { g_gtk.window_set_transient_for(w, p); }
void gtk4_window_set_modal(void *w, bool v) noexcept { g_gtk.window_set_modal(w, v ? 1 : 0); }
void gtk4_window_set_icon_name(void *w, const char *n) noexcept { g_gtk.window_set_icon_name(w, n); }
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
void gtk4_text_view_set_wrap_mode(void *v, int mode) noexcept { g_gtk.text_view_set_wrap_mode(v, mode); }
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
namespace
{
constexpr unsigned int GDK_ACTION_COPY_VALUE = 1U << 0;
constexpr unsigned int GDK_ACTION_MOVE_VALUE = 1U << 1;
constexpr unsigned int GDK_ACTION_LINK_VALUE = 1U << 2;
GType gtk4_string_type() noexcept
{
    return g_gtk.type_from_name ? g_gtk.type_from_name("gchararray") : 0;
}
}
void *gtk4_drag_source_new() noexcept { return g_gtk.drag_source_new(); }
void gtk4_drag_source_set_move_action(void *source) noexcept
{ g_gtk.drag_source_set_actions(source, GDK_ACTION_MOVE_VALUE); }
void gtk4_drag_source_set_actions(void *source, unsigned int actions) noexcept
{ g_gtk.drag_source_set_actions(source, actions); }
bool gtk4_drag_source_set_widget_icon(void *source, void *widget) noexcept
{
    void *paintable = g_gtk.widget_paintable_new(widget);
    if (!paintable)
        return false;
    // GtkDragSource retains the paintable. GtkWidgetPaintable observes the
    // handle without owning it, so this does not create a widget/controller cycle.
    g_gtk.drag_source_set_icon(source, paintable, 10, 10);
    g_gtk.object_unref(paintable);
    return true;
}
bool gtk4_drag_source_set_text(void *source, const char *text) noexcept
{
    if (!text)
    {
        g_gtk.drag_source_set_content(source, nullptr);
        return true;
    }
    const GType string_type = gtk4_string_type();
    if (!string_type)
    {
        g_gtk.drag_source_set_content(source, nullptr);
        return false;
    }
    void *provider = g_gtk.content_provider_new_typed(string_type, text);
    if (!provider)
    {
        g_gtk.drag_source_set_content(source, nullptr);
        return false;
    }
    g_gtk.drag_source_set_content(source, provider);
    g_gtk.object_unref(provider);
    return true;
}
void *gtk4_drop_target_new_text_move() noexcept
{
    return gtk4_drop_target_new_text(GDK_ACTION_MOVE_VALUE);
}
void *gtk4_drop_target_new_text(unsigned int actions) noexcept
{
    const GType string_type = gtk4_string_type();
    return string_type ? g_gtk.drop_target_new(string_type, actions) : nullptr;
}
void gtk4_drop_target_set_actions(void *target, unsigned int actions) noexcept
{ g_gtk.drop_target_set_actions(target, actions); }
void gtk4_drop_target_set_preload(void *target, bool preload) noexcept
{ g_gtk.drop_target_set_preload(target, preload ? 1 : 0); }
void gtk4_drop_target_set_enabled(void *target, bool enabled) noexcept
{
    g_gtk.drop_target_set_actions(target, enabled ? GDK_ACTION_MOVE_VALUE : 0U);
    g_gtk.drop_target_set_preload(target, enabled ? 1 : 0);
}
void gtk4_drop_target_reject(void *target) noexcept
{ g_gtk.drop_target_reject(target); }
const char *gtk4_drop_target_text(void *target) noexcept
{
    const void *value = g_gtk.drop_target_get_value(target);
    return value ? g_gtk.value_get_string(value) : nullptr;
}
const char *gtk4_value_text(const void *value) noexcept
{ return value ? g_gtk.value_get_string(value) : nullptr; }
unsigned int gtk4_drag_action_copy() noexcept { return GDK_ACTION_COPY_VALUE; }
unsigned int gtk4_drag_action_move() noexcept { return GDK_ACTION_MOVE_VALUE; }
unsigned int gtk4_drag_action_link() noexcept { return GDK_ACTION_LINK_VALUE; }
void *gtk4_drop_target_drag(void *target) noexcept
{
    void *drop = g_gtk.drop_target_get_drop(target);
    return drop ? g_gtk.drop_get_drag(drop) : nullptr;
}
void *gtk4_drop_target_current_drop(void *target) noexcept
{
    return target ? g_gtk.drop_target_get_drop(target) : nullptr;
}
unsigned int gtk4_drop_target_offered_actions(void *target) noexcept
{
    void *drop = g_gtk.drop_target_get_drop(target);
    return drop ? g_gtk.drop_get_actions(drop) : 0U;
}
unsigned int gtk4_drop_target_selected_action(void *target) noexcept
{
    void *drag = gtk4_drop_target_drag(target);
    return drag ? g_gtk.drag_get_selected_action(drag) : 0U;
}
unsigned int gdk4_drag_selected_action(void *drag) noexcept
{
    return drag ? g_gtk.drag_get_selected_action(drag) : 0U;
}
bool gtk4_utf8_valid(const char *text, std::size_t length) noexcept
{
    return text && g_gtk.utf8_validate(text, static_cast<std::ptrdiff_t>(length), nullptr) != 0;
}
bool gtk4_gesture_surface_position(void *gesture, double &x, double &y) noexcept
{
    void *sequence = g_gtk.gesture_single_get_current_sequence(gesture);
    void *event = g_gtk.gesture_get_last_event(gesture, sequence);
    return event && g_gtk.gdk_event_get_position(event, &x, &y) != 0;
}
void gtk4_widget_set_size_request(void *w, int width, int height) noexcept { g_gtk.widget_set_size_request(w, width, height); }
void gtk4_widget_set_cursor_name(void *w, const char *name) noexcept { g_gtk.widget_set_cursor_from_name(w, name); }
void gtk4_widget_set_tooltip_text(void *w, const char *text) noexcept { g_gtk.widget_set_tooltip_text(w, text); }
bool gtk4_widget_grab_focus(void *w) noexcept { return g_gtk.widget_grab_focus(w) != 0; }
bool gtk4_widget_has_focus(void *w) noexcept { return g_gtk.widget_has_focus(w) != 0; }
bool gtk4_widget_get_mapped(void *w) noexcept { return w && g_gtk.widget_get_mapped(w) != 0; }
int gtk4_widget_get_width(void *w) noexcept { return g_gtk.widget_get_width(w); }
int gtk4_widget_get_height(void *w) noexcept { return g_gtk.widget_get_height(w); }
bool gtk4_widget_compute_point(void *w, void *target, double x, double y, double &out_x, double &out_y) noexcept
{
    GraphenePoint in{static_cast<float>(x), static_cast<float>(y)};
    GraphenePoint out{0.0f, 0.0f};
    if (!g_gtk.widget_compute_point(w, target, &in, &out)) return false;
    out_x = out.x; out_y = out.y; return true;
}
void *gtk4_widget_pick(void *w, double x, double y) noexcept
{
    return g_gtk.widget_pick(w, x, y, 0U);
}
void gtk4_widget_set_halign(void *w, int align) noexcept { g_gtk.widget_set_halign(w, align); }
void gtk4_widget_set_valign(void *w, int align) noexcept { g_gtk.widget_set_valign(w, align); }
void *gtk4_event_controller_motion_new() noexcept { return g_gtk.event_controller_motion_new(); }
void *gtk4_event_controller_key_new() noexcept { return g_gtk.event_controller_key_new(); }
unsigned int gtk4_event_controller_current_state(void *controller) noexcept
{
    return g_gtk.event_controller_get_current_event_state(controller);
}
void gtk4_event_controller_set_propagation_phase(void *controller, int phase) noexcept
{
    g_gtk.event_controller_set_propagation_phase(controller, phase);
}
const char *gdk4_keyval_name(unsigned int keyval) noexcept { return g_gtk.keyval_name(keyval); }

void *gtk4_box_new(int o, int s) noexcept { return g_gtk.box_new(o, s); }
void *gtk4_separator_new(int o) noexcept { return g_gtk.separator_new(o); }
void *gtk4_paned_new(int o) noexcept { return g_gtk.paned_new(o); }
void gtk4_paned_set_start_child(void *p, void *c) noexcept { g_gtk.paned_set_start_child(p, c); }
void gtk4_paned_set_end_child(void *p, void *c) noexcept { g_gtk.paned_set_end_child(p, c); }
void gtk4_paned_set_position(void *p, int v) noexcept { g_gtk.paned_set_position(p, v); }
int gtk4_paned_get_position(void *p) noexcept { return g_gtk.paned_get_position(p); }
void gtk4_paned_set_resize_start(void *p, bool v) noexcept { g_gtk.paned_set_resize_start_child(p, v ? 1 : 0); }
void gtk4_paned_set_resize_end(void *p, bool v) noexcept { g_gtk.paned_set_resize_end_child(p, v ? 1 : 0); }
void gtk4_paned_set_shrink_start(void *p, bool v) noexcept { g_gtk.paned_set_shrink_start_child(p, v ? 1 : 0); }
void gtk4_paned_set_shrink_end(void *p, bool v) noexcept { g_gtk.paned_set_shrink_end_child(p, v ? 1 : 0); }
void gtk4_paned_set_wide_handle(void *p, bool v) noexcept { g_gtk.paned_set_wide_handle(p, v ? 1 : 0); }
void gtk4_box_append(void *b, void *c) noexcept { g_gtk.box_append(b, c); }
void gtk4_box_remove(void *b, void *c) noexcept { g_gtk.box_remove(b, c); }
void gtk4_box_reorder_child_after(void *b, void *c, void *s) noexcept
{ g_gtk.box_reorder_child_after(b, c, s); }
void *gtk4_scrolled_window_new() noexcept { return g_gtk.scrolled_window_new(); }
void gtk4_scrolled_window_set_child(void *s, void *c) noexcept { g_gtk.scrolled_window_set_child(s, c); }
void *gtk4_label_new(const char *t) noexcept { return g_gtk.label_new(t); }
void *gtk4_image_new_from_icon_name(const char *n) noexcept { return g_gtk.image_new_from_icon_name(n); }
void gtk4_image_set_from_icon_name(void *i, const char *n) noexcept { g_gtk.image_set_from_icon_name(i, n); }
void gtk4_label_set_text(void *l, const char *t) noexcept { g_gtk.label_set_text(l, t); }
void gtk4_label_set_wrap(void *l, bool v) noexcept { g_gtk.label_set_wrap(l, v ? 1 : 0); }
void gtk4_label_set_wrap_mode(void *l, int m) noexcept { g_gtk.label_set_wrap_mode(l, m); }
void gtk4_label_set_xalign(void *l, float a) noexcept { g_gtk.label_set_xalign(l, a); }
void *gtk4_button_new_with_label(const char *t) noexcept { return g_gtk.button_new_with_label(t); }
void gtk4_button_set_label(void *b, const char *t) noexcept { g_gtk.button_set_label(b, t); }
void gtk4_button_set_icon_name(void *b, const char *n) noexcept { g_gtk.button_set_icon_name(b, n); }
void *gtk4_menu_button_new() noexcept { return g_gtk.menu_button_new(); }
void gtk4_menu_button_set_label(void *b, const char *t) noexcept { g_gtk.menu_button_set_label(b, t); }
void gtk4_menu_button_set_icon_name(void *b, const char *n) noexcept { g_gtk.menu_button_set_icon_name(b, n); }
void gtk4_menu_button_set_popover(void *b, void *p) noexcept { g_gtk.menu_button_set_popover(b, p); }
void gtk4_menu_button_popup(void *b) noexcept { g_gtk.menu_button_popup(b); }
void gtk4_menu_button_popdown(void *b) noexcept { g_gtk.menu_button_popdown(b); }
void *gtk4_popover_new() noexcept { return g_gtk.popover_new(); }
void gtk4_popover_set_child(void *p, void *c) noexcept { g_gtk.popover_set_child(p, c); }
void gtk4_popover_set_has_arrow(void *p, bool v) noexcept { g_gtk.popover_set_has_arrow(p, v ? 1 : 0); }
void gtk4_popover_set_autohide(void *p, bool v) noexcept { g_gtk.popover_set_autohide(p, v ? 1 : 0); }
void gtk4_popover_set_position(void *p, int v) noexcept { g_gtk.popover_set_position(p, v); }
void gtk4_popover_set_pointing_to(void *p, int x, int y, int width, int height) noexcept
{ GdkRectangle r{x, y, width, height}; g_gtk.popover_set_pointing_to(p, &r); }
void gtk4_popover_popup(void *p) noexcept { g_gtk.popover_popup(p); }
void gtk4_popover_popdown(void *p) noexcept { g_gtk.popover_popdown(p); }
void gtk4_popover_present(void *p) noexcept { g_gtk.popover_present(p); }
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
void gtk4_widget_set_parent(void *w, void *p) noexcept { g_gtk.widget_set_parent(w, p); }
void gtk4_widget_unparent(void *w) noexcept { g_gtk.widget_unparent(w); }
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


void * rich_gtk_text_tag_new(const char *a) noexcept { return g_gtk.rich_gtk_text_tag_new(a); }
void * rich_gtk_text_buffer_get_tag_table(void *a) noexcept { return g_gtk.rich_gtk_text_buffer_get_tag_table(a); }
int rich_gtk_text_tag_table_add(void *a, void *b) noexcept { return g_gtk.rich_gtk_text_tag_table_add(a, b); }
void * rich_gtk_text_tag_table_lookup(void *a, const char *b) noexcept { return g_gtk.rich_gtk_text_tag_table_lookup(a, b); }
void rich_gtk_text_buffer_get_bounds(void *a, TextIter *b, TextIter *c) noexcept { g_gtk.rich_gtk_text_buffer_get_bounds(a, b, c); }
char * rich_gtk_text_buffer_get_text(void *a, const TextIter *b, const TextIter *c, int d) noexcept { return g_gtk.rich_gtk_text_buffer_get_text(a, b, c, d); }
void rich_gtk_text_buffer_get_iter_at_offset(void *a, TextIter *b, int c) noexcept { g_gtk.rich_gtk_text_buffer_get_iter_at_offset(a, b, c); }
void rich_gtk_text_buffer_apply_tag(void *a, void *b, const TextIter *c, const TextIter *d) noexcept { g_gtk.rich_gtk_text_buffer_apply_tag(a, b, c, d); }
void rich_gtk_text_buffer_remove_tag(void *a, void *b, const TextIter *c, const TextIter *d) noexcept { g_gtk.rich_gtk_text_buffer_remove_tag(a, b, c, d); }
void rich_gtk_text_buffer_remove_all_tags(void *a, const TextIter *b, const TextIter *c) noexcept { g_gtk.rich_gtk_text_buffer_remove_all_tags(a, b, c); }
int rich_gtk_text_iter_get_offset(const TextIter *a) noexcept { return g_gtk.rich_gtk_text_iter_get_offset(a); }
int rich_gtk_text_iter_has_tag(const TextIter *a, void *b) noexcept { return g_gtk.rich_gtk_text_iter_has_tag(a, b); }
int rich_gtk_text_iter_starts_tag(const TextIter *a, void *b) noexcept { return g_gtk.rich_gtk_text_iter_starts_tag(a, b); }
int rich_gtk_text_iter_backward_to_tag_toggle(TextIter *a, void *b) noexcept { return g_gtk.rich_gtk_text_iter_backward_to_tag_toggle(a, b); }
int rich_gtk_text_iter_forward_to_tag_toggle(TextIter *a, void *b) noexcept { return g_gtk.rich_gtk_text_iter_forward_to_tag_toggle(a, b); }
void rich_gtk_text_view_window_to_buffer_coords(void *a, int b, int c, int d, int *e, int *f) noexcept { g_gtk.rich_gtk_text_view_window_to_buffer_coords(a, b, c, d, e, f); }
int rich_gtk_text_view_get_iter_at_location(void *a, TextIter *b, int c, int d) noexcept { return g_gtk.rich_gtk_text_view_get_iter_at_location(a, b, c, d); }
void * rich_g_value_init(NativeValue *a, std::size_t b) noexcept { return g_gtk.rich_g_value_init(a, b); }
void rich_g_value_unset(NativeValue *a) noexcept { g_gtk.rich_g_value_unset(a); }
void rich_g_value_set_string(NativeValue *a, const char *b) noexcept { g_gtk.rich_g_value_set_string(a, b); }
void rich_g_value_set_int(NativeValue *a, int b) noexcept { g_gtk.rich_g_value_set_int(a, b); }
void rich_g_value_set_boolean(NativeValue *a, int b) noexcept { g_gtk.rich_g_value_set_boolean(a, b); }
void rich_g_value_set_double(NativeValue *a, double b) noexcept { g_gtk.rich_g_value_set_double(a, b); }
void rich_g_value_set_enum(NativeValue *a, int b) noexcept { g_gtk.rich_g_value_set_enum(a, b); }
void rich_g_object_set_property(void *a, const char *b, const NativeValue *c) noexcept { g_gtk.rich_g_object_set_property(a, b, c); }
std::ptrdiff_t rich_g_utf8_pointer_to_offset(const char *a, const char *b) noexcept { return g_gtk.rich_g_utf8_pointer_to_offset(a, b); }
void rich_gtk_drop_target_set_gtypes(void *a, const std::size_t *b, std::size_t c) noexcept { g_gtk.rich_gtk_drop_target_set_gtypes(a, b, c); }
std::size_t rich_gdk_file_list_get_type() noexcept { return g_gtk.rich_gdk_file_list_get_type(); }
const NativeSList * rich_gdk_file_list_get_files(void *a) noexcept { return g_gtk.rich_gdk_file_list_get_files(a); }
void * rich_g_value_get_boxed(const void *a) noexcept { return g_gtk.rich_g_value_get_boxed(a); }
int rich_g_type_check_value_holds(const void *a, std::size_t b) noexcept { return g_gtk.rich_g_type_check_value_holds(a, b); }
bool gtk4_text_tags_available() noexcept { return g_gtk.rich_gtk_text_tag_new && g_gtk.rich_gtk_text_buffer_get_tag_table && g_gtk.rich_gtk_text_tag_table_add && g_gtk.rich_gtk_text_tag_table_lookup && g_gtk.rich_gtk_text_buffer_get_bounds && g_gtk.rich_gtk_text_buffer_get_text && g_gtk.rich_gtk_text_buffer_get_iter_at_offset && g_gtk.rich_gtk_text_buffer_apply_tag && g_gtk.rich_gtk_text_buffer_remove_tag && g_gtk.rich_gtk_text_buffer_remove_all_tags && g_gtk.rich_gtk_text_iter_get_offset && g_gtk.rich_gtk_text_iter_has_tag && g_gtk.rich_gtk_text_iter_starts_tag && g_gtk.rich_gtk_text_iter_backward_to_tag_toggle && g_gtk.rich_gtk_text_iter_forward_to_tag_toggle && g_gtk.rich_gtk_text_view_window_to_buffer_coords && g_gtk.rich_gtk_text_view_get_iter_at_location && g_gtk.rich_g_value_init && g_gtk.rich_g_value_unset && g_gtk.rich_g_value_set_string && g_gtk.rich_g_value_set_int && g_gtk.rich_g_value_set_boolean && g_gtk.rich_g_value_set_double && g_gtk.rich_g_value_set_enum && g_gtk.rich_g_object_set_property && g_gtk.rich_g_utf8_pointer_to_offset; }
bool gtk4_drop_files_available() noexcept { return g_gtk.rich_gtk_drop_target_set_gtypes && g_gtk.rich_gdk_file_list_get_type && g_gtk.rich_gdk_file_list_get_files && g_gtk.rich_g_value_get_boxed && g_gtk.rich_g_type_check_value_holds && g_gtk.files_g_file_get_path; }
std::size_t rich_type_from_name(const char *s) noexcept { return g_gtk.type_from_name(s); }
const void *rich_drop_value(void *t) noexcept { return g_gtk.drop_target_get_value(t); }
bool rich_value_holds(const void *v, std::size_t type) noexcept { return v && g_gtk.rich_g_type_check_value_holds && g_gtk.rich_g_type_check_value_holds(v, type); }
void rich_set_drop_types(void *t, bool text, bool files) noexcept { if (!g_gtk.rich_gtk_drop_target_set_gtypes) return; std::size_t types[2]; std::size_t n=0; if(files) types[n++]=g_gtk.rich_gdk_file_list_get_type(); if(text) types[n++]=g_gtk.type_from_name("gchararray"); g_gtk.rich_gtk_drop_target_set_gtypes(t, types, n); }

} // namespace babet_gui::detail
