#ifndef PUNCTUATION_RUNTIME_H
#define PUNCTUATION_RUNTIME_H

#include <stdint.h>

/// Thin C wrapper over the ONNX Runtime C API for the punctuation model.
/// The Objective-C bindings can't read bool tensors, and two of the model's
/// outputs are bool, so Swift goes through this instead.
typedef struct PunctuationModel PunctuationModel;

/// Loads the model. Returns NULL on failure and writes a message to `error`.
PunctuationModel *punctuation_model_load(const char *path, char *error, int errorLength);

void punctuation_model_free(PunctuationModel *model);

/// Runs one window. `ids` has `count` entries, BOS and EOS included.
/// Outputs, all sized by the caller:
///   post  - `count` entries, the post-punctuation label index per token
///   caps  - `count * capWidth` bytes, 1 where a character should be uppercase
/// Returns 0 on success.
int punctuation_model_run(PunctuationModel *model,
                          const int64_t *ids, int count,
                          int64_t *post,
                          uint8_t *caps, int capWidth,
                          char *error, int errorLength);

#endif
