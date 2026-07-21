#define CAML_INTERNALS
#include <caml/mlvalues.h>
#include <caml/signals.h>

CAMLprim value blorp_process_status_signal_number(value signal) {
    return Val_int(caml_convert_signal_number(Int_val(signal)));
}
