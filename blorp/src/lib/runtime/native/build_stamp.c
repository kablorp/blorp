/* Definitions for the build facts declared in build_stamp.h. Every value
 * defaults to "unknown" so a build that does not pass -D defines (for
 * example a standalone `cc` invocation while iterating, or the embedded
 * runtime any other compiled Blorp program links against) still links and
 * reports an honest, unambiguous value instead of stale or fabricated data.
 * The CLI's own Makefile-built binary supplies the real values as -D
 * defines when it compiles this file directly (see
 * BLORP_CLI_BUILD_STAMP_OBJECT in the Makefile).
 *
 * Deliberately no `#include "build_stamp.h"` here: this file's text is also
 * pasted into the embedded runtime bundle (see generate_embedded_runtime_c
 * in blorp/tool/generate_build_sources.brp), where "build_stamp.h" is not a
 * real file on disk. The blorp_String type it needs is already visible from
 * whatever precedes it in either compile context (runtime_decl.c via
 * -include for the CLI's own object, or runtime.c's own copy in the
 * embedded bundle). */

#ifndef BLORP_BUILD_STAMP_COMMIT
#define BLORP_BUILD_STAMP_COMMIT "unknown"
#endif
#ifndef BLORP_BUILD_STAMP_TARGET
#define BLORP_BUILD_STAMP_TARGET "unknown"
#endif
#ifndef BLORP_BUILD_STAMP_COMPILED_BY
#define BLORP_BUILD_STAMP_COMPILED_BY "unknown"
#endif
#ifndef BLORP_BUILD_STAMP_CLI_OPTIMIZATION
#define BLORP_BUILD_STAMP_CLI_OPTIMIZATION "unknown"
#endif
#ifndef BLORP_BUILD_STAMP_RUNTIME_OPTIMIZATION
#define BLORP_BUILD_STAMP_RUNTIME_OPTIMIZATION "unknown"
#endif
#ifndef BLORP_BUILD_STAMP_SPLIT
#define BLORP_BUILD_STAMP_SPLIT "unknown"
#endif
#ifndef BLORP_BUILD_STAMP_CC
#define BLORP_BUILD_STAMP_CC "unknown"
#endif

blorp_String *blorp_build_stamp_commit(void) {
    return blorp_string_create(BLORP_BUILD_STAMP_COMMIT);
}

blorp_String *blorp_build_stamp_target(void) {
    return blorp_string_create(BLORP_BUILD_STAMP_TARGET);
}

blorp_String *blorp_build_stamp_compiled_by(void) {
    return blorp_string_create(BLORP_BUILD_STAMP_COMPILED_BY);
}

blorp_String *blorp_build_stamp_cli_optimization(void) {
    return blorp_string_create(BLORP_BUILD_STAMP_CLI_OPTIMIZATION);
}

blorp_String *blorp_build_stamp_runtime_optimization(void) {
    return blorp_string_create(BLORP_BUILD_STAMP_RUNTIME_OPTIMIZATION);
}

blorp_String *blorp_build_stamp_split(void) {
    return blorp_string_create(BLORP_BUILD_STAMP_SPLIT);
}

blorp_String *blorp_build_stamp_cc(void) {
    return blorp_string_create(BLORP_BUILD_STAMP_CC);
}
