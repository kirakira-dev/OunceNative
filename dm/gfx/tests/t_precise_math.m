#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) {fprintf(stderr,"FAIL %d %s\n",__LINE__,#x);return 1;} }while(0)
static uint32_t rng=0x7a595c13;static uint32_t next(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static uint32_t bits(float f){uint32_t u;memcpy(&u,&f,4);return u;}
static int isnan32(uint32_t u){return (u&0x7f800000)==0x7f800000&&(u&0x7fffff);}
static int isnan16(uint16_t u){return (u&0x7c00)==0x7c00&&(u&0x3ff);}
int main(int argc,char **argv){@autoreleasepool {
 CHECK(argc==3);id<MTLDevice> dev=MTLCreateSystemDefaultDevice();id<MTLCommandQueue> queue=[dev newCommandQueue];NSError *error=nil;
 const unsigned n=65536,words=n*32;id<MTLComputePipelineState> ps[2];id<MTLBuffer> output[2];
 for(unsigned j=0;j<2;j++){id<MTLLibrary> lib=[dev newLibraryWithURL:[NSURL fileURLWithPath:@(argv[j+1])] error:&error];CHECK(lib);ps[j]=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"test"] error:&error];CHECK(ps[j]);output[j]=[dev newBufferWithLength:words*4+64 options:MTLResourceStorageModeShared];}
 id<MTLBuffer> input=[dev newBufferWithLength:n*16 options:MTLResourceStorageModeShared];uint32_t *v=input.contents;
 const uint32_t edge[]={0,0x80000000,0x7f800000,0xff800000,0x7fc00001,0x7f800001,0xffc12345,1,0x80000001,0x007fffff,0x00800000,0x00800001,0x3f800000,0xbf800000,0x3f800001,0x3f7fffff,0x7f7fffff,0xff7fffff,0x33800000,0x34000000,0x3f000000,0xbf000000,0x4b000001,0xcb000001,0x00000400,0x84000000,0x3b800001,0x40800000,0xc0800000,0x3eaaaaab,0xbeaaaaab,0x3f333333};
 unsigned long exact=0,nans=0;double seconds[2]={0};
 for(unsigned mode=0;mode<8;mode++){@autoreleasepool {
  for(unsigned i=0;i<n;i++)for(unsigned k=0;k<4;k++){
   uint32_t u=next();if(mode%4==1)u=bits((float)(int32_t)u/134217728.0f);
   if(mode%4==2)u=edge[(i>>(k*4))%32];
   if(mode%4==3)u=k==0?0x3f800001:k==1?0x3f7ffffe:k==2?0xbf800000:((i%2)?0x80000000:0);
   v[i*4+k]=u;
  }
  if(mode==0){for(unsigned i=0;i<n;i++)v[i*4]=(next()&0xffff0000)|i;}
  for(unsigned j=0;j<2;j++){
   memset(output[j].contents,0xcd,output[j].length);id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLComputeCommandEncoder> en=[cb computeCommandEncoder];[en setComputePipelineState:ps[j]];[en setBuffer:input offset:0 atIndex:0];[en setBuffer:output[j] offset:32 atIndex:1];[en dispatchThreads:MTLSizeMake(n,1,1) threadsPerThreadgroup:MTLSizeMake(128,1,1)];[en endEncoding];[cb commit];[cb waitUntilCompleted];CHECK(!cb.error);seconds[j]+=cb.GPUEndTime-cb.GPUStartTime;unsigned char *g=output[j].contents;for(unsigned i=0;i<32;i++){CHECK(g[i]==0xcd);CHECK(g[output[j].length-1-i]==0xcd);}
  }
  const uint32_t *a=(void *)((char *)output[0].contents+32),*b=(void *)((char *)output[1].contents+32);
  for(unsigned i=0;i<words;i++){
   if((i%32)/4==2){for(unsigned k=0;k<2;k++){uint16_t x=a[i]>>(k*16),y=b[i]>>(k*16);if(x==y){exact++;continue;}if(isnan16(x)&&isnan16(y)){nans++;continue;}fprintf(stderr,"mode%u half[%u,%u] %04x != %04x\n",mode,i,k,x,y);return 2;}}
   else if(a[i]==b[i])exact++;
   else if(isnan32(a[i])&&isnan32(b[i]))nans++;
   else{fprintf(stderr,"mode%u float[%u] %08x != %08x\n",mode,i,a[i],b[i]);return 3;}
  }
 }}
 printf("PASS %lu bit-exact scalar/vector/matrix components; %lu differing NaN payloads with matching NaN class; signed zeros/infinities/subnormals and contraction-sensitive cancellation checked; GPU reference %.3f ms inline %.3f ms\n",exact,nans,seconds[0]*1000,seconds[1]*1000);return 0;
}}
