/* Native tag storage and external file-list fixture. No binding implementation
   is reused: iterators use character offsets, applications use a bitmap. */
typedef struct RichIter {
    void *dummy1,*dummy2;
    int dummy3,dummy4,dummy5,dummy6,dummy7,dummy8;
    void *dummy9,*dummy10;
    int dummy11,dummy12,dummy13;
    void *dummy14;
} RichIter;
typedef struct RichValue {
    size_t type;
    union { int i; unsigned u; long l; unsigned long ul; long long i64;
        unsigned long long u64; float f; double d; void *p; } data[2];
} RichValue;
typedef struct RichList { void *data; struct RichList *next; } RichList;
static size_t rich_chars(const char *s) {
    size_t n=0;for(;*s;++s) if(((unsigned char)*s & 0xc0)!=0x80) ++n;return n;
}
static size_t rich_byte(const char *s,int n) {
    size_t i=0;while(n>0 && s[i]) { ++i;while(s[i] && ((unsigned char)s[i]&0xc0)==0x80) ++i;--n; }return i;
}
static char *rich_copy(const char *s,size_t n) {
    char *r=(char*)malloc(n+1);if(!r) abort();memcpy(r,s,n);r[n]=0;
#ifdef BABET_FAKE_GTK_OOM_PROBE
    ++owned_text_copies;
#endif
    return r;
}
#ifndef BABET_FAKE_GTK_NO_TEXT_TAGS
void *gtk_text_tag_new(const char *name) {
    if(getenv("BABET_FAKE_GTK_TAG_FAIL")) return NULL;
    FakeWidget *t=make_widget(60,name);if(t)t->floating=0;return t;
}
#endif
void *gtk_text_buffer_get_tag_table(void *b) {return b;}
void *gtk_text_tag_table_lookup(void *p,const char *name) {
    FakeWidget *b=p;for(size_t i=0;i<b->rich_tag_count;++i) if(!strcmp(b->rich_tags[i]->text,name))return b->rich_tags[i];return NULL;
}
int gtk_text_tag_table_add(void *p,void *tag) {
    FakeWidget *b=p,*t=tag;
    if(getenv("BABET_FAKE_GTK_TAG_ADD_FAIL") || b->rich_tag_count==32 || gtk_text_tag_table_lookup(b,t->text))return 0;
    b->rich_tags[b->rich_tag_count++]=t;++t->refs;return 1;
}
void gtk_text_buffer_get_iter_at_offset(void *p,RichIter *i,int offset) {
    memset(i,0,sizeof(*i));i->dummy1=p;i->dummy3=offset;
}
void gtk_text_buffer_get_bounds(void *p,RichIter *a,RichIter *b) {
    gtk_text_buffer_get_iter_at_offset(p,a,0);gtk_text_buffer_get_iter_at_offset(p,b,(int)rich_chars(((FakeWidget*)p)->text));
}
char *gtk_text_buffer_get_text(void *p,const RichIter *a,const RichIter *b,int hidden) {
    (void)hidden;const char *s=((FakeWidget*)p)->text;size_t first=rich_byte(s,a->dummy3),last=rich_byte(s,b->dummy3);return rich_copy(s+first,last-first);
}
int gtk_text_iter_get_offset(const RichIter *i) {return i->dummy3;}
static int rich_slot(FakeWidget *b,void *tag) {
    for(size_t j=0;j<b->rich_tag_count;++j) if(b->rich_tags[j]==tag)return (int)j;
    abort();
}
static void rich_change(void *p,void *tag,const RichIter *a,const RichIter *z,int active) {
    FakeWidget *b=p;int slot=rich_slot(b,tag);size_t n=rich_chars(b->text);
    if(!b->rich_marks[slot]) b->rich_marks[slot]=calloc(n+1,1);
    if(a->dummy3<0 || z->dummy3<a->dummy3 || (size_t)z->dummy3>n)abort();
    for(int i=a->dummy3;i<z->dummy3;++i)b->rich_marks[slot][i]=(unsigned char)active;
}
void gtk_text_buffer_apply_tag(void *p,void *t,const RichIter *a,const RichIter *b) {rich_change(p,t,a,b,1);}
void gtk_text_buffer_remove_tag(void *p,void *t,const RichIter *a,const RichIter *b) {rich_change(p,t,a,b,0);}
void gtk_text_buffer_remove_all_tags(void *p,const RichIter *a,const RichIter *b) {
    FakeWidget *w=p;for(size_t j=0;j<w->rich_tag_count;++j)rich_change(p,w->rich_tags[j],a,b,0);
}
int gtk_text_iter_has_tag(const RichIter *i,void *t) {
    FakeWidget *b=i->dummy1;int slot=rich_slot(b,t);return i->dummy3>=0 && (size_t)i->dummy3<rich_chars(b->text) && b->rich_marks[slot] && b->rich_marks[slot][i->dummy3];
}
int gtk_text_iter_starts_tag(const RichIter *i,void *t) {
    RichIter prev=*i;--prev.dummy3;return gtk_text_iter_has_tag(i,t) && !gtk_text_iter_has_tag(&prev,t);
}
int gtk_text_iter_backward_to_tag_toggle(RichIter *i,void *t) {
    while(i->dummy3>0) {--i->dummy3;RichIter prev=*i;--prev.dummy3;if(gtk_text_iter_has_tag(i,t)!=gtk_text_iter_has_tag(&prev,t)) return 1;}return 0;
}
int gtk_text_iter_forward_to_tag_toggle(RichIter *i,void *t) {
    int n=(int)rich_chars(((FakeWidget*)i->dummy1)->text);
    while(i->dummy3<n) {++i->dummy3;RichIter prev=*i;--prev.dummy3;if(gtk_text_iter_has_tag(i,t)!=gtk_text_iter_has_tag(&prev,t)) return 1;}return 0;
}
void gtk_text_view_window_to_buffer_coords(void *p,int window,int x,int y,int *bx,int *by) {
    (void)p;if(window!=1)abort();*bx=x-3;*by=y-5;
}
int gtk_text_view_get_iter_at_location(void *p,RichIter *i,int x,int y) {
    FakeWidget *b=gtk_text_view_get_buffer(p);if(x<0 || y<0 || y>=16 || x/8>=(int)rich_chars(b->text))return 0;
    gtk_text_buffer_get_iter_at_offset(b,i,x/8);return 1;
}
long g_utf8_pointer_to_offset(const char *s,const char *end) {
    long n=0;for(;s<end;++s)if(((unsigned char)*s&0xc0)!=0x80)++n;return n;
}
void *g_value_init(RichValue *v,size_t t) {memset(v,0,sizeof(*v));v->type=t;return v;}
void g_value_unset(RichValue *v) {if(v->type==64)g_free(v->data[0].p);memset(v,0,sizeof(*v));}
void g_value_set_string(RichValue *v,const char *s) {if(v->type!=64)abort();v->data[0].p=rich_copy(s,strlen(s));}
void g_value_set_int(RichValue *v,int n) {if(v->type!=24)abort();v->data[0].i=n;}
void g_value_set_boolean(RichValue *v,int n) {if(v->type!=20)abort();v->data[0].i=n;}
void g_value_set_enum(RichValue *v,int n) {if(v->type!=300 && v->type!=301)abort();v->data[0].i=n;}
void g_value_set_double(RichValue *v,double n) {if(v->type!=60)abort();v->data[0].d=n;}
void g_object_set_property(void *p,const char *key,const RichValue *v) {
    if(((FakeWidget*)p)->kind!=60)abort();
    char text[128];
    if(!strcmp(key,"foreground") || !strcmp(key,"background")) {if(v->type!=64)abort();snprintf(text,sizeof(text),"%s=%s",key,(char*)v->data[0].p);}
    else if(!strcmp(key,"scale")) {if(v->type!=60)abort();snprintf(text,sizeof(text),"%s=%.2f",key,v->data[0].d);}
    else {size_t type=!strcmp(key,"weight")?24:!strcmp(key,"strikethrough")?20:!strcmp(key,"underline")?300:301;if(v->type!=type)abort();snprintf(text,sizeof(text),"%s=%d",key,v->data[0].i);}
    log_line("tag-property:",text);
}
#ifndef BABET_FAKE_GTK_NO_FILE_DROP
size_t gdk_file_list_get_type(void) {return 600;}
#endif
void *g_value_get_boxed(const void *v) {return ((const FakeValue*)v)->files;}
int g_type_check_value_holds(const void *v,size_t type) {return type==600 ? ((const FakeValue*)v)->files!=NULL : type==64 && ((const FakeValue*)v)->text!=NULL;}
RichList *gdk_file_list_get_files(void *list) {return list;}
void gtk_drop_target_set_gtypes(void *p,const size_t *types,size_t n) {
    FakeWidget *w=p;w->rich_drop_types=0;
    for(size_t i=0;i<n;++i){if(types[i]==64)w->rich_drop_types|=1;else if(types[i]==600)w->rich_drop_types|=2;else abort();}
    /* GtkDropTarget keeps the first configured GType offered by the drop, and
       a GdkFileList source is also serialized as text/plain. */
    if(n==2 && types[0]==64)w->rich_drop_types|=4;
}
static int rich_files_emitted;
/* External drop over nested targets. GTK sends one status per event: the first
   accepting target, ancestors first for enter, descendants first for motion.
   The drop itself goes to the deepest target, even if it refused hover. */
static int rich_emit_nested_files(void) {
    FakeWidget *chain[MAX_WIDGETS];size_t n=0;
    for(size_t i=0;i<widget_count && n<2;++i) {
        FakeWidget *c=widgets[i];
        if(!c || !c->alive || c->kind!=23 || !c->dnd_cb[3] || !c->parent) continue;
        n=0;
        for(FakeWidget *w=c->parent;w;w=w->parent)
            for(size_t j=0;j<widget_count;++j) {
                FakeWidget *d=widgets[j];
                if(d && d->alive && d->kind==23 && d->dnd_cb[3] && d->parent==w) chain[n++]=d;
            }
    }
    if(n<2) {log_line("files:filtered",NULL);return 1;}
    FakeWidget *pins[MAX_WIDGETS];size_t count=0;
    for(size_t k=0;k<n;++k) dnd_pin_path(pins,&count,chain[k]);
    FakeWidget *files[2];files[0]=g_file_new_for_path("/tmp/image é.png");files[1]=g_file_new_for_path("/tmp/second.png");
    RichList nodes[2]={{files[0],&nodes[1]},{files[1],NULL}};
    for(size_t k=0;k<n;++k) {
        chain[k]->dnd_source=NULL;chain[k]->dnd_external=1;chain[k]->dnd_active=1;chain[k]->dnd_value.files=nodes;
    }
    unsigned int status=0;
    for(size_t k=n;k>0;--k) {
        FakeWidget *t=chain[k-1];
        if(t->alive && t->dnd_active && t->dnd_cb[0]) {
            const unsigned int a=as_drop_motion_signal(t->dnd_cb[0])(t,12,18,t->dnd_data[0]);
            if(a && !status) status=a;
        }
    }
    /* On X11, a drop right after entering the toplevel has no motion window. */
    if(!getenv("BABET_FAKE_GTK_DROP_ENTER_ONLY")) status=0; /* motion replaces enter */
    for(size_t k=0;k<n && !getenv("BABET_FAKE_GTK_DROP_ENTER_ONLY");++k) {
        FakeWidget *t=chain[k];
        if(t->alive && t->dnd_active && t->dnd_cb[1]) {
            const unsigned int a=as_drop_motion_signal(t->dnd_cb[1])(t,12,18,t->dnd_data[1]);
            if(a && !status) status=a;
        }
    }
    log_line("files:negotiated:",fake_action_name(status));
    FakeWidget *deepest=chain[0];int accepted=0;
    if(status && deepest->alive && deepest->dnd_active && deepest->dnd_cb[3]) {
        deepest->dnd_in_drop=1;
        accepted=as_drop_signal(deepest->dnd_cb[3])(deepest,&deepest->dnd_value,12,18,deepest->dnd_data[3]);
        deepest->dnd_in_drop=0;
    }
    log_line(accepted?"files:accepted":"files:refused",NULL);
    for(size_t k=0;k<n;++k) {chain[k]->dnd_value.files=NULL;chain[k]->dnd_active=0;chain[k]->dnd_external=0;}
    for(int j=0;j<2;++j)g_object_unref(files[j]);
    while(count)g_object_unref(pins[--count]);
    return 1;
}
static int rich_emit_files(void) {
    if(rich_files_emitted)return 0;
    rich_files_emitted=1;
    if(getenv("BABET_FAKE_GTK_DROP_NESTED")) return rich_emit_nested_files();
    FakeWidget *target=NULL;
    for(size_t i=0;i<widget_count;++i)if(widgets[i] && widgets[i]->alive && widgets[i]->kind==23 && widgets[i]->dnd_cb[3]) {target=widgets[i];break;}
    if(!target || !(target->rich_drop_types&2)) {log_line("files:filtered",NULL);return 1;}
    FakeWidget *pins[MAX_WIDGETS];size_t count=0;
    dnd_pin_path(pins,&count,target);
    FakeWidget *files[3];files[0]=g_file_new_for_path(getenv("BABET_FAKE_GTK_REMOTE_FILES")?"https://example.org/first":"/tmp/image é.png");
    files[1]=g_file_new_for_path("https://example.org/ignored");files[2]=g_file_new_for_path(getenv("BABET_FAKE_GTK_REMOTE_FILES")?"sftp://host/file":"/tmp/second.png");
    RichList nodes[3]={{files[0],&nodes[1]},{files[1],&nodes[2]},{files[2],NULL}};
    target->dnd_source=NULL;target->dnd_external=1; /* external application: no GdkDrag */
    const int as_text=(target->rich_drop_types&4)!=0;
    char text[]="/tmp/image \xc3\xa9.png\n/tmp/second.png";
    target->dnd_active=1;target->dnd_value.files=getenv("BABET_FAKE_GTK_DELAY_FILES")||as_text?NULL:nodes;
    if(as_text && !getenv("BABET_FAKE_GTK_DELAY_FILES"))target->dnd_value.text=text;
    unsigned int action=0;
    for(int phase=0;phase<2 && target->alive && target->dnd_active;++phase) {
        if(target->dnd_cb[phase]) action=as_drop_motion_signal(target->dnd_cb[phase])(target,12,18,target->dnd_data[phase]);
    }
    if(as_text)target->dnd_value.text=text;else target->dnd_value.files=nodes;
    int accepted=0;
    if(action && target->alive && target->dnd_active && target->dnd_cb[3]) {
        target->dnd_in_drop=1;accepted=as_drop_signal(target->dnd_cb[3])(target,&target->dnd_value,12,18,target->dnd_data[3]);target->dnd_in_drop=0;
    }
    log_line(accepted?"files:accepted":"files:refused",NULL);
    target->dnd_value.files=NULL;target->dnd_value.text=NULL;target->dnd_active=0;target->dnd_external=0;
    for(int j=0;j<3;++j)g_object_unref(files[j]);
    while(count)g_object_unref(pins[--count]);
    return 1;
}
void babet_fake_gtk_emit_files(void) {(void)rich_emit_files();}
void babet_fake_gtk_reset_files(void) {rich_files_emitted=0;}
