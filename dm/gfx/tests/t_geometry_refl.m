#import "../nvn/nvn_refl.h"
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);return 1;}}while(0)
int main(void){@autoreleasepool{
    NSMutableDictionary *geometry=[@{@"version":@1,@"vertex_stride":@608,@"input_buffer":@20,@"primitive_buffer":@21,
        @"input":@"triangles",@"input_vertices":@3,@"output":@"triangles",@"max_vertices":@12,@"max_primitives":@10,
        @"inputs":@[@0,@3,@31],@"outputs":@[@0,@1],@"layer":@NO,@"input_point_size":@YES,@"output_point_size":@NO,
        @"written_position":@"xyzw",@"unresolved_position_default":@NO} mutableCopy];
    NSMutableDictionary *json=[@{@"route":@"B",@"stage":@"geometry",@"entry":@"main0",@"entry_z":@"main0_z",
        @"bindings":@[],@"vertex_inputs":@[],@"nx2_geometry":geometry} mutableCopy];
    nvn_refl reflection;char error[256];CHECK(!nvn_refl_from_json(json,&reflection,error,sizeof error));
    CHECK(reflection.geometry.valid&&reflection.geometry.inputs==0x80000009u&&reflection.geometry.outputs==3);
    CHECK(reflection.geometry.input_vertices==3&&reflection.geometry.max_vertices==12&&reflection.geometry.max_primitives==10&&reflection.geometry.input_point_size);
    unsigned rejected=0;
    NSArray *bad=@[@[@"version",@2],@[@"vertex_stride",@604],@[@"input_buffer",@0],@[@"primitive_buffer",@20],
        @[@"input",@"points"],@[@"input_vertices",@2],@[@"output",@"lines"],@[@"max_vertices",@129],
        @[@"max_primitives",@9],@[@"inputs",@[@0,@0]],@[@"outputs",@[@32]],@[@"inputs",@[@(-1)]],
        @[@"input_vertices",@2.5],@[@"input_point_size",@2],@[@"written_position",@"xy"],@[@"unresolved_position_default",@YES]];
    for(NSArray *change in bad){id old=geometry[change[0]];geometry[change[0]]=change[1];CHECK(nvn_refl_from_json(json,&reflection,error,sizeof error));geometry[change[0]]=old;rejected++;}
    json[@"stage"]=@"vertex";CHECK(nvn_refl_from_json(json,&reflection,error,sizeof error));rejected++;json[@"stage"]=@"geometry";
    geometry[@"written_position"]=@"xy";geometry[@"unresolved_position_default"]=@YES;CHECK(!nvn_refl_from_json(json,&reflection,error,sizeof error));CHECK(reflection.geometry.unresolved_position);
    for(NSString *value in @[@"xyzq",@"xx",@"yx"]){geometry[@"written_position"]=value;CHECK(nvn_refl_from_json(json,&reflection,error,sizeof error));rejected++;}
    geometry[@"written_position"]=@"xyzw";geometry[@"unresolved_position_default"]=@NO;geometry[@"input"]=@"points";geometry[@"input_vertices"]=@1;geometry[@"output"]=@"points";geometry[@"max_vertices"]=geometry[@"max_primitives"]=@1;
    CHECK(!nvn_refl_from_json(json,&reflection,error,sizeof error));CHECK(reflection.geometry.output_points);
    printf("PASS geometry reflection contracts and %u malformed layout/stage/component rejections\n",rejected);return 0;
}}
