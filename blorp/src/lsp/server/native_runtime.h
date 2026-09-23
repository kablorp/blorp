#ifndef BLORP_LSP_NATIVE_RUNTIME_H
#define BLORP_LSP_NATIVE_RUNTIME_H

long blorp_compiler_require_fiber_stack_size(void);
void blorp_compiler_lsp_exit_now(long status);
void blorp_compiler_lower_background_thread_priority(void);

#endif
