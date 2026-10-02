typedef __SIZE_TYPE__ size_t;
typedef __UINTPTR_TYPE__ uintptr_t;
typedef __UINT32_TYPE__ uint32_t;
typedef __UINT64_TYPE__ uint64_t;
typedef __INT64_TYPE__ int64_t;
typedef signed long ssize_t;

#ifndef GLOW_LATE_LOADER_DIAGNOSTICS
#define GLOW_LATE_LOADER_DIAGNOSTICS 0
#endif

#define IN_CODE __attribute__((used, section("__TEXT,__glow_code")))
/*
 * Modern Apple Clang rejects C functions and C data declarations forced into
 * the same custom Mach-O section because it assigns them different section
 * attributes. Emit the strings with inline assembler instead. Hidden symbols
 * keep references direct so the patcher still receives PAGE21/PAGEOFF12
 * relocations within __glow_code.
 */
#define STR(name, value) \
    enum { name##_len = sizeof(value) - 1 }; \
    extern const char name[] __attribute__((visibility("hidden"))); \
    __asm__(".section __TEXT,__glow_code,regular,pure_instructions\n" \
            ".private_extern _" #name "\n" \
            "_" #name ":\n" \
            ".asciz " #value "\n")
#define SYMBOL(type, name) ((type)dlsym((void *)-2, name))
#define PATH_MAX 1024
#define F_OK 0
#define RTLD_NOW 2
#define RTLD_LOCAL 4
#define DISPATCH_TIME_NOW 0

extern void *dlsym(void *, const char *);

typedef void *(*malloc_fn)(size_t);
typedef uint32_t (*image_count_fn)(void);
typedef const char *(*image_name_fn)(uint32_t);
typedef uint64_t (*dispatch_time_fn)(uint64_t, int64_t);
typedef void (*dispatch_after_f_fn)(uint64_t, void *, void *, void (*)(void *));
typedef int (*dladdr_fn)(const void *, void *);
typedef void *(*dlopen_fn)(const char *, int);
typedef int (*access_fn)(const char *, int);

typedef struct {
    const char *dli_fname;
    void *dli_fbase;
    const char *dli_sname;
    void *dli_saddr;
} Dl_info_compat;

IN_CODE void glow_late_initializer(void);

STR(kMalloc, "malloc");
STR(kDispatchAfterF, "dispatch_after_f");
STR(kDispatchTime, "dispatch_time");
STR(kDispatchMainQ, "_dispatch_main_q");
STR(kDyldImageCount, "_dyld_image_count");
STR(kDyldGetImageName, "_dyld_get_image_name");
STR(kDladdr, "dladdr");
STR(kDlopen, "dlopen");
STR(kAccess, "access");
STR(kFacebookName, "Facebook");
STR(kGlowName, "Glow.dylib");
STR(kCompatName, "GlowCompat.dylib");
STR(kFrameworks, "Frameworks/GlowCompat.dylib");

#if GLOW_LATE_LOADER_DIAGNOSTICS
typedef char *(*getenv_fn)(const char *);
typedef int (*open_fn)(const char *, int, int);
typedef ssize_t (*write_fn)(int, const void *, size_t);
typedef int (*close_fn)(int);
typedef const char *(*dlerror_fn)(void);

#define O_WRONLY 1
#define O_CREAT 0x200
#define O_TRUNC 0x400
#define STATUS(value) write_diag_file(kStatusName, kStatusName_len, value, value##_len)

STR(kGetenv, "getenv");
STR(kOpen, "open");
STR(kWrite, "write");
STR(kClose, "close");
STR(kTmpdir, "TMPDIR");
STR(kDlerror, "dlerror");
STR(kStatusName, "GlowLateLoader-G2.status");
STR(kErrorName, "GlowLateLoader-G2.error");
STR(kInitializerExecuted, "INITIALIZER_EXECUTED");
STR(kCallbackExecuted, "CALLBACK_EXECUTED");
STR(kDispatchMissing, "DISPATCH_API_MISSING");
STR(kAllocFailed, "ALLOC_FAILED");
STR(kDyldMissing, "DYLD_API_MISSING");
STR(kGlowMissing, "GLOW_MISSING");
STR(kGlowPresent, "GLOW_PRESENT");
STR(kFacebookPathFailed, "FACEBOOK_PATH_FAILED");
STR(kFacebookPathOK, "FACEBOOK_PATH_OK");
STR(kCompatMissing, "COMPAT_MISSING");
STR(kCompatPresent, "COMPAT_PRESENT");
STR(kCompatAlreadyLoaded, "COMPAT_ALREADY_LOADED");
STR(kCompatNotLoaded, "COMPAT_NOT_LOADED");
STR(kDlopenBegin, "DLOPEN_BEGIN");
STR(kDlopenFailed, "DLOPEN_FAILED");
STR(kDlopenSuccess, "DLOPEN_SUCCESS");
STR(kNewline, "\n");

IN_CODE static size_t bounded_length(const char *s, size_t limit) {
    size_t n = 0;
    if (!s) return limit;
    while (n < limit && s[n]) ++n;
    return n;
}

IN_CODE static void write_diag_file(const char *name, size_t name_len,
                                    const char *payload, size_t payload_len) {
    getenv_fn get_env = SYMBOL(getenv_fn, kGetenv);
    open_fn open_file = SYMBOL(open_fn, kOpen);
    write_fn write_file = SYMBOL(write_fn, kWrite);
    close_fn close_file = SYMBOL(close_fn, kClose);
    if (!get_env || !open_file || !write_file || !close_file) return;

    const char *tmp = get_env(kTmpdir);
    size_t tmp_len = bounded_length(tmp, PATH_MAX);
    if (!tmp_len || tmp_len >= PATH_MAX) return;

    char path[PATH_MAX];
    size_t pos = 0;
    for (size_t i = 0; i < tmp_len; ++i) path[pos++] = tmp[i];
    if (path[pos - 1] != '/') path[pos++] = '/';
    if (pos + name_len >= PATH_MAX) return;
    for (size_t i = 0; i < name_len; ++i) path[pos++] = name[i];
    path[pos] = 0;

    int fd = open_file(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;
    if (payload_len) write_file(fd, payload, payload_len);
    write_file(fd, kNewline, 1);
    close_file(fd);
}
#else
#define STATUS(value) ((void)0)
#endif

IN_CODE static int same_text(const char *a, const char *b) {
    size_t i = 0;
    while (a[i] && b[i] && a[i] == b[i]) ++i;
    return a[i] == 0 && b[i] == 0;
}

IN_CODE static int image_is_loaded(const char *wanted) {
    image_count_fn count_images = SYMBOL(image_count_fn, kDyldImageCount);
    image_name_fn image_name = SYMBOL(image_name_fn, kDyldGetImageName);
    if (!count_images || !image_name) return -1;

    uint32_t count = count_images();
    for (uint32_t i = 0; i < count; ++i) {
        const char *path = image_name(i);
        if (!path) continue;
        size_t end = 0;
        while (end < PATH_MAX && path[end]) ++end;
        if (end == PATH_MAX) continue;
        size_t start = end;
        while (start && path[start - 1] != '/') --start;
        if (same_text(path + start, wanted)) return 1;
    }
    return 0;
}

IN_CODE static int facebook_compat_path(char *out, size_t cap) {
    Dl_info_compat info;
    dladdr_fn get_info = SYMBOL(dladdr_fn, kDladdr);
    if (!get_info || !get_info((const void *)(uintptr_t)&glow_late_initializer, &info) ||
        !info.dli_fname) return 0;

    size_t len = 0;
    while (len < PATH_MAX && info.dli_fname[len]) ++len;
    if (!len || len == PATH_MAX) return 0;
    size_t slash = len;
    while (slash && info.dli_fname[slash - 1] != '/') --slash;
    if (!slash || !same_text(info.dli_fname + slash, kFacebookName)) return 0;

    size_t tail_len = kFrameworks_len;
    if (slash + tail_len + 1 > cap) return 0;
    size_t pos = 0;
    while (pos < slash) {
        out[pos] = info.dli_fname[pos];
        ++pos;
    }
    for (size_t i = 0; i < tail_len; ++i) out[pos++] = kFrameworks[i];
    out[pos] = 0;
    return 1;
}

IN_CODE static void glow_late_callback(void *context) {
    volatile unsigned char *guard = (volatile unsigned char *)context;
    if (!guard || *guard) return;
    *guard = 1;
    STATUS(kCallbackExecuted);

    int glow = image_is_loaded(kGlowName);
    if (glow < 0) { STATUS(kDyldMissing); return; }
    if (!glow) { STATUS(kGlowMissing); return; }
    STATUS(kGlowPresent);

    char compat_path[PATH_MAX];
    if (!facebook_compat_path(compat_path, sizeof(compat_path))) {
        STATUS(kFacebookPathFailed);
        return;
    }
    STATUS(kFacebookPathOK);

    access_fn access_file = SYMBOL(access_fn, kAccess);
    if (!access_file) { STATUS(kCompatMissing); return; }
    if (access_file(compat_path, F_OK) != 0) { STATUS(kCompatMissing); return; }
    STATUS(kCompatPresent);

    int compat = image_is_loaded(kCompatName);
    if (compat < 0) { STATUS(kDyldMissing); return; }
    if (compat) { STATUS(kCompatAlreadyLoaded); return; }
    STATUS(kCompatNotLoaded);

    dlopen_fn load_image = SYMBOL(dlopen_fn, kDlopen);
    if (!load_image) { STATUS(kDlopenFailed); return; }
    STATUS(kDlopenBegin);
    void *handle = load_image(compat_path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
#if GLOW_LATE_LOADER_DIAGNOSTICS
        dlerror_fn get_error = SYMBOL(dlerror_fn, kDlerror);
        const char *error = get_error ? get_error() : 0;
        size_t error_len = bounded_length(error, 256);
        if (error && error_len && error_len < 256)
            write_diag_file(kErrorName, kErrorName_len, error, error_len);
#endif
        STATUS(kDlopenFailed);
        return;
    }
    STATUS(kDlopenSuccess);
}

IN_CODE void glow_late_initializer(void) {
    STATUS(kInitializerExecuted);

    malloc_fn allocate = SYMBOL(malloc_fn, kMalloc);
    dispatch_after_f_fn after = SYMBOL(dispatch_after_f_fn, kDispatchAfterF);
    dispatch_time_fn time_after = SYMBOL(dispatch_time_fn, kDispatchTime);
    void *main_queue = dlsym((void *)-2, kDispatchMainQ);
    if (!allocate || !after || !time_after || !main_queue) {
        STATUS(kDispatchMissing);
        return;
    }

    unsigned char *guard = (unsigned char *)allocate(1);
    if (!guard) { STATUS(kAllocFailed); return; }
    *guard = 0;
    uint64_t when = time_after(DISPATCH_TIME_NOW, 500000000LL);
    after(when, main_queue, guard, glow_late_callback);
}
