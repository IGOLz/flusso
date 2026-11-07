// Bridges the transcribe.cpp C API (the inference engine Handy uses) into Swift.
#include "transcribe.h"
#include "transcribe/vad.h"
// llama.cpp behind a small C API, for smart formatting (Native/flusso-llm).
#include "flusso_llm.h"
