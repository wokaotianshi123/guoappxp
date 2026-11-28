#ifndef JHPYBRIDGE_H
#define JHPYBRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Plain-C shim over the CPython C API. Swift in this pod cannot
 * `import Python`: BeeWare's Python.framework ships no module map and
 * CocoaPods does not resolve the vendored framework as a Swift module
 * for the pod's own target (verified in CI, runs 40037627474 /
 * 40039135049). The C compiler resolves <Python/Python.h> through the
 * framework search path, so all PyObject handling lives in JHPyBridge.c
 * and Swift only sees C strings. */

/* Starts the interpreter (once), appends host_dir and vendor_dir to
 * sys.path when non-NULL, and imports py_spider_host.
 * Returns 0 on success, -2 when the interpreter failed to initialize,
 * -1 on a Python error (message written to errbuf). */
int jhpy_start(const char *host_dir, const char *vendor_dir, char *errbuf, unsigned long errbuf_len);

int jhpy_is_initialized(void);

/* Borrowed pointer to static storage; do not free. */
const char *jhpy_version(void);

/* Calls a host function with string arguments. On success returns a
 * malloc'd UTF-8 string (release with jhpy_free). On failure returns
 * NULL and sets *err_kind: 1 = Python error (errbuf filled),
 * 2 = host function missing, 3 = non-string return value. */
char *jhpy_call(const char *function, const char *const *args, int argc,
                char *errbuf, unsigned long errbuf_len, int *err_kind);

int jhpy_module_available(const char *name);

void jhpy_free(char *p);

#ifdef __cplusplus
}
#endif

#endif /* JHPYBRIDGE_H */
