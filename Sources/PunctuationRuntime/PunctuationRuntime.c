#include "PunctuationRuntime.h"

#include <onnxruntime/onnxruntime_c_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct PunctuationModel {
    const OrtApi *api;
    OrtEnv *env;
    OrtSession *session;
    OrtMemoryInfo *memory;
};

static int take_status(const OrtApi *api, OrtStatus *status, char *error, int errorLength) {
    if (status == NULL) return 0;
    if (error != NULL && errorLength > 0) {
        snprintf(error, (size_t)errorLength, "%s", api->GetErrorMessage(status));
    }
    api->ReleaseStatus(status);
    return 1;
}

PunctuationModel *punctuation_model_load(const char *path, char *error, int errorLength) {
    const OrtApi *api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (api == NULL) {
        if (error != NULL && errorLength > 0) snprintf(error, (size_t)errorLength, "ONNX Runtime API unavailable");
        return NULL;
    }
    PunctuationModel *model = calloc(1, sizeof(PunctuationModel));
    if (model == NULL) return NULL;
    model->api = api;

    OrtSessionOptions *options = NULL;
    if (take_status(api, api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "murmur-punctuation", &model->env), error, errorLength)
        || take_status(api, api->CreateSessionOptions(&options), error, errorLength)
        || take_status(api, api->SetIntraOpNumThreads(options, 2), error, errorLength)
        || take_status(api, api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL), error, errorLength)
        || take_status(api, api->CreateSession(model->env, path, options, &model->session), error, errorLength)
        || take_status(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &model->memory), error, errorLength)) {
        if (options != NULL) api->ReleaseSessionOptions(options);
        punctuation_model_free(model);
        return NULL;
    }
    api->ReleaseSessionOptions(options);
    return model;
}

void punctuation_model_free(PunctuationModel *model) {
    if (model == NULL) return;
    const OrtApi *api = model->api;
    if (model->memory != NULL) api->ReleaseMemoryInfo(model->memory);
    if (model->session != NULL) api->ReleaseSession(model->session);
    if (model->env != NULL) api->ReleaseEnv(model->env);
    free(model);
}

static int element_count(const OrtApi *api, OrtValue *value, size_t *count, int64_t *lastDim,
                         char *error, int errorLength) {
    OrtTensorTypeAndShapeInfo *info = NULL;
    if (take_status(api, api->GetTensorTypeAndShape(value, &info), error, errorLength)) return 1;
    size_t dims = 0;
    int failed = take_status(api, api->GetTensorShapeElementCount(info, count), error, errorLength)
        || take_status(api, api->GetDimensionsCount(info, &dims), error, errorLength);
    if (!failed && lastDim != NULL && dims > 0) {
        int64_t shape[8] = {0};
        if (dims <= 8) {
            failed = take_status(api, api->GetDimensions(info, shape, dims), error, errorLength);
            *lastDim = shape[dims - 1];
        } else {
            failed = 1;
        }
    }
    api->ReleaseTensorTypeAndShapeInfo(info);
    return failed;
}

int punctuation_model_run(PunctuationModel *model,
                          const int64_t *ids, int count,
                          int64_t *post,
                          uint8_t *caps, int capWidth,
                          char *error, int errorLength) {
    if (model == NULL || count <= 0) return 1;
    const OrtApi *api = model->api;
    int64_t shape[2] = {1, count};
    OrtValue *input = NULL;
    if (take_status(api, api->CreateTensorWithDataAsOrtValue(
            model->memory, (void *)ids, sizeof(int64_t) * (size_t)count, shape, 2,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &input), error, errorLength)) {
        return 1;
    }

    const char *inputNames[] = {"input_ids"};
    const char *outputNames[] = {"post_preds", "cap_preds"};
    OrtValue *outputs[2] = {NULL, NULL};
    int failed = take_status(api, api->Run(model->session, NULL, inputNames,
                                           (const OrtValue *const *)&input, 1,
                                           outputNames, 2, outputs), error, errorLength);
    api->ReleaseValue(input);

    if (!failed) {
        size_t postCount = 0, capCount = 0;
        int64_t capDim = 0;
        void *postData = NULL, *capData = NULL;
        failed = element_count(api, outputs[0], &postCount, NULL, error, errorLength)
            || element_count(api, outputs[1], &capCount, &capDim, error, errorLength)
            || take_status(api, api->GetTensorMutableData(outputs[0], &postData), error, errorLength)
            || take_status(api, api->GetTensorMutableData(outputs[1], &capData), error, errorLength);
        if (!failed && (postCount != (size_t)count || capDim <= 0 || capCount != (size_t)count * (size_t)capDim)) {
            if (error != NULL && errorLength > 0) snprintf(error, (size_t)errorLength, "unexpected output shape");
            failed = 1;
        }
        if (!failed) {
            memcpy(post, postData, sizeof(int64_t) * (size_t)count);
            // bool tensors are one byte per element.
            const uint8_t *bytes = (const uint8_t *)capData;
            int width = capWidth < capDim ? capWidth : (int)capDim;
            memset(caps, 0, (size_t)count * (size_t)capWidth);
            for (int t = 0; t < count; t++) {
                for (int c = 0; c < width; c++) {
                    caps[t * capWidth + c] = bytes[(size_t)t * (size_t)capDim + (size_t)c] ? 1 : 0;
                }
            }
        }
    }
    for (int i = 0; i < 2; i++) {
        if (outputs[i] != NULL) api->ReleaseValue(outputs[i]);
    }
    return failed;
}
