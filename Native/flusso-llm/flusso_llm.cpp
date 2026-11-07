#include "flusso_llm.h"

#include <cstdlib>
#include <cstring>

#if defined(FLUSSO_LLM_STUB)

// Intel Macs: no Metal backend, and a 4B model on the CPU is too slow for
// dictation. The app checks `flusso_llm_is_supported` and hides the option.
bool flusso_llm_is_supported(void) { return false; }
flusso_llm * flusso_llm_load(const char *, int) { return nullptr; }
bool flusso_llm_set_prefix(flusso_llm *, const char *) { return false; }
char * flusso_llm_complete(flusso_llm *, const char *, const char *, int) { return nullptr; }
void flusso_llm_free_string(char * string) { free(string); }
void flusso_llm_free(flusso_llm *) {}

#else

#include "llama.h"

#include <algorithm>
#include <cstdio>
#include <mutex>
#include <string>
#include <vector>

struct flusso_llm {
    llama_model * model = nullptr;
    llama_context * ctx = nullptr;
    llama_sampler * sampler = nullptr;
    const llama_vocab * vocab = nullptr;
    std::vector<llama_token> prefix;
    /// The prefix is in the cache (positions 0..<prefix.size()).
    bool prefix_cached = false;
};

static void log_errors(ggml_log_level level, const char * text, void *) {
    if (level == GGML_LOG_LEVEL_ERROR) fputs(text, stderr);
}

static std::vector<llama_token> tokenize(const llama_vocab * vocab, const char * text, bool add_special, bool parse_special) {
    const int32_t length = (int32_t) strlen(text);
    std::vector<llama_token> tokens(length + 8);
    int32_t n = llama_tokenize(vocab, text, length, tokens.data(), (int32_t) tokens.size(), add_special, parse_special);
    if (n < 0) {
        tokens.resize(-n);
        n = llama_tokenize(vocab, text, length, tokens.data(), (int32_t) tokens.size(), add_special, parse_special);
        if (n < 0) return {};
    }
    tokens.resize(n);
    return tokens;
}

/// Evaluates `tokens` after what's already in the cache, in batches.
static bool decode(llama_context * ctx, std::vector<llama_token> & tokens) {
    const size_t batch = llama_n_batch(ctx);
    for (size_t i = 0; i < tokens.size(); i += batch) {
        const int32_t n = (int32_t) std::min(batch, tokens.size() - i);
        if (llama_decode(ctx, llama_batch_get_one(tokens.data() + i, n)) != 0) return false;
    }
    return true;
}

/// Longest draft checked per step.
static constexpr size_t kMaxDraft = 12;

/// The tokens that follow the output's last 3 (or 2, or 1) tokens in
/// `source`, preferring a match at or after `cursor` (where the previous
/// match ended: the copy usually moves forward).
static std::vector<llama_token> lookup(const std::vector<llama_token> & source, const std::vector<llama_token> & output,
                                       size_t & cursor, size_t limit) {
    for (size_t n = 3; n >= 1; n--) {
        if (output.size() < n || source.size() <= n) continue;
        const llama_token * tail = output.data() + output.size() - n;
        auto matches = [&](size_t p) { return std::equal(tail, tail + n, source.begin() + p); };
        size_t found = SIZE_MAX;
        for (size_t p = std::min(cursor, source.size()); p + n < source.size(); p++) {
            if (matches(p)) { found = p; break; }
        }
        for (size_t p = 0; found == SIZE_MAX && p + n < source.size() && p < cursor; p++) {
            if (matches(p)) found = p;
        }
        if (found == SIZE_MAX) continue;
        cursor = found + n;
        const size_t end = std::min(source.size(), cursor + limit);
        return std::vector<llama_token>(source.begin() + cursor, source.begin() + end);
    }
    return {};
}

bool flusso_llm_is_supported(void) { return true; }

flusso_llm * flusso_llm_load(const char * path, int n_ctx) {
    static std::once_flag once;
    std::call_once(once, [] {
        llama_log_set(log_errors, nullptr);
        llama_backend_init();
    });

    auto model_params = llama_model_default_params();
    model_params.n_gpu_layers = -1;
    llama_model * model = llama_model_load_from_file(path, model_params);
    if (!model) return nullptr;

    auto ctx_params = llama_context_default_params();
    ctx_params.n_ctx = (uint32_t) n_ctx;
    ctx_params.n_batch = 1024;
    ctx_params.n_ubatch = 512;
    ctx_params.n_seq_max = 1;
    ctx_params.no_perf = true;
    // Keeps every position of the sliding-window layers, so the cached
    // prefix survives removing the previous dictation from the cache.
    ctx_params.swa_full = true;
    llama_context * ctx = llama_init_from_model(model, ctx_params);
    if (!ctx) {
        llama_model_free(model);
        return nullptr;
    }

    auto * llm = new flusso_llm();
    llm->model = model;
    llm->ctx = ctx;
    llm->vocab = llama_model_get_vocab(model);
    llm->sampler = llama_sampler_init_greedy();
    return llm;
}

static bool cache_prefix(flusso_llm * llm) {
    llama_memory_clear(llama_get_memory(llm->ctx), true);
    llm->prefix_cached = decode(llm->ctx, llm->prefix);
    return llm->prefix_cached;
}

bool flusso_llm_set_prefix(flusso_llm * llm, const char * prefix) {
    if (!llm) return false;
    llm->prefix = tokenize(llm->vocab, prefix, /*add_special*/ true, /*parse_special*/ true);
    if (llm->prefix.empty()) return false;
    return cache_prefix(llm);
}

char * flusso_llm_complete(flusso_llm * llm, const char * text, const char * suffix, int max_tokens) {
    if (!llm || llm->prefix.empty()) return nullptr;

    std::vector<llama_token> input = tokenize(llm->vocab, text, false, /*parse_special*/ false);
    const std::vector<llama_token> tail = tokenize(llm->vocab, suffix, false, /*parse_special*/ true);
    if (input.empty()) return nullptr;
    const std::vector<llama_token> source = input; // what the answer mostly copies
    input.insert(input.end(), tail.begin(), tail.end());

    const size_t needed = llm->prefix.size() + input.size() + (size_t) max_tokens + kMaxDraft + 1;
    if (needed > llama_n_ctx(llm->ctx)) return nullptr;

    // Drop the previous dictation, keep the prefix.
    llama_memory_t memory = llama_get_memory(llm->ctx);
    if (!llm->prefix_cached || !llama_memory_seq_rm(memory, 0, (llama_pos) llm->prefix.size(), -1)) {
        if (!cache_prefix(llm)) return nullptr;
    }

    if (!decode(llm->ctx, input)) {
        llm->prefix_cached = false;
        return nullptr;
    }

    // Prompt-lookup decoding: an edited dictation mostly repeats the
    // dictation, so the tokens that follow the last few output tokens in the
    // input are proposed as a draft and checked in one batch. Greedy
    // verification keeps the output identical to plain decoding.
    llama_pos n_past = (llama_pos) (llm->prefix.size() + input.size());
    std::vector<llama_token> output;
    llama_batch batch = llama_batch_init(kMaxDraft + 1, 0, 1);
    llama_sampler_reset(llm->sampler);
    llama_token token = llama_sampler_sample(llm->sampler, llm->ctx, -1);
    size_t cursor = 0;
    bool failed = false;
    while (!llama_vocab_is_eog(llm->vocab, token) && (int) output.size() < max_tokens) {
        output.push_back(token);
        const std::vector<llama_token> draft = lookup(source, output, cursor,
                                                      std::min<size_t>(kMaxDraft, max_tokens - output.size()));
        batch.n_tokens = 0;
        for (size_t i = 0; i <= draft.size(); i++) {
            const int j = batch.n_tokens++;
            batch.token[j] = i == 0 ? token : draft[i - 1];
            batch.pos[j] = n_past + (llama_pos) i;
            batch.n_seq_id[j] = 1;
            batch.seq_id[j][0] = 0;
            batch.logits[j] = true;
        }
        if (llama_decode(llm->ctx, batch) != 0) {
            failed = true;
            break;
        }
        size_t accepted = 0;
        token = llama_sampler_sample(llm->sampler, llm->ctx, 0);
        while (accepted < draft.size() && token == draft[accepted]) {
            output.push_back(token);
            accepted++;
            token = llama_sampler_sample(llm->sampler, llm->ctx, (int32_t) accepted);
        }
        n_past += (llama_pos) (1 + accepted);
        // Forget the rejected part of the draft.
        if (accepted < draft.size() && !llama_memory_seq_rm(memory, 0, n_past, -1)) {
            failed = true;
            break;
        }
    }
    llama_batch_free(batch);
    if (failed) {
        llm->prefix_cached = false;
        return nullptr;
    }
    if ((int) output.size() > max_tokens) output.resize(max_tokens);

    std::vector<char> buffer(output.size() * 16 + 16);
    int32_t n = llama_detokenize(llm->vocab, output.data(), (int32_t) output.size(),
                                 buffer.data(), (int32_t) buffer.size(), /*remove_special*/ true, /*unparse_special*/ false);
    if (n < 0) {
        buffer.resize(-n + 1);
        n = llama_detokenize(llm->vocab, output.data(), (int32_t) output.size(),
                             buffer.data(), (int32_t) buffer.size(), true, false);
        if (n < 0) return nullptr;
    }
    char * result = (char *) malloc((size_t) n + 1);
    if (!result) return nullptr;
    memcpy(result, buffer.data(), (size_t) n);
    result[n] = '\0';
    return result;
}

void flusso_llm_free_string(char * string) { free(string); }

void flusso_llm_free(flusso_llm * llm) {
    if (!llm) return;
    if (llm->sampler) llama_sampler_free(llm->sampler);
    if (llm->ctx) llama_free(llm->ctx);
    if (llm->model) llama_model_free(llm->model);
    delete llm;
}

#endif
