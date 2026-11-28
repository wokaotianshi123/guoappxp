#include "JHPyBridge.h"

#include "Python.h"

#include <stdlib.h>
#include <string.h>

static PyObject *jhpy_host_module = NULL;
static int jhpy_started = 0;

static void jhpy_set_err(char *errbuf, unsigned long errbuf_len, const char *msg) {
  if (errbuf == NULL || errbuf_len == 0) return;
  strncpy(errbuf, msg != NULL ? msg : "", errbuf_len - 1);
  errbuf[errbuf_len - 1] = '\0';
}

static void jhpy_fetch_error(char *errbuf, unsigned long errbuf_len) {
  PyObject *type = NULL, *value = NULL, *traceback = NULL;
  PyErr_Fetch(&type, &value, &traceback);
  PyErr_NormalizeException(&type, &value, &traceback);
  const char *msg = NULL;
  PyObject *text = NULL;
  if (value != NULL) {
    text = PyObject_Str(value);
    if (text != NULL) {
      msg = PyUnicode_AsUTF8(text);
      if (msg == NULL) PyErr_Clear();
    }
  }
  jhpy_set_err(errbuf, errbuf_len, msg != NULL ? msg : "Python error");
  Py_XDECREF(text);
  Py_XDECREF(type);
  Py_XDECREF(value);
  Py_XDECREF(traceback);
}

static int jhpy_append_path(const char *dir, char *errbuf, unsigned long errbuf_len) {
  if (dir == NULL || dir[0] == '\0') return 0;
  PyObject *sys_module = PyImport_ImportModule("sys");
  PyObject *path = sys_module != NULL ? PyObject_GetAttrString(sys_module, "path") : NULL;
  PyObject *entry = path != NULL ? PyUnicode_FromString(dir) : NULL;
  if (path == NULL || entry == NULL) {
    jhpy_fetch_error(errbuf, errbuf_len);
    Py_XDECREF(sys_module);
    Py_XDECREF(path);
    Py_XDECREF(entry);
    return -1;
  }
  int appended = PyList_Append(path, entry);
  Py_DECREF(entry);
  Py_DECREF(path);
  Py_DECREF(sys_module);
  if (appended != 0 || PyErr_Occurred() != NULL) {
    jhpy_fetch_error(errbuf, errbuf_len);
    return -1;
  }
  return 0;
}

int jhpy_start(const char *host_dir, const char *vendor_dir, char *errbuf, unsigned long errbuf_len) {
  if (jhpy_started) return 0;
  Py_Initialize();
  if (!Py_IsInitialized()) {
    jhpy_set_err(errbuf, errbuf_len, "CPython initialize failed");
    return -2;
  }
  int rc = 0;
  if (jhpy_append_path(host_dir, errbuf, errbuf_len) != 0) {
    rc = -1;
  } else if (jhpy_append_path(vendor_dir, errbuf, errbuf_len) != 0) {
    rc = -1;
  }
  if (rc == 0) {
    PyObject *module = PyImport_ImportModule("py_spider_host");
    if (module == NULL) {
      jhpy_fetch_error(errbuf, errbuf_len);
      rc = -1;
    } else {
      jhpy_host_module = module;
      jhpy_started = 1;
    }
  }
  /* Release the GIL and unbind the initializing thread's state; later
   * calls re-acquire with PyGILState_Ensure/Release pairs because the
   * serial queue does not guarantee a fixed OS thread. This must happen
   * on failure exits too: returning with the GIL still held would wedge
   * every later call on another queue thread. */
  PyEval_SaveThread();
  return rc;
}

int jhpy_is_initialized(void) { return jhpy_started && Py_IsInitialized() != 0; }

const char *jhpy_version(void) { return Py_GetVersion(); }

char *jhpy_call(const char *function, const char *const *args, int argc,
                char *errbuf, unsigned long errbuf_len, int *err_kind) {
  if (err_kind != NULL) *err_kind = 1;
  if (!jhpy_started || jhpy_host_module == NULL) {
    jhpy_set_err(errbuf, errbuf_len, "runtime not started");
    return NULL;
  }
  PyGILState_STATE state = PyGILState_Ensure();
  PyObject *callable = PyObject_GetAttrString(jhpy_host_module, function);
  if (callable == NULL) {
    PyErr_Clear();
    PyGILState_Release(state);
    if (err_kind != NULL) *err_kind = 2;
    return NULL;
  }
  PyObject *tuple = PyTuple_New(argc);
  if (tuple == NULL) {
    jhpy_fetch_error(errbuf, errbuf_len);
    Py_DECREF(callable);
    PyGILState_Release(state);
    return NULL;
  }
  for (int i = 0; i < argc; i++) {
    PyObject *item = PyUnicode_FromString(args[i] != NULL ? args[i] : "");
    if (item == NULL) {
      jhpy_fetch_error(errbuf, errbuf_len);
      Py_DECREF(tuple);
      Py_DECREF(callable);
      PyGILState_Release(state);
      return NULL;
    }
    PyTuple_SetItem(tuple, i, item);
  }
  PyObject *result = PyObject_CallObject(callable, tuple);
  Py_DECREF(tuple);
  Py_DECREF(callable);
  if (result == NULL) {
    jhpy_fetch_error(errbuf, errbuf_len);
    PyGILState_Release(state);
    if (err_kind != NULL) *err_kind = 1;
    return NULL;
  }
  const char *utf8 = PyUnicode_AsUTF8(result);
  if (utf8 == NULL) {
    Py_DECREF(result);
    PyErr_Clear();
    PyGILState_Release(state);
    if (err_kind != NULL) *err_kind = 3;
    return NULL;
  }
  char *copy = strdup(utf8);
  Py_DECREF(result);
  PyGILState_Release(state);
  return copy;
}

int jhpy_module_available(const char *name) {
  if (!jhpy_started) return 0;
  PyGILState_STATE state = PyGILState_Ensure();
  PyObject *module = PyImport_ImportModule(name);
  if (module == NULL) {
    PyErr_Clear();
    PyGILState_Release(state);
    return 0;
  }
  Py_DECREF(module);
  PyGILState_Release(state);
  return 1;
}

void jhpy_free(char *p) { free(p); }
