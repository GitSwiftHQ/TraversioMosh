// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

#ifndef TRAVERSIOMOSH_CZLIB_H
#define TRAVERSIOMOSH_CZLIB_H

#include <stddef.h>
#include <stdint.h>

#define TRAVERSIOMOSH_ZLIB_SUCCESS 0
#define TRAVERSIOMOSH_ZLIB_INVALID_ARGUMENT 1
#define TRAVERSIOMOSH_ZLIB_OUT_OF_MEMORY 2
#define TRAVERSIOMOSH_ZLIB_COMPRESS_FAILED 3
#define TRAVERSIOMOSH_ZLIB_DECOMPRESS_FAILED 4
#define TRAVERSIOMOSH_ZLIB_OUTPUT_LIMIT_EXCEEDED 5

int traversiomosh_zlib_compress(
    const uint8_t *input,
    size_t input_length,
    uint8_t **output,
    size_t *output_length
);

int traversiomosh_zlib_decompress(
    const uint8_t *input,
    size_t input_length,
    size_t maximum_output_length,
    uint8_t **output,
    size_t *output_length
);

void traversiomosh_zlib_free(uint8_t *pointer);

#endif
