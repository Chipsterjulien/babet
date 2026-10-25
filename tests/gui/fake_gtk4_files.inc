/* Optional GTK4 image/FileDialog surface with real ownership and queued completion. */
typedef struct FileError { unsigned int domain; int code; char *message; } FileError;
static size_t file_errors;
size_t babet_fake_gtk_file_errors(void) { return file_errors; }
static void file_error(void **out, int code, const char *message)
{
    FileError *e = (FileError *)calloc(1, sizeof(*e));
    e->domain = 733; e->code = code;
    e->message = (char *)malloc(strlen(message) + 1); strcpy(e->message, message);
    *out = e; ++file_errors;
}
void g_error_free(void *p)
{
    if (!p) return;
    FileError *e = (FileError *)p; free(e->message); free(e); --file_errors;
}
static FakeWidget *file_object(int kind, const char *text)
{
    const char *fail = getenv("BABET_FAKE_GTK_FILE_FAIL");
    if (fail && atoi(fail) == kind) return NULL;
    FakeWidget *w = make_widget(kind, text);
    if (w && kind != 40) w->floating = 0;
    return w;
}
static void file_hold(void *p, unsigned int slot, void *value)
{
    FakeWidget *w = (FakeWidget *)p, *v = (FakeWidget *)value;
    if (v) ++v->refs;
    if (w->file_owned[slot]) g_object_unref(w->file_owned[slot]);
    w->file_owned[slot] = v;
}
void *gtk_picture_new(void) { return file_object(40, NULL); }
void gtk_picture_set_paintable(void *p, void *v) { file_hold(p, 0, v); }
void *gtk_picture_get_paintable(void *p) { return ((FakeWidget *)p)->file_owned[0]; }
void gtk_picture_set_can_shrink(void *p, int v) { ((FakeWidget *)p)->editable = v; }
#ifndef BABET_FAKE_GTK_NO_CONTENT_FIT
void gtk_picture_set_content_fit(void *p, int v) { ((FakeWidget *)p)->expanded = v; }
#endif
void gtk_picture_set_alternative_text(void *p, const char *s) { set_text(p, s ? s : ""); }
int gdk_paintable_get_intrinsic_width(void *p) { return ((FakeWidget *)p)->width; }
int gdk_paintable_get_intrinsic_height(void *p) { return ((FakeWidget *)p)->height; }
#ifndef BABET_FAKE_GTK_NO_TEXTURE_FILE
void *gdk_texture_new_from_filename(const char *path, void **error)
{
    unsigned char bytes[24];
    FILE *f = fopen(path, "rb");
    size_t n = f ? fread(bytes, 1, 24, f) : 0;
    if (f) fclose(f);
    if (n != 24 || memcmp(bytes, "\x89PNG\r\n\x1a\n", 8)) { file_error(error, 0, "image illisible"); return NULL; }
    FakeWidget *w = file_object(41, NULL);
    if (!w) { file_error(error, 0, "texture indisponible"); return NULL; }
    w->width = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    w->height = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    return w;
}
#endif
#ifndef BABET_FAKE_GTK_NO_FILE_DIALOG
void *gtk_file_dialog_new(void) { return file_object(42, NULL); }
#endif
void gtk_file_dialog_set_title(void *p, const char *s) { set_text(p, s); log_line("file-title:", s); }
void gtk_file_dialog_set_modal(void *p, int b) { ((FakeWidget *)p)->editable = b; log_line("file-modal:", b ? "true" : "false"); }
void gtk_file_dialog_set_initial_folder(void *p, void *f) { file_hold(p, 0, f); log_line("file-folder:", ((FakeWidget *)f)->text); }
void gtk_file_dialog_set_initial_name(void *p, const char *s) { (void)p; log_line("file-name:", s); }
void gtk_file_dialog_set_filters(void *p, void *f) { file_hold(p, 1, f); }
unsigned int gtk_dialog_error_quark(void) { return 733; }
void *g_cancellable_new(void) { return file_object(43, NULL); }
void g_cancellable_cancel(void *p) { ((FakeWidget *)p)->clicked = 1; log_line("file-cancel", NULL); }
void *g_file_new_for_path(const char *p) { return file_object(44, p); }
char *g_file_get_path(void *p)
{
    FakeWidget *w = (FakeWidget *)p;
    if (strstr(w->text, "://")) return NULL;
    size_t n = strlen(w->text);
    char *copy = (char *)malloc(n + 2);
    if (w->text[0] == '/') strcpy(copy, w->text);
    else { copy[0] = '/'; strcpy(copy + 1, w->text); }
#ifdef BABET_FAKE_GTK_OOM_PROBE
    ++owned_text_copies;
#endif
    return copy;
}
char *g_file_get_uri(void *p)
{
    FakeWidget *w = (FakeWidget *)p;
    const int remote = strstr(w->text, "://") != NULL;
    char *copy = (char *)malloc(strlen(w->text) + 8);
    if (!copy) return NULL;
    if (remote) strcpy(copy, w->text);
    else { strcpy(copy, "file://"); strcat(copy, w->text); }
#ifdef BABET_FAKE_GTK_OOM_PROBE
    ++owned_text_copies;
#endif
    return copy;
}
void *gtk_file_filter_new(void) { return file_object(45, NULL); }
size_t gtk_file_filter_get_type(void) { return 45; }
void gtk_file_filter_set_name(void *p, const char *s) { set_text(p, s); log_line("filter-name:", s); }
void gtk_file_filter_add_pattern(void *p, const char *s) { (void)p; log_line("filter-pattern:", s); }
void gtk_file_filter_add_mime_type(void *p, const char *s) { (void)p; log_line("filter-mime:", s); }
void *g_list_store_new(size_t type) { (void)type; return file_object(46, NULL); }
void g_list_store_append(void *p, void *item)
{
    FakeWidget *w = p, *v = item;
    if (w->file_count == 64) abort();
    ++v->refs; w->file_items[w->file_count++] = v;
}
unsigned int g_list_model_get_n_items(void *p) { return ((FakeWidget *)p)->file_count; }
void *g_list_model_get_item(void *p, unsigned int i)
{ FakeWidget *v = ((FakeWidget *)p)->file_items[i]; ++v->refs; return v; }
typedef void (*FileReady)(void *, void *, void *);
typedef struct FileRequest { FakeWidget *source, *cancel; FileReady cb; void *data; int mode; struct FileRequest *next; } FileRequest;
static FileRequest *file_requests;
static void file_start(void *p, void *parent, void *cancel, FileReady cb, void *data, int mode)
{
    (void)parent;
    FileRequest *r = (FileRequest *)calloc(1, sizeof(*r));
    r->source = p; r->cancel = cancel; ++r->source->refs; ++r->cancel->refs;
    r->cb = cb; r->data = data; r->mode = mode; r->next = file_requests; file_requests = r;
    log_line("file-start:", mode == 2 ? "save" : mode == 1 ? "multiple" : "open");
}
void gtk_file_dialog_open(void *p, void *parent, void *c, FileReady cb, void *d) { file_start(p,parent,c,cb,d,0); }
void gtk_file_dialog_open_multiple(void *p, void *parent, void *c, FileReady cb, void *d) { file_start(p,parent,c,cb,d,1); }
void gtk_file_dialog_save(void *p, void *parent, void *c, FileReady cb, void *d) { file_start(p,parent,c,cb,d,2); }
static void *file_finish(void *p, void *result, void **error)
{
    (void)p; FileRequest *r = result;
    const char *mode = getenv("BABET_FAKE_GTK_FILE_RESULT");
    if (r->cancel->clicked || (mode && !strcmp(mode, "cancel"))) { file_error(error, 2, "annulé"); return NULL; }
    if (mode && !strcmp(mode, "error")) { file_error(error, 0, "échec injecté"); return NULL; }
    const char *name = mode && !strcmp(mode, "remote") ? "sftp://host/a.png" : "/tmp/été image.png";
    if (r->mode != 1) return file_object(44, name);
    FakeWidget *list = file_object(46, NULL);
    FakeWidget *a = file_object(44, name), *b = file_object(44, mode && !strcmp(mode, "mixed") ? "sftp://host/b.png" : "/tmp/b.png");
    g_list_store_append(list, a); g_list_store_append(list, b); g_object_unref(a); g_object_unref(b);
    return list;
}
void *gtk_file_dialog_open_finish(void *p, void *r, void **e) { return file_finish(p,r,e); }
void *gtk_file_dialog_open_multiple_finish(void *p, void *r, void **e) { return file_finish(p,r,e); }
void *gtk_file_dialog_save_finish(void *p, void *r, void **e) { return file_finish(p,r,e); }
static int file_complete_one(void)
{
    FileRequest **next = &file_requests;
    while (*next && getenv("BABET_FAKE_GTK_FILE_HOLD") && !(*next)->cancel->clicked) next = &(*next)->next;
    FileRequest *r = *next;
    if (!r) return 0;
    *next = r->next;
    r->cb(r->source, r, r->data);
    g_object_unref(r->source); g_object_unref(r->cancel); free(r);
    log_line("file-complete", NULL); return 1;
}
