#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %d %s\n", __LINE__, #x); return 1; } } while (0)
static uint32_t random_word(void) {
    static uint32_t state = 0xb7e1a34d;
    state ^= state << 13; state ^= state >> 17; state ^= state << 5;
    return state;
}

// Compare an owned shader's original indirect-bank capture with its proven
// direct-bank variant. Both use the production 608-byte intermediate layout.
int main(int argc, char **argv) { @autoreleasepool {
    CHECK(argc == 3);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    NSError *error = nil;
    const unsigned count = 65536, stride = 608, guard = 256;
    id<MTLBuffer> constants[14], arguments[2], output[2];
    id<MTLComputePipelineState> pipelines[2];
    for (unsigned bank = 0; bank < 14; bank++) {
        constants[bank] = [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
        float *values = constants[bank].contents;
        for (unsigned i = 0; i < 16384; i++) values[i] = ((int)((i*17 + bank*13) % 61)-30) / 64.f;
    }
    for (unsigned variant = 0; variant < 2; variant++) {
        id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:@(argv[variant+1])] error:&error];
        CHECK(library);
        id<MTLFunction> function = [library newFunctionWithName:@"main0"];
        CHECK(function);
        pipelines[variant] = [device newComputePipelineStateWithFunction:function error:&error];
        CHECK(pipelines[variant]);
        id<MTLArgumentEncoder> encoder = [function newArgumentEncoderWithBufferIndex:0];
        CHECK(encoder);
        arguments[variant] = [device newBufferWithLength:encoder.encodedLength options:MTLResourceStorageModeShared];
        [encoder setArgumentBuffer:arguments[variant] offset:0];
        if (variant) {
            [encoder setBuffer:constants[1] offset:0 atIndex:0];
            [encoder setBuffer:constants[3] offset:0 atIndex:1];
        } else {
            for (unsigned bank = 0; bank < 14; bank++) [encoder setBuffer:constants[bank] offset:0 atIndex:bank];
        }
        output[variant] = [device newBufferWithLength:(NSUInteger)count*stride + 2*guard options:MTLResourceStorageModeShared];
    }
    id<MTLBuffer> indices = [device newBufferWithLength:count*4 options:MTLResourceStorageModeShared];
    uint32_t *index = indices.contents;
    uint32_t parameters[4] = {0};
    uint64_t compared = 0, nonzero = 0;
    for (unsigned mode = 0; mode < 8; mode++) { @autoreleasepool {
        for (unsigned i = 0; i < count; i++) {
            switch (mode) {
            case 0: index[i] = i; break;
            case 1: index[i] = UINT32_MAX - i; break;
            case 2: index[i] = 0x80000000u + i - count/2; break;
            case 3: index[i] = i << 16; break;
            default: index[i] = random_word(); break;
            }
        }
        for (unsigned variant = 0; variant < 2; variant++) {
            memset(output[variant].contents, 0xa5, output[variant].length);
            id<MTLCommandBuffer> command = [queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:pipelines[variant]];
            [encoder setBuffer:arguments[variant] offset:0 atIndex:0];
            [encoder setBuffer:indices offset:0 atIndex:21];
            [encoder setBytes:parameters length:sizeof parameters atIndex:23];
            [encoder setBuffer:output[variant] offset:guard atIndex:28];
            for (unsigned bank = 0; bank < 14; bank++) [encoder useResource:constants[bank] usage:MTLResourceUsageRead];
            [encoder setStageInRegion:MTLRegionMake2D(0, 0, count, 1)];
            [encoder dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(128, 1, 1)];
            [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
            if (command.error) fprintf(stderr, "%s\n", command.error.description.UTF8String);
            CHECK(!command.error);
            const unsigned char *bytes = output[variant].contents;
            for (unsigned i = 0; i < guard; i++) {
                CHECK(bytes[i] == 0xa5);
                CHECK(bytes[output[variant].length-1-i] == 0xa5);
            }
        }
        for (unsigned i = 0; i < count; i++) {
            const uint32_t *a = (const void *)((const char *)output[0].contents + guard + (NSUInteger)i*stride);
            const uint32_t *b = (const void *)((const char *)output[1].contents + guard + (NSUInteger)i*stride);
            CHECK(a[128] == 0 && a[129] == 0 && b[128] == 0 && b[129] == 0);
            for (unsigned component = 0; component < 12; component++) {
                unsigned word = component < 8 ? component : 128 + component-8;
                if (a[word] != b[word]) {
                    fprintf(stderr, "mode %u vertex %08x component %u: %08x != %08x\n", mode, index[i], component, a[word], b[word]);
                    return 2;
                }
                compared++; nonzero += a[word] != 0;
            }
        }
    } }
    printf("PASS %llu exact output components (%llu nonzero), 524288 vertex IDs including unsigned and signed boundaries; guards intact\n", compared, nonzero);
    return 0;
} }
