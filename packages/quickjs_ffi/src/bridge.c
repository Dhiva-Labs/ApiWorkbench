/*
 * A small C surface over QuickJS-ng for Dart FFI.
 *
 * One handle is one runtime with one context. Values cross the boundary as
 * UTF-8 JSON text only, so Dart never holds a JSValue. quickjs-libc (the
 * std and os modules) is not built in: scripts get the ECMAScript built-ins
 * plus whatever the host evaluates into the context, nothing that touches
 * files, processes or the network.
 *
 * Every entry point re-reads the stack top because the Dart isolate that
 * drives a handle may run on a different OS thread from call to call.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#define AWQ_API __declspec(dllexport)
#else
#include <time.h>
#define AWQ_API __attribute__((visibility("default")))
#endif

#include "quickjs.h"

#define AWQ_VERSION 1

/* Status codes written to *status. */
#define AWQ_OK 0
#define AWQ_EXCEPTION 1
#define AWQ_INTERRUPTED 2

typedef struct {
  char *name;
  const uint8_t *bytecode; /* owned by the caller, must outlive the handle */
  size_t length;
} awq_module;

typedef struct {
  JSRuntime *rt;
  JSContext *ctx;
  int64_t deadline_ms; /* monotonic; 0 = no deadline */
  int interrupted;
  awq_module *modules;
  int module_count;
  int module_capacity;
} awq;

static int64_t awq_now_ms(void) {
#if defined(_WIN32)
  return (int64_t)GetTickCount64();
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

static int awq_interrupt(JSRuntime *rt, void *opaque) {
  awq *h = (awq *)opaque;
  (void)rt;
  if (h->deadline_ms > 0 && awq_now_ms() >= h->deadline_ms) {
    h->interrupted = 1;
    return 1;
  }
  return 0;
}

static char *awq_strdup_len(const char *s, size_t len) {
  char *out = (char *)malloc(len + 1);
  if (!out) return NULL;
  memcpy(out, s, len);
  out[len] = 0;
  return out;
}

static char *awq_strdup(const char *s) { return awq_strdup_len(s, strlen(s)); }

/* "Name: message" plus the stack, for the pending exception. */
static char *awq_take_exception(awq *h, int32_t *status) {
  JSContext *ctx = h->ctx;
  JSValue exc = JS_GetException(ctx);
  char *out = NULL;
  *status = h->interrupted ? AWQ_INTERRUPTED : AWQ_EXCEPTION;
  if (JS_IsError(exc)) {
    JSValue name = JS_GetPropertyStr(ctx, exc, "name");
    JSValue message = JS_GetPropertyStr(ctx, exc, "message");
    JSValue stack = JS_GetPropertyStr(ctx, exc, "stack");
    const char *n = JS_IsUndefined(name) ? NULL : JS_ToCString(ctx, name);
    const char *m = JS_IsUndefined(message) ? NULL : JS_ToCString(ctx, message);
    const char *s = JS_IsString(stack) ? JS_ToCString(ctx, stack) : NULL;
    size_t len = (n ? strlen(n) : 5) + (m ? strlen(m) : 0) + (s ? strlen(s) : 0) + 4;
    out = (char *)malloc(len);
    if (out) {
      strcpy(out, n ? n : "Error");
      if (m && *m) {
        strcat(out, ": ");
        strcat(out, m);
      }
      if (s && *s) {
        strcat(out, "\n");
        strcat(out, s);
      }
    }
    if (n) JS_FreeCString(ctx, n);
    if (m) JS_FreeCString(ctx, m);
    if (s) JS_FreeCString(ctx, s);
    JS_FreeValue(ctx, name);
    JS_FreeValue(ctx, message);
    JS_FreeValue(ctx, stack);
  } else if (JS_IsNull(exc) && !h->interrupted) {
    /* QuickJS throws null when it can't even allocate the error object for
       "out of memory". */
    out = awq_strdup("InternalError: out of memory");
  } else {
    size_t len;
    const char *str = JS_ToCStringLen(ctx, &len, exc);
    if (str) {
      out = awq_strdup_len(str, len);
      JS_FreeCString(ctx, str);
    } else {
      JS_FreeValue(ctx, JS_GetException(ctx));
    }
  }
  JS_FreeValue(ctx, exc);
  return out ? out : awq_strdup("Error: unknown exception");
}

/* JSON text of [val] (consumed); "null" for undefined and functions. */
static char *awq_to_json(awq *h, JSValue val, int32_t *status) {
  JSContext *ctx = h->ctx;
  JSValue json = JS_JSONStringify(ctx, val, JS_UNDEFINED, JS_UNDEFINED);
  JS_FreeValue(ctx, val);
  if (JS_IsException(json)) return awq_take_exception(h, status);
  if (JS_IsUndefined(json)) {
    *status = AWQ_OK;
    return awq_strdup("null");
  }
  size_t len;
  const char *str = JS_ToCStringLen(ctx, &len, json);
  JS_FreeValue(ctx, json);
  if (!str) return awq_take_exception(h, status);
  char *out = awq_strdup_len(str, len);
  JS_FreeCString(ctx, str);
  *status = AWQ_OK;
  return out;
}

static void awq_enter(awq *h) {
  JS_UpdateStackTop(h->rt);
  h->interrupted = 0;
}

/* __awLoad(name): instantiates a module registered with awq_add_module and
 * returns its completion value (the module's factory function). */
static JSValue awq_js_load(JSContext *ctx, JSValueConst this_val, int argc,
                           JSValueConst *argv) {
  awq *h = (awq *)JS_GetContextOpaque(ctx);
  (void)this_val;
  if (argc < 1) return JS_ThrowTypeError(ctx, "module name expected");
  const char *name = JS_ToCString(ctx, argv[0]);
  if (!name) return JS_EXCEPTION;
  for (int i = 0; i < h->module_count; i++) {
    if (strcmp(h->modules[i].name, name) == 0) {
      JS_FreeCString(ctx, name);
      JSValue fn = JS_ReadObject(ctx, h->modules[i].bytecode,
                                 h->modules[i].length, JS_READ_OBJ_BYTECODE);
      if (JS_IsException(fn)) return fn;
      return JS_EvalFunction(ctx, fn);
    }
  }
  JSValue err = JS_ThrowReferenceError(ctx, "Cannot find module '%s'", name);
  JS_FreeCString(ctx, name);
  return err;
}

/* Interface version, so a stale library is refused rather than misused. */
AWQ_API int32_t awq_version(void) { return AWQ_VERSION; }

/* A new runtime and context. [memory_limit] and [stack_size] are bytes; 0
 * keeps QuickJS's default. Returns NULL when out of memory. */
AWQ_API void *awq_new(int64_t memory_limit, int64_t stack_size) {
  awq *h = (awq *)calloc(1, sizeof(awq));
  if (!h) return NULL;
  h->rt = JS_NewRuntime();
  if (!h->rt) {
    free(h);
    return NULL;
  }
  if (memory_limit > 0) JS_SetMemoryLimit(h->rt, (size_t)memory_limit);
  if (stack_size > 0) JS_SetMaxStackSize(h->rt, (size_t)stack_size);
  JS_UpdateStackTop(h->rt);
  JS_SetInterruptHandler(h->rt, awq_interrupt, h);
  h->ctx = JS_NewContext(h->rt);
  if (!h->ctx) {
    JS_FreeRuntime(h->rt);
    free(h);
    return NULL;
  }
  JS_SetContextOpaque(h->ctx, h);
  JSValue global = JS_GetGlobalObject(h->ctx);
  JS_SetPropertyStr(h->ctx, global, "__awLoad",
                    JS_NewCFunction(h->ctx, awq_js_load, "__awLoad", 1));
  JS_FreeValue(h->ctx, global);
  return h;
}

AWQ_API void awq_free(void *handle) {
  awq *h = (awq *)handle;
  if (!h) return;
  JS_UpdateStackTop(h->rt);
  JS_FreeContext(h->ctx);
  JS_FreeRuntime(h->rt);
  for (int i = 0; i < h->module_count; i++) free(h->modules[i].name);
  free(h->modules);
  free(h);
}

/* Interrupts evaluation [timeout_ms] from now; 0 or less clears it. */
AWQ_API void awq_set_deadline(void *handle, int64_t timeout_ms) {
  awq *h = (awq *)handle;
  h->deadline_ms = timeout_ms > 0 ? awq_now_ms() + timeout_ms : 0;
}

/* Evaluates [code] as a global script. Returns the completion value as JSON
 * with *status 0, or the exception text with *status 1 (2 when the deadline
 * interrupted it). Free the result with awq_free_buffer. */
AWQ_API char *awq_eval(void *handle, const char *code, int64_t length,
                       const char *filename, int32_t *status) {
  awq *h = (awq *)handle;
  awq_enter(h);
  JSValue val = JS_Eval(h->ctx, code, (size_t)length, filename,
                        JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(val)) return awq_take_exception(h, status);
  return awq_to_json(h, val, status);
}

/* Runs pending promise jobs until none is left. Returns NULL with *status 0,
 * or the exception text of a job that failed outright (a deadline). */
AWQ_API char *awq_run_jobs(void *handle, int32_t *status) {
  awq *h = (awq *)handle;
  awq_enter(h);
  for (;;) {
    JSContext *job_ctx;
    int r = JS_ExecutePendingJob(h->rt, &job_ctx);
    if (r == 0) break;
    if (r < 0) return awq_take_exception(h, status);
  }
  *status = AWQ_OK;
  return NULL;
}

/* Compiles [code] (a global script) to bytecode without running it, for
 * awq_add_module. Returns the bytecode with its size in *length and *status
 * 0, or a syntax error's text with *status 1. Free with awq_free_buffer. */
AWQ_API uint8_t *awq_compile(void *handle, const char *code, int64_t length,
                             const char *filename, int32_t strip_source,
                             int64_t *out_length, int32_t *status) {
  awq *h = (awq *)handle;
  awq_enter(h);
  JSValue fn = JS_Eval(h->ctx, code, (size_t)length, filename,
                       JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
  if (JS_IsException(fn)) {
    *out_length = 0;
    return (uint8_t *)awq_take_exception(h, status);
  }
  size_t size = 0;
  int flags = JS_WRITE_OBJ_BYTECODE;
  if (strip_source) flags |= JS_WRITE_OBJ_STRIP_SOURCE;
  uint8_t *buf = JS_WriteObject(h->ctx, &size, fn, flags);
  JS_FreeValue(h->ctx, fn);
  if (!buf) {
    *out_length = 0;
    return (uint8_t *)awq_take_exception(h, status);
  }
  /* Hand out malloc memory so awq_free_buffer works for every result. */
  uint8_t *out = (uint8_t *)malloc(size);
  if (out) memcpy(out, buf, size);
  js_free(h->ctx, buf);
  *out_length = out ? (int64_t)size : 0;
  *status = out ? AWQ_OK : AWQ_EXCEPTION;
  return out;
}

/* Makes bytecode from awq_compile loadable as __awLoad(name). The buffer is
 * not copied: it must stay valid until awq_free. */
AWQ_API int32_t awq_add_module(void *handle, const char *name,
                               const uint8_t *bytecode, int64_t length) {
  awq *h = (awq *)handle;
  if (h->module_count == h->module_capacity) {
    int cap = h->module_capacity ? h->module_capacity * 2 : 16;
    awq_module *m = (awq_module *)realloc(h->modules, cap * sizeof(awq_module));
    if (!m) return 0;
    h->modules = m;
    h->module_capacity = cap;
  }
  char *copy = awq_strdup(name);
  if (!copy) return 0;
  h->modules[h->module_count].name = copy;
  h->modules[h->module_count].bytecode = bytecode;
  h->modules[h->module_count].length = (size_t)length;
  h->module_count++;
  return 1;
}

AWQ_API void awq_free_buffer(void *buffer) { free(buffer); }
