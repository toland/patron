# Patron modernization plan (C bindings for Ruby 3.3+)

Status: phases 0 through 4 landed together in the `hypermodernization` branch (the Patron 1.0 PR).
Phase 5 (Fiber scheduler integration, multiplexed concurrent transfers) remains future work.

Date: 2026-10-27. Basis: the Ruby core doc "Tips for updating Ruby C extensions for
efficiently using Ruby 4 VM APIs" (`doc/efficient_extensions.md` in ruby/ruby, which is
what Ivo Anjo's 2026-09-23 post points at), four parallel audits of this repo
(VM/GC audit of `session_ext.c`, libcurl API audit, Ruby-side/build/test survey,
Ruby 3.3..4.1 C-API research), and the headers of the installed Rubies (3.3.12, 4.0.9).

## 0. Decisions

| Decision | Choice | Why |
|---|---|---|
| Minimum Ruby | **3.3** (`required_ruby_version = ">= 3.3"`) | 3.3 is the oldest branch still receiving patches (security-only since 2026-04-01, EOL expected 2027-03-31). 3.4 and 4.0 are in normal maintenance. |
| Rubies in CI | 3.3, 3.4, 4.0, head (allow-failure) on ubuntu + macOS | Drop 2.4 and 3.0 from the matrix. |
| Minimum libcurl | **7.81.0** (`LIBCURL_VERSION_NUM >= 0x075100`), enforced in extconf | Ubuntu 22.04. Everything we need (curl_mime, XFERINFOFUNCTION, `_LARGE` options, multi_poll/wakeup, HTTP/3 enum, CA/cert blobs) predates it. Announce 8.5 (Ubuntu 24.04) as the floor for the release after April 2027. |
| Keep `TypedData`, keep a separately allocated struct, **no** `RUBY_TYPED_EMBEDDABLE` | Yes | libcurl holds raw pointers into the struct (WRITEDATA, HEADERDATA, XFERINFODATA, ERRORBUFFER) for the object's lifetime and writes through them without the GVL. An embedded struct moves under compaction. Document this in a comment next to the type. |
| Marking | Declarative (`RUBY_REFERENCES` + `RUBY_TYPED_DECL_MARKING`) | Available since 3.3. No `dmark`/`dcompact` to keep in sync; the GC handles compaction itself. |
| GVL | Keep `curl_easy_perform` without the GVL in phase 1 and 2; move to `curl_multi_poll` + `curl_multi_wakeup` in phase 4 | Instant interruption and no progress-callback hack, no public API change. Fiber scheduler integration is a later, separate design. |
| `RB_NOGVL_OFFLOAD_SAFE` | **Off** | The progress callback calls `rb_thread_call_with_gvl`, which exits the process with `[BUG]` if the scheduler offloads the function to a non-Ruby thread. Revisit only after phase 4 removes the callback. |
| Version | 1.0.0 | Floors change, SSLv2/3 go away, Request marshalling changes. README already describes "1.0 and up" semantics. |

## 1. What is wrong today (prioritised)

Line numbers refer to `ext/patron/session_ext.c` on master (commit 1d75870).

### P0. Memory safety and undefined behaviour

1. **Request body pointer into a temporary String** (460-476, 793-800). `state->upload_buf = StringValuePtr(data)` where `data = rb_funcall(obj, to_s)`. For a String argument `to_s` returns self and `Request#upload_data` keeps it alive, but for anything else it is a fresh String referenced only by a C local that is gone before `perform_request` runs. `CURLOPT_POSTFIELDS` does not copy. Use-after-free during the no-GVL transfer.
2. **`curl_formadd` with `CURLFORM_PTRNAME`/`CURLFORM_PTRCONTENTS` of temporaries** (384-403). Same class of bug, plus `PTRCONTENTS` stops at the first NUL byte, plus the whole API is deprecated since libcurl 7.56 (GCC 12+ warns on every use).
3. **Exceptions from the progress Proc longjmp through libcurl frames** (78-88, 107). `rb_funcall` inside `rb_thread_call_with_gvl` inside a libcurl callback. `ruby/thread.h` says this "yields whatever fatal undefined behaviours". Covers `raise`, `Thread#raise`, `Timeout`, `Thread#kill`.
4. **Two threads on one Session corrupt memory** (510, 389, 906). Thread A drops the GVL inside perform; thread B overwrites `state->handle`, appends to `state->headers`, and both transfers write into the same membuffers. The `CURLSH` share also has no lock callbacks. The README says "not thread safe" but the failure mode is corruption, not an error.
5. **Wrong callback prototype** (96, 246). `CURLOPT_XFERINFOFUNCTION` takes four `curl_off_t`; the code declares four `size_t`. Works by accident on LP64, UB everywhere, wrong on ILP32. The `CURLOPT_PROGRESSFUNCTION` fallback (248) passes doubles into it.

### P1. VM mechanical sympathy and robustness

6. `rb_data_type_t` lacks `RUBY_TYPED_WB_PROTECTED` (212): every Session is permanently in the remembered set and rescanned on every minor GC.
7. `rb_gc_mark` pins the progress Proc; no `dcompact` (200, 211).
8. The at-exit interrupt machinery (`cs_list`, `rb_set_end_proc`, `sglib.h`, 129-167, 1054) is redundant: at exit the VM calls every blocked thread's ubf, which sets the same flag. It costs an unlocked global list (blocks `rb_ext_ractor_safe`, races during Ractor-local sweeps), one `xmalloc` per Session, and 1952 lines of `sglib.h` for three macros.
9. No `rb_ext_ractor_safe(true)`: every Patron method call pays a `rb_ractor_main_p()` guard, and nothing works from a non-main Ractor.
10. `rb_thread_call_without_gvl` without flags (906). The ubf only stores an int, so it is async-signal-safe and should be declared so with `rb_nogvl(..., RB_NOGVL_UBF_ASYNC_SAFE)`.
11. `interrupt` is a plain `int` written by other threads and the ubf (45): data race in the C sense. `volatile sig_atomic_t` or C11 `_Atomic`.
12. The progress callback re-acquires the GVL on every XFERINFO tick (107). A CPU-busy sibling thread throttles downloads to one chunk per GVL handoff.
13. `ruby_xrealloc` from the write callback runs without the GVL (membuffer.c `membuffer_ensure_capacity`). Works, but means GC can be triggered from inside libcurl's write path and OOM longjmps through libcurl. The `NULL` check is dead code.
14. `membuffer_clear` memsets the whole capacity on every request; capacity never shrinks (a Session that once downloaded 1 GiB holds it until GC).
15. Numeric conversions: `FIX2INT(download_byte_limit)` into `size_t` (519, raises above 2 GiB), `FIX2INT`/`FIX2LONG` on values that may be Float or Bignum (655, 660, 665, 670), `LONG2NUM(size_t)` (83-86), `(int) RSTRING_LEN` (317, 349).
16. `curl_easy_setopt` return codes never checked. `CURL_SSLVERSION_SSLv2`/`SSLv3` (709, 711) are refused by modern libcurl, so the request silently proceeds with default TLS.
17. `RSTRING_PTR` used as a C string without NUL guarantee (1013, 1031, 431); `curl_easy_escape`/`unescape` NULL return unchecked and `unescape` truncates at NUL (303-361).
18. `curl_easy_init`/`curl_share_init` return values unchecked (230, 236).
19. Deprecated libcurl options: `CURLOPT_PROTOCOLS`/`REDIR_PROTOCOLS` (255-256, deprecated 7.85), `CURLOPT_ENCODING` fallback, `CURLOPT_PROGRESSFUNCTION` fallback. GCC 12+ warns; a `-Werror` CI job fails.
20. `CURLOPT_READDATA` with a `FILE*` but no `CURLOPT_READFUNCTION` (444): curl docs require the callback on Windows (CRT boundary), same reason the write callback is set.

### P2. Cleanups

21. `void Init_session_ext()` → `(void)`; `session_alloc` and `session_ubf_abort` should be `static`; missing explicit `<string.h>`, `<stdio.h>`; `membuffer.h` uses `VALUE` without including `ruby.h`.
22. ~35 `rb_intern("...")` per request (cached by the GCC/clang macro, not on MSVC); `rb_iv_set(…, "@timings")`; `rb_str_new2` literals per call ("Accept-Encoding", ": ", "gzip"); `rb_funcall(value, include?)`; header-name comparison is case-sensitive.
23. `rb_ary_new3(2, self, request)` allocated per request just to feed `rb_ensure`.
24. Error objects carry only `error_buf`; `error_buf` may be empty; no curl code.
25. `extconf.rb`: `-pedantic` produces 160+ warnings from Ruby 4's own headers and hides the one real one; curl-config path skips header/link verification and overrides `--with-curl-dir`; no floor check.
26. Repo: `lib/patron/proxy_type.rb` is dead and would `NameError` if required; `.travis.yml`, `.autotest`; `pic.png` at root; `*.so` not gitignored; gemspec ships test private keys, has `bindir "exe"` with no exe, `ext` in `require_paths`, stale post-install message; no `frozen_string_literal` anywhere; `webrick` required by three specs but never used; test server readback goes through YAML + OpenStruct.

## 2. Phases

Each phase is one PR (or a short PR stack), green on the full matrix before the next starts. Phase 0 and 1 are prerequisites for everything else; 2 and 3 are independent of each other; 4 depends on 1 and 2.

### Phase 0: Floors, build, CI, repo hygiene

Goal: make the compiler and CI tell us the truth before we touch the C.

- gemspec: `required_ruby_version = ">= 3.3"`; drop `required_rubygems_version`, the `respond_to?(:metadata)` block, `allowed_push_host`, `bindir`/`executables`, `platform`, post-install message; explicit `spec.files` (`lib/**/*.rb`, `ext/**/*.{c,h,rb}`, README, CHANGELOG, LICENSE); `require_paths = ["lib"]`; metadata (`source_code_uri`, `changelog_uri`, `bug_tracker_uri`, `rubygems_mfa_required`); decide on authors/maintainer fields.
- `extconf.rb` rewrite:
  1. `dir_config('curl')`; if `--with-curl-dir/-include/-lib` given, honour them and skip discovery; else `pkg_config('libcurl')`; else `curl-config`; else `have_library('curl')`.
  2. Always `have_header('curl/curl.h')` and `have_library('curl', 'curl_easy_init')` after flags are set; abort with a clear message.
  3. Floor check: `try_compile` on `#if LIBCURL_VERSION_NUM < 0x075100 #error` and abort with the version found.
  4. Optional-feature probes via `have_const`/`have_func` so the C can `#ifdef HAVE_*`: `CURLOPT_PROTOCOLS_STR` (7.85), `curl_easy_header` (7.83), `CURL_HTTP_VERSION_3` runtime-gated, `CURLOPT_CA_CACHE_TIMEOUT` (7.87), `CURL_VERSION_THREADSAFE`.
  5. Flags: `append_cflags(%w[-Wall -Wextra -Wno-unused-parameter -Werror=implicit-function-declaration -Werror=incompatible-pointer-types])`. Drop `-pedantic` and `-Wno-void-pointer-to-enum-cast`. `--enable-werror` for CI.
- Delete `#if LIBCURL_VERSION_NUM` / `#ifdef CURLOPT_*` ladders in the C that are dead at 7.81 (244-249, 251/257, 375-382, 419-423, 447-451, 565-572, 609-613, 626-633, 715-730, 747-764). Keep one guard for `curl_easy_escape(NULL, …)` (7.82) and the `HAVE_*` probes above.
- Repo: delete `lib/patron/proxy_type.rb`, `.travis.yml`, `.autotest`; move `pic.png` to `spec/support/`; `.gitignore` adds `*.so *.o *.dll lib/patron/session_ext.* .claude/settings.local.json`; `.rspec` gets `--require spec_helper`; `# frozen_string_literal: true` everywhere; freeze `VALID_ACTIONS`, `READER_VARS`, `WRITER_VARS`, `VERSION`; dependabot for bundler.
- CI matrix (`ci.yml`):
  - `test`: `{ubuntu-latest, macos-15} × {3.3, 3.4, 4.0, head}`; macOS uses Homebrew curl via `--with-curl-dir=$(brew --prefix curl)` so TLS tests run against OpenSSL, not SecureTransport.
  - `werror`: compile-only with `--enable-werror` on ubuntu (GCC, emits `CURL_DEPRECATED`) and macOS (clang). This job fails until phase 1 lands; that is its purpose.
  - `old-libcurl`: `container: ruby:3.3-bookworm` (libcurl 7.88) and, if obtainable, a 7.81 image (ubuntu:22.04 + a Ruby 3.3 build); `ruby:3.3-alpine` for musl and the no-curl-config path.
  - `gc-stress`: ubuntu, Ruby 3.4, `PATRON_GC_STRESS=1` (see phase 3 for what that enables).
  - `asan`: compile the extension with `-fsanitize=address -fno-omit-frame-pointer -g`, run with `LD_PRELOAD=libasan.so ASAN_OPTIONS=detect_leaks=0`; `continue-on-error` initially.
  - `gem`: `gem build` + `gem install ./patron-*.gem` + `yard --fail-on-warning`.
- README: Ruby/libcurl requirements, remove the `curl-openssl` Homebrew section, hash-rocket examples → modern syntax, thread-safety wording.

Acceptance: full matrix green except `werror`; `gem install` of the built gem works; `rake compile` under Ruby 4.0.9 shows only Patron-origin warnings.

### Phase 1: Correctness fixes in `session_ext.c`

Each item is a separately reviewable commit with a spec.

1. **Hold the request body VALUE.** Add `VALUE upload_data` to `struct patron_curl_state`; `set_request_body` stores it with `RB_OBJ_WRITE` (phase 2 adds the flag that makes this matter, but write it this way now); add to the reference list; `cleanup` resets it to `Qnil`. Hoist the DELETE-with-body path (793-800) into `set_request_body` so it gets `POSTFIELDSIZE_LARGE`. Do not use `CURLOPT_COPYPOSTFIELDS` (doubles memory for large bodies). Spec: POST with an object whose `to_s` builds a new String, run with `GC.stress` around `handle_request`.
2. **`curl_formadd` → `curl_mime`.** `curl_mime_init(handle)`, `curl_mime_addpart`, `curl_mime_name` + `curl_mime_data(part, ptr, RSTRING_LEN)` (binary-safe, copies), `curl_mime_filedata` for files, `CURLOPT_MIMEPOST`, `curl_mime_free` in `cleanup`. Replace `curl_httppost *post, *last` with `curl_mime *mime`. This also lifts the "Multipart PUT not supported" restriction (594). Spec: multipart body assertions through `RawRequestCapture` (boundary, filename, a value containing `\0`, Symbol keys).
3. **Protect the progress Proc.** `rb_protect` around `rb_proc_call`; on non-zero tag store it in `state->pending_tag` (and `rb_errinfo()` for `TAG_RAISE`), set `interrupt = INTERRUPT_ABORT`, return non-zero so libcurl aborts with `CURLE_ABORTED_BY_CALLBACK`. After `rb_nogvl` returns and C cleanup ran, `rb_jump_tag(tag)` (this is also how `Thread#kill`'s `TAG_FATAL` must be propagated; never swallow it). Give the Proc's return value meaning: `false`/`nil` aborts (closes the old TODO at 104). Spec: Proc raises → exception propagates, Session usable afterwards; Proc returns false → `Patron::Aborted`; `Timeout.timeout` around a slow download with a progress Proc.
4. **Busy flag.** `volatile sig_atomic_t busy` set at the top of `session_handle_request`, cleared in `cleanup`; raise `Patron::Error` ("Session is already performing a request in another thread; use one Session per thread") if already set. Also register `CURLSHOPT_LOCKFUNC`/`UNLOCKFUNC` with a `pthread_mutex_t` array (plain mutexes, called without the GVL, never Ruby API) so the share is correct for the phase 4 design. Spec: two threads on one Session → one raises, no crash.
5. **Fix the xferinfo prototype**: `curl_off_t` parameters, `curl_off_t` fields in the struct, `LL2NUM` for the Proc arguments. Delete the `PROGRESSFUNCTION` fallback. Rename `CURLOPT_PROGRESSDATA` → `CURLOPT_XFERINFODATA`.
6. **Numeric conversions**: `NUM2SIZET`/`NUM2OFFT` for `download_byte_limit`, `NUM2LONG` for timeouts and limits, `SIZET2NUM`/`LL2NUM` outbound, `rb_long2int` for escape/unescape lengths.
7. **`setopt_or_raise`** wrapper used everywhere; remove `SSLv2`/`SSLv3` (raise `UnsupportedSSLVersion` from Ruby before reaching C); `CURLOPT_PROTOCOLS_STR "http,https"` under `HAVE_CURLOPT_PROTOCOLS_STR`, bitmask fallback otherwise; NULL-check `curl_easy_init`/`curl_share_init` → `NoMemoryError`.
8. **String handling**: `StringValueCStr`/`FilePathValue` for every path (431, 1013, 1031); `escape`/`unescape` check NULL and use `outlength` + `rb_str_new(p, len)`; tag results `ASCII-8BIT` or the input encoding deliberately.
9. **`CURLOPT_READFUNCTION`** set to an `fread` wrapper next to `READDATA`; `CURLOPT_DEBUGFUNCTION` into a membuffer flushed to the Ruby IO after perform instead of `CURLOPT_STDERR FILE*` (keeps `enable_debug` output on `$stderr`, works across CRTs). Optional in this phase.
10. `rb_raise` falls back to `curl_easy_strerror(code)` when `error_buf` is empty; exceptions get `curl_code` (and `curl_message`) via `rb_ivar_set` on an `rb_exc_new_str` object. Ruby side: `Patron::Error#curl_code` reader.

Acceptance: `werror` job green on GCC and clang; ASan job green; new specs green under `GC.stress` for the body-lifetime cases.

### Phase 2: VM mechanical sympathy (the "efficient extensions" checklist)

1. **Type definition** with designated initialisers:
   ```c
   RUBY_REFERENCES(session_refs) = {
     RUBY_REF_EDGE(struct patron_curl_state, user_progress_blk),
     RUBY_REF_EDGE(struct patron_curl_state, upload_data),
     RUBY_REF_END,
   };
   static const rb_data_type_t patron_session_data_type = {
     .wrap_struct_name = "Patron::Session",
     .function = { .dmark = RUBY_REFS_LIST_PTR(session_refs),
                   .dfree = session_free,
                   .dsize = session_memsize },
     .flags = RUBY_TYPED_DECL_MARKING | RUBY_TYPED_WB_PROTECTED | RUBY_TYPED_FREE_IMMEDIATELY
   #ifdef RUBY_TYPED_THREAD_SAFE_FREE
            | RUBY_TYPED_THREAD_SAFE_FREE   /* 4.1+: dfree touches only this object's memory */
   #endif
   };
   ```
   Every VALUE store goes through `RB_OBJ_WRITE(self, &state->field, v)`. Initialise VALUE fields to `Qnil` in `session_alloc`. `RUBY_TYPED_FREE_IMMEDIATELY` stays: `session_free` calls no Ruby API (`curl_easy_cleanup` may do a short non-blocking TLS shutdown write, same as socket-wrapping extensions). `THREAD_SAFE_FREE` is only valid once item 2 removes the global list. Add a comment explaining why `RUBY_TYPED_EMBEDDABLE` is deliberately not used.
2. **Delete `cs_list`, `sglib.h`, `rb_set_end_proc`.** Rely on the ubf (invoked by `rb_thread_terminate_all` at exit) for in-flight aborts. Spec: process with a request in flight on a background thread exits promptly (fork + `/slow` + `exit`).
3. **`rb_ext_ractor_safe(true)`** as the first statement of `Init_session_ext`, before any `rb_define_*method`. Session instances stay non-shareable (mutable). Spec: `escape`/`unescape`/`libcurl_version` and a full GET from a non-main Ractor (Ractor specs guarded on Ruby version and warnings silenced).
4. **`rb_nogvl(perform_without_gvl, &ctx, session_ubf_abort, state, RB_NOGVL_UBF_ASYNC_SAFE)`.** `interrupt` becomes `volatile sig_atomic_t`. No `RB_NOGVL_OFFLOAD_SAFE` (see decisions).
5. **Throttle the progress callback**: call into Ruby only when ≥ 100 ms (monotonic clock) elapsed or counters changed by ≥ N bytes since the last call; always check `interrupt` and the byte limit. Consider replacing the byte-limit check with `CURLOPT_MAXFILESIZE_LARGE` → `CURLE_FILESIZE_EXCEEDED` mapped to the existing error (verify it aborts mid-transfer on 7.81, not only on Content-Length).
6. **membuffer**: stays a plain C buffer (it is written without the GVL; `rb_str_cat` there is not allowed). Use `realloc` in the no-GVL path and return 0 on failure (libcurl → `CURLE_WRITE_ERROR`, raised with the GVL), then `rb_gc_adjust_memory_usage(delta)` after perform for accounting. `membuffer_clear` sets `length = 0; buf[0] = 0`, no memset. Shrink to `DEFAULT_CAPACITY` in `cleanup` when capacity exceeds a threshold (e.g. 1 MiB). Remove `membuffer_insert`. `dsize` keeps reporting struct + capacities.
7. **Interning and IDs**: `static ID id_url, …` set with `rb_intern_const` in `Init_`; `rb_ivar_set` with a cached ID for `@timings`; header-name check in C with `strncasecmp` (fixes case-sensitivity) and `memmem` for "gzip"; header line built with `rb_sprintf("%"PRIsVALUE": %"PRIsVALUE)`; `rb_proc_call` instead of `rb_funcall(proc, call)`; `RB_TYPE_P`; `rb_str_new_cstr`; stack struct instead of `rb_ary_new3` for `rb_ensure`.
8. **Hygiene**: `Init_session_ext(void)`, `static` on `session_alloc`/`session_ubf_abort`, explicit includes, exact method prototypes passed uncast to `rb_define_method` so the arity check applies.
9. **Fork**: record `getpid()` at alloc; on mismatch in `handle_request` abandon the inherited `base_handle`/`share` (do not `cleanup` them: that would send TLS close_notify on a socket the parent still uses) and build fresh ones. Or document Sessions as not fork-inheritable. Decide during review.

Acceptance: `ObjectSpace.memsize_of(session)` reflects buffer growth and shrink; `GC.verify_compaction_references(expand_heap: true, toward: :empty)` around requests with a live progress Proc passes; `GC.stress` on the unit specs passes; the Ractor spec passes on 3.3, 3.4, 4.0; `werror`/ASan green.

### Phase 3: Ruby side and test suite

Ruby layer (public API kept compatible except where noted):

- `Session#initialize(**options, &block)`, `Session#request(action, url, headers = {}, **options)`; `build_request` becomes `Request.new(**defaults, **options)`.
- `Request` becomes an immutable value object (`Data.define(*FIELDS)` with a `.build` that validates and normalises: `auth_type` via pattern matching, `upload_data` Hash → form string, `to_path` probing moved here so C always receives a String or a path String, `ssl_version`/`http_version` validated in Ruby against a frozen table of C-exported constants). Drops the hand-rolled `marshal_dump`/`marshal_load` and `eql?`. Breaking for anyone mutating a Request after `build_request`; note in CHANGELOG.
- C exports `Patron::Request::SSL_VERSIONS`/`HTTP_VERSIONS` constant tables (like `ProxyType`), so the strcmp ladders (703-767) leave C.
- Accept-Encoding sniffing (370-385) moves to Ruby: `Request.build` sets `automatic_content_encoding`-like intent; C only sets `CURLOPT_ACCEPT_ENCODING`.
- `Response`: C associates encodings (`rb_usascii_str_new` for URL, binary for body/headers) so `force_encoding` goes; `timings` passed as a keyword (`response_class` contract documented as `new(url, status, redirect_count, headers, body, charset, timings:)`; keep accepting 6 positional for custom classes by probing arity, or bump the contract and document it); actually use or drop `default_charset`.
- `HeaderParser::SingleResponseHeaders` → `Data.define`.
- Fix `File.join` for URLs (407); relax `VALID_ACTIONS` (issue #180) since C already falls back to `CUSTOMREQUEST`.
- `Patron.user_agent_string` memo → frozen constant.
- `Patron::Error#curl_code` (from phase 1).

Test suite:

- Puma 6 + Rack 3 + rackup; `Rack::Files`; JSON readback instead of YAML/OpenStruct; drop `webrick`, `ostruct`, `base64`; readiness wait after forking servers; `Dir.mktmpdir` instead of `/tmp/patron_test.yaml`.
- Replace `TLSv1_0`/`TLSv1_1` expectations with `TLSv1_2`/`TLSv1_3` (+ `CURL_SSLVERSION_MAX_*` if exposed).
- New specs: `Session#interrupt` from another thread; progress Proc raising/aborting; two threads on one Session; multipart body assertions; a tiny in-process forward proxy for `proxy`/`proxy_type`; digest auth; `memsize_of`; compaction and `GC.stress` hooks behind `PATRON_GC_STRESS=1` (`GC.auto_compact = true` plus `GC.verify_compaction_references` in an `around` hook for the session specs, `GC.stress = true` for unit specs only, so the 5-second `/slow` timing assertions survive); Ractor smoke spec; exit-with-request-in-flight spec.

### Phase 4: `curl_multi` with `curl_multi_poll` and `curl_multi_wakeup`

One `CURLM` per Session. `handle_request` adds the duplicated easy handle, then loops `curl_multi_perform` → `curl_multi_poll(multi, NULL, 0, timeout_ms, &numfds)` inside `rb_nogvl` → `curl_multi_info_read`. The ubf and `Session#interrupt` call `curl_multi_wakeup(multi)` (designed to be called from another thread). Effects:

- Interruption is immediate everywhere, including DNS and connect (today: up to 1 s, and never during connect).
- `curl_multi_perform` runs **with** the GVL, so the user's progress Proc is called directly; `rb_thread_call_with_gvl`, the throttle from phase 2.5 and the `rb_protect` dance from phase 1.3 shrink to a normal protected call. The write callbacks, however, now run with the GVL held, so membuffer could become a Ruby String buffer (`rb_str_buf_new` + `rb_str_cat`) if desired; keep the C buffer unless it measurably helps.
- No public API change. Busy flag stays (one transfer per Session at a time).
- Keep the easy-interface implementation behind a compile-time switch for one release as a fallback.

Spec: interrupt latency assertions (< 100 ms) for `/slow`, during connect to a black-holed address, and during DNS (unresolvable host with a slow resolver stub if feasible).

### Phase 5 (later, separate design): Fiber scheduler and multiplexing

`CURLMOPT_SOCKETFUNCTION`/`TIMERFUNCTION` + `curl_multi_socket_action`, sockets wrapped with `rb_io_open_descriptor(..., RUBY_IO_MODE_EXTERNAL)` (3.3+) and waited on with `rb_io_wait` (dispatches to the Fiber scheduler when one is installed, else blocks the thread). Enables HTTP/2 multiplexing (`CURLPIPE_MULTIPLEX`) and `async` compatibility, answers issue #138 and relates to #158 (streaming bodies). Needs an API discussion first (connection pool scope, concurrency limits, what `interrupt` means).

### Free libcurl features to expose along the way (any phase after 0)

HTTP/3 (`CURL_HTTP_VERSION_3`, runtime-gated on `CURL_VERSION_HTTP3`), `CURLOPT_CA_CACHE_TIMEOUT`, `CURLSSLOPT_NATIVE_CA`, `CURLOPT_CAINFO_BLOB`/`SSLCERT_BLOB`/`SSLKEY_BLOB` (pairs with the new mTLS support), `CURLOPT_MAXAGE_CONN`/`MAXLIFETIME_CONN`, `CURLOPT_TCP_KEEPALIVE`, `CURLOPT_UNIX_SOCKET_PATH`, `CURLOPT_RESOLVE`, `CURLOPT_DOH_URL`, `CURLOPT_HSTS` (+ `CURL_LOCK_DATA_HSTS` in the share), `CURLAUTH_BEARER`/`NTLM`/`NEGOTIATE` and `CURLPROXY_HTTPS` constants, `CURLINFO_*_TIME_T` microsecond timings plus `QUEUE_TIME_T`/`POSTTRANSFER_TIME_T` under guards, `CURLINFO_HTTP_VERSION`/`PRIMARY_IP`/`PRIMARY_PORT` on the Response, `curl_easy_header` (7.83) as an optional replacement for `HeaderParser`.

## 3. Disagreements between the audits, resolved

- **Body lifetime: hold the VALUE vs `CURLOPT_COPYPOSTFIELDS`.** Hold the VALUE (no double copy; the struct already needs a reference list for the Proc).
- **`RB_NOGVL_OFFLOAD_SAFE` when no progress Proc is set.** Not worth a per-call flag computation; off until phase 4 makes the question moot.
- **Share lock callbacks vs busy flag.** Both: the busy flag is the user-facing guarantee today, the lock callbacks make the share correct for phase 4 and cost nothing.
- **`ruby_xrealloc` vs `realloc` in the write callback.** `realloc` + `rb_gc_adjust_memory_usage` after perform. The doc's preference for `ruby_x*` assumes the GVL is held.
- **`RUBY_TYPED_FREE_IMMEDIATELY` with `curl_easy_cleanup` in `dfree`.** Keep. No Ruby API is called; the cleanup is bounded, non-blocking I/O.

## 4. Open questions for the maintainer

1. Version: 1.0.0 (recommended) or 0.14.0?
2. `response_class` contract: keep 6 positional args and set `@timings` afterwards, or move to a keyword and bump the documented contract?
3. Fork handling (phase 2.9): detect and rebuild, or document only?
4. libcurl floor 7.81 now and 8.5 after April 2027, or 8.5 immediately (drops Ubuntu 22.04 and Debian 12)?
5. Gemspec authorship/maintainer fields.

## 5. Sources

- ruby/ruby `doc/efficient_extensions.md` (master, moved from `doc/contributing/` on 2026-10-09); local copy in the session scratchpad.
- ruby/ruby `doc/extension.rdoc` Appendices F (Ractor) and G (embedded TypedData); `include/ruby/thread.h`, `include/ruby/internal/core/rtypeddata.h`, `include/ruby/internal/gc.h` at v3_3_0, v3_4_0, v4.0.0, v4.1.0-preview1, master.
- Ruby NEWS 3.3, 3.4, 4.0, 4.1 (master): `RB_NOGVL_OFFLOAD_SAFE` (3.4), `rb_thread_call_with_gvl` callable with GVL held (4.0, #20750), `RUBY_TYPED_EMBEDDABLE` public (4.1, #21853), `RUBY_TYPED_THREAD_SAFE_FREE` (4.1, #22067), untyped Data API removed (4.1, #21768), Ractor-scoped `rb_global_variable` (4.1, #22277), per-Ractor GC (4.1).
- https://www.ruby-lang.org/en/downloads/branches/ (fetched 2026-10-27).
- libcurl: `curl.h`/`curlver.h` 8.7.1 (macOS SDK), `docs/libcurl/symbols-in-versions`, CURLOPT_HTTPPOST and CURLOPT_PROTOCOLS deprecation pages, distro package versions via repology.
- Ivo Anjo, "updating a c extension for a modern vm" (2026-09-23) and the RubyKaigi 2026 talk video; slides not published.
