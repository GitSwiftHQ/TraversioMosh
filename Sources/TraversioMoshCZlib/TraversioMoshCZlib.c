// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

#include "TraversioMoshCZlib.h"

#include <limits.h>
#include <stdlib.h>
#include <zlib.h>

static int traversiomosh_zlib_validate(
    const uint8_t *input,
    size_t input_length,
    uint8_t **output,
    size_t *output_length
) {
    if ((input == NULL && input_length != 0) || output == NULL || output_length == NULL) {
        return TRAVERSIOMOSH_ZLIB_INVALID_ARGUMENT;
    }

    *output = NULL;
    *output_length = 0;
    return TRAVERSIOMOSH_ZLIB_SUCCESS;
}

int traversiomosh_zlib_compress(
    const uint8_t *input,
    size_t input_length,
    uint8_t **output,
    size_t *output_length
) {
    int validation = traversiomosh_zlib_validate(input, input_length, output, output_length);
    if (validation != TRAVERSIOMOSH_ZLIB_SUCCESS) {
        return validation;
    }
    if (input_length > ULONG_MAX) {
        return TRAVERSIOMOSH_ZLIB_INVALID_ARGUMENT;
    }

    uLong source_length = (uLong)input_length;
    uLongf destination_length = compressBound(source_length);
    uint8_t *destination = malloc(destination_length == 0 ? 1 : destination_length);
    if (destination == NULL) {
        return TRAVERSIOMOSH_ZLIB_OUT_OF_MEMORY;
    }

    static const uint8_t empty_input = 0;
    const Bytef *source = input_length == 0 ? &empty_input : (const Bytef *)input;
    int status = compress((Bytef *)destination, &destination_length, source, source_length);
    if (status != Z_OK) {
        free(destination);
        return TRAVERSIOMOSH_ZLIB_COMPRESS_FAILED;
    }

    *output = destination;
    *output_length = (size_t)destination_length;
    return TRAVERSIOMOSH_ZLIB_SUCCESS;
}

int traversiomosh_zlib_decompress(
    const uint8_t *input,
    size_t input_length,
    size_t maximum_output_length,
    uint8_t **output,
    size_t *output_length
) {
    int validation = traversiomosh_zlib_validate(input, input_length, output, output_length);
    if (validation != TRAVERSIOMOSH_ZLIB_SUCCESS) {
        return validation;
    }
    if (input_length > ULONG_MAX || maximum_output_length > ULONG_MAX) {
        return TRAVERSIOMOSH_ZLIB_INVALID_ARGUMENT;
    }

    uint8_t *destination = malloc(maximum_output_length == 0 ? 1 : maximum_output_length);
    if (destination == NULL) {
        return TRAVERSIOMOSH_ZLIB_OUT_OF_MEMORY;
    }

    static const uint8_t empty_input = 0;
    const Bytef *source = input_length == 0 ? &empty_input : (const Bytef *)input;
    uLongf destination_length = (uLongf)maximum_output_length;
    int status = uncompress(
        (Bytef *)destination,
        &destination_length,
        source,
        (uLong)input_length
    );
    if (status != Z_OK) {
        free(destination);
        if (status == Z_BUF_ERROR) {
            return TRAVERSIOMOSH_ZLIB_OUTPUT_LIMIT_EXCEEDED;
        }
        return TRAVERSIOMOSH_ZLIB_DECOMPRESS_FAILED;
    }

    *output = destination;
    *output_length = (size_t)destination_length;
    return TRAVERSIOMOSH_ZLIB_SUCCESS;
}

void traversiomosh_zlib_free(uint8_t *pointer) {
    free(pointer);
}
