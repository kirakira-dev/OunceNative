// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); return 1; } } while(0)
int main(int argc,char **argv) { @autoreleasepool {
    CHECK(argc == 2);
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue=[device newCommandQueue];
    CHECK(device && queue);
    const unsigned count=65536,guard=256;
    id<MTLBuffer> c0=[device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    id<MTLBuffer> c1=[device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output=[device newBufferWithLength:count*4+2*guard options:MTLResourceStorageModeShared];
    memset(c0.contents,0,c0.length);
    uint8_t *input=c1.contents;
    for(unsigned i=0;i<count;i++)input[i]=(uint8_t)(i*73+19);
    unsigned compared=0;
    for(unsigned test=1;test<=10;test++) { @autoreleasepool {
        NSString *path=[NSString stringWithFormat:@"%s/%016x.metal",argv[1],test];
        NSError *error=nil;
        NSString *source=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
        CHECK(source);
        id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
        if(!library)fprintf(stderr,"%s\n",error.description.UTF8String);
        CHECK(library);
        id<MTLFunction> function=[library newFunctionWithName:@"main0"];
        id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:function error:&error];
        CHECK(pipeline);
        memset(output.contents,0xa5,output.length);
        id<MTLCommandBuffer> command=[queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:c0 offset:0 atIndex:0];
        const BOOL byteLoad=test==5 || test==6;
        if(byteLoad)[encoder setBuffer:c1 offset:0 atIndex:1];
        [encoder setBuffer:output offset:guard atIndex:byteLoad?2:1];
        [encoder dispatchThreadgroups:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
        [encoder endEncoding];[command commit];[command waitUntilCompleted];
        if(command.error)fprintf(stderr,"%s\n",command.error.description.UTF8String);
        CHECK(command.status==MTLCommandBufferStatusCompleted && !command.error);
        const uint32_t *actual=(const uint32_t *)((const uint8_t *)output.contents+guard);
        for(unsigned i=0;i<count;i++) {
            const BOOL sign=test==3 || test==4 || test==9 || test==10;
            const int value=byteLoad?input[test==5?3:i] : sign&&i>=32768?(int)i-65536:(int)i;
            float expected=(float)value;uint32_t bits;memcpy(&bits,&expected,4);
            if(actual[i]!=bits){fprintf(stderr,"case %u input %u: %08x != %08x\n",test,i,actual[i],bits);return 1;}
            compared++;
        }
        const uint8_t *bytes=output.contents;
        for(unsigned i=0;i<guard;i++)CHECK(bytes[i]==0xa5 && bytes[guard+count*4+i]==0xa5);
    }}
    printf("PASS %u exact GPU scalar values, ten native programs, output guards intact\n",compared);
    return 0;
}}
