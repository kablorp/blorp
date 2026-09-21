#ifndef BLORP_BUILD_STAMP_H
#define BLORP_BUILD_STAMP_H

/* Build facts stamped into the CLI binary by the Makefile (see
 * build_stamp.c and the BLORP_CLI_BUILD_STAMP_OBJECT target). These are
 * supplied as -D defines to a single small translation unit so that a
 * changed git commit relinks the binary without recompiling the generated
 * compiler C or its split translation units. */

blorp_String *blorp_build_stamp_commit(void);
blorp_String *blorp_build_stamp_target(void);
blorp_String *blorp_build_stamp_channel(void);
blorp_String *blorp_build_stamp_dirty(void);
blorp_String *blorp_build_stamp_compiled_by(void);
blorp_String *blorp_build_stamp_cli_optimization(void);
blorp_String *blorp_build_stamp_runtime_optimization(void);
blorp_String *blorp_build_stamp_split(void);
blorp_String *blorp_build_stamp_cc(void);

#endif
