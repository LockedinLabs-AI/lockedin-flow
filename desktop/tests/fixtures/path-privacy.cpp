// Synthetic compiler fixture. Keep both narrow and wide source macros alive.
#define FLOW_WIDEN_IMPL(value) L##value
#define FLOW_WIDEN(value) FLOW_WIDEN_IMPL(value)
const char *flow_source_path = __FILE__;
const wchar_t *flow_wide_source_path = FLOW_WIDEN(__FILE__);

// Require the same C++ exception support used by the native speech dependency.
int flow_exception_probe(int value) {
    try {
        if (value != 0) throw value;
        return 0;
    } catch (int caught) {
        return caught;
    }
}
