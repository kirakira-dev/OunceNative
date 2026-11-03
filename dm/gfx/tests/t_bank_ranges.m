#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %d %s\n", __LINE__, #x); return 1; } } while (0)
static uint32_t random_word(void) {
    static uint32_t state = 0x639ed782;
    state ^= state << 13; state ^= state >> 17; state ^= state << 5;
    return state;
}

int main(int argc, char **argv) { @autoreleasepool {
    CHECK(argc == 2);
    NSError *error = nil;
    NSData *json = [NSData dataWithContentsOfFile:@(argv[1])];
    CHECK(json);
    NSArray *fixtures = [NSJSONSerialization JSONObjectWithData:json options:0 error:&error];
    CHECK(fixtures.count == 2);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    const unsigned count = 32768, guard = 256;
    id<MTLBuffer> constants[3];
    for (unsigned bank = 0; bank < 3; bank++) {
        constants[bank] = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
        uint32_t *data = constants[bank].contents;
        for (unsigned i = 0; i < 64; i++) data[i] = random_word();
    }
    id<MTLBuffer> input = [device newBufferWithLength:count*4 options:MTLResourceStorageModeShared];
    uint64_t compared = 0;
    for (NSDictionary *fixture in fixtures) { @autoreleasepool {
        unsigned stride = [fixture[@"outputs_per_thread"] unsignedIntValue];
        CHECK(stride == 1 || stride == 13);
        id<MTLComputePipelineState> pipelines[2];
        id<MTLBuffer> arguments[2], output[2];
        NSArray *variants = fixture[@"variants"];
        CHECK(variants.count == 2);
        for (unsigned variant = 0; variant < 2; variant++) {
            NSDictionary *item = variants[variant];
            id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:item[@"path"]] error:&error];
            CHECK(library);
            id<MTLFunction> function = [library newFunctionWithName:@"main0"];
            CHECK(function);
            pipelines[variant] = [device newComputePipelineStateWithFunction:function error:&error];
            CHECK(pipelines[variant]);
            id<MTLArgumentEncoder> encoder = [function newArgumentEncoderWithBufferIndex:0];
            CHECK(encoder);
            arguments[variant] = [device newBufferWithLength:encoder.encodedLength options:MTLResourceStorageModeShared];
            output[variant] = [device newBufferWithLength:(NSUInteger)count*stride*16 + 2*guard options:MTLResourceStorageModeShared];
            [encoder setArgumentBuffer:arguments[variant] offset:0];
            for (NSDictionary *binding in item[@"bindings"]) {
                NSString *name = binding[@"name"];
                unsigned index = [binding[@"aid"] unsignedIntValue];
                if ([name isEqualToString:@"outbuf"]) [encoder setBuffer:output[variant] offset:guard atIndex:index];
                else if ([name isEqualToString:@"inputs"]) [encoder setBuffer:input offset:0 atIndex:index];
                else {
                    CHECK(name.length == 2 && [name characterAtIndex:0] == 'c');
                    unsigned bank = [name characterAtIndex:1] - '0';
                    CHECK(bank < 3);
                    [encoder setBuffer:constants[bank] offset:0 atIndex:index];
                }
            }
        }
        for (unsigned mode = 0; mode < 8; mode++) {
            uint32_t *inputs = input.contents;
            for (unsigned i = 0; i < count; i++) {
                switch (mode) {
                case 0: inputs[i] = i; break;
                case 1: inputs[i] = UINT32_MAX-i; break;
                case 2: inputs[i] = 0x80000000u+i-count/2; break;
                case 3: inputs[i] = i << 16; break;
                default: inputs[i] = random_word(); break;
                }
            }
            for (unsigned variant = 0; variant < 2; variant++) {
                memset(output[variant].contents, 0xa5, output[variant].length);
                id<MTLCommandBuffer> command = [queue commandBuffer];
                id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
                [encoder setComputePipelineState:pipelines[variant]];
                [encoder setBuffer:arguments[variant] offset:0 atIndex:0];
                for (unsigned bank = 0; bank < 3; bank++) [encoder useResource:constants[bank] usage:MTLResourceUsageRead];
                [encoder useResource:input usage:MTLResourceUsageRead];
                [encoder useResource:output[variant] usage:MTLResourceUsageWrite];
                [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];
                [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
                if (command.error) fprintf(stderr, "%s\n", command.error.description.UTF8String);
                CHECK(!command.error);
                const unsigned char *bytes = output[variant].contents;
                for (unsigned i = 0; i < guard; i++) {
                    CHECK(bytes[i] == 0xa5);
                    CHECK(bytes[output[variant].length-1-i] == 0xa5);
                }
            }
            const uint32_t *a = (const void *)((const char *)output[0].contents+guard);
            const uint32_t *b = (const void *)((const char *)output[1].contents+guard);
            const uint32_t *expected = constants[1].contents;
            for (unsigned i = 0; i < count; i++) {
                for (unsigned j = 0; j < stride; j++) {
                    unsigned source = stride == 13 ? j : (((inputs[i] >> 1)&1)*2 + ((~inputs[i])&1));
                    for (unsigned component = 0; component < 4; component++) {
                        NSUInteger at = ((NSUInteger)i*stride+j)*4+component;
                        CHECK(a[at] == b[at] && b[at] == expected[source*4+component]);
                        compared++;
                    }
                }
            }
        }
    } }
    printf("PASS %llu exact output components against original dispatchers and CPU values; two shader pairs, eight input patterns; guards intact\n", compared);
    return 0;
} }
