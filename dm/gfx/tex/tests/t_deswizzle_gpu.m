// Compare the independent CPU and Metal deswizzlers for both GOB orderings.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../nvn_deswizzle_gpu.h"
#include <stdio.h>
#include <string.h>
int main(void) { @autoreleasepool {
 id<MTLDevice> dev=MTLCreateSystemDefaultDevice();
 id<MTLCommandQueue> q=[dev newCommandQueue];
 if(nvn_deswz_gpu_init(dev)) return 2;
 nvn_texdesc cases[]={
  {.target=1,.format=1,.width=64,.height=8,.depth=1,.levels=1},
  {.target=1,.format=0x25,.width=100,.height=37,.depth=1,.levels=4},
  {.target=2,.format=0x29,.width=32,.height=32,.depth=32,.levels=5},
  {.target=9,.format=0x4d,.width=64,.height=64,.depth=12,.levels=4}
 };
 unsigned checks=0;
 for(unsigned mode=0;mode<2;mode++) for(unsigned c=0;c<4;c++) {
  nvn_texdesc d=cases[c]; d.native_tiling=mode;
  nvn_texlayout l; nvn_tex_layout(&d,&l);
  id<MTLBuffer> src=[dev newBufferWithLength:l.size options:MTLResourceStorageModeShared];
  uint8_t *sp=src.contents; for(uint64_t i=0;i<l.size;i++) sp[i]=(i*37+(i>>7)*91+(i>>13))&255;
  for(unsigned layer=0;layer<l.layers;layer++) for(unsigned level=0;level<d.levels;level++) {
   uint32_t rb,rows,slices,bpb; uint64_t base; unsigned th,td;
   if(nvn_deswizzle_geom(&d,level,layer,&rb,&rows,&slices,&base,&th,&td,&bpb)) return 3;
   size_t pitch=(rb+255)&~255,size=pitch*rows*slices;
   uint8_t *want=calloc(size,1);
   if(nvn_deswizzle(&d,level,layer,src.contents,want,pitch)) return 4;
   id<MTLBuffer> out=[dev newBufferWithLength:size options:MTLResourceStorageModeShared];
   memset(out.contents,0,size);
   id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLComputeCommandEncoder> en=[cb computeCommandEncoder];
   if(nvn_deswz_gpu_encode(en,src,0,&d,level,layer,out,0,pitch)) return 5;
   [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
   if(cb.error || memcmp(want,out.contents,size)) { fprintf(stderr,"FAIL mode%u case%u layer%u level%u\n",mode,c,layer,level); return 6; }
   free(want);checks++;
  }
 }
 printf("PASS: %u CPU/Metal deswizzle comparisons, NX1 and NX2, 2D/3D/cube arrays/mip levels\n",checks);
 return 0;
}}
