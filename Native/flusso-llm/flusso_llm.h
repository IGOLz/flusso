// A minimal C API over llama.cpp for Flusso's smart formatting.
//
// llama.cpp is linked into its own dylib (libflusso-llm.dylib) together with
// its own copy of ggml, and only these functions are exported: the app's
// transcription engine (transcribe.cpp) ships a different ggml, and the two
// must never see each other's symbols.
#ifndef FLUSSO_LLM_H
#define FLUSSO_LLM_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct flusso_llm flusso_llm;

/// False on Intel Macs: the dylib's x86_64 slice is a stub.
bool flusso_llm_is_supported(void);

/// Loads a GGUF model (all layers on the GPU) with a context of `n_ctx`
/// tokens. NULL on failure.
flusso_llm * flusso_llm_load(const char * path, int n_ctx);

/// Evaluates the fixed start of every prompt (instructions, examples) once
/// and keeps it in the cache. The text may contain special tokens.
bool flusso_llm_set_prefix(flusso_llm * llm, const char * prefix);

/// Greedy completion of prefix + `text` + `suffix`. `text` is tokenized as
/// plain text (special-token strings in it stay text); `suffix` may contain
/// special tokens. Stops at an end-of-generation token or after `max_tokens`.
/// Returns a malloc'd UTF-8 string (free with `flusso_llm_free_string`), or
/// NULL on failure or if the prompt doesn't fit the context.
char * flusso_llm_complete(flusso_llm * llm, const char * text, const char * suffix, int max_tokens);

void flusso_llm_free_string(char * string);
void flusso_llm_free(flusso_llm * llm);

#ifdef __cplusplus
}
#endif

#endif
