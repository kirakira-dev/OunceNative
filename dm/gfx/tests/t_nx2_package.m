#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p,unsigned stage,uint8_t key[8]){(void)p;(void)stage;memset(key,0,8);return 0;}
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
uint64_t nvn_new_serial(void){static uint64_t serial=90000;return ++serial;}
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=2)return 2;
    mtl_init();g_msl_dir=@(argv[1]);
    NSArray<NSString *> *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:g_msl_dir error:nil];
    NSMutableSet<NSString *> *loaded=[NSMutableSet set];unsigned reflections=0,functions=0,stages[6]={0};
    for(NSString *name in files){@autoreleasepool{
        if(![name hasSuffix:@"_b.json"])continue;
        NSString *path=[g_msl_dir stringByAppendingPathComponent:name];
        NSDictionary *j=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
        nvn_refl reflection;char error[256]="chain mismatch";
        if(!j||![j[@"chain"] isEqual:@DMSH_CHAIN]||nvn_refl_from_json(j,&reflection,error,sizeof error)){
            fprintf(stderr,"FAIL reflection %s: %s\n",name.UTF8String,j?error:"invalid json");return 1;}
        free(reflection.c1);int stage=stage_of(j[@"stage"]);if(stage<0)return 1;
        reflections++;stages[stage]++;
        NSString *identity=[NSString stringWithFormat:@"%@:%d:%@:%@",j[@"library_binary_sha256"],stage,j[@"entry"],j[@"vertex_fetch"]?:@""];
        if([loaded containsObject:identity])continue;
        [loaded addObject:identity];
        for(unsigned depth=0;depth<(j[@"entry_z"]?2u:1u);depth++){
            atomic_store(&g_depth_zero,depth);
            NvShader *shader=shader_load(name.stringByDeletingPathExtension,stage);
            if(!shader){fprintf(stderr,"FAIL library %s depth %u\n",name.UTF8String,depth);return 1;}
            res_remove(shader->c1buf);res_commit();functions++;
        }
    }}
    if(!reflections||!functions)return 1;
    printf("PASS %u reflections; %u distinct library/stage/fetch combinations; %u native function loads including both depth entries; stages %u/%u/%u/%u/%u/%u\n",reflections,(unsigned)loaded.count,functions,stages[0],stages[1],stages[2],stages[3],stages[4],stages[5]);return 0;
}}
